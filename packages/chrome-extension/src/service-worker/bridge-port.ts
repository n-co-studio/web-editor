/**
 * Service-worker side of the bridge Port (KL-4).
 *
 * The WebSocket to the MCP server lives here, not in the content script, so
 * the server sees `Origin: chrome-extension://<id>` and a script on the page
 * cannot open (or hijack) the socket. One BridgeSocket per connected tab.
 *
 * The tab identity is `port.sender.tab.id`, supplied by the browser. Nothing in
 * a message from the content script can change it.
 */

import type { VisualDiff } from '@nco-studio/shared';
import { BridgeSocket } from './bridge-socket';
import type { BridgeSocketCallbacks } from './bridge-socket';
import { BRIDGE_PORT_NAME } from '../shared/bridge-port';
import type { ProxyToWorker, WorkerToProxy, RelayedEvent } from '../shared/bridge-port';

/** How long to wait for the content script's pending diff ids before sending none. */
export const PENDING_IDS_TIMEOUT_MS = 1_000;
const MAX_PENDING_IDS = 10_000;

interface Entry {
  readonly port: chrome.runtime.Port;
  readonly socket: BridgeSocket;
  readonly teardown: () => void;
}

const entries = new Map<string, Entry>();

export type SocketFactory = (cb: BridgeSocketCallbacks) => BridgeSocket;

/** Handle a new Port from a content script. Registered as chrome.runtime.onConnect. */
const BROWSER_ID_KEY = 'nco-bridge-browser-id';
let browserIdPromise: Promise<string> | null = null;

/**
 * A random id for this browser instance, generated once and kept in
 * chrome.storage.session so it survives a service-worker restart. Tab ids are
 * only unique within one browser, and two browsers (Chrome and Canary) can
 * share one server; the prefix keeps their tab ids apart.
 */
function getBrowserId(): Promise<string> {
  browserIdPromise ??= (async () => {
    try {
      const got = await chrome.storage.session.get(BROWSER_ID_KEY);
      const existing = got?.[BROWSER_ID_KEY];
      if (typeof existing === 'string' && /^[0-9a-f]{8}$/.test(existing)) return existing;
    } catch {
      // fall through to a fresh id
    }
    const id = crypto.randomUUID().replace(/-/g, '').slice(0, 8);
    try {
      await chrome.storage.session.set({ [BROWSER_ID_KEY]: id });
    } catch {
      // in-memory only
    }
    return id;
  })();
  return browserIdPromise;
}

/** Test hook: forget the cached browser id (simulates a service-worker restart). */
export function resetBrowserIdCacheForTest(): void {
  browserIdPromise = null;
}

/** Handle a new Port from a content script. Registered as chrome.runtime.onConnect. */
export function handleBridgePort(
  port: chrome.runtime.Port,
  createSocket: SocketFactory = (cb) => new BridgeSocket(cb),
): void {
  if (port.name !== BRIDGE_PORT_NAME) return;

  // Only this extension's own content script. (onConnectExternal is not
  // registered, so a foreign extension cannot reach here at all; this is the
  // belt to that pair of braces.)
  const tabNumber = port.sender?.tab?.id;
  if (port.sender?.id !== chrome.runtime.id || typeof tabNumber !== 'number') {
    port.disconnect();
    return;
  }

  // The browser id is async; messages that arrive first are held and replayed,
  // and a disconnect before it resolves cancels the setup.
  const held: unknown[] = [];
  let live: ((raw: unknown) => void) | null = null;
  let gone = false;
  let onGone: (() => void) | null = null;
  port.onMessage.addListener((raw: unknown) => {
    if (live) live(raw);
    else held.push(raw);
  });
  port.onDisconnect.addListener(() => {
    gone = true;
    onGone?.();
  });

  void getBrowserId().then((browserId) => {
    if (gone) return;
    const attach = attachPort(port, `${browserId}-${tabNumber}`, createSocket);
    live = attach.onMessage;
    onGone = attach.onDisconnect;
    for (const m of held.splice(0)) live(m);
  });
}

function attachPort(
  port: chrome.runtime.Port,
  tabId: string,
  createSocket: SocketFactory,
): { onMessage: (raw: unknown) => void; onDisconnect: () => void } {
  // A reload of the content script on the same tab replaces its old socket.
  entries.get(tabId)?.teardown();

  const post = (msg: WorkerToProxy): void => {
    try {
      port.postMessage(msg);
    } catch {
      // Port already closed — the disconnect handler cleans up.
    }
  };

  let nextReq = 0;
  const waiting = new Map<number, { resolve: (ids: readonly string[]) => void; timer: ReturnType<typeof setTimeout> }>();

  const relay = (e: RelayedEvent): void => post({ kind: 'event', ...e });
  const socket = createSocket({
    tabId,
    getPendingDiffIds: () =>
      new Promise((resolve) => {
        const reqId = ++nextReq;
        const timer = setTimeout(() => {
          if (waiting.delete(reqId)) resolve([]);
        }, PENDING_IDS_TIMEOUT_MS);
        waiting.set(reqId, { resolve, timer });
        post({ kind: 'need-pending-ids', reqId });
      }),
    onStatusChange: (status) => post({ kind: 'status', status, everConnected: socket.hasEverConnected }),
    onServerHello: (payload) => relay({ event: 'onServerHello', payload }),
    onDiffAck: (payload) => relay({ event: 'onDiffAck', payload }),
    onDiffApplied: (payload) => relay({ event: 'onDiffApplied', payload }),
    onTokenData: (payload) => relay({ event: 'onTokenData', payload }),
    onTokenUpdate: (payload) => relay({ event: 'onTokenUpdate', payload }),
    onComponentData: (payload) => relay({ event: 'onComponentData', payload }),
    onComponentUpdate: (payload) => relay({ event: 'onComponentUpdate', payload }),
    onStatusResponse: (payload) => relay({ event: 'onStatusResponse', payload }),
    onError: (payload) => relay({ event: 'onError', payload }),
  });

  let started = false;
  const teardown = (): void => {
    socket.destroy();
    for (const w of waiting.values()) {
      clearTimeout(w.timer);
      w.resolve([]);
    }
    waiting.clear();
    if (entries.get(tabId)?.socket === socket) entries.delete(tabId);
    try {
      port.disconnect();
    } catch {
      // already gone
    }
  };
  entries.set(tabId, { port, socket, teardown });

  const onMessage = (raw: unknown): void => {
    if (typeof raw !== 'object' || raw === null) return;
    // Deliberately not reading any `tabId` off the message.
    const msg = raw as Partial<ProxyToWorker> & Record<string, unknown>;
    switch (msg.kind) {
      case 'connect':
        if (started) return;
        started = true;
        socket.connect();
        return;
      case 'retry':
        socket.retryNow();
        return;
      case 'status-request':
        socket.sendStatusRequest();
        return;
      case 'send-batch': {
        if (!Array.isArray(msg.diffs)) return;
        const diffs = (msg.diffs as VisualDiff[]).map((d) =>
          // The server routes DIFF_APPLIED by context.tabId, so make it the
          // authoritative tab rather than whatever the content script wrote.
          d && typeof d === 'object' && d.context && typeof d.context === 'object'
            ? { ...d, context: { ...d.context, tabId } }
            : d,
        );
        const ok = socket.sendDiffBatch(
          diffs,
          typeof msg.batchNote === 'string' ? msg.batchNote : undefined,
          typeof msg.batchId === 'string' ? msg.batchId : undefined,
          Array.isArray(msg.notes) ? msg.notes : undefined,
        );
        // Report the socket's real answer. The content script clears the
        // designer's notes only on a true.
        post({ kind: 'send-result', reqId: typeof msg.reqId === 'number' ? msg.reqId : -1, ok });
        return;
      }
      case 'pending-ids': {
        const w = typeof msg.reqId === 'number' ? waiting.get(msg.reqId) : undefined;
        if (!w) return;
        waiting.delete(msg.reqId as number);
        clearTimeout(w.timer);
        const ids = Array.isArray(msg.ids)
          ? msg.ids.filter((x): x is string => typeof x === 'string').slice(0, MAX_PENDING_IDS)
          : [];
        w.resolve(ids);
        return;
      }
      default:
        return;
    }
  };

  const onDisconnect = (): void => {
    // Only tear down if this port still owns the tab's entry.
    if (entries.get(tabId)?.port === port) teardown();
    else socket.destroy();
  };

  return { onMessage, onDisconnect };
}

/** Test hook: number of live per-tab sockets. */
export function liveBridgeSocketCount(): number {
  return entries.size;
}
