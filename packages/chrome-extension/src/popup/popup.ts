/**
 * Toolbar icon popup (default_popup).
 *
 * Replaces the former chrome.action.onClicked one-click toggle: setting a
 * default_popup suppresses onClicked in MV3, so this popup is the menu surface.
 * It offers two actions — toggle the extension on/off, and open/close the
 * docked Change Request Queue panel — by messaging the content script. If the
 * content script is not yet injected (e.g. first interaction on a tab), it is
 * injected programmatically before the message is retried.
 */

import { GUIDE_URL } from '../shared/constants';
import { isLocalDevUrl } from '../shared/is-local-host';

interface EditorState {
  active: boolean;
  queueOpen: boolean;
}

const dot = document.getElementById('status-dot') as HTMLSpanElement;
const extStateEl = document.getElementById('extension-state') as HTMLSpanElement;
const queueBtn = document.getElementById('toggle-queue') as HTMLButtonElement;
const queueLabel = document.getElementById('queue-label') as HTMLSpanElement;
const queueStateEl = document.getElementById('queue-state') as HTMLSpanElement;
const extBtn = document.getElementById('toggle-extension') as HTMLButtonElement;
const hint = document.getElementById('hint') as HTMLDivElement;

let currentState: EditorState = { active: false, queueOpen: false };

async function getActiveTab(): Promise<chrome.tabs.Tab | undefined> {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

/**
 * The extension is documented as running only on the developer's own machine.
 * The manifest's content_scripts.matches enforces that for automatic
 * injection; this check enforces it for the programmatic path below, so the
 * popup never injects the editor into a public page. `activeTab` gives us the
 * URL of the tab the user opened the popup on.
 */
async function getLocalDevTabId(): Promise<number | undefined> {
  const tab = await getActiveTab();
  if (tab?.id == null) return undefined;
  return isLocalDevUrl(tab.url) ? tab.id : undefined;
}

/** Send a message to the content script, injecting it first if not present. */
async function sendToTab(tabId: number, message: { type: string }): Promise<EditorState | undefined> {
  try {
    return (await chrome.tabs.sendMessage(tabId, message)) as EditorState | undefined;
  } catch {
    // Content script not present — inject programmatically, then retry once.
    await chrome.scripting.executeScript({ target: { tabId }, files: ['content.js'] });
    return (await chrome.tabs.sendMessage(tabId, message)) as EditorState | undefined;
  }
}

function render(state: EditorState): void {
  currentState = state;
  dot.classList.toggle('on', state.active);
  extStateEl.textContent = state.active ? 'On' : 'Off';
  extStateEl.classList.toggle('active', state.active);
  extBtn.setAttribute('aria-pressed', String(state.active));
  queueLabel.textContent = state.queueOpen ? 'Close Change Queue' : 'Open Change Queue';
  queueStateEl.textContent = state.queueOpen ? 'Open' : '';
  queueStateEl.classList.toggle('active', state.queueOpen);
  queueBtn.setAttribute('aria-pressed', String(state.queueOpen));
}

function renderUnavailable(): void {
  extBtn.disabled = true;
  queueBtn.disabled = true;
  hint.textContent = `Visual Web Editor for AI Agents is unavailable on this page. Open a localhost dev page to use it. See the setup guide at ${GUIDE_URL}`;
}

async function init(): Promise<void> {
  const tabId = await getLocalDevTabId();
  if (tabId == null) {
    renderUnavailable();
    return;
  }
  try {
    const state = await sendToTab(tabId, { type: 'GET_STATE' });
    if (state) render(state);
  } catch {
    renderUnavailable();
  }
}

extBtn.addEventListener('click', async () => {
  const tabId = await getLocalDevTabId();
  if (tabId == null) return;
  try {
    const state = await sendToTab(tabId, { type: 'TOGGLE_EXTENSION' });
    // TOGGLE_EXTENSION returns { active }; preserve known queue state.
    render({ active: state?.active ?? !currentState.active, queueOpen: currentState.queueOpen });
  } catch {
    renderUnavailable();
  }
});

queueBtn.addEventListener('click', async () => {
  const tabId = await getLocalDevTabId();
  if (tabId == null) return;
  try {
    await sendToTab(tabId, { type: 'TOGGLE_QUEUE_PANEL' });
    // The panel now overlays the page — close the popup so it is visible.
    window.close();
  } catch {
    renderUnavailable();
  }
});

void init();
