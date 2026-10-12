/**
 * Mounts the Shadow DOM host for the Visual Web Editor for AI Agents overlay.
 * All extension UI is rendered inside this shadow root, isolated
 * from the host page via `all: initial` CSS reset.
 */
export function mountShadowHost(): { host: HTMLDivElement; shadow: ShadowRoot } {
  const host = document.createElement('div');
  host.id = 'nco-web-editor-overlay';
  host.setAttribute('data-nco-web-editor', 'true');

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

    /* Dark theme (default) */
    --fe-bg: rgba(0, 0, 0, 0.85);
    --fe-bg-subtle: rgba(0, 0, 0, 0.65);
    --fe-bg-raised: rgba(30, 30, 35, 0.90);
    --fe-text: #ffffff;
    --fe-text-muted: #a1a1aa;
    --fe-text-inverse: #ffffff;
    --fe-border: rgba(255, 255, 255, 0.15);
    --fe-hover: rgba(255, 255, 255, 0.08);
    --fe-active: rgba(255, 255, 255, 0.12);

    --fe-primary: #06b6d4;
    --fe-primary-hover: #0891b2;
    --fe-primary-light: #cffafe;
    /* Text on a primary fill. Black here because dark-theme primary is a bright
       cyan: #000 on #06b6d4 = 8.65:1, where white would be only 2.43:1. */
    --fe-on-primary: #000000;
    --fe-accent: #fb7185;
    --fe-accent-hover: #f43f5e;
    /* Accent is a light rose and is not redefined per-theme, so one foreground
       serves both: black is 7.80:1 on the base and 5.72:1 on hover, where white
       would be 2.69:1 and 3.67:1. */
    --fe-on-accent: #000000;

    /* Semantic colors here are the TEXT role — read against a dark panel.
       #f87171 rather than #ef4444: the latter is 4.41:1 on --fe-bg-raised and
       3.82:1 on the tinted warning chip, both under AA. #f87171 gives 6.00:1
       and 5.20:1. Fills are separate tokens below, for the same reason primary
       needed one — a colour legible as text on dark is too light to carry
       white text as a background. */
    --fe-destructive: #f87171;
    --fe-success: #22c55e;
    --fe-warning: #f59e0b;
    --fe-info: #3b82f6;

    /* Fill role: a filled chip or button, always with white text. */
    --fe-destructive-fill: #dc2626;
    --fe-destructive-fill-hover: #b91c1c;
    --fe-on-destructive: #ffffff;
    --fe-info-fill: #1d4ed8;
    --fe-on-info: #ffffff;

    --fe-space: 4px;
    --fe-radius-sm: 4px;
    --fe-radius-md: 8px;
    --fe-radius-lg: 12px;

    --fe-shadow-md: 0 4px 6px rgba(0, 0, 0, 0.07);
    --fe-shadow-lg: 0 10px 15px rgba(0, 0, 0, 0.10);
  }

  /* Light theme — redefine only chrome tokens; on-page indicator tokens are unchanged */
  :host([data-fe-theme="light"]) {
    --fe-bg: rgba(255, 255, 255, 0.95);
    --fe-bg-subtle: rgba(248, 248, 250, 0.92);
    --fe-bg-raised: rgba(255, 255, 255, 1);
    --fe-text: #18181b;
    --fe-text-muted: #52525b;
    --fe-text-inverse: #000000;
    --fe-border: rgba(0, 0, 0, 0.14);
    --fe-hover: rgba(0, 0, 0, 0.06);
    --fe-active: rgba(0, 0, 0, 0.10);

    /* Primary darkened for 4.5:1 AA on light background: #0e7490 = 5.33:1 vs white */
    --fe-primary: #0e7490;
    --fe-primary-hover: #0c6479;
    --fe-primary-light: #cffafe;
    /* Text on a primary fill, and the reason this token exists. The darkening
       above was chosen for primary used AS text on white; used as a FILL it
       needs the opposite foreground. Black on #0e7490 is 3.92:1 (3.11:1 on the
       hover shade) and fails AA; white is 5.36:1 and 6.74:1. */
    --fe-on-primary: #ffffff;

    /* Semantic colors adjusted for AA on light backgrounds */
    /* --fe-destructive: #dc2626 = 4.87:1 vs white ✓ */
    --fe-destructive: #dc2626;
    /* --fe-success: #166534 = 7.24:1 vs white ✓ */
    --fe-success: #166534;
    /* --fe-warning: #b45309 = 5.02:1 vs white ✓ */
    --fe-warning: #b45309;
    /* --fe-info: #1d4ed8 = 6.77:1 vs white ✓ */
    --fe-info: #1d4ed8;

    /* Fill role — same values as the light text role here, since a colour that
       reads on white is already dark enough to carry white text. Declared
       explicitly rather than inherited so the two roles stay independent. */
    --fe-destructive-fill: #dc2626;
    --fe-destructive-fill-hover: #b91c1c;
    --fe-on-destructive: #ffffff;
    --fe-info-fill: #1d4ed8;
    --fe-on-info: #ffffff;

    --fe-shadow-md: 0 4px 6px rgba(0, 0, 0, 0.08);
    --fe-shadow-lg: 0 10px 15px rgba(0, 0, 0, 0.12);
  }

  *, *::before, *::after {
    box-sizing: border-box;
    margin: 0;
    padding: 0;
  }
`;
