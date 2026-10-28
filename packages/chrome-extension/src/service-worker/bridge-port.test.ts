/**
 * Service-worker side of the bridge Port (KL-4): one socket per connected tab,
 * identity from the browser (`port.sender.tab.id`) and never from message
 * content, and a Port disconnect tears the socket down.
 */
import { describe, it, beforeEach, afterEach, mock } from 'node:test';
import assert from 'node:assert/strict';

// --- fakes (installed before the modules under test run) -------------------

const sockets: FakeWebSocket[] = [];

class FakeWebSocket {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;
  readyState = FakeWebSocket.CONNECTING;
  readonly sends: string[] = [];
  closeCount = 0;
  private listeners = new Map<string, Array<(e: any) => void>>();
  constructor(readonly url: string) {
    sockets.push(this);
  }
  addEventListener(type: string, fn: (e: any) => void) {
    if (!this.listeners.has(type)) this.listeners.set(type, []);
    this.listeners.get(type)!.push(fn);
  }
  send(d: string) {
    this.sends.push(d);
  }
  close() {
    if (this.readyState === FakeWebSocket.CLOSED) return;
    this.closeCount++;
    this.readyState = FakeWebSocket.CLOSED;
    this.emit('close', {});
  }
  open() {
    this.readyState = FakeWebSocket.OPEN;
    this.emit('open', {});
  }
  message(data: unknown) {
    this.emit('message', { data: JSON.stringify(data) });
  }
  sent() {
    return this.sends.map((s) => JSON.parse(s));
  }
  private emit(type: string, e: any) {
    for (const fn of [...(this.listeners.get(type) ?? [])]) fn(e);
  }
}
(globalThis as any).WebSocket = FakeWebSocket;
const EXT_ID = 'test-extension-id';
const sessionStore: Record<string, unknown> = {};
(globalThis as any).chrome = {
  runtime: { id: EXT_ID },
  storage: {
    session: {
      get: async (k: string) => ({ [k]: sessionStore[k] }),
      set: async (o: Record<string, unknown>) => { Object.assign(sessionStore, o); },
    },
  },
};

import { handleBridgePort, liveBridgeSocketCount, PENDING_IDS_TIMEOUT_MS, resetBrowserIdCacheForTest } from './bridge-port';
import { BRIDGE_PORT_NAME } from '../shared/bridge-port';
import { WS_PORT_BASE, WS_KEEPALIVE_INTERVAL_MS } from '../shared/constants';

class FakePort {
  readonly posted: any[] = [];
  disconnected = false;
  private msgListeners: Array<(m: unknown) => void> = [];
  private discListeners: Array<() => void> = [];
  readonly onMessage = { addListener: (fn: (m: unknown) => void) => this.msgListeners.push(fn) };
  readonly onDisconnect = { addListener: (fn: () => void) => this.discListeners.push(fn) };
  constructor(
    readonly name: string,
    readonly sender: { id?: string; tab?: { id?: number } } | undefined,
  ) {}
  postMessage(m: unknown) {
    this.posted.push(m);
  }
  disconnect() {
    this.disconnected = true;
  }
  /** Content script -> worker. */
  fromContent(m: unknown) {
    for (const fn of this.msgListeners) fn(m);
  }
  /** The other end went away. */
  closeFromContent() {
    for (const fn of this.discListeners) fn();
  }
}

const livePorts: FakePort[] = [];

async function connect(tab: number | null = 42, opts: { id?: string; name?: string } = {}): Promise<FakePort> {
  const port = new FakePort(opts.name ?? BRIDGE_PORT_NAME, {
    id: opts.id ?? EXT_ID,
    tab: tab === null ? undefined : { id: tab },
  });
  livePorts.push(port);
  handleBridgePort(port as unknown as chrome.runtime.Port);
  await new Promise<void>((r) => setImmediate(r)); // the browser id resolves asynchronously
  return port;
}

/** Disconnect every port so the module-level per-tab map and socket retries are cleaned up. */
function teardownAll() {
  for (const p of livePorts.splice(0)) p.closeFromContent();
  sockets.length = 0;
}

const flush = () => new Promise<void>((r) => setImmediate(r));
const HELLO = { type: 'SERVER_HELLO', payload: { protocolVersion: '0.5.0', pendingDiffIds: [], appliedDiffIds: [] } };

/** Drive a port all the way to a confirmed, hello-sent connection. */
async function establish(port: FakePort, ids: string[] = []): Promise<FakeWebSocket> {
  port.fromContent({ kind: 'connect' });
  const ws = sockets[sockets.length - 1];
  ws.open();
  ws.message(HELLO);
  const req = port.posted.find((m) => m.kind === 'need-pending-ids');
  assert.ok(req, 'worker must ask the content script for pending ids');
  port.fromContent({ kind: 'pending-ids', reqId: req.reqId, ids });
  await flush();
  return ws;
}

function reset() {
  teardownAll();
  for (const k of Object.keys(sessionStore)) delete sessionStore[k];
  resetBrowserIdCacheForTest();
}

describe('bridge port — round trip', () => {
  beforeEach(reset);
  afterEach(teardownAll);

  it('opens the socket to ws://127.0.0.1:<port> when the content script connects', async () => {
    const port = await connect(42);
    assert.equal(sockets.length, 0, 'nothing opens before the content script asks');
    port.fromContent({ kind: 'connect' });
    assert.equal(sockets.length, 1);
    assert.equal(sockets[0].url, `ws://127.0.0.1:${WS_PORT_BASE}`);
  });

  it('reports status to the content script and relays server events', async () => {
    const port = await connect(42);
    const ws = await establish(port, ['d1']);
    assert.ok(port.posted.some((m) => m.kind === 'status' && m.status === 'connected' && m.everConnected === true));
    ws.message({ type: 'DIFF_ACK', payload: { diffIds: ['d1'] } });
    assert.ok(port.posted.some((m) => m.kind === 'event' && m.event === 'onDiffAck' && m.payload.diffIds[0] === 'd1'));
  });

  it('sends EXTENSION_HELLO with the pending ids the content script supplied', async () => {
    const port = await connect(42);
    const ws = await establish(port, ['d1', 'd2']);
    const hello = ws.sent().find((m) => m.type === 'EXTENSION_HELLO');
    assert.ok(hello, 'EXTENSION_HELLO sent');
    assert.deepEqual(hello.payload.pendingDiffIds, ['d1', 'd2']);
  });

  it('forwards a batch with structured notes and the legacy batchNote', async () => {
    const port = await connect(42);
    const ws = await establish(port);
    const notes = [{ text: 'bigger', elements: [{ tagName: 'img', selector: '.a' }] }];
    port.fromContent({ kind: 'send-batch', diffs: [], batchNote: '1. bigger', batchId: 'b1', notes });
    const batch = ws.sent().find((m) => m.type === 'VISUAL_DIFF_BATCH');
    assert.ok(batch);
    assert.deepEqual(batch.payload.notes, notes);
    assert.equal(batch.payload.batchNote, '1. bigger');
    assert.equal(batch.payload.batchId, 'b1');
  });
});

describe('bridge port — identity comes from the browser, not the message (KL-4)', () => {
  beforeEach(reset);
  afterEach(teardownAll);

  it('uses port.sender.tab.id as the tabId in EXTENSION_HELLO', async () => {
    const port = await connect(77);
    const ws = await establish(port);
    assert.match(ws.sent().find((m) => m.type === 'EXTENSION_HELLO').payload.tabId, /^[0-9a-f]{8}-77$/);
  });

  it('ignores a spoofed tabId on the connect message', async () => {
    const port = await connect(77);
    port.fromContent({ kind: 'connect', tabId: 'spoofed-tab' });
    const ws = sockets[0];
    ws.open();
    ws.message(HELLO);
    const req = port.posted.find((m) => m.kind === 'need-pending-ids');
    port.fromContent({ kind: 'pending-ids', reqId: req.reqId, ids: [], tabId: 'spoofed-tab' });
    await flush();
    const hello = ws.sent().find((m) => m.type === 'EXTENSION_HELLO');
    assert.match(hello.payload.tabId, /^[0-9a-f]{8}-77$/);
    assert.ok(!ws.sends.some((s) => s.includes('spoofed-tab')), 'the spoofed id must not reach the server');
  });

  it('ignores a spoofed tabId inside a batch payload and on its diffs', async () => {
    const port = await connect(77);
    const ws = await establish(port);
    const diff = { id: 'd1', context: { url: 'u', tabId: 'victim-tab' } };
    port.fromContent({ kind: 'send-batch', tabId: 'victim-tab', diffs: [diff], batchId: 'b1' });
    const batch = ws.sent().find((m) => m.type === 'VISUAL_DIFF_BATCH');
    assert.ok(batch);
    assert.match(batch.payload.diffs[0].context.tabId, /^[0-9a-f]{8}-77$/);
    assert.ok(!ws.sends.some((s) => s.includes('victim-tab')), 'the spoofed id must not reach the server');
  });

  it('gives each tab its own socket and its own tabId', async () => {
    const a = await connect(1);
    const b = await connect(2);
    const wsA = await establish(a);
    const wsB = await establish(b);
    assert.notEqual(wsA, wsB);
    assert.equal(liveBridgeSocketCount(), 2);
    assert.match(wsA.sent().find((m) => m.type === 'EXTENSION_HELLO').payload.tabId, /-1$/);
    assert.match(wsB.sent().find((m) => m.type === 'EXTENSION_HELLO').payload.tabId, /-2$/);
  });

  it('refuses a port whose sender is not this extension', async () => {
    const port = await connect(5, { id: 'some-other-extension' });
    assert.equal(port.disconnected, true);
    port.fromContent({ kind: 'connect' });
    assert.equal(sockets.length, 0, 'no socket may be opened for a foreign sender');
  });

  it('refuses a port with no tab (not a content script)', async () => {
    const port = await connect(null);
    assert.equal(port.disconnected, true);
    port.fromContent({ kind: 'connect' });
    assert.equal(sockets.length, 0);
  });

  it('ignores a port that is not the bridge port', async () => {
    const port = await connect(5, { name: 'something-else' });
    port.fromContent({ kind: 'connect' });
    assert.equal(sockets.length, 0);
  });

  it('ignores malformed messages without throwing', async () => {
    const port = await connect(5);
    port.fromContent(null);
    port.fromContent('x');
    port.fromContent({ kind: 'send-batch', diffs: 'nope' });
    port.fromContent({ kind: 'nonsense' });
    assert.equal(sockets.length, 0);
  });
});

describe('bridge port — lifecycle', () => {
  beforeEach(() => {
    reset();
    mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
  });
  afterEach(() => {
    teardownAll();
    mock.timers.reset();
  });

  it('closes the tab socket when the Port disconnects (worker/content teardown)', async () => {
    const port = await connect(9);
    port.fromContent({ kind: 'connect' });
    const ws = sockets[0];
    ws.open();
    port.closeFromContent();
    assert.equal(ws.closeCount, 1, 'socket must be closed');
    assert.equal(liveBridgeSocketCount(), 0);
  });

  it('a reconnecting content script on the same tab replaces the old socket', async () => {
    const first = await connect(9);
    first.fromContent({ kind: 'connect' });
    const ws1 = sockets[0];
    ws1.open();
    const second = await connect(9);
    assert.equal(ws1.closeCount, 1, 'old socket closed');
    assert.equal(first.disconnected, true);
    second.fromContent({ kind: 'connect' });
    assert.equal(sockets.length, 2);
    assert.equal(liveBridgeSocketCount(), 1);
  });

  it('sends a KEEPALIVE inside the 30s service-worker idle window', async () => {
    assert.ok(WS_KEEPALIVE_INTERVAL_MS <= 20_000, 'keepalive must stay at 20s or less');
    const port = await connect(9);
    port.fromContent({ kind: 'connect' });
    const ws = sockets[0];
    ws.open();
    ws.message(HELLO);
    mock.timers.tick(WS_KEEPALIVE_INTERVAL_MS + 1);
    assert.ok(ws.sent().some((m) => m.type === 'KEEPALIVE'));
  });

  it('sends an empty pending list if the content script never answers', async () => {
    const port = await connect(9);
    port.fromContent({ kind: 'connect' });
    const ws = sockets[0];
    ws.open();
    ws.message(HELLO);
    mock.timers.tick(PENDING_IDS_TIMEOUT_MS + 1);
    await flush();
    const hello = ws.sent().find((m) => m.type === 'EXTENSION_HELLO');
    assert.ok(hello);
    assert.deepEqual(hello.payload.pendingDiffIds, []);
  });
});

describe('bridge port — browser-instance prefix on tab ids (KL-4)', () => {
  beforeEach(reset);
  afterEach(teardownAll);

  const helloTab = (ws: FakeWebSocket) => ws.sent().find((m) => m.type === 'EXTENSION_HELLO').payload.tabId as string;

  it('prefixes the tab id with a per-browser id and keeps it a plain string', async () => {
    const ws = await establish(await connect(5));
    assert.equal(typeof helloTab(ws), 'string');
    assert.match(helloTab(ws), /^[0-9a-f]{8}-5$/);
  });

  it('keeps the same prefix across a service-worker restart (persisted in storage.session)', async () => {
    const first = helloTab(await establish(await connect(5)));
    teardownAll();
    resetBrowserIdCacheForTest(); // worker restarted: memory gone, storage.session kept
    const second = helloTab(await establish(await connect(5)));
    assert.equal(second, first);
  });

  it('gives two browser instances different prefixes for the same tab number', async () => {
    const first = helloTab(await establish(await connect(5)));
    teardownAll();
    resetBrowserIdCacheForTest();
    for (const k of Object.keys(sessionStore)) delete sessionStore[k]; // a different browser: its own storage
    const second = helloTab(await establish(await connect(5)));
    assert.notEqual(second, first);
  });

  it('holds messages that arrive before the browser id resolves and replays them', async () => {
    const port = new FakePort(BRIDGE_PORT_NAME, { id: EXT_ID, tab: { id: 8 } });
    livePorts.push(port);
    handleBridgePort(port as unknown as chrome.runtime.Port);
    port.fromContent({ kind: 'connect' }); // before the async id resolves
    assert.equal(sockets.length, 0);
    await flush();
    assert.equal(sockets.length, 1, 'the early connect must not be lost');
  });
});

describe('bridge port — send result and retry (KL-4/KL-6)', () => {
  beforeEach(reset);
  afterEach(teardownAll);

  it('replies send-result ok:true when the socket sent the frame', async () => {
    const port = await connect(3);
    await establish(port);
    port.fromContent({ kind: 'send-batch', reqId: 11, diffs: [] });
    assert.ok(port.posted.some((m) => m.kind === 'send-result' && m.reqId === 11 && m.ok === true));
  });

  it('replies send-result ok:false when the socket is not connected', async () => {
    const port = await connect(3);
    port.fromContent({ kind: 'connect' }); // socket opened but handshake not confirmed
    sockets[0].open();
    port.fromContent({ kind: 'send-batch', reqId: 12, diffs: [] });
    assert.ok(port.posted.some((m) => m.kind === 'send-result' && m.reqId === 12 && m.ok === false));
  });

  it('ignores a retry while the socket is live, so it cannot orphan it', async () => {
    const port = await connect(3);
    const ws = await establish(port);
    const before = sockets.length;
    port.fromContent({ kind: 'retry' });
    assert.equal(sockets.length, before, 'no second socket may be opened');
    assert.equal(ws.closeCount, 0);
  });

  it('ignores a retry while a scan is in flight', async () => {
    const port = await connect(3);
    port.fromContent({ kind: 'connect' });
    const before = sockets.length;
    port.fromContent({ kind: 'retry' });
    assert.equal(sockets.length, before);
  });
});

describe('bridge port — pending-ids timer', () => {
  beforeEach(() => {
    reset();
    mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
  });
  afterEach(() => {
    teardownAll();
    mock.timers.reset();
  });

  it('answering the request clears its timeout (no late empty hello)', async () => {
    const port = await connect(4);
    port.fromContent({ kind: 'connect' });
    const ws = sockets[0];
    ws.open();
    ws.message(HELLO);
    const req = port.posted.find((m) => m.kind === 'need-pending-ids');
    port.fromContent({ kind: 'pending-ids', reqId: req.reqId, ids: ['a'] });
    await flush();
    mock.timers.tick(PENDING_IDS_TIMEOUT_MS * 3);
    await flush();
    const hellos = ws.sent().filter((m) => m.type === 'EXTENSION_HELLO');
    assert.equal(hellos.length, 1);
    assert.deepEqual(hellos[0].payload.pendingDiffIds, ['a']);
  });
});
