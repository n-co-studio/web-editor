/**
 * Service worker for the Frontend Editor Chrome extension.
 * Intentionally minimal — the content script owns the WebSocket
 * connection to avoid MV3 service worker termination risk.
 *
 * Responsibilities:
 * 1. Toolbar icon click → send TOGGLE_EXTENSION to content script
 * 2. Badge text updates from content script
 */

// ---------------------------------------------------------------------------
// Toolbar icon click
// ---------------------------------------------------------------------------

chrome.action.onClicked.addListener((tab) => {
  if (!tab.id) return;
  chrome.tabs.sendMessage(tab.id, { type: 'TOGGLE_EXTENSION' }).catch(() => {
    // Content script not injected on this page (non-localhost)
  });
});

// ---------------------------------------------------------------------------
// Badge updates from content script
// ---------------------------------------------------------------------------

chrome.runtime.onMessage.addListener(
  (msg: { type: string; payload?: { count?: number } }, sender, sendResponse) => {
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
    return true; // keep sendResponse channel open
  },
);

// ---------------------------------------------------------------------------
// Install / update
// ---------------------------------------------------------------------------

chrome.runtime.onInstalled.addListener(() => {
  console.log('[frontend-editor] Extension installed');
});
