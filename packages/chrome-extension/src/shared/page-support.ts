/**
 * Where the editor can be injected at all.
 *
 * This is a capability check, not a policy one. The editor is a design tool for
 * the page in front of you: on your dev server it loads automatically (the
 * manifest's `content_scripts.matches`), and anywhere else it loads when you
 * click the toolbar icon, which is what `activeTab` grants. Both are legitimate,
 * so this predicate only rules out pages Chrome itself refuses to let an
 * extension script — asking would fail with an opaque error, and the popup can
 * say something useful instead.
 *
 * Deliberately NOT a localhost check. An earlier version of this extension
 * refused every non-localhost page, which removed a capability the product has
 * on purpose: you can edit a site you are not synced to. What you lose off
 * localhost is source mapping, not editing — `data-source-file` comes from the
 * dev plugin at build time, so a production page has nothing to map back to.
 * `is-local-host.ts` answers that question and drives a hint; it does not gate.
 */

/**
 * Schemes an extension content script cannot run in. Chrome rejects
 * `chrome.scripting.executeScript` against all of these regardless of
 * permissions, so there is nothing a user could grant to change it.
 *
 * `file:` is included because it additionally needs the per-extension
 * "Allow access to file URLs" toggle, which this extension does not ask for.
 */
const BLOCKED_PROTOCOLS = new Set([
  'chrome:',
  'chrome-untrusted:',
  'chrome-extension:',
  'devtools:',
  'about:',
  'view-source:',
  'data:',
  'blob:',
  'javascript:',
  'file:',
  'edge:',
  'brave:',
  'opera:',
  'vivaldi:',
]);

/**
 * Hosts Chrome protects from extension scripting. The Web Store is blocked by
 * the browser itself; scripting it fails no matter what the manifest asks for.
 */
const BLOCKED_HOSTS = new Set([
  'chromewebstore.google.com',
  'chrome.google.com',
  'microsoftedge.microsoft.com',
]);

/**
 * True when the editor can be injected into `url`.
 *
 * Only `http:` and `https:` pages qualify, minus the browser's own protected
 * origins. Anything unparseable is refused — an unknown URL is not a page we
 * can reason about.
 */
export function isInjectableUrl(url: string | null | undefined): boolean {
  if (!url) return false;

  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return false;
  }

  if (BLOCKED_PROTOCOLS.has(parsed.protocol)) return false;
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return false;

  const host = parsed.hostname.toLowerCase().replace(/\.$/, '');
  if (BLOCKED_HOSTS.has(host)) return false;

  // The Web Store also lives under chrome.google.com/webstore on older Chrome.
  if (host === 'chrome.google.com' && parsed.pathname.startsWith('/webstore')) return false;

  return true;
}
