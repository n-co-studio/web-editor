/**
 * Service worker for the n'co studio Web Editor Chrome extension.
 * Intentionally minimal — the content script owns the WebSocket
 * connection to avoid MV3 service worker termination risk.
 *
 * Responsibilities:
 * 1. Badge text updates from content script
 * 2. Status icon updates from content script (chrome.action.setIcon)
 * 3. Viewport capture for full-page screenshots
 *
 * The toolbar icon uses a default_popup (popup.html) for its menu, so there is
 * no chrome.action.onClicked handler here — setting default_popup suppresses the
 * onClicked event in MV3. The popup messages the content script directly
 * (TOGGLE_EXTENSION / TOGGLE_QUEUE_PANEL), injecting content.js if needed.
 */

import type { IconStatus } from '../shared/types';

// ---------------------------------------------------------------------------
// Status icon paths (bundled to dist/icons/status by esbuild.config.js)
// ---------------------------------------------------------------------------

const ICON_PATHS: Record<IconStatus, string> = {
  disabled: 'icons/status/nco-web-editor-icon-disabled.png',
  active: 'icons/status/nco-web-editor-icon-active.png',
  orange: 'icons/status/nco-web-editor-icon-orange.png',
  green: 'icons/status/nco-web-editor-icon-green.png',
  red: 'icons/status/nco-web-editor-icon-red.png',
};

const ICON_TITLES: Record<IconStatus, string> = {
  disabled: "n'co studio Web Editor — off",
  active: "n'co studio Web Editor — connected",
  orange: "n'co studio Web Editor — pending changes",
  green: "n'co studio Web Editor — changes applied",
  red: "n'co studio Web Editor — connection error",
};

// Toolbar icon sizes Chrome requests. We rasterize the source PNG to these via
// OffscreenCanvas and hand setIcon ImageData — chrome.action.setIcon({ path })
// from an MV3 service worker is unreliable, whereas { imageData } always applies
// (and downscaling here is sharper than letting Chrome scale one large PNG).
const ICON_SIZES = [16, 32, 48, 128];

/** Cache of rasterized ImageData per status (keyed by size). */
const iconImageDataCache = new Map<IconStatus, Record<number, ImageData>>();

async function getIconImageData(status: IconStatus): Promise<Record<number, ImageData>> {
  const cached = iconImageDataCache.get(status);
  if (cached) return cached;

  const url = chrome.runtime.getURL(ICON_PATHS[status]);
  const blob = await (await fetch(url)).blob();
  const bitmap = await createImageBitmap(blob);

  const imageData: Record<number, ImageData> = {};
  for (const size of ICON_SIZES) {
    const canvas = new OffscreenCanvas(size, size);
    const ctx = canvas.getContext('2d');
    if (!ctx) continue;
    ctx.clearRect(0, 0, size, size);
    ctx.drawImage(bitmap, 0, 0, size, size);
    imageData[size] = ctx.getImageData(0, 0, size, size);
  }
  bitmap.close();

  // If no canvas context was available, don't cache an empty result — throw so
  // the caller falls back to the path-based setIcon.
  if (Object.keys(imageData).length === 0) {
    throw new Error('icon rasterization produced no image data');
  }

  iconImageDataCache.set(status, imageData);
  return imageData;
}

/** Apply the status icon to a tab, preferring ImageData with a path fallback. */
async function applyStatusIcon(status: IconStatus, tabId: number | undefined): Promise<void> {
  try {
    const imageData = await getIconImageData(status);
    await chrome.action.setIcon({ imageData, tabId });
  } catch {
    // Fallback: best-effort path-based set (and ignore navigated-away tabs).
    chrome.action.setIcon({ path: ICON_PATHS[status], tabId }).catch(() => {});
  }
}

// ---------------------------------------------------------------------------
// Badge updates from content script
// ---------------------------------------------------------------------------

chrome.runtime.onMessage.addListener(
  (msg: { type: string; payload?: { count?: number; status?: IconStatus } }, sender, sendResponse) => {
    // Only honor messages from this extension's own contexts. CAPTURE_VIEWPORT
    // triggers a full-tab screenshot — without this guard another installed
    // extension could silently capture the active tab. Reject foreign senders.
    if (sender.id !== chrome.runtime.id) return false;
    if (msg.type === 'CAPTURE_VIEWPORT') {
      const windowId = sender.tab?.windowId;
      if (windowId == null) {
        sendResponse({ error: 'No window ID' });
        return true;
      }
      chrome.tabs.captureVisibleTab(windowId, { format: 'png' })
        .then((dataUrl) => sendResponse({ dataUrl }))
        .catch((err) => sendResponse({ error: String(err) }));
      return true;
    }

    if (msg.type === 'UPDATE_BADGE') {
      const count = msg.payload?.count ?? 0;
      const text = count > 0 ? String(count) : '';

      chrome.action.setBadgeText({ text, tabId: sender.tab?.id });
      chrome.action.setBadgeBackgroundColor({
        color: '#fb7185', // accent color
        tabId: sender.tab?.id,
      });

      sendResponse({ success: true });
    }

    if (msg.type === 'UPDATE_ICON') {
      const status: IconStatus = msg.payload?.status ?? 'disabled';
      const tabId = sender.tab?.id;
      void applyStatusIcon(status, tabId);
      void Promise.resolve(chrome.action.setTitle({ title: ICON_TITLES[status], tabId })).catch(() => {
        // Tab may have navigated away — non-fatal
      });
      sendResponse({ success: true });
    }
    return true; // keep sendResponse channel open
  },
);

// ---------------------------------------------------------------------------
// Install / update
// ---------------------------------------------------------------------------

chrome.runtime.onInstalled.addListener(() => {
  console.log('[nco-web-editor] Extension installed');
});
