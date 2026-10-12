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
import {
  THEME_STORAGE_KEY,
  DEFAULT_THEME_PREFERENCE,
  isThemePreference,
  resolveTheme,
} from '../shared/theme';
import type { ThemePreference } from '../shared/theme';

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
const themeGroup = document.getElementById('theme-group') as HTMLDivElement;
const themeOpts = Array.from(
  themeGroup.querySelectorAll<HTMLButtonElement>('[data-theme]'),
);

let currentState: EditorState = { active: false, queueOpen: false };

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

const popupMq = window.matchMedia('(prefers-color-scheme: dark)');

function applyThemeToPopup(pref: ThemePreference): void {
  const resolved = resolveTheme(pref, popupMq.matches);
  document.documentElement.setAttribute('data-fe-theme', resolved);
}

function renderTheme(pref: ThemePreference): void {
  for (const btn of themeOpts) {
    btn.setAttribute('aria-checked', String(btn.dataset.theme === pref));
  }
  applyThemeToPopup(pref);
}

async function initThemePopup(): Promise<void> {
  let pref: ThemePreference = DEFAULT_THEME_PREFERENCE;
  try {
    const result = await chrome.storage.local.get(THEME_STORAGE_KEY);
    const stored = result[THEME_STORAGE_KEY];
    pref = isThemePreference(stored) ? stored : DEFAULT_THEME_PREFERENCE;
  } catch {
    /* storage unavailable — use default */
  }
  renderTheme(pref);

  // Re-resolve when OS flips while the popup is open
  popupMq.addEventListener('change', () => {
    const current = themeOpts.find(b => b.getAttribute('aria-checked') === 'true')?.dataset.theme;
    applyThemeToPopup(isThemePreference(current) ? current : DEFAULT_THEME_PREFERENCE);
  });
}

// Theme button clicks
themeGroup.addEventListener('click', async (e) => {
  const btn = (e.target as HTMLElement).closest<HTMLButtonElement>('[data-theme]');
  if (!btn) return;
  const pref = btn.dataset.theme;
  if (!isThemePreference(pref)) return;
  renderTheme(pref);
  try {
    await chrome.storage.local.set({ [THEME_STORAGE_KEY]: pref });
  } catch {
    /* non-fatal */
  }
});

// Keyboard navigation (arrow keys within radiogroup)
themeGroup.addEventListener('keydown', (e) => {
  if (!['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(e.key)) return;
  const idx = themeOpts.findIndex(b => b === document.activeElement);
  if (idx === -1) return;
  e.preventDefault();
  const dir = (e.key === 'ArrowRight' || e.key === 'ArrowDown') ? 1 : -1;
  const next = themeOpts[(idx + dir + themeOpts.length) % themeOpts.length];
  next.focus();
  next.click();
});

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
  hint.textContent = `AI Agent Visual Editor is unavailable on this page. Open a localhost dev page to use it. See the setup guide at ${GUIDE_URL}`;
}

async function init(): Promise<void> {
  // Theme is always initialized regardless of whether the tab is a localhost page
  void initThemePopup();

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
