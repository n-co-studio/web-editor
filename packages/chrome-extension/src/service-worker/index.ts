/**
 * Service worker for the Frontend Editor Chrome extension.
 * Intentionally minimal — the content script owns the WebSocket
 * connection to avoid MV3 service worker termination risk.
 *
 * Responsibilities:
 * 1. Toolbar icon click → send TOGGLE_EXTENSION to content script
 * 2. Badge text updates from content script
 * 3. Status icon updates from content script (chrome.action.setIcon)
 * 4. Viewport capture for full-page screenshots
 */

import type { IconStatus } from '../shared/types';

// ---------------------------------------------------------------------------
// Status icon paths (bundled to dist/icons/status by esbuild.config.js)
// ---------------------------------------------------------------------------

const ICON_PATHS: Record<IconStatus, string> = {
  disabled: 'icons/status/frontend-editor-icon-disabled.png',
  active: 'icons/status/frontend-editor-icon-active.png',
  orange: 'icons/status/frontend-editor-icon-orange.png',
  green: 'icons/status/frontend-editor-icon-green.png',
  red: 'icons/status/frontend-editor-icon-red.png',
};

const ICON_TITLES: Record<IconStatus, string> = {
  disabled: 'Frontend Editor — off',
  active: 'Frontend Editor — connected',
  orange: 'Frontend Editor — pending changes',
  green: 'Frontend Editor — changes applied',
  red: 'Frontend Editor — connection error',
};

// ---------------------------------------------------------------------------
// Toolbar icon click
// ---------------------------------------------------------------------------

chrome.action.onClicked.addListener(async (tab) => {
  if (!tab.id) return;
  try {
    // Try sending to already-injected content script (localhost auto-inject)
    await chrome.tabs.sendMessage(tab.id, { type: 'TOGGLE_EXTENSION' });
  } catch {
    // Content script not present — inject programmatically, then toggle
    try {
      await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        files: ['content.js'],
      });
      await chrome.tabs.sendMessage(tab.id, { type: 'TOGGLE_EXTENSION' });
    } catch {
      // Injection failed (chrome://, web store, etc.) — silently ignore
    }
  }
});

// ---------------------------------------------------------------------------
// Badge updates from content script
// ---------------------------------------------------------------------------

chrome.runtime.onMessage.addListener(
  (msg: { type: string; payload?: { count?: number; status?: IconStatus } }, sender, sendResponse) => {
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
      chrome.action.setIcon({ path: ICON_PATHS[status], tabId }).catch(() => {
        // Tab may have navigated away — non-fatal
      });
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
  console.log('[frontend-editor] Extension installed');
});
