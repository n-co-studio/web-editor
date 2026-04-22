/**
 * Web-embed environment shim.
 *
 * When the content script runs inside a real Chrome extension, `window.chrome`
 * is provided by the browser. When the script runs as a plain <script> tag
 * embedded in a website, it is not. This module installs a minimal shim that
 * satisfies the APIs the content script actually uses:
 *
 *   - chrome.storage.session.get/set  → localStorage, session-scoped keys
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

type MessageListener = (
  msg: unknown,
  sender: unknown,
  sendResponse: (response?: unknown) => void,
) => boolean | undefined;

const messageListeners: MessageListener[] = [];

function storageGet(keys: string | string[] | null | undefined): Promise<StorageBag> {
  const out: StorageBag = {};
  const keyList = keys == null
    ? null
    : Array.isArray(keys) ? keys : [keys];
  try {
    if (keyList === null) {
      for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (!k || !k.startsWith(LS_PREFIX)) continue;
        const raw = localStorage.getItem(k);
        if (raw != null) {
          try { out[k.slice(LS_PREFIX.length)] = JSON.parse(raw); }
          catch { /* skip bad json */ }
        }
      }
    } else {
      for (const key of keyList) {
        const raw = localStorage.getItem(LS_PREFIX + key);
        if (raw != null) {
          try { out[key] = JSON.parse(raw); }
          catch { /* skip bad json */ }
        }
      }
    }
  } catch { /* localStorage may be blocked; best-effort */ }
  return Promise.resolve(out);
}

function storageSet(items: StorageBag): Promise<void> {
  try {
    for (const [k, v] of Object.entries(items)) {
      localStorage.setItem(LS_PREFIX + k, JSON.stringify(v));
    }
  } catch { /* localStorage quota or block; best-effort */ }
  return Promise.resolve();
}

function storageRemove(keys: string | string[]): Promise<void> {
  const keyList = Array.isArray(keys) ? keys : [keys];
  try {
    for (const k of keyList) localStorage.removeItem(LS_PREFIX + k);
  } catch { /* best-effort */ }
  return Promise.resolve();
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
