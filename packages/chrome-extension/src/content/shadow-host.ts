/**
 * Mounts the Shadow DOM host for the AI Agent Visual Editor overlay.
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
    --fe-text-muted: #b4b4bc;
    --fe-text-inverse: #ffffff;
    --fe-border: rgba(255, 255, 255, 0.15);
    /* Outline for a colour swatch. Distinct from --fe-border because a swatch
       is filled with an arbitrary colour, so its edge must read against the
       FILL as well as the panel: the general border is far too faint to
       separate a white swatch from a light panel. */
    --fe-swatch-border: rgba(255, 255, 255, 0.45);
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
    /* #60a5fa: #3b82f6 was 3.51:1 on its own tint in the multi-select header. */
    --fe-info: #60a5fa;

    /* Fill role: a filled chip or button, always with white text. */
    --fe-destructive-fill: #dc2626;
    --fe-destructive-fill-hover: #b91c1c;
    --fe-on-destructive: #ffffff;
    --fe-info-fill: #1d4ed8;
    --fe-on-info: #ffffff;

    /* Field and band fills. Themed because a white overlay is invisible on the
       light panel; these were literals (rgba(255,255,255,0.1) / 0.04) before. */
    --fe-input-bg: rgba(255, 255, 255, 0.10);
    --fe-band: rgba(255, 255, 255, 0.04);

    /* Primary as TEXT on a primary tint (token chips, element pills). Plain
       --fe-primary on a 12% tint of itself is 5.12:1 here; kept as its own role
       so light mode can darken it without touching the primary fill. */
    --fe-primary-strong: #06b6d4;

    /* Insert mode. Text role is legible on the panel and on a 12% tint
       (5.18:1); the fill carries white text (5.48:1). */
    --fe-insert-text: #34d399;
    --fe-insert-fill: #047857;
    --fe-on-insert: #ffffff;

    /* Change-type text in the review queue, each >= 4.5:1 on its 12% tint. */
    --fe-reorder-text: #a5b4fc;
    --fe-group-text: #c4b5fd;
    --fe-var-text: #c084fc;

    /* Box-model labels in DevTools. Same hues as the on-page handles, which
       stay untouched; only their use as panel TEXT is themed. */
    --fe-box-margin-text: #fb7185;
    --fe-box-padding-text: #f59e0b;
    --fe-box-content-text: #06b6d4;

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
    /* Dark in this theme: the case that drove it is a white swatch on the
       near-white panel, which the 0.14 general border left invisible. */
    --fe-swatch-border: rgba(0, 0, 0, 0.38);
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
    /* Text role measured on the panel over a DARK page (#f2f2f2), the worst case:
       #dc2626 was 4.32:1 there; #b91c1c = 5.79:1. The fill keeps #dc2626. */
    --fe-destructive: #b91c1c;
    /* --fe-success: #166534 = 7.24:1 vs white ✓ */
    --fe-success: #166534;
    /* #b45309 was 4.50:1 on #f2f2f2 and 3.45:1 on its tint; #92400e = 6.35:1 / 5.30:1. */
    --fe-warning: #92400e;
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


    --fe-input-bg: rgba(0, 0, 0, 0.04);
    --fe-band: rgba(0, 0, 0, 0.03);
    /* #0c6479 = 5.07:1 on a 12% primary tint over the panel; #0e7490 was 4.09:1. */
    --fe-primary-strong: #0c6479;
    /* #065f46 = 5.72:1 on its 12% tint; #10b981 was 2.54:1 as text on white. */
    --fe-insert-text: #065f46;
    --fe-insert-fill: #047857;
    --fe-on-insert: #ffffff;
    --fe-reorder-text: #4338ca;
    --fe-group-text: #6d28d9;
    --fe-var-text: #7e22ce;
    /* Handle hues darkened for text: #f59e0b on white was 2.15:1, #fb7185 2.69:1,
       #06b6d4 2.43:1. */
    --fe-box-margin-text: #be123c;
    --fe-box-padding-text: #92400e;
    --fe-box-content-text: #0c6479;

    --fe-shadow-md: 0 4px 6px rgba(0, 0, 0, 0.08);
    --fe-shadow-lg: 0 10px 15px rgba(0, 0, 0, 0.12);
  }

  *, *::before, *::after {
    box-sizing: border-box;
    margin: 0;
    padding: 0;
  }
`;
