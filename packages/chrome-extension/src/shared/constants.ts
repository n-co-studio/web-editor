// ---------------------------------------------------------------------------
// WebSocket
// ---------------------------------------------------------------------------

export const WS_PORT_BASE = 7890;
export const WS_PORT_RANGE = 10;
export const WS_BACKOFF_BASE_MS = 1_000;
export const WS_BACKOFF_MAX_MS = 30_000;
export const WS_MAX_RETRIES = 0; // 0 = unlimited — keep retrying indefinitely
export const WS_KEEPALIVE_INTERVAL_MS = 20_000;
// HACK-008: max time to wait for the peer to identify itself as the MCP server
// (proactive SERVER_HELLO, or a STATUS_RESPONSE to our identifier-free probe)
// before abandoning the port. No identifiers are disclosed until confirmation.
export const WS_HANDSHAKE_TIMEOUT_MS = 2_000;

// ---------------------------------------------------------------------------
// Batching
// ---------------------------------------------------------------------------

export const MAX_DIFFS_PER_BATCH = 100;
export const BATCH_CONFIRM_THRESHOLD = 50;

// ---------------------------------------------------------------------------
// UI measurements
// ---------------------------------------------------------------------------

export const PANEL_MAX_WIDTH = 300;
export const HANDLE_VISUAL_SIZE = 7;
export const HANDLE_HIT_AREA = 20;
export const SELECTOR_TRUNCATE_LENGTH = 40;
export const TEXT_CONTENT_TRUNCATE_LENGTH = 80;

// ---------------------------------------------------------------------------
// Timings
// ---------------------------------------------------------------------------

export const SNAP_EASE_MS = 125;
/**
 * Outer width of the floating toolbar, and the offset every editing panel
 * anchors off (`anchorPos.x + TOOLBAR_WIDTH + 8`). Two 32px button columns,
 * a 2px gap, 4px padding each side: 32 + 2 + 32 + 8 = 74.
 */
export const TOOLBAR_WIDTH = 74;
/** One button cell — the grid track width sections lay out against. */
export const TOOLBAR_BUTTON_SIZE = 32;
/** Columns per toolbar section. Arrow-key navigation steps by this for Up/Down. */
export const TOOLBAR_COLUMNS = 2;
export const NOTES_PANEL_MAX_HEIGHT = 320;
export const NOTES_PANEL_WIDTH = 260;

// DevTools bottom panel
export const DEVTOOLS_DEFAULT_HEIGHT = 250;
export const DEVTOOLS_MIN_HEIGHT = 120;
export const DEVTOOLS_MAX_HEIGHT_RATIO = 0.6;
export const DEVTOOLS_DEFAULT_LEFT_RATIO = 0.30;
export const DEVTOOLS_DEFAULT_MIDDLE_RATIO = 0.40;

// Change Request Queue — right-docked side panel
export const QUEUE_PANEL_DEFAULT_WIDTH = 340;
export const QUEUE_PANEL_MIN_WIDTH = 260;
export const QUEUE_PANEL_MAX_WIDTH_RATIO = 0.5;

// ---------------------------------------------------------------------------
// Overlay design tokens (px, not rem — isolated in Shadow DOM)
// ---------------------------------------------------------------------------

export const OVERLAY = {
  // Typography (static — not themed, not var())
  fontFamily: 'system-ui, -apple-system, BlinkMacSystemFont, sans-serif',
  monoFamily: 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace',
  headingSize: '13px',
  headingWeight: '600',
  bodySize: '12px',
  bodyWeight: '400',
  monoSize: '11px',
  monoWeight: '400',

  // Chrome colors — CSS custom property references.
  // Safe because every overlay element lives inside the shadow root, so
  // var() resolves against the :host token block. NOT safe for canvas
  // fillStyle, color-math helpers, or string comparisons — use resolved
  // computed values in those contexts (see ruler-overlay.ts).
  bg: 'var(--fe-bg)',
  bgSubtle: 'var(--fe-bg-subtle)',
  bgRaised: 'var(--fe-bg-raised)',
  text: 'var(--fe-text)',
  textMuted: 'var(--fe-text-muted)',
  border: 'var(--fe-border)',
  /** Outline for a colour swatch — must read against the swatch's own fill,
   *  not just the panel. Use this anywhere a user-chosen colour is shown as a
   *  filled chip; `border` is too faint for white-on-white. */
  swatchBorder: 'var(--fe-swatch-border)',
  hover: 'var(--fe-hover)',
  active: 'var(--fe-active)',

  // Brand — UI accent only (see SELECTION.ring for the on-page indicator)
  primary: 'var(--fe-primary)',
  primaryHover: 'var(--fe-primary-hover)',
  primaryLight: 'var(--fe-primary-light)',
  /** Foreground for text sitting ON a `primary` fill. Theme-dependent: the two
   *  themes use primary at opposite ends of the lightness range, so a single
   *  hard-coded value fails contrast in one of them. See shadow-host.ts. */
  onPrimary: 'var(--fe-on-primary)',
  accent: 'var(--fe-accent)',
  accentHover: 'var(--fe-accent-hover)',
  /** Foreground for text on an `accent` fill. See `onPrimary`. */
  onAccent: 'var(--fe-on-accent)',

  // Semantic — the TEXT role: these read against the panel background.
  destructive: 'var(--fe-destructive)',
  success: 'var(--fe-success)',
  warning: 'var(--fe-warning)',
  info: 'var(--fe-info)',

  /** Semantic FILL role: use these for a filled button or chip, paired with the
   *  matching `on*` foreground. Distinct from the text role above because a
   *  colour chosen to be legible as text on the panel is too light to carry
   *  white text as a background — the same split `onPrimary` exists for. */
  destructiveFill: 'var(--fe-destructive-fill)',
  destructiveFillHover: 'var(--fe-destructive-fill-hover)',
  onDestructive: 'var(--fe-on-destructive)',
  infoFill: 'var(--fe-info-fill)',
  onInfo: 'var(--fe-on-info)',

  // Field / band fills and role colors added in the token-cohesion pass.
  inputBg: 'var(--fe-input-bg)',
  band: 'var(--fe-band)',
  primaryStrong: 'var(--fe-primary-strong)',
  insertText: 'var(--fe-insert-text)',
  insertFill: 'var(--fe-insert-fill)',
  onInsert: 'var(--fe-on-insert)',
  reorderText: 'var(--fe-reorder-text)',
  groupText: 'var(--fe-group-text)',
  varText: 'var(--fe-var-text)',

  // Guide overlay (on-page — not themed, mode-coded to read over page content)
  guide: '#8b5cf6',

  // Spacing base unit
  spaceUnit: 4,

  // Radii
  radiusSm: '4px',
  radiusMd: '8px',
  radiusLg: '12px',

  // Shadows
  shadowMd: 'var(--fe-shadow-md)',
  shadowLg: 'var(--fe-shadow-lg)',

  // Breakpoints (overlay layout, not project tokens)
  compactBreakpoint: 1024,
  standardBreakpoint: 1280,
} as const;

// ---------------------------------------------------------------------------
// Selection / indicator colors — on-page, mode-coded, NOT themed
// ---------------------------------------------------------------------------

/** On-page selection ring color. Kept separate from OVERLAY.primary so the
 *  themed UI accent can be adjusted for light mode without changing the ring. */
export const SELECTION = {
  ring: '#06b6d4',
} as const;

// ---------------------------------------------------------------------------
// Handle mode colors — one color per edit-mode layer
// ---------------------------------------------------------------------------

export const HANDLE_COLORS = {
  padding: '#f59e0b',       // amber (inner space)
  margin: '#fb7185',        // rose (outer space)
  dimensions: '#06b6d4',    // cyan (element intrinsic)
  borderRadius: '#22c55e',  // green (corner)
  snapped: '#22c55e',       // green (token snap feedback)
  reorder: '#6366f1',       // indigo (drag reorder)
  reparent: '#8b5cf6',      // violet (cross-container move)
} as const;

// Spacing zone overlay fills + outlines
export const ZONE_OVERLAY = {
  paddingFill: 'rgba(245, 158, 11, 0.20)',
  paddingOutline: 'rgba(245, 158, 11, 0.60)',
  marginFill: 'rgba(251, 113, 133, 0.15)',
  marginOutline: 'rgba(251, 113, 133, 0.50)',
} as const;

// Drop indicator for reorder drag operations
export const DROP_INDICATOR = {
  color: '#3b82f6',
  activeColor: '#60a5fa',
  thickness: 2,
  activeThickness: 3,
  /** Diameter of a 2D wrap-aware drop pip (issue #30). */
  pipSize: 9,
} as const;

// Measure + multi-select indicators — on-page, NOT themed
//
// Deliberately fixed literals, like SELECTION.ring and DROP_INDICATOR above.
// These draw over the user's page, so a themed value would make the same
// measurement render in two different colours depending on a panel setting.
// The label uses the darker #1d4ed8 rather than the frame colour: white on
// #3b82f6 is 3.68:1, under AA for 10px type, while white on #1d4ed8 is 6.7:1.
export const MEASURE_INDICATOR = {
  color: '#3b82f6',
  fill: 'rgba(59, 130, 246, 0.08)',
  labelBg: '#1d4ed8',
  labelText: '#ffffff',
} as const;

// Insert indicator for insert tool drop zones and phantom
export const INSERT_INDICATOR = {
  color: '#10b981',
  activeColor: '#34d399',
  phantomBorder: '#6b7280',
  phantomBg: 'rgba(107, 114, 128, 0.08)',
  thickness: 2,
  activeThickness: 3,
  plusSize: 20,
} as const;

// Insert element picker panel
export const INSERT_PANEL_WIDTH = 240;
export const INSERT_PANEL_MAX_HEIGHT = 420;

// Box model diagram colors (reuses zone overlay palette)
export const BOX_MODEL = {
  marginFill: 'rgba(251, 113, 133, 0.20)',
  borderFill: OVERLAY.active,
  paddingFill: 'rgba(245, 158, 11, 0.20)',
  contentFill: 'rgba(6, 182, 212, 0.20)',
  marginText: 'var(--fe-box-margin-text)',
  borderText: OVERLAY.textMuted,
  paddingText: 'var(--fe-box-padding-text)',
  contentText: 'var(--fe-box-content-text)',
} as const;

// Panel height tier thresholds
export type PanelSizeTier = 'compact' | 'standard' | 'full';
export const PANEL_TIER_COMPACT_MAX = 180;
export const PANEL_TIER_STANDARD_MAX = 300;

// ---------------------------------------------------------------------------
// Onboarding links
// ---------------------------------------------------------------------------

/** Hosted setup guide — opened on first install and linked from the popup. */
export const GUIDE_URL = 'https://nco.studio/web-editor/';

// ---------------------------------------------------------------------------
// Guide overlay
// ---------------------------------------------------------------------------

export const GUIDE_LINE_Z = '52';
export const RULER_BAR_Z = '53';
export const GUIDE_SNAP_THRESHOLD = 8;
export const MAX_GUIDES_PER_PAGE = 50;

/**
 * A translucent tint of a themed color, for chip and row backgrounds.
 * Derived from the token instead of a hard-coded rgba() so the tint follows
 * the theme (light primary is #0e7490, dark is #06b6d4).
 */
export function tint(color: string, percent: number): string {
  return `color-mix(in srgb, ${color} ${percent}%, transparent)`;
}
