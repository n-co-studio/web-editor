/**
 * Content-script proxy for the service-worker socket (KL-4).
 */
import { describe, it, beforeEach, afterEach, mock } from 'node:test';
import assert from 'node:assert/strict';

const ports: FakePort[] = [];
let connectThrows = false;

class FakePort {
  readonly posted: any[] = [];
  disconnected = false;
  private msgListeners: Array<(m: unknown) => void> = [];
  private discListeners: Array<() => void> = [];
  readonly onMessage = { addListener: (fn: (m: unknown) => void) => this.msgListeners.push(fn) };
  readonly onDisconnect = { addListener: (fn: () => void) => this.discListeners.push(fn) };
  constructor(readonly name: string) {}
  postMessage(m: unknown) {
    this.posted.push(m);
  }
  disconnect() {
    this.disconnected = true;
  }
  /** Service worker -> content. */
  fromWorker(m: unknown) {
    for (const fn of this.msgListeners) fn(m);
  }
  /** The worker died / was torn down. */
  workerGone() {
    for (const fn of this.discListeners) fn();
  }
}

(globalThis as any).__NCO_WEB_EDITOR_DEMO__ = false;
(globalThis as any).chrome = {
  runtime: {
    id: 'x',
    connect({ name }: { name: string }) {
      if (connectThrows) throw new Error('Extension context invalidated.');
      const p = new FakePort(name);
      ports.push(p);
      return p;
    },
  },
};

import { WebSocketClient as ProxyClient, PORT_RECONNECT_BASE_MS, SEND_RESULT_TIMEOUT_MS } from './websocket-client';

// Destroyed after each test even if an assertion throws first, so a pending
// reconnect timer cannot outlive a failing test.
const liveClients: ProxyClient[] = [];
class WebSocketClient extends ProxyClient {
  constructor(cb: ConstructorParameters<typeof ProxyClient>[0]) {
    super(cb);
    liveClients.push(this);
  }
}
afterEach(() => {
  for (const c of liveClients.splice(0)) c.destroy();
});
import type { WebSocketClientCallbacks } from './websocket-client';
import { BRIDGE_PORT_NAME } from '../shared/bridge-port';

function makeCb(extra: Partial<WebSocketClientCallbacks> = {}) {
  const statuses: string[] = [];
  const events: Array<[string, unknown]> = [];
  const cb: WebSocketClientCallbacks = {
    getPendingDiffIds: () => ['p1', 'p2'],
    onStatusChange: (s) => statuses.push(s),
    onServerHello: (p) => events.push(['onServerHello', p]),
    onDiffAck: (p) => events.push(['onDiffAck', p]),
    onDiffApplied: (p) => events.push(['onDiffApplied', p]),
    onTokenData: (p) => events.push(['onTokenData', p]),
    onTokenUpdate: (p) => events.push(['onTokenUpdate', p]),
    onComponentData: (p) => events.push(['onComponentData', p]),
    onComponentUpdate: (p) => events.push(['onComponentUpdate', p]),
    onStatusResponse: (p) => events.push(['onStatusResponse', p]),
    onError: (p) => events.push(['onError', p]),
    ...extra,
  };
  return { cb, statuses, events };
}

const last = () => ports[ports.length - 1];

describe('WebSocketClient proxy — round trip with the service worker', () => {
  beforeEach(() => {
    ports.length = 0;
    connectThrows = false;
  });

  it('opens the bridge Port and asks the worker to connect, carrying no tab identity', () => {
    const { cb } = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    assert.equal(ports.length, 1);
    assert.equal(last().name, BRIDGE_PORT_NAME);
    assert.deepEqual(last().posted, [{ kind: 'connect' }]);
    client.destroy();
  });

  it('mirrors worker status and enables sends only once connected', async () => {
    const { cb, statuses } = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    assert.equal(await client.sendDiffBatch([]), false, 'not connected yet');
    assert.equal(client.sendStatusRequest(), false);
    last().fromWorker({ kind: 'status', status: 'connected', everConnected: true });
    assert.equal(client.status, 'connected');
    assert.equal(statuses.at(-1), 'connected');
    assert.equal(client.sendStatusRequest(), true);
    const pending = client.sendDiffBatch([], '1. x', 'b1', [{ text: 'x', elements: [] }]);
    const sent = last().posted.at(-1);
    last().fromWorker({ kind: 'send-result', reqId: sent.reqId, ok: true });
    assert.equal(await pending, true);
    assert.equal(sent.kind, 'send-batch');
    assert.equal(sent.batchId, 'b1');
    assert.deepEqual(sent.notes, [{ text: 'x', elements: [] }]);
    assert.ok(!('tabId' in sent), 'the proxy must not send a tab identity');
    client.destroy();
  });

  it('answers the worker\'s request for pending diff ids', () => {
    const { cb } = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    last().fromWorker({ kind: 'need-pending-ids', reqId: 7 });
    assert.deepEqual(last().posted.at(-1), { kind: 'pending-ids', reqId: 7, ids: ['p1', 'p2'] });
    client.destroy();
  });

  it('relays server events to the callbacks', () => {
    const { cb, events } = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    last().fromWorker({ kind: 'event', event: 'onDiffAck', payload: { diffIds: ['a'] } });
    last().fromWorker({ kind: 'event', event: 'onServerHello', payload: { protocolVersion: '0.5.0', pendingDiffIds: [], appliedDiffIds: [] } });
    assert.deepEqual(events.map((e) => e[0]), ['onDiffAck', 'onServerHello']);
    client.destroy();
  });

  it('ignores malformed worker messages', () => {
    const { cb, events } = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    last().fromWorker(null);
    last().fromWorker('x');
    last().fromWorker({ kind: 'event', event: 'onNotAThing', payload: {} });
    last().fromWorker({ kind: 'unknown' });
    assert.equal(events.length, 0);
    client.destroy();
  });

  it('retryNow asks the worker to retry over the live Port', () => {
    const { cb } = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    client.retryNow();
    assert.deepEqual(last().posted.at(-1), { kind: 'retry' });
    client.destroy();
  });

  it('destroy disconnects the Port (closing the worker socket) and reports disconnected', () => {
    const { cb, statuses } = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    last().fromWorker({ kind: 'status', status: 'connected', everConnected: true });
    client.destroy();
    assert.equal(last().disconnected, true);
    assert.equal(client.status, 'disconnected');
    assert.equal(statuses.at(-1), 'disconnected');
  });

  it('does not open a Port in demo mode', async () => {
    (globalThis as any).__NCO_WEB_EDITOR_DEMO__ = true;
    try {
      const { cb } = makeCb();
      const client = new WebSocketClient(cb);
      client.connect();
      assert.equal(ports.length, 0);
      assert.equal(await client.sendDiffBatch([]), false);
    } finally {
      (globalThis as any).__NCO_WEB_EDITOR_DEMO__ = false;
    }
  });
});

describe('WebSocketClient proxy — service worker restart', () => {
  beforeEach(() => {
    ports.length = 0;
    connectThrows = false;
    mock.timers.enable({ apis: ['setTimeout'] });
  });
  afterEach(() => mock.timers.reset());

  it('reopens the Port after the worker goes away and asks it to connect again', async () => {
    const { cb, statuses } = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    last().fromWorker({ kind: 'status', status: 'connected', everConnected: true });
    last().workerGone();
    assert.equal(client.status, 'disconnected');
    assert.equal(statuses.at(-1), 'disconnected');
    assert.equal(ports.length, 1, 'no new Port before the delay');
    assert.equal(await client.sendDiffBatch([]), false, 'sends refused while the worker is gone');

    mock.timers.tick(PORT_RECONNECT_BASE_MS + 1);
    assert.equal(ports.length, 2, 'Port reopened');
    assert.deepEqual(ports[1].posted, [{ kind: 'connect' }]);
    client.destroy();
  });

  it('shows connecting then connected again once the new worker reports in', async () => {
    const { cb, statuses } = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    ports[0].fromWorker({ kind: 'status', status: 'connected', everConnected: true });
    ports[0].workerGone();
    mock.timers.tick(PORT_RECONNECT_BASE_MS + 1);
    assert.equal(client.status, 'connecting');
    ports[1].fromWorker({ kind: 'status', status: 'connected', everConnected: false });
    assert.equal(client.status, 'connected');
    assert.deepEqual(statuses, ['connecting', 'connected', 'disconnected', 'connecting', 'connected']);
    const p = client.sendDiffBatch([]);
    ports[1].fromWorker({ kind: 'send-result', reqId: ports[1].posted.at(-1).reqId, ok: true });
    assert.equal(await p, true);
    client.destroy();
  });

  it('keeps hasEverConnected true across a worker restart, even though the new worker starts with false', () => {
    const { cb } = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    assert.equal(client.hasEverConnected, false);
    ports[0].fromWorker({ kind: 'status', status: 'connected', everConnected: true });
    assert.equal(client.hasEverConnected, true);
    ports[0].workerGone();
    mock.timers.tick(PORT_RECONNECT_BASE_MS + 1);
    ports[1].fromWorker({ kind: 'status', status: 'connecting', everConnected: false });
    assert.equal(client.hasEverConnected, true, 'sticky for the page session');
    client.destroy();
  });

  it('reports hasEverConnected false when a connection never completed', () => {
    const { cb } = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    ports[0].fromWorker({ kind: 'status', status: 'connecting', everConnected: false });
    ports[0].workerGone();
    mock.timers.tick(PORT_RECONNECT_BASE_MS + 1);
    ports[1].fromWorker({ kind: 'status', status: 'connecting', everConnected: false });
    assert.equal(client.hasEverConnected, false);
    client.destroy();
  });

  it('backs off between repeated Port failures', () => {
    const { cb } = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    ports[0].workerGone();
    mock.timers.tick(PORT_RECONNECT_BASE_MS + 1);
    ports[1].workerGone();
    mock.timers.tick(PORT_RECONNECT_BASE_MS + 1);
    assert.equal(ports.length, 2, 'second delay is longer than the first');
    mock.timers.tick(PORT_RECONNECT_BASE_MS + 1);
    assert.equal(ports.length, 3);
    client.destroy();
  });

  it('does not reconnect after destroy', () => {
    const { cb } = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    ports[0].workerGone();
    client.destroy();
    mock.timers.tick(PORT_RECONNECT_BASE_MS * 10);
    assert.equal(ports.length, 1);
  });

  it('survives chrome.runtime.connect throwing (extension context invalidated) and recovers', () => {
    connectThrows = true;
    const { cb } = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    assert.equal(client.status, 'disconnected');
    assert.equal(ports.length, 0);
    connectThrows = false;
    mock.timers.tick(PORT_RECONNECT_BASE_MS + 1);
    assert.equal(ports.length, 1);
    client.destroy();
  });
});

describe('WebSocketClient proxy — send result (KL-6)', () => {
  beforeEach(() => {
    ports.length = 0;
    connectThrows = false;
  });

  function connected() {
    const { cb } = makeCb();
    const client = new WebSocketClient(cb);
    client.connect();
    last().fromWorker({ kind: 'status', status: 'connected', everConnected: true });
    return client;
  }

  it('resolves false when the worker reports the socket did not send', async () => {
    const client = connected();
    const p = client.sendDiffBatch([], 'x', 'b1');
    last().fromWorker({ kind: 'send-result', reqId: last().posted.at(-1).reqId, ok: false });
    assert.equal(await p, false);
  });

  it('resolves true only on the worker\'s ok:true for that request', async () => {
    const client = connected();
    const p = client.sendDiffBatch([], 'x', 'b1');
    const reqId = last().posted.at(-1).reqId;
    last().fromWorker({ kind: 'send-result', reqId: reqId + 99, ok: true }); // someone else's
    last().fromWorker({ kind: 'send-result', reqId, ok: true });
    assert.equal(await p, true);
  });

  it('resolves false when the Port disconnects mid-send', async () => {
    mock.timers.enable({ apis: ['setTimeout'] });
    try {
      const client = connected();
      const p = client.sendDiffBatch([], 'x', 'b1');
      last().workerGone();
      assert.equal(await p, false);
    } finally {
      mock.timers.reset();
    }
  });

  it('resolves false when destroy() is called mid-send', async () => {
    const client = connected();
    const p = client.sendDiffBatch([], 'x', 'b1');
    client.destroy();
    assert.equal(await p, false);
  });

  it('resolves false if the worker never answers', async () => {
    mock.timers.enable({ apis: ['setTimeout'] });
    try {
      const client = connected();
      const p = client.sendDiffBatch([], 'x', 'b1');
      mock.timers.tick(SEND_RESULT_TIMEOUT_MS + 1);
      assert.equal(await p, false);
      client.destroy();
    } finally {
      mock.timers.reset();
    }
  });
});
