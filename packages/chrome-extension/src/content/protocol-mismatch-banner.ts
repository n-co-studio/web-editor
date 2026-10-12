/**
 * Protocol mismatch banner — shown in the Shadow DOM overlay when the extension
 * and MCP server are running incompatible protocol versions.
 *
 * The banner is persistent and non-dismissible: the user must update their MCP
 * server (or extension) to restore functionality.
 *
 * Styling uses overlay CSS custom properties (--fe-*) from shadow-host.ts so
 * the banner is consistent with the rest of the overlay and never leaks styles
 * to the host page.
 *
 * Motion: respects `prefers-reduced-motion` — transition is suppressed when
 * the user has requested reduced motion.
 */

const BANNER_ID = 'nco-web-editor-protocol-mismatch';

export function showProtocolMismatchBanner(
  shadow: ShadowRoot,
  serverVersion: string,
  clientVersion: string,
): void {
  // Idempotent — don't show multiple banners if somehow called twice
  if (shadow.getElementById(BANNER_ID)) return;

  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  const banner = document.createElement('div');
  banner.id = BANNER_ID;

  // Inline styles — no class names that could bleed from/to host page
  Object.assign(banner.style, {
    position: 'fixed',
    top: '0',
    left: '0',
    right: '0',
    zIndex: '2147483647',
    display: 'flex',
    alignItems: 'flex-start',
    gap: '12px',
    padding: '14px 20px',
    background: 'var(--fe-bg)',
    borderBottom: '2px solid var(--fe-destructive)',
    color: 'var(--fe-text)',
    fontFamily: 'var(--fe-font)',
    fontSize: '12px',
    lineHeight: '1.5',
    pointerEvents: 'auto',
    boxShadow: 'var(--fe-shadow-lg)',
    opacity: reducedMotion ? '1' : '0',
    transition: reducedMotion ? 'none' : 'opacity 0.2s ease',
  } satisfies Partial<CSSStyleDeclaration>);

  const icon = document.createElement('span');
  Object.assign(icon.style, {
    flexShrink: '0',
    marginTop: '1px',
    color: 'var(--fe-destructive)',
    fontSize: '14px',
    fontWeight: '700',
  } satisfies Partial<CSSStyleDeclaration>);
  icon.textContent = '⚠';
  icon.setAttribute('aria-hidden', 'true');

  const body = document.createElement('div');
  body.style.flex = '1';

  const heading = document.createElement('div');
  Object.assign(heading.style, {
    fontWeight: '600',
    fontSize: '13px',
    marginBottom: '4px',
    color: 'var(--fe-destructive)',
  } satisfies Partial<CSSStyleDeclaration>);
  heading.textContent = "AI Agent Visual Editor — Protocol Version Mismatch";

  const detail = document.createElement('div');
  Object.assign(detail.style, {
    color: 'var(--fe-text-muted)',
    marginBottom: '8px',
  } satisfies Partial<CSSStyleDeclaration>);
  detail.textContent =
    `Extension expects protocol ${clientVersion} but the MCP server sent ${serverVersion}. ` +
    `The WebSocket connection has been closed to prevent data corruption.`;

  const fix = document.createElement('div');
  fix.style.marginTop = '4px';

  const fixLabel = document.createElement('span');
  fixLabel.style.color = 'var(--fe-text-muted)';
  fixLabel.textContent = 'Fix: ';

  const fixCmd = document.createElement('code');
  Object.assign(fixCmd.style, {
    fontFamily: 'var(--fe-mono)',
    fontSize: '11px',
    background: 'var(--fe-hover)',
    padding: '2px 6px',
    borderRadius: '3px',
    color: 'var(--fe-warning)',
    userSelect: 'all',
  } satisfies Partial<CSSStyleDeclaration>);
  fixCmd.textContent = 'npx --yes @nco-studio/web-editor-mcp@latest';

  fix.appendChild(fixLabel);
  fix.appendChild(fixCmd);

  body.appendChild(heading);
  body.appendChild(detail);
  body.appendChild(fix);

  banner.appendChild(icon);
  banner.appendChild(body);

  shadow.appendChild(banner);

  // Fade in (skip if reduced-motion)
  if (!reducedMotion) {
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        banner.style.opacity = '1';
      });
    });
  }
}
