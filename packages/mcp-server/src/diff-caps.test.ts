import { describe, it, after, afterEach, mock } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, mkdir, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Bridge, capText } from './bridge.js';

/**
 * Caps by explicit path (KL-7). A named list of page-derived strings is
 * shortened on ingest, import and restore. Nothing is walked: values that are
 * long on purpose are never touched.
 */

const MARK = '… [truncated]';

type Writer = { drain(): Promise<void> };
type Diff = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
type Priv = {
  pendingQueue: Diff[];
  queueWriter: Writer;
  statusWriter: Writer;
  processDiffBatch(payload: unknown): Promise<void>;
  restoreQueue(): Promise<void>;
  importSession(p: string): Promise<{ imported: number; skipped: number; warnings: string[] }>;
};

const cleanup: string[] = [];
after(async () => {
  for (const d of cleanup) await rm(d, { recursive: true, force: true });
});
afterEach(() => mock.restoreAll());

async function fresh(): Promise<{ root: string; p: Priv }> {
  const base = await mkdtemp(join(tmpdir(), 'nco-caps-'));
  cleanup.push(base);
  const root = join(base, 'proj');
  await mkdir(root, { recursive: true });
  return { root, p: new Bridge(root) as unknown as Priv };
}

function base(id: string, element: Diff = {}, changes?: Diff[]): Diff {
  return {
    id,
    timestamp: '2026-11-09T00:00:00.000Z',
    batchId: 'batch-20261109-000000-aaaa',
    element: {
      selector: '#a',
      tagName: 'div',
      sourceFile: 'src/App.tsx',
      sourceLine: 1,
      attributes: {},
      boundingRect: { x: 0, y: 0, width: 1, height: 1, top: 0, right: 1, bottom: 1, left: 0 },
      ...element,
    },
    changes: changes ?? [{ property: 'color', fromValue: '#000', toValue: '#fff' }],
    context: { url: 'http://localhost:3000', viewport: { width: 1280, height: 800 }, tabId: 't1' },
    status: 'pending',
    sourceVerified: false,
  };
}

const capture = () => mock.method(console, 'error', () => {});

async function viaIngest(diffs: Diff[]): Promise<Diff[]> {
  const { p } = await fresh();
  capture();
  await p.processDiffBatch({ diffs, batchId: 'batch-20261109-000000-aaaa' });
  await p.queueWriter.drain();
  await p.statusWriter.drain();
  return p.pendingQueue;
}

async function viaImport(diffs: Diff[]): Promise<Diff[]> {
  const { root, p } = await fresh();
  capture();
  await writeFile(join(root, 's.json'), JSON.stringify({ diffs }));
  await p.importSession('s.json');
  await p.queueWriter.drain();
  await p.statusWriter.drain();
  return p.pendingQueue;
}

async function viaRestore(diffs: Diff[]): Promise<Diff[]> {
  const { root, p } = await fresh();
  capture();
  await mkdir(join(root, '.nco-web-editor'), { recursive: true });
  await writeFile(join(root, '.nco-web-editor', 'pending-queue.json'), JSON.stringify({ version: '0', diffs }));
  await p.restoreQueue();
  return p.pendingQueue;
}

const paths: [string, (d: Diff[]) => Promise<Diff[]>][] = [
  ['ingest', viaIngest],
  ['import', viaImport],
  ['restore', viaRestore],
];

const x = (n: number): string => 'x'.repeat(n);

describe('capText', () => {
  it('leaves a string at the cap unchanged', () => {
    assert.equal(capText(x(10), 10), x(10));
    assert.equal(capText('', 10), '');
  });

  it('cuts a string just over the cap and appends the marker', () => {
    assert.equal(capText(x(11), 10), x(10) + MARK);
  });

  it('is idempotent', () => {
    const once = capText(x(500), 10);
    assert.equal(capText(once, 10), once);
  });

  it('never leaves a lone surrogate, and a second pass changes nothing', () => {
    // 9 units then a pair: the cut at 10 would split the pair.
    const s = x(9) + '\u{1F600}' + x(5);
    const once = capText(s, 10);
    assert.equal(once, x(9) + MARK);
    assert.equal(capText(once, 10), once);
    assert.ok(!/[\ud800-\udbff](?![\udc00-\udfff])/.test(once));
  });

  it('keeps a pair that ends exactly at the cap', () => {
    const s = x(8) + '\u{1F600}' + x(5);
    assert.equal(capText(s, 10), x(8) + '\u{1F600}' + MARK);
  });
});

for (const [name, run] of paths) {
  describe(`caps on ${name}`, () => {
    it('element.textContent: 201 is capped at 200, 200 is unchanged', async () => {
      const q = await run([
        base('over', { textContent: x(201) }),
        base('at', { textContent: x(200) }),
      ]);
      assert.equal(q.find((d) => d.id === 'over')!.element.textContent, x(200) + MARK);
      assert.equal(q.find((d) => d.id === 'at')!.element.textContent, x(200));
    });

    it('element.label: 201 is capped at 200, 200 is unchanged', async () => {
      const q = await run([base('over', { label: x(201) }), base('at', { label: x(200) })]);
      assert.equal(q.find((d) => d.id === 'over')!.element.label, x(200) + MARK);
      assert.equal(q.find((d) => d.id === 'at')!.element.label, x(200));
    });

    it('element.assetPath over 1024 removes both assetPath and label; 1024 keeps both', async () => {
      const q = await run([
        base('over', { assetPath: x(1025), label: 'logo' }),
        base('at', { assetPath: x(1024), label: 'logo' }),
      ]);
      const over = q.find((d) => d.id === 'over')!.element;
      assert.ok(!('assetPath' in over));
      assert.ok(!('label' in over));
      const at = q.find((d) => d.id === 'at')!.element;
      assert.equal(at.assetPath, x(1024));
      assert.equal(at.label, 'logo');
    });

    it('element.attributes: values over 2048 are capped; 2048, a 600-char class and many keys are not', async () => {
      const many: Record<string, string> = {};
      for (let i = 0; i < 300; i++) many[`data-k${i}`] = 'v';
      const q = await run([
        base('over', { attributes: { src: x(2049), class: x(600) } }),
        base('at', { attributes: { src: x(2048) } }),
        base('many', { attributes: many }),
      ]);
      const over = q.find((d) => d.id === 'over')!.element.attributes;
      assert.equal(over.src, x(2048) + MARK);
      assert.equal(over.class, x(600));
      assert.equal(q.find((d) => d.id === 'at')!.element.attributes.src, x(2048));
      assert.equal(Object.keys(q.find((d) => d.id === 'many')!.element.attributes).length, 300);
    });

    it('changes[].source.sourceHref: 2049 is capped, 2048 and null are unchanged', async () => {
      const rule = (href: string | null): Diff => ({
        selector: '.a',
        sourceHref: href,
        sourceIndex: 0,
        specificity: [0, 1, 0],
        isInline: false,
      });
      const change = (href: string | null): Diff => ({
        property: 'color',
        fromValue: 'a',
        toValue: 'b',
        source: rule(href),
      });
      const q = await run([
        base('over', {}, [change(x(2049))]),
        base('at', {}, [change(x(2048))]),
        base('null', {}, [change(null)]),
      ]);
      assert.equal(q.find((d) => d.id === 'over')!.changes[0].source.sourceHref, x(2048) + MARK);
      assert.equal(q.find((d) => d.id === 'at')!.changes[0].source.sourceHref, x(2048));
      assert.equal(q.find((d) => d.id === 'null')!.changes[0].source.sourceHref, null);
    });

    it('values that are long on purpose are not touched', async () => {
      const long = x(5000);
      const diff = base('long', {}, [
        {
          property: 'color',
          fromValue: 'a',
          toValue: 'b',
          source: { selector: long, sourceHref: null, sourceIndex: 0, specificity: [0, 0, 1], isInline: false },
        },
      ]);
      diff.insertChanges = [
        {
          type: 'insert',
          tagName: 'div',
          insertIndex: 0,
          containerSelector: '#root',
          prevSibling: null,
          nextSibling: null,
          sameSiblingSource: true,
          crossFileInsertion: false,
          initialStyles: [],
          textContent: long,
          outerHTML: long,
        },
      ];
      const [kept] = await run([diff]);
      assert.equal(kept.changes[0].source.selector, long);
      assert.equal(kept.insertChanges[0].textContent, long);
      assert.equal(kept.insertChanges[0].outerHTML, long);
    });

    it('a 3000-char selector drops the diff, it is not shortened', async () => {
      const q = await run([base('bad', { selector: x(3000) }), base('good')]);
      assert.deepEqual(q.map((d) => d.id), ['good']);
    });
  });
}

describe('caps are stable across a restore', () => {
  it('a restored over-cap value is capped, and a second restore changes nothing', async () => {
    const first = await viaRestore([
      base('a', { textContent: x(500), label: x(300), attributes: { src: x(4000) } }),
    ]);
    assert.equal(first[0].element.textContent, x(200) + MARK);
    assert.equal(first[0].element.label, x(200) + MARK);
    assert.equal(first[0].element.attributes.src, x(2048) + MARK);

    const second = await viaRestore(JSON.parse(JSON.stringify(first)));
    assert.deepEqual(second, first);
  });

  it('the persisted queue file carries the capped value', async () => {
    const { root, p } = await fresh();
    capture();
    await p.processDiffBatch({ diffs: [base('a', { textContent: x(500) })], batchId: 'batch-20261109-000000-aaaa' });
    await p.queueWriter.drain();
    const onDisk = JSON.parse(await readFile(join(root, '.nco-web-editor', 'pending-queue.json'), 'utf-8'));
    assert.equal(onDisk.diffs[0].element.textContent, x(200) + MARK);
  });
});
