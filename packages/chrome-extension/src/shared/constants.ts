// ---------------------------------------------------------------------------
// WebSocket
// ---------------------------------------------------------------------------

export const WS_PORT_BASE = 7890;
export const WS_PORT_RANGE = 10;
export const WS_BACKOFF_BASE_MS = 1_000;
export const WS_BACKOFF_MAX_MS = 30_000;
export const WS_MAX_RETRIES = 0; // 0 = unlimited — keep retrying indefinitely
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

  // Guide overlay
  guide: '#8b5cf6',

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
  borderFill: 'rgba(255, 255, 255, 0.12)',
  paddingFill: 'rgba(245, 158, 11, 0.20)',
  contentFill: 'rgba(6, 182, 212, 0.20)',
  marginText: '#fb7185',
  borderText: '#a1a1aa',
  paddingText: '#f59e0b',
  contentText: '#06b6d4',
} as const;

// Panel height tier thresholds
export type PanelSizeTier = 'compact' | 'standard' | 'full';
export const PANEL_TIER_COMPACT_MAX = 180;
export const PANEL_TIER_STANDARD_MAX = 300;

// ---------------------------------------------------------------------------
// Guide overlay
// ---------------------------------------------------------------------------

export const GUIDE_LINE_Z = '52';
export const RULER_BAR_Z = '53';
export const GUIDE_SNAP_THRESHOLD = 8;
export const MAX_GUIDES_PER_PAGE = 50;
