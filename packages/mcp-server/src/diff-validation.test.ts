import { describe, it, after, afterEach, mock } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Bridge } from './bridge.js';

/**
 * Per-field diff validation (KL-7). One rule set, three entry points: live
 * ingest, session import and queue restore. A diff that breaks a rule is
 * dropped whole, and the log names the field path, never the value.
 */

type Writer = { drain(): Promise<void> };
type Priv = {
  pendingQueue: { id: string }[];
  queueWriter: Writer;
  statusWriter: Writer;
  processDiffBatch(payload: unknown): Promise<void>;
  restoreQueue(): Promise<void>;
  importSession(p: string): Promise<{ imported: number; skipped: number; warnings: string[] }>;
};
type Diff = Record<string, unknown>;

const cleanup: string[] = [];
after(async () => {
  for (const d of cleanup) await rm(d, { recursive: true, force: true });
});
afterEach(() => mock.restoreAll());

async function fresh(): Promise<{ root: string; p: Priv }> {
  const base = await mkdtemp(join(tmpdir(), 'nco-dv-'));
  cleanup.push(base);
  const root = join(base, 'proj');
  await mkdir(root, { recursive: true });
  return { root, p: new Bridge(root) as unknown as Priv };
}

function base(id: string): Diff {
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
    },
    changes: [{ property: 'color', fromValue: '#000', toValue: '#fff' }],
    context: { url: 'http://localhost:3000', viewport: { width: 1280, height: 800 }, tabId: 't1' },
    status: 'pending',
    sourceVerified: false,
  };
}

const insert = (extra: Diff = {}): Diff => ({
  type: 'insert',
  tagName: 'div',
  insertIndex: 0,
  containerSelector: '#root',
  prevSibling: null,
  nextSibling: null,
  sameSiblingSource: true,
  crossFileInsertion: false,
  initialStyles: [],
  ...extra,
});

const attr = (extra: Diff = {}): Diff => ({
  type: 'attribute',
  attribute: 'src',
  fromValue: '/images/a.png',
  toValue: '/images/b.png',
  ...extra,
});

// ---------------------------------------------------------------------------
// The three entry points, each reduced to "which of these ids ended up queued"
// ---------------------------------------------------------------------------

interface Outcome {
  kept: string[];
  log: string;
  warnings: string[];
}

const capture = () => mock.method(console, 'error', () => {});
const logText = (m: ReturnType<typeof capture>): string =>
  m.mock.calls.map((c) => c.arguments.join(' ')).join('\n');

async function viaIngest(diffs: Diff[]): Promise<Outcome> {
  const { p } = await fresh();
  const logged = capture();
  await p.processDiffBatch({ diffs, batchId: 'batch-20261109-000000-aaaa' });
  await p.queueWriter.drain();
  await p.statusWriter.drain();
  return { kept: p.pendingQueue.map((d) => d.id), log: logText(logged), warnings: [] };
}

async function viaImport(diffs: Diff[]): Promise<Outcome> {
  const { root, p } = await fresh();
  const logged = capture();
  await writeFile(join(root, 's.json'), JSON.stringify({ diffs }));
  const r = await p.importSession('s.json');
  await p.queueWriter.drain();
  await p.statusWriter.drain();
  return { kept: p.pendingQueue.map((d) => d.id), log: logText(logged), warnings: r.warnings };
}

async function viaRestore(diffs: Diff[]): Promise<Outcome> {
  const { root, p } = await fresh();
  const logged = capture();
  await mkdir(join(root, '.nco-web-editor'), { recursive: true });
  await writeFile(join(root, '.nco-web-editor', 'pending-queue.json'), JSON.stringify({ version: '0', diffs }));
  await p.restoreQueue();
  return { kept: p.pendingQueue.map((d) => d.id), log: logText(logged), warnings: [] };
}

const paths: [string, (d: Diff[]) => Promise<Outcome>][] = [
  ['ingest', viaIngest],
  ['import', viaImport],
  ['restore', viaRestore],
];

// ---------------------------------------------------------------------------
// Positive corpus: everything the extension legitimately sends stays
// ---------------------------------------------------------------------------

const corpus: Diff[] = [
  { ...base('property'), changes: [{ property: 'color', fromValue: '#000', toValue: '#fff', toToken: '--c', unit: 'px' }] },
  { ...base('empty-to-value'), changes: [{ property: 'color', fromValue: '', toValue: '' }] },
  { ...base('no-optional-strings'), changes: [{ property: 'color', toValue: 'red' }] },
  {
    ...base('attribute-pending'),
    attributeChanges: [attr({ pendingUpload: { filename: 'b.png', mimeType: 'image/png', sizeBytes: 3 } })],
  },
  {
    // pendingUpload.filename is not validated: assetFilename copes with any type.
    ...base('attribute-numeric-filename'),
    attributeChanges: [attr({ pendingUpload: { filename: 42, mimeType: 'image/png', sizeBytes: 3 } })],
  },
  { ...base('attribute-no-from'), attributeChanges: [{ type: 'attribute', attribute: 'alt', toValue: 'x' }] },
  {
    ...base('insert-component'),
    insertChanges: [insert({ componentInsert: { name: 'Card' }, outerHTML: '<div>x</div>' })],
  },
  { ...base('insert-plain'), insertChanges: [insert()] },
  { ...base('text'), textChanges: [{ type: 'text', fromText: 'a', toText: 'b', toHtml: '<b>b</b>' }] },
  {
    ...base('reorder'),
    reorderChanges: [{ type: 'reorder', containerSelector: '#r', fromIndex: 0, toIndex: 1, siblingAnchors: [{ selector: '#x' }] }],
  },
  { ...base('group'), groupChanges: [{ type: 'group', containerSelector: '#r', wrapperTag: 'div', childUids: ['u1'] }] },
  { ...base('reparent'), reparentChanges: [{ type: 'reparent', fromContainer: '#a', toContainer: '#b', toIndex: 0 }] },
  {
    ...base('stylesheet'),
    stylesheetChanges: [{ type: 'stylesheet', selector: '.x', sourceFile: 'src/a.css', declarations: [{ property: 'color', value: 'red' }] }],
  },
  {
    ...base('script'),
    scriptChanges: [
      {
        type: 'script-behavior',
        behavior: 'parallax-scroll',
        targetSelector: '#hero',
        sourceFile: 'src/App.tsx',
        params: { axis: 'y', strengthFactor: 0.5, throttle: 'raf', scrollSource: 'window' },
        respectsReducedMotion: true,
        descriptor: 'd',
        reason: 'r',
      },
    ],
  },
  {
    ...base('related'),
    relatedChanges: [
      { element: (base('r') as { element: Diff }).element, changes: [{ property: 'isolation', fromValue: '', toValue: 'isolate' }], reason: 'blend' },
    ],
  },
  {
    ...base('layout-containers'),
    layoutContainers: [{ selector: '#r', childUids: ['u1', 'u2'], direction: 'row' }],
  },
  {
    ...base('source-null-href'),
    changes: [
      {
        property: 'color',
        fromValue: '#000',
        toValue: '#fff',
        source: { selector: '.x', sourceHref: null, sourceIndex: 0, specificity: [0, 1, 0], isInline: true },
      },
    ],
  },
  (() => {
    const legacy = base('legacy-no-batch');
    delete legacy.batchId;
    return legacy;
  })(),
  { ...base('empty-changes'), changes: [] },
  {
    ...base('selector-at-cap'),
    element: { ...(base('x').element as Diff), selector: 'a'.repeat(2048) },
  },
];

describe('diff validation: what stays (KL-7)', () => {
  for (const [name, run] of paths) {
    it(`${name}: every legitimate diff shape is kept`, async () => {
      const out = await run(corpus.map((d) => structuredClone(d)));
      assert.deepEqual(
        out.kept.slice().sort(),
        corpus.map((d) => d.id as string).sort(),
        `dropped: ${out.log}`,
      );
    });
  }
});

// ---------------------------------------------------------------------------
// Negatives: one per rule. Each carries a marker the log must not repeat.
// ---------------------------------------------------------------------------

interface Negative {
  name: string;
  /** The field path the log has to name. */
  path: string;
  /** A value injected into the diff that must never reach the log. */
  marker: string;
  make(marker: string): Diff;
}

const withChange = (c: Diff): Diff => ({ ...base('bad'), changes: [c] });
const withAttr = (a: unknown): Diff => ({ ...base('bad'), attributeChanges: [a] });
const withInsert = (i: unknown): Diff => ({ ...base('bad'), insertChanges: [i] });

const negatives: Negative[] = [
  { name: 'numeric toValue', path: 'changes[0].toValue', marker: '31337', make: (m) => withChange({ property: 'color', fromValue: '', toValue: Number(m) }) },
  { name: 'object toValue', path: 'changes[0].toValue', marker: 'LEAKMARKER', make: (m) => withChange({ property: 'color', fromValue: '', toValue: { v: m } }) },
  { name: 'missing toValue', path: 'changes[0].toValue', marker: 'LEAKMARKER', make: (m) => withChange({ property: 'color', fromValue: m }) },
  { name: 'numeric property', path: 'changes[0].property', marker: '31337', make: (m) => withChange({ property: Number(m), fromValue: '', toValue: 'x' }) },
  { name: 'numeric fromValue', path: 'changes[0].fromValue', marker: '31337', make: (m) => withChange({ property: 'color', fromValue: Number(m), toValue: 'x' }) },
  { name: 'object toToken', path: 'changes[0].toToken', marker: 'LEAKMARKER', make: (m) => withChange({ property: 'color', fromValue: '', toValue: 'x', toToken: { t: m } }) },
  { name: 'numeric unit', path: 'changes[0].unit', marker: '31337', make: (m) => withChange({ property: 'color', fromValue: '', toValue: 'x', unit: Number(m) }) },
  { name: 'a bad entry after a good one', path: 'changes[1].toValue', marker: '31337', make: (m) => ({ ...base('bad'), changes: [{ property: 'a', toValue: 'x' }, { property: 'b', toValue: Number(m) }] }) },
  { name: 'string entry in attributeChanges', path: 'attributeChanges[0]', marker: 'LEAKMARKER', make: (m) => withAttr(m) },
  { name: 'attributeChanges that is not an array', path: 'attributeChanges', marker: 'LEAKMARKER', make: (m) => ({ ...base('bad'), attributeChanges: { k: m } }) },
  { name: 'numeric attribute', path: 'attributeChanges[0].attribute', marker: '31337', make: (m) => withAttr(attr({ attribute: Number(m) })) },
  { name: 'numeric attribute toValue', path: 'attributeChanges[0].toValue', marker: '31337', make: (m) => withAttr(attr({ toValue: Number(m) })) },
  { name: 'numeric attribute fromValue', path: 'attributeChanges[0].fromValue', marker: '31337', make: (m) => withAttr(attr({ fromValue: Number(m) })) },
  { name: 'string pendingUpload', path: 'attributeChanges[0].pendingUpload', marker: 'LEAKMARKER', make: (m) => withAttr(attr({ pendingUpload: m })) },
  { name: 'null pendingUpload', path: 'attributeChanges[0].pendingUpload', marker: 'LEAKMARKER', make: () => withAttr(attr({ pendingUpload: null, note: 'LEAKMARKER' })) },
  { name: 'insertChanges that is an empty object', path: 'insertChanges', marker: 'LEAKMARKER', make: (m) => ({ ...base('bad'), insertChanges: { k: m } }) },
  { name: 'string entry in insertChanges', path: 'insertChanges[0]', marker: 'LEAKMARKER', make: (m) => withInsert(m) },
  { name: 'numeric outerHTML', path: 'insertChanges[0].outerHTML', marker: '31337', make: (m) => withInsert(insert({ outerHTML: Number(m) })) },
  { name: 'initialStyles that is not an array', path: 'insertChanges[0].initialStyles', marker: 'LEAKMARKER', make: (m) => withInsert(insert({ initialStyles: { k: m } })) },
  {
    name: 'a selector over 2048 chars',
    path: 'element.selector',
    marker: 'LEAKMARKER',
    make: (m) => ({ ...base('bad'), element: { ...(base('x').element as Diff), selector: m + 'a'.repeat(2100) } }),
  },
];

describe('diff validation: what is dropped (KL-7)', () => {
  for (const [name, run] of paths) {
    describe(name, () => {
      for (const neg of negatives) {
        it(`drops a diff with ${neg.name}, names the field, and does not log the value`, async () => {
          const out = await run([neg.make(neg.marker), base('good')]);
          assert.deepEqual(out.kept, ['good'], 'the bad diff goes, its neighbour stays');
          assert.ok(out.log.includes(neg.path), `log should name ${neg.path}, got: ${out.log}`);
          assert.ok(out.log.includes('Skipped diff bad'), `log should carry the diff id, got: ${out.log}`);
          assert.ok(!out.log.includes(neg.marker), 'the injected value must not reach the log');
          if (name === 'import') {
            const w = out.warnings.join('\n');
            assert.ok(w.includes(neg.path), `warning should name ${neg.path}, got: ${w}`);
            assert.ok(!w.includes(neg.marker), 'the injected value must not reach the warnings');
          }
        });
      }
    });
  }

  it('a diff with no id is logged without stringifying whatever stands in for it', async () => {
    // An own `toString` makes String() throw. The id of a bad diff is logged
    // without it, and the rest of the batch still goes through.
    const hostile = { ...base('x'), id: { toString: 1 } };
    const out = await viaIngest([hostile, base('good')]);
    assert.deepEqual(out.kept, ['good']);
    assert.ok(out.log.includes('(no id)'));
  });
});

describe('diff validation: restore logging (KL-7)', () => {
  it('logs at most five reasons, then counts the rest', async () => {
    const bad = (i: number): Diff => ({ ...base(`bad${i}`), changes: [{ property: 'p', toValue: 31337 }] });
    const out = await viaRestore([...Array.from({ length: 9 }, (_, i) => bad(i)), base('good')]);
    assert.deepEqual(out.kept, ['good']);
    const reasons = out.log.split('\n').filter((l) => l.includes('Skipped diff bad'));
    assert.equal(reasons.length, 5);
    assert.ok(out.log.includes('Skipped 9 invalid entries'), out.log);
  });
});
