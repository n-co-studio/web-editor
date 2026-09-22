import { describe, it, beforeEach, afterEach } from 'node:test';
import { mock } from 'node:test';
import assert from 'node:assert/strict';

// ---------------------------------------------------------------------------
// FakeWebSocket — hand-rolled test double for globalThis.WebSocket
//
// Implemented WebSocket members:
//   Static:   CONNECTING=0, OPEN=1, CLOSING=2, CLOSED=3
//   Instance: readyState (number), url (string)
//             send(data: string)               — recorded in .sends[]
//             close()                          — fires 'close' event synchronously
//             addEventListener(type, fn)        — registers a listener
//             removeEventListener(type, fn)     — removes a listener
//
// Test helpers (not on the real WebSocket interface):
//   emitOpen()               — sets readyState=OPEN, fires 'open'
//   emitMessage(data)        — fires 'message' with JSON.stringify(data) as event.data
//   emitClose()              — sets readyState=CLOSED, fires 'close'
//   emitError()              — fires 'error'
//   closeCount               — number of times close() was called
// ---------------------------------------------------------------------------

const createdSockets: FakeWebSocket[] = [];

class FakeWebSocket {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;

  readyState = FakeWebSocket.CONNECTING;
  readonly url: string;
  readonly sends: string[] = [];
  private _closeCalled = 0;
  private _listeners = new Map<string, Array<(e: any) => void>>();

  constructor(url: string) {
    this.url = url;
    createdSockets.push(this);
  }

  addEventListener(type: string, fn: (e: any) => void): void {
    if (!this._listeners.has(type)) this._listeners.set(type, []);
    this._listeners.get(type)!.push(fn);
  }

  removeEventListener(type: string, fn: (e: any) => void): void {
    const list = this._listeners.get(type);
    if (list) {
      const i = list.indexOf(fn);
      if (i >= 0) list.splice(i, 1);
    }
  }

  send(data: string): void {
    this.sends.push(data);
  }

  close(): void {
    if (this.readyState === FakeWebSocket.CLOSED) return;
    this._closeCalled++;
    this.readyState = FakeWebSocket.CLOSED;
    this._emit('close', {});
  }

  get closeCount() { return this._closeCalled; }

  // --- Test helpers ---

  emitOpen(): void {
    this.readyState = FakeWebSocket.OPEN;
    this._emit('open', {});
  }

  emitMessage(data: unknown): void {
    this._emit('message', { data: JSON.stringify(data) });
  }

  emitClose(): void {
    if (this.readyState !== FakeWebSocket.CLOSED) {
      this.readyState = FakeWebSocket.CLOSED;
    }
    this._emit('close', {});
  }

  emitError(): void {
    this._emit('error', new Error('fake error'));
  }

  private _emit(type: string, event: any): void {
    // Snapshot before dispatch so a listener that removes itself does not skip the next
    for (const fn of [...(this._listeners.get(type) ?? [])]) fn(event);
  }
}

// Assign the fake before any imports that might reference globalThis.WebSocket
(globalThis as any).WebSocket = FakeWebSocket;
// isDemoMode() checks this flag; keep it false so connect() actually runs
(globalThis as any).__NCO_WEB_EDITOR_DEMO__ = false;

// ---------------------------------------------------------------------------
// Imports (after globals are set — modules use WebSocket only inside methods,
// so the assignment above is in effect before any test code executes)
// ---------------------------------------------------------------------------
import { WebSocketClient } from './websocket-client';
import { WS_PORT_BASE, WS_BACKOFF_BASE_MS, WS_HANDSHAKE_TIMEOUT_MS } from '../shared/constants';
import type { WebSocketClientCallbacks } from './websocket-client';

// ---------------------------------------------------------------------------
// Callback factory
// ---------------------------------------------------------------------------

function makeCb(): WebSocketClientCallbacks & { statusHistory: string[] } {
  const statusHistory: string[] = [];
  return {
    tabId: 'test-tab-id',
    getPendingDiffIds: () => ['diff-1', 'diff-2'],
    onStatusChange: (s) => { statusHistory.push(s); },
    onServerHello: () => {},
    onDiffAck: () => {},
    onDiffApplied: () => {},
    onTokenData: () => {},
    onTokenUpdate: () => {},
    onComponentData: () => {},
    onComponentUpdate: () => {},
    onStatusResponse: () => {},
    onError: () => {},
    statusHistory,
  };
}

function lastSocket(): FakeWebSocket {
  return createdSockets[createdSockets.length - 1];
}

// ---------------------------------------------------------------------------
// HACK-008 handshake guard: no identifiers before SERVER_HELLO / STATUS_RESPONSE
// ---------------------------------------------------------------------------

describe('WebSocketClient — HACK-008 handshake guard', () => {
  beforeEach(() => { createdSockets.length = 0; });

  it('sends only an identifier-free STATUS_REQUEST probe on connect — no tabId/pendingDiffIds before confirmation', () => {
    const cb = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();

    const ws = lastSocket();
    assert.ok(ws, 'FakeWebSocket should have been created');
    assert.equal(ws.sends.length, 0, 'no sends before open');

    ws.emitOpen();

    // Only the identifier-free probe is sent
    assert.equal(ws.sends.length, 1, 'exactly one message sent on open');
    const probe = JSON.parse(ws.sends[0]);
    assert.equal(probe.type, 'STATUS_REQUEST', 'probe message must be STATUS_REQUEST');
    assert.equal(
      'tabId' in (probe.payload ?? {}),
      false,
      'probe payload must not carry tabId — HACK-008 violation',
    );

    // sendDiffBatch and sendStatusRequest must be blocked before handshake
    assert.equal(client.sendDiffBatch([] as any), false, 'sendDiffBatch must return false before handshake');
    assert.equal(client.sendStatusRequest(), false, 'sendStatusRequest must return false before handshake');

    // No EXTENSION_HELLO must have been sent
    const hasHello = ws.sends.some(s => JSON.parse(s).type === 'EXTENSION_HELLO');
    assert.equal(hasHello, false, 'EXTENSION_HELLO must not be sent before handshake confirmed');

    client.destroy();
  });

  it('confirms handshake on valid SERVER_HELLO and sends EXTENSION_HELLO with tabId + pendingDiffIds', () => {
    const cb = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    const ws = lastSocket();
    ws.emitOpen();

    ws.emitMessage({
      type: 'SERVER_HELLO',
      payload: { protocolVersion: '0.4.0', pendingDiffIds: [], appliedDiffIds: [] },
    });

    assert.equal(cb.statusHistory.at(-1), 'connected', 'status must transition to connected');

    const allMsgs = ws.sends.map(s => JSON.parse(s));
    const hello = allMsgs.find((m: any) => m.type === 'EXTENSION_HELLO');
    assert.ok(hello, 'EXTENSION_HELLO must be sent after confirmation');
    assert.equal(hello.payload.tabId, 'test-tab-id', 'tabId must be sent in EXTENSION_HELLO');
    assert.deepEqual(
      hello.payload.pendingDiffIds,
      ['diff-1', 'diff-2'],
      'pendingDiffIds must be sent in EXTENSION_HELLO',
    );

    // Downstream sends should now work
    const countBefore = ws.sends.length;
    assert.equal(client.sendStatusRequest(), true, 'sendStatusRequest must return true after handshake');
    assert.equal(ws.sends.length, countBefore + 1, 'sendStatusRequest must have sent a message');

    client.destroy();
  });

  it('confirms handshake on STATUS_RESPONSE (old-server compatibility path)', () => {
    const cb = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    const ws = lastSocket();
    ws.emitOpen();

    ws.emitMessage({
      type: 'STATUS_RESPONSE',
      payload: { pendingCount: 0, deliveredCount: 0, perDiff: [], lastToolCallAt: null },
    });

    assert.equal(cb.statusHistory.at(-1), 'connected');
    const hasHello = ws.sends.some(s => JSON.parse(s).type === 'EXTENSION_HELLO');
    assert.ok(hasHello, 'EXTENSION_HELLO must be sent after STATUS_RESPONSE confirmation');

    client.destroy();
  });

  it('non-MCP message before handshake does not confirm — identifiers remain withheld', () => {
    const cb = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    const ws = lastSocket();
    ws.emitOpen();

    ws.emitMessage({ type: 'NOT_MCP', payload: { data: 'random' } });

    assert.notEqual(cb.statusHistory.at(-1), 'connected', 'must not confirm on an unrecognized message');
    const hasHello = ws.sends.some(s => JSON.parse(s).type === 'EXTENSION_HELLO');
    assert.equal(hasHello, false, 'EXTENSION_HELLO must not be sent after a non-MCP message');
    assert.equal(client.sendDiffBatch([] as any), false, 'sendDiffBatch must still be blocked');

    client.destroy();
  });

  it('SERVER_HELLO without a string protocolVersion field does not confirm handshake', () => {
    const cb = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    const ws = lastSocket();
    ws.emitOpen();

    ws.emitMessage({ type: 'SERVER_HELLO', payload: { protocolVersion: 42 } });

    assert.notEqual(cb.statusHistory.at(-1), 'connected');
    const hasHello = ws.sends.some(s => JSON.parse(s).type === 'EXTENSION_HELLO');
    assert.equal(hasHello, false, 'malformed SERVER_HELLO must not confirm handshake');

    client.destroy();
  });
});

// ---------------------------------------------------------------------------
// Handshake timeout — closes non-MCP peer, continues port scan
// ---------------------------------------------------------------------------

describe('WebSocketClient — handshake timeout and port scan', () => {
  beforeEach(() => {
    createdSockets.length = 0;
    mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
  });

  afterEach(() => {
    mock.timers.reset();
  });

  it('closes non-MCP peer on handshake timeout and scans the next port', () => {
    const cb = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();

    const ws0 = lastSocket();
    ws0.emitOpen();
    assert.equal(createdSockets.length, 1, 'only one socket so far');

    // Advance past handshake timeout — timer fires → ws.close() → close event →
    // scanPorts(port+1) → new WebSocket for port+1 (all synchronous within tick)
    mock.timers.tick(WS_HANDSHAKE_TIMEOUT_MS + 1);

    assert.equal(ws0.closeCount, 1, 'ws.close() must be called on handshake timeout');
    assert.equal(createdSockets.length, 2, 'port scan must continue to the next port');
    assert.ok(
      createdSockets[1].url.includes(`:${WS_PORT_BASE + 1}`),
      `second socket must target port ${WS_PORT_BASE + 1}, got ${createdSockets[1]?.url}`,
    );

    client.destroy();
  });
});

// ---------------------------------------------------------------------------
// Reconnect backoff — exponential delay after confirmed connection drops
// ---------------------------------------------------------------------------

describe('WebSocketClient — reconnect backoff', () => {
  beforeEach(() => {
    createdSockets.length = 0;
    mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
  });

  afterEach(() => {
    mock.timers.reset();
  });

  it('schedules a retry after a confirmed connection drops with delay = backoff_base * 2^(retryCount-1)', () => {
    const cb = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();

    const ws0 = lastSocket();
    ws0.emitOpen();
    ws0.emitMessage({
      type: 'SERVER_HELLO',
      payload: { protocolVersion: '0.4.0', pendingDiffIds: [], appliedDiffIds: [] },
    });
    assert.equal(cb.statusHistory.at(-1), 'connected');

    const socketsBefore = createdSockets.length;
    ws0.emitClose(); // drop confirmed connection → scheduleRetry()

    assert.equal(cb.statusHistory.at(-1), 'disconnected');
    assert.equal(createdSockets.length, socketsBefore, 'no new socket before retry delay elapses');

    // retryCount=1, delay = WS_BACKOFF_BASE_MS * 2^0 = WS_BACKOFF_BASE_MS
    mock.timers.tick(WS_BACKOFF_BASE_MS + 1);

    assert.equal(
      createdSockets.length,
      socketsBefore + 1,
      'new connection attempt must be made after backoff delay',
    );

    client.destroy();
  });
});
