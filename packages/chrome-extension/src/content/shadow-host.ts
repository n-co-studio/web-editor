/**
 * Mounts the Shadow DOM host for the Frontend Editor overlay.
 * All extension UI is rendered inside this shadow root, isolated
 * from the host page via `all: initial` CSS reset.
 */
export function mountShadowHost(): { host: HTMLDivElement; shadow: ShadowRoot } {
  const host = document.createElement('div');
  host.id = 'frontend-editor-overlay';
  host.setAttribute('data-frontend-editor', 'true');

  Object.assign(host.style, {
    position: 'fixed',
    top: '0',
    left: '0',
    right: '0',
    bottom: '0',
    zIndex: '2147483647',
    pointerEvents: 'none',
  } satisfies Partial<CSSStyleDeclaration>);

  const shadow = host.attachShadow({ mode: 'open' });

  // CSS reset + overlay token declarations (px values, not rem)
  const style = document.createElement('style');
  style.textContent = OVERLAY_CSS;
  shadow.appendChild(style);

  document.body.appendChild(host);
  return { host, shadow };
}

/** Remove the shadow host from the page. */
export function unmountShadowHost(host: HTMLDivElement): void {
  host.remove();
}

// ---------------------------------------------------------------------------
// Overlay stylesheet
// ---------------------------------------------------------------------------

const OVERLAY_CSS = /* css */ `
  :host {
    all: initial;
    position: fixed;
    top: 0; left: 0; right: 0; bottom: 0;
    z-index: 2147483647;
    pointer-events: none;

    /* Overlay tokens (px, not rem) */
    --fe-font: system-ui, -apple-system, BlinkMacSystemFont, sans-serif;
    --fe-mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    --fe-heading-size: 13px;
    --fe-heading-weight: 600;
    --fe-body-size: 12px;
    --fe-body-weight: 400;
    --fe-mono-size: 11px;
    --fe-mono-weight: 400;

    --fe-bg: rgba(0, 0, 0, 0.85);
    --fe-bg-subtle: rgba(0, 0, 0, 0.65);
    --fe-text: #ffffff;
    --fe-text-muted: #a1a1aa;
    --fe-border: rgba(255, 255, 255, 0.15);

    --fe-primary: #06b6d4;
    --fe-primary-hover: #0891b2;
    --fe-primary-light: #cffafe;
    --fe-accent: #fb7185;
    --fe-accent-hover: #f43f5e;

    --fe-destructive: #ef4444;
    --fe-success: #22c55e;
    --fe-warning: #f59e0b;
    --fe-info: #3b82f6;

    --fe-space: 4px;
    --fe-radius-sm: 4px;
    --fe-radius-md: 8px;
    --fe-radius-lg: 12px;

    --fe-shadow-md: 0 4px 6px rgba(0, 0, 0, 0.07);
    --fe-shadow-lg: 0 10px 15px rgba(0, 0, 0, 0.10);
  }

  *, *::before, *::after {
    box-sizing: border-box;
    margin: 0;
    padding: 0;
  }
`;
