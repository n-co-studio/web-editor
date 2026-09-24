/**
 * Local dev-host predicate.
 *
 * The extension is documented — in the store listing, the privacy policy and
 * the `scripting` permission justification — as running only on a developer's
 * own machine. The manifest's `content_scripts.matches` covers the automatic
 * injection path; this predicate covers the programmatic one (the popup's
 * `chrome.scripting.executeScript` fallback) and the content script's own
 * activation guard, so the claim holds wherever the bundle is reached from.
 *
 * Deliberately strict: a hostname must BE a loopback name, not merely contain
 * one. `localhost.evil.com` and `notlocalhost` are public hosts.
 */

/** Loopback hostnames, compared case-insensitively after normalisation. */
const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1', '::1', '0:0:0:0:0:0:0:1']);

/**
 * True when `hostname` is the developer's own machine: `localhost`, any
 * `*.localhost` subdomain (reserved for loopback by RFC 6761), the IPv4
 * loopback address, or IPv6 loopback in bracketed or bare form.
 *
 * Note this checks the *name*, not the resolved address: a public hostname
 * that happens to resolve to 127.0.0.1 is not treated as local, which is the
 * conservative choice for a permission claim.
 */
export function isLocalDevHost(hostname: string | null | undefined): boolean {
  if (!hostname) return false;

  // `location.hostname` yields IPv6 in brackets; URL.hostname does too.
  // Strip IPv6 brackets and a trailing FQDN dot ("localhost." is still loopback).
  const host = hostname
    .trim()
    .toLowerCase()
    .replace(/^\[/, '')
    .replace(/\]$/, '')
    .replace(/\.$/, '');
  if (host === '') return false;

  if (LOOPBACK_HOSTS.has(host)) return true;

  // RFC 6761 reserves the whole `.localhost` TLD for loopback.
  return host.endsWith('.localhost');
}

/**
 * True when `url` points at a local dev host over a web scheme. Used by the
 * popup, which sees a URL string rather than a live `location`.
 */
export function isLocalDevUrl(url: string | null | undefined): boolean {
  if (!url) return false;
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return false;
    return isLocalDevHost(parsed.hostname);
  } catch {
    return false;
  }
}
