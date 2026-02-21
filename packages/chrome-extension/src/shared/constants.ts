// ---------------------------------------------------------------------------
// WebSocket
// ---------------------------------------------------------------------------

export const WS_PORT_BASE = 7890;
export const WS_PORT_RANGE = 10;
export const WS_BACKOFF_BASE_MS = 1_000;
export const WS_BACKOFF_MAX_MS = 16_000;
export const WS_MAX_RETRIES = 5;
export const WS_KEEPALIVE_INTERVAL_MS = 20_000;

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
export const TOOLBAR_WIDTH = 40;

// DevTools bottom panel
export const DEVTOOLS_DEFAULT_HEIGHT = 250;
export const DEVTOOLS_MIN_HEIGHT = 120;
export const DEVTOOLS_MAX_HEIGHT_RATIO = 0.6;
export const DEVTOOLS_DEFAULT_LEFT_RATIO = 0.30;
export const DEVTOOLS_DEFAULT_MIDDLE_RATIO = 0.40;

// ---------------------------------------------------------------------------
// Overlay design tokens (px, not rem — isolated in Shadow DOM)
// ---------------------------------------------------------------------------

export const OVERLAY = {
  // Typography
  fontFamily: 'system-ui, -apple-system, BlinkMacSystemFont, sans-serif',
  monoFamily: 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace',
  headingSize: '13px',
  headingWeight: '600',
  bodySize: '12px',
  bodyWeight: '400',
  monoSize: '11px',
  monoWeight: '400',

  // Colors
  bg: 'rgba(0, 0, 0, 0.85)',
  bgSubtle: 'rgba(0, 0, 0, 0.65)',
  text: '#ffffff',
  textMuted: '#a1a1aa',
  border: 'rgba(255, 255, 255, 0.15)',

  // Brand
  primary: '#06b6d4',
  primaryHover: '#0891b2',
  primaryLight: '#cffafe',
  accent: '#fb7185',
  accentHover: '#f43f5e',

  // Semantic
  destructive: '#ef4444',
  success: '#22c55e',
  warning: '#f59e0b',
  info: '#3b82f6',

  // Spacing base unit
  spaceUnit: 4,

  // Radii
  radiusSm: '4px',
  radiusMd: '8px',
  radiusLg: '12px',

  // Shadows
  shadowMd: '0 4px 6px rgba(0, 0, 0, 0.07)',
  shadowLg: '0 10px 15px rgba(0, 0, 0, 0.10)',

  // Breakpoints (overlay layout, not project tokens)
  compactBreakpoint: 1024,
  standardBreakpoint: 1280,
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
} as const;

// Spacing zone overlay fills + outlines
export const ZONE_OVERLAY = {
  paddingFill: 'rgba(245, 158, 11, 0.20)',
  paddingOutline: 'rgba(245, 158, 11, 0.60)',
  marginFill: 'rgba(251, 113, 133, 0.15)',
  marginOutline: 'rgba(251, 113, 133, 0.50)',
} as const;
