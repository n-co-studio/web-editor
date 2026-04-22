/**
 * Web-embed environment shim.
 *
 * When the content script runs inside a real Chrome extension, `window.chrome`
 * is provided by the browser. When the script runs as a plain <script> tag
 * embedded in a website, it is not. This module installs a minimal shim that
 * satisfies the APIs the content script actually uses:
 *
 *   - chrome.storage.session.get/set  → in-memory Map (per page load only,
 *                                        nothing persists across reloads —
 *                                        matches the demo's "refresh resets
 *                                        everything" promise)
 *   - chrome.runtime.sendMessage      → noop that resolves with `{ ok: false }`
 *   - chrome.runtime.onMessage        → registry-backed dispatch (broadcast()
 *                                        fires all listeners synchronously)
 *
 * The shim also sets `window.__FRONTEND_EDITOR_DEMO__ = true` so other
 * modules (WebSocket client, Apply-Changes button) can behave differently
 * when persistence / MCP submission would make no sense.
 */

type StorageBag = Record<string, unknown>;
const LS_PREFIX = 'frontend-editor-demo:';

const memoryStore = new Map<string, unknown>();

type MessageListener = (
  msg: unknown,
  sender: unknown,
  sendResponse: (response?: unknown) => void,
) => boolean | undefined;

const messageListeners: MessageListener[] = [];

function storageGet(keys: string | string[] | null | undefined): Promise<StorageBag> {
  const out: StorageBag = {};
  if (keys == null) {
    for (const [k, v] of memoryStore) out[k] = v;
  } else {
    const keyList = Array.isArray(keys) ? keys : [keys];
    for (const k of keyList) {
      if (memoryStore.has(k)) out[k] = memoryStore.get(k);
    }
  }
  return Promise.resolve(out);
}

function storageSet(items: StorageBag): Promise<void> {
  for (const [k, v] of Object.entries(items)) memoryStore.set(k, v);
  return Promise.resolve();
}

function storageRemove(keys: string | string[]): Promise<void> {
  const keyList = Array.isArray(keys) ? keys : [keys];
  for (const k of keyList) memoryStore.delete(k);
  return Promise.resolve();
}

/**
 * Removes any stale localStorage entries left behind by an earlier version of
 * the shim that did persist to localStorage. Safe to keep indefinitely — the
 * cost is one storage scan per shim install.
 */
function purgeLegacyLocalStorage(): void {
  try {
    const keysToRemove: string[] = [];
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      if (k && k.startsWith(LS_PREFIX)) keysToRemove.push(k);
    }
    for (const k of keysToRemove) localStorage.removeItem(k);
  } catch { /* localStorage may be blocked; best-effort */ }
}

function sendMessage(_msg: unknown): Promise<unknown> {
  return Promise.resolve({ ok: false, reason: 'demo-mode' });
}

function addMessageListener(listener: MessageListener): void {
  messageListeners.push(listener);
}

function removeMessageListener(listener: MessageListener): void {
  const idx = messageListeners.indexOf(listener);
  if (idx >= 0) messageListeners.splice(idx, 1);
}

/**
 * Fires a message to all registered listeners. Used by the embed harness to
 * trigger the same activation path the service worker would use in the real
 * extension.
 */
export function broadcastRuntimeMessage(msg: unknown): Promise<unknown> {
  const responses: unknown[] = [];
  for (const listener of messageListeners) {
    try {
      listener(msg, { id: 'web-embed-demo' }, (resp) => { responses.push(resp); });
    } catch (e) {
      console.error('[frontend-editor][demo] listener threw', e);
    }
  }
  return Promise.resolve(responses[0]);
}

export function isDemoMode(): boolean {
  return (globalThis as any).__FRONTEND_EDITOR_DEMO__ === true;
}

/**
 * Installs the chrome.* shim on window. Idempotent — subsequent calls are
 * no-ops if the shim is already present.
 */
export function installChromeShim(): void {
  const w = globalThis as any;
  w.__FRONTEND_EDITOR_DEMO__ = true;

  if (w.chrome && w.chrome.__FRONTEND_EDITOR_SHIM__) return;

  // Clear any leftover keys from an older shim build that persisted to
  // localStorage; the current shim is in-memory only.
  purgeLegacyLocalStorage();

  const existing = w.chrome || {};
  w.chrome = {
    ...existing,
    __FRONTEND_EDITOR_SHIM__: true,
    storage: {
      ...(existing.storage || {}),
      session: {
        get: storageGet,
        set: storageSet,
        remove: storageRemove,
      },
    },
    runtime: {
      ...(existing.runtime || {}),
      sendMessage,
      onMessage: {
        addListener: addMessageListener,
        removeListener: removeMessageListener,
      },
      id: 'frontend-editor-demo',
    },
  };
}
