import { describe, it, after, afterEach, mock } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readdir, readFile, writeFile, mkdir, symlink, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Bridge } from './bridge.js';

/**
 * The queue file and the status file each have one coalescing writer, and
 * shutdown drains both before the lock is released (KL-7). Every ordering here
 * is forced by gating on promises, never by waiting.
 */

type Writer = { schedule(): void; drain(): Promise<void> };
type Priv = {
  pendingQueue: unknown[];
  pendingNotes: unknown[];
  queueWriter: Writer;
  statusWriter: Writer;
  persistQueue(): Promise<void>;
  writeStatusFile(): Promise<void>;
  extractDataUrls(d: unknown): Promise<unknown>;
  handleDiffBatch(ws: unknown, payload: unknown): void;
  processDiffBatch(payload: unknown): Promise<void>;
  restoreQueue(): Promise<void>;
  importSession(p: string): Promise<{ imported: number; skipped: number; warnings: string[] }>;
  acknowledgeDiff(id: string): boolean;
  acquireLock(): Promise<boolean>;
  safePersistQueue(): void;
  safeWriteStatusFile(): void;
  wss: unknown;
  closeTimeoutMs: number;
};

const cleanup: string[] = [];
after(async () => {
  for (const d of cleanup) await rm(d, { recursive: true, force: true });
});

async function fresh(): Promise<{ root: string; base: string; b: Bridge; p: Priv; queuePath: string; statusPath: string }> {
  const base = await mkdtemp(join(tmpdir(), 'nco-qw-'));
  cleanup.push(base);
  const root = join(base, 'proj');
  await mkdir(root, { recursive: true });
  const b = new Bridge(root);
  const p = b as unknown as Priv & { statusFilePath: string };
  return {
    root,
    base,
    b,
    p,
    queuePath: join(root, '.nco-web-editor', 'pending-queue.json'),
    statusPath: p.statusFilePath,
  };
}

/** A promise and the function that resolves it. */
function gate(): { promise: Promise<void>; open: () => void } {
  let open!: () => void;
  const promise = new Promise<void>((r) => {
    open = r;
  });
  return { promise, open };
}

/**
 * Replace the write body with one whose first call runs the real body and then
 * waits at a gate; later calls run straight through. `started` resolves once
 * the first write has landed and is held at the gate.
 */
function gateFirstWrite(
  p: Priv,
  method: 'persistQueue' | 'writeStatusFile',
): { started: Promise<void>; release: () => void; calls: () => number } {
  const original = p[method].bind(p) as () => Promise<void>;
  const started = gate();
  const hold = gate();
  let calls = 0;
  p[method] = async () => {
    calls++;
    await original();
    if (calls === 1) {
      started.open();
      await hold.promise;
    }
  };
  return { started: started.promise, release: hold.open, calls: () => calls };
}

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

const noteTexts = async (path: string): Promise<string[]> =>
  (JSON.parse(await readFile(path, 'utf-8')).notes as { text: string }[]).map((n) => n.text);

function validDiff(id: string): Record<string, unknown> {
  return {
    id,
    timestamp: '2026-11-09T00:00:00.000Z',
    element: { selector: '#a', tagName: 'div' },
    changes: [],
    context: { tabId: 't1' },
    status: 'pending',
    sourceVerified: false,
  };
}

const fakeWs = { readyState: 0, OPEN: 1, send() {} };

describe('queue file writer (KL-7)', () => {
  afterEach(() => mock.restoreAll());

  it('(i) a request during an in-flight write produces exactly one more write, and the file holds the latest state', async () => {
    const { p, queuePath } = await fresh();
    mock.method(console, 'error', () => {});
    p.pendingNotes = [{ text: 'a' }];
    const g = gateFirstWrite(p, 'persistQueue');

    p.safePersistQueue();
    await g.started;
    // Four requests while the first write is held: they coalesce into one.
    p.pendingNotes = [{ text: 'b' }];
    p.safePersistQueue();
    p.safePersistQueue();
    p.safePersistQueue();
    p.safePersistQueue();
    g.release();
    await p.queueWriter.drain();

    assert.equal(g.calls(), 2);
    assert.deepEqual(await noteTexts(queuePath), ['b']);
  });

  it('(ii) emptying the queue during a persist leaves no queue file', async () => {
    const { p, queuePath } = await fresh();
    mock.method(console, 'error', () => {});
    p.pendingNotes = [{ text: 'a' }];
    const g = gateFirstWrite(p, 'persistQueue');

    p.safePersistQueue();
    await g.started;
    assert.equal(await exists(queuePath), true);
    p.pendingNotes = [];
    p.safePersistQueue();
    g.release();
    await p.queueWriter.drain();

    assert.equal(g.calls(), 2);
    assert.equal(await exists(queuePath), false);
  });

  it('(iv) after a rejected write the next write lands, and stop() settles', async () => {
    const { p, b, queuePath } = await fresh();
    const logged = mock.method(console, 'error', () => {});
    const original = p.persistQueue.bind(p);
    let calls = 0;
    p.persistQueue = async () => {
      calls++;
      if (calls === 1) throw new Error('disk full');
      await original();
    };
    p.pendingNotes = [{ text: 'a' }];

    p.safePersistQueue();
    await p.queueWriter.drain();
    assert.equal(await exists(queuePath), false);
    assert.ok(
      logged.mock.calls.some((c) => String(c.arguments[0]).includes('Failed to write queue file: disk full')),
      'the failure is logged',
    );

    p.safePersistQueue();
    await p.queueWriter.drain();
    assert.deepEqual(await noteTexts(queuePath), ['a']);
    await b.stop();
  });

  it('(ix) a .nco-web-editor link created after construction makes persist write nothing outside', async () => {
    const { root, base, p } = await fresh();
    mock.method(console, 'error', () => {});
    const outside = join(base, 'outside');
    await mkdir(outside, { recursive: true });
    try {
      await symlink(outside, join(root, '.nco-web-editor'), 'dir');
    } catch {
      return; // no symlink support here
    }
    p.pendingNotes = [{ text: 'a' }];

    await assert.rejects(() => p.persistQueue(), /escapes project after symlink resolution/);
    p.safePersistQueue();
    await p.queueWriter.drain();
    assert.deepEqual(await readdir(outside), []);
  });
});

describe('status file writer (KL-7)', () => {
  afterEach(() => mock.restoreAll());

  it('(iii) overlapping status requests log no ENOENT, and pending_count equals the queue length', async () => {
    const { p, statusPath } = await fresh();
    const logged = mock.method(console, 'error', () => {});
    p.pendingQueue = [{ id: 'x' }, { id: 'y' }];

    // Unserialised, two overlapping writes share one .tmp name and the second
    // rename finds it gone. Repeat to make that reliable.
    for (let i = 0; i < 25; i++) {
      p.safeWriteStatusFile();
      p.safeWriteStatusFile();
      await Promise.resolve();
      p.safeWriteStatusFile();
      await p.statusWriter.drain();
    }

    assert.equal(
      logged.mock.calls.some((c) => String(c.arguments[0]).includes('ENOENT')),
      false,
    );
    const text = await readFile(statusPath, 'utf-8');
    assert.match(text, /^status: active$/m);
    assert.match(text, /^pending_count: 2$/m);
  });

  it('(viii) the shutdown status is the last one written, even with an active request pending', async () => {
    const { b, p, statusPath } = await fresh();
    mock.method(console, 'error', () => {});
    p.pendingQueue = [{ id: 'x' }];
    const g = gateFirstWrite(p, 'writeStatusFile');

    p.safeWriteStatusFile();
    await g.started;
    assert.match(await readFile(statusPath, 'utf-8'), /^status: active$/m);
    p.safeWriteStatusFile(); // an `active` request, pending behind the first write
    const shutdown = b.writeShutdownStatus();
    g.release();
    await shutdown;

    assert.match(await readFile(statusPath, 'utf-8'), /^status: closed$/m);
    assert.equal(g.calls(), 2);
  });
});

describe('stop() flushes before it lets go (KL-7)', () => {
  afterEach(() => mock.restoreAll());

  it('(v) stop() on a Bridge that was never started flushes both files', async () => {
    const { b, p, queuePath, statusPath } = await fresh();
    mock.method(console, 'error', () => {});
    p.pendingNotes = [{ text: 'a' }];
    p.safePersistQueue();
    p.safeWriteStatusFile();

    await b.stop();

    assert.deepEqual(await noteTexts(queuePath), ['a']);
    assert.equal(await exists(statusPath), true);
  });

  it('(vi) an ingest in flight when stop() begins is on disk after stop()', async () => {
    const { b, p, queuePath } = await fresh();
    mock.method(console, 'error', () => {});
    const entered = gate();
    const hold = gate();
    p.extractDataUrls = async (d) => {
      entered.open();
      await hold.promise;
      return d;
    };

    p.handleDiffBatch(fakeWs, { diffs: [validDiff('in-flight')], batchId: 'b1' });
    await entered.promise;
    const stopping = b.stop();
    hold.open();
    await stopping;

    const saved = JSON.parse(await readFile(queuePath, 'utf-8')) as { diffs: { id: string }[] };
    assert.deepEqual(saved.diffs.map((d) => d.id), ['in-flight']);
  });

  it('(vii) the lock file exists while the drain is pending and is gone after', async () => {
    const { root, b, p } = await fresh();
    mock.method(console, 'error', () => {});
    const lockPath = join(root, '.nco-web-editor', 'server.lock');
    assert.equal(await p.acquireLock(), true);

    p.pendingNotes = [{ text: 'a' }];
    const g = gateFirstWrite(p, 'persistQueue');
    const drainCalled = gate();
    const drain = p.queueWriter.drain.bind(p.queueWriter);
    p.queueWriter.drain = () => {
      drainCalled.open();
      return drain();
    };

    p.safePersistQueue();
    await g.started;
    const stopping = b.stop();
    await drainCalled.promise; // stop() is now waiting on the held write
    assert.equal(await exists(lockPath), true);
    g.release();
    await stopping;

    assert.equal(await exists(lockPath), false);
  });

  it('(x) a connection close that never completes does not hold stop() forever', async () => {
    const { root, b, p } = await fresh();
    const logged = mock.method(console, 'error', () => {});
    const lockPath = join(root, '.nco-web-editor', 'server.lock');
    assert.equal(await p.acquireLock(), true);
    // A server whose close callback never fires: a client that will not hang up.
    p.wss = { close() {} };
    p.closeTimeoutMs = 50;

    await b.stop();

    const text = logged.mock.calls.map((c) => c.arguments.join(' ')).join('\n');
    assert.equal(/Timed out after 50ms closing connections at shutdown/.test(text), true, text);
    assert.equal(await exists(lockPath), false, 'the lock is still released');
  });
});

describe('an id is queued once (KL-7)', () => {
  afterEach(() => mock.restoreAll());

  /** Stub extraction so a diff stays "in flight" until its own gate opens. */
  function holdById(p: Priv, ids: string[]): { open: (id: string) => void; extractions: () => number } {
    const gates = new Map(ids.map((id) => [id, gate()]));
    let extractions = 0;
    p.extractDataUrls = async (d) => {
      extractions++;
      await gates.get((d as { id: string }).id)?.promise;
      return d;
    };
    return { open: (id) => gates.get(id)!.open(), extractions: () => extractions };
  }

  const settle = async (p: Priv): Promise<void> => {
    await p.queueWriter.drain();
    await p.statusWriter.drain();
  };
  const ids = (p: Priv): string[] => (p.pendingQueue as { id: string }[]).map((d) => d.id);

  it('two overlapping payloads with the same id leave one entry (the reservation)', async () => {
    const { p } = await fresh();
    mock.method(console, 'error', () => {});
    const h = holdById(p, ['X']);

    const first = p.processDiffBatch({ diffs: [validDiff('X')], batchId: 'b1' });
    const second = p.processDiffBatch({ diffs: [validDiff('X')], batchId: 'b1' });
    h.open('X');
    await Promise.all([first, second]);
    await settle(p);

    assert.deepEqual(ids(p), ['X']);
    assert.equal(h.extractions(), 1, 'the second payload never started processing X');
  });

  it('an id that an overlapping payload queued meanwhile is not queued again (the live check)', async () => {
    const { p } = await fresh();
    mock.method(console, 'error', () => {});
    const h = holdById(p, ['X', 'A']);

    const first = p.processDiffBatch({ diffs: [validDiff('X')], batchId: 'b1' });
    // Arrived while X was in flight; held on A, so it reaches X only later.
    const second = p.processDiffBatch({ diffs: [validDiff('A'), validDiff('X')], batchId: 'b2' });
    h.open('X');
    await first;
    h.open('A');
    await second;
    await settle(p);

    assert.deepEqual(ids(p).sort(), ['A', 'X']);
  });

  it('acknowledging X between overlapping payloads does not let X back in', async () => {
    const { p } = await fresh();
    mock.method(console, 'error', () => {});
    const h = holdById(p, ['X', 'A']);

    const first = p.processDiffBatch({ diffs: [validDiff('X')], batchId: 'b1' });
    const second = p.processDiffBatch({ diffs: [validDiff('A'), validDiff('X')], batchId: 'b2' });
    h.open('X');
    await first;
    assert.equal(p.acknowledgeDiff('X'), true);
    h.open('A');
    await second;
    await settle(p);

    assert.deepEqual(ids(p), ['A']);
    // And a later resend is still refused.
    await p.processDiffBatch({ diffs: [validDiff('X')], batchId: 'b3' });
    await settle(p);
    assert.deepEqual(ids(p), ['A']);
  });

  it('a repeated id within one payload is queued once', async () => {
    const { p } = await fresh();
    mock.method(console, 'error', () => {});
    await p.processDiffBatch({ diffs: [validDiff('X'), validDiff('X'), validDiff('Y')], batchId: 'b1' });
    await settle(p);
    assert.deepEqual(ids(p), ['X', 'Y']);
  });

  it('releases the reservation when processing throws, so a resend is accepted', async () => {
    const { p } = await fresh();
    mock.method(console, 'error', () => {});
    let calls = 0;
    p.extractDataUrls = async (d) => {
      if (++calls === 1) throw new Error('boom');
      return d;
    };
    await p.processDiffBatch({ diffs: [validDiff('X')], batchId: 'b1' });
    await p.processDiffBatch({ diffs: [validDiff('X')], batchId: 'b1' });
    await settle(p);
    assert.deepEqual(ids(p), ['X']);
  });

  it('an import with a repeated id imports it once', async () => {
    const { root, p } = await fresh();
    mock.method(console, 'error', () => {});
    await writeFile(join(root, 's.json'), JSON.stringify({ diffs: [validDiff('X'), validDiff('X'), validDiff('Y')] }));
    const r = await p.importSession('s.json');
    await settle(p);
    assert.equal(r.imported, 2);
    assert.equal(r.skipped, 1);
    assert.deepEqual(ids(p), ['X', 'Y']);
  });

  it('a restore with a repeated id restores the first occurrence only', async () => {
    const { root, p, queuePath } = await fresh();
    mock.method(console, 'error', () => {});
    const first = validDiff('X');
    const second = { ...validDiff('X'), element: { selector: '#second', tagName: 'p' } };
    await mkdir(join(root, '.nco-web-editor'), { recursive: true });
    await writeFile(queuePath, JSON.stringify({ version: '0', diffs: [first, second, validDiff('Y')] }));

    await p.restoreQueue();

    assert.deepEqual(ids(p), ['X', 'Y']);
    assert.equal((p.pendingQueue[0] as { element: { selector: string } }).element.selector, '#a');
  });

  it('a restore logs at most five duplicate-id reasons', async () => {
    const { root, p, queuePath } = await fresh();
    const logged = mock.method(console, 'error', () => {});
    const dupes = Array.from({ length: 20 }, () => validDiff('X'));
    await mkdir(join(root, '.nco-web-editor'), { recursive: true });
    await writeFile(queuePath, JSON.stringify({ version: '0', diffs: dupes }));

    await p.restoreQueue();

    assert.deepEqual(ids(p), ['X']);
    const text = logged.mock.calls.map((c) => c.arguments.join(' ')).join('\n');
    assert.equal(text.split('Skipped duplicate diff').length - 1, 5, text);
  });
});
