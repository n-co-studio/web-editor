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

import { isLocalDevUrl } from '../shared/is-local-host';
import { isInjectableUrl } from '../shared/page-support';
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
 * The tab the editor can run in, or undefined if this page cannot host it.
 *
 * Clicking the toolbar icon is what grants `activeTab` for the current tab, so
 * the editor can run on any ordinary page — not just a dev server. The only
 * pages ruled out are the ones Chrome refuses to let extensions script at all
 * (see `isInjectableUrl`), where injecting would fail with an opaque error.
 *
 * Automatic injection is a separate matter and stays narrow: the manifest's
 * `content_scripts.matches` covers localhost only, so nothing runs uninvited on
 * a site you are merely visiting.
 */
async function getEditableTabId(): Promise<number | undefined> {
  const tab = await getActiveTab();
  if (tab?.id == null) return undefined;
  return isInjectableUrl(tab.url) ? tab.id : undefined;
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

/**
 * Shown only where Chrome will not let any extension run — its own pages, the
 * Web Store, `file:` URLs. Not a policy message: on an ordinary page the editor
 * works, whether or not it is a dev server.
 */
function renderUnavailable(): void {
  extBtn.disabled = true;
  queueBtn.disabled = true;
  hint.textContent =
    'Chrome does not allow extensions to run on this page. Open an ordinary web page — your dev server, or any site you want to work on.';
}

/**
 * What you get on this page. Off a dev server the editor still works — you can
 * select, adjust and queue changes — but the agent cannot write them back:
 * source mapping comes from `data-source-file` attributes the dev plugin adds
 * at build time, which a production page has never had.
 */
function renderScopeHint(url: string | undefined): void {
  hint.textContent = isLocalDevUrl(url)
    ? 'Works on localhost dev pages.'
    : 'Editing works here, but changes stay in the browser — source mapping needs your dev server.';
}

async function init(): Promise<void> {
  // Theme is always initialized, whatever page the popup was opened on.
  void initThemePopup();

  const tab = await getActiveTab();
  const tabId = isInjectableUrl(tab?.url) && tab?.id != null ? tab.id : undefined;
  if (tabId == null) {
    renderUnavailable();
    return;
  }
  renderScopeHint(tab?.url);
  try {
    const state = await sendToTab(tabId, { type: 'GET_STATE' });
    if (state) render(state);
  } catch {
    // The content script is not there yet — normal on a page where it has to be
    // injected by a click. The buttons stay live; clicking one injects it.
  }
}

extBtn.addEventListener('click', async () => {
  const tabId = await getEditableTabId();
  if (tabId == null) return;
  try {
    const state = await sendToTab(tabId, { type: 'TOGGLE_EXTENSION' });
    // TOGGLE_EXTENSION returns { active }; preserve known queue state.
    render({ active: state?.active ?? !currentState.active, queueOpen: currentState.queueOpen });
  } catch {
    // Injection itself failed (sendToTab already retried once). Report that,
    // rather than claiming the page is unsupported — it is, we just could not
    // reach it.
    hint.textContent = 'Could not start the editor on this page. Reload the page and try again.';
  }
});

queueBtn.addEventListener('click', async () => {
  const tabId = await getEditableTabId();
  if (tabId == null) return;
  try {
    await sendToTab(tabId, { type: 'TOGGLE_QUEUE_PANEL' });
    // The panel now overlays the page — close the popup so it is visible.
    window.close();
  } catch {
    hint.textContent = 'Could not open the change queue on this page. Reload the page and try again.';
  }
});

void init();
