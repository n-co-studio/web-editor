/**
 * Static element catalog for the insert element picker.
 *
 * Defines all HTML elements a user can insert, organized by category.
 */

import type { CompoundChildDescriptor } from '@frontend-editor/shared';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type InsertCategory =
  | 'layout'
  | 'layouts'
  | 'text'
  | 'list'
  | 'media'
  | 'form'
  | 'interactive'
  | 'table'
  | 'components';

export type SizingPreset = 'auto' | 'stretch' | 'fixed';

/** Alias — single source of truth is CompoundChildDescriptor in @frontend-editor/shared. */
export type CompoundChild = CompoundChildDescriptor;

export interface InsertCatalogEntry {
  readonly tag: string;
  readonly label: string;
  readonly category: InsertCategory;
  readonly icon: string;
  readonly defaultWidthPreset: SizingPreset;
  readonly defaultHeightPreset: SizingPreset;
  readonly defaultFixedWidth?: number;
  readonly defaultFixedHeight?: number;
  readonly defaultStyles?: readonly { property: string; value: string }[];
  readonly compoundChildren?: readonly CompoundChild[];
  readonly attributes?: readonly { name: string; value: string }[];
}

/**
 * A project-local React component surfaced in the Insert panel's Components
 * tab. The DOM phantom always uses `tag: 'div'` as a placeholder; on commit
 * the diff carries `componentInsert` with the real component identity so
 * the receiving agent can rewrite to a JSX usage + import.
 */
export interface ProjectComponentEntry extends InsertCatalogEntry {
  readonly category: 'components';
  readonly componentName: string;
  readonly importPath: string;
  readonly exportType: 'named' | 'default';
}

export function isProjectComponentEntry(
  entry: InsertCatalogEntry,
): entry is ProjectComponentEntry {
  return entry.category === 'components';
}

// ---------------------------------------------------------------------------
// SVG icon helpers (16×16 viewBox, stroke-based, currentColor)
// ---------------------------------------------------------------------------

function svg(inner: string): string {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">${inner}</svg>`;
}

// Rectangle outline — generic container / div
const ICON_DIV = svg('<rect x="2" y="3" width="12" height="10" rx="1"/>');

// Rectangle with a horizontal divider near the top — section/article
const ICON_SECTION = svg(
  '<rect x="2" y="3" width="12" height="10" rx="1"/><line x1="2" y1="6.5" x2="14" y2="6.5"/>',
);

// Rectangle with two inner horizontal bars — article (content block)
const ICON_ARTICLE = svg(
  '<rect x="2" y="3" width="12" height="10" rx="1"/><line x1="4" y1="6.5" x2="12" y2="6.5"/><line x1="4" y1="9.5" x2="12" y2="9.5"/>',
);

// Rectangle spanning full top — header
const ICON_HEADER = svg(
  '<rect x="2" y="2" width="12" height="5" rx="1"/><line x1="2" y1="10" x2="14" y2="10"/><line x1="2" y1="13" x2="10" y2="13"/>',
);

// Rectangle at bottom — footer
const ICON_FOOTER = svg(
  '<line x1="2" y1="3" x2="14" y2="3"/><line x1="2" y1="6" x2="10" y2="6"/><rect x="2" y="9" width="12" height="5" rx="1"/>',
);

// Compass rose — navigation
const ICON_NAV = svg(
  '<circle cx="8" cy="8" r="5.5"/><line x1="8" y1="2.5" x2="8" y2="5"/><line x1="8" y1="11" x2="8" y2="13.5"/><line x1="2.5" y1="8" x2="5" y2="8"/><line x1="11" y1="8" x2="13.5" y2="8"/>',
);

// Simple centered rectangle — main content area
const ICON_MAIN = svg(
  '<rect x="4" y="2" width="8" height="12" rx="1"/><line x1="6" y1="5" x2="10" y2="5"/><line x1="6" y1="8" x2="10" y2="8"/><line x1="6" y1="11" x2="9" y2="11"/>',
);

// Sidebar rectangle offset to the right — aside
const ICON_ASIDE = svg(
  '<rect x="2" y="3" width="7" height="10" rx="1"/><rect x="11" y="3" width="3" height="10" rx="1"/>',
);

// Bold "H1" — heading 1
const ICON_H1 = svg(
  '<text x="1" y="12" font-family="sans-serif" font-size="10" font-weight="700" stroke="none" fill="currentColor">H1</text>',
);

// "H2"
const ICON_H2 = svg(
  '<text x="1" y="12" font-family="sans-serif" font-size="10" font-weight="700" stroke="none" fill="currentColor">H2</text>',
);

// "H3"
const ICON_H3 = svg(
  '<text x="1" y="12" font-family="sans-serif" font-size="10" font-weight="700" stroke="none" fill="currentColor">H3</text>',
);

// "H4"
const ICON_H4 = svg(
  '<text x="1" y="12" font-family="sans-serif" font-size="10" font-weight="700" stroke="none" fill="currentColor">H4</text>',
);

// "H5"
const ICON_H5 = svg(
  '<text x="1" y="12" font-family="sans-serif" font-size="10" font-weight="700" stroke="none" fill="currentColor">H5</text>',
);

// "H6"
const ICON_H6 = svg(
  '<text x="1" y="12" font-family="sans-serif" font-size="10" font-weight="700" stroke="none" fill="currentColor">H6</text>',
);

// Three horizontal lines of varying length — paragraph
const ICON_P = svg(
  '<line x1="2" y1="5" x2="14" y2="5"/><line x1="2" y1="8" x2="14" y2="8"/><line x1="2" y1="11" x2="9" y2="11"/>',
);

// Small inline rectangle — span
const ICON_SPAN = svg(
  '<rect x="3" y="5" width="10" height="6" rx="1"/><line x1="5" y1="8" x2="11" y2="8"/>',
);

// Chain link icon — anchor / link
const ICON_A = svg(
  '<path d="M6.5 9.5a3.5 3.5 0 0 0 5 0l1.5-1.5a3.5 3.5 0 0 0-5-5L7 4"/><path d="M9.5 6.5a3.5 3.5 0 0 0-5 0L3 8a3.5 3.5 0 0 0 5 5L9 12"/>',
);

// Quote marks — blockquote
const ICON_BLOCKQUOTE = svg(
  '<path d="M4 7c0-1.1.9-2 2-2h.5v2H5.5C5.5 8.5 6.5 9 6.5 10v1H4V9c0-.6.2-1.3.5-2H4z"/><path d="M9.5 7c0-1.1.9-2 2-2h.5v2H11C11 8.5 12 9 12 10v1H9.5V9c0-.6.2-1.3.5-2H9.5z"/>',
);

// Three dots + lines — unordered list
const ICON_UL = svg(
  '<circle cx="3.5" cy="5" r="1" fill="currentColor" stroke="none"/><line x1="6" y1="5" x2="14" y2="5"/><circle cx="3.5" cy="8.5" r="1" fill="currentColor" stroke="none"/><line x1="6" y1="8.5" x2="14" y2="8.5"/><circle cx="3.5" cy="12" r="1" fill="currentColor" stroke="none"/><line x1="6" y1="12" x2="14" y2="12"/>',
);

// "1." + lines — ordered list
const ICON_OL = svg(
  '<text x="1" y="7" font-family="sans-serif" font-size="5" stroke="none" fill="currentColor">1.</text><line x1="6" y1="5" x2="14" y2="5"/><text x="1" y="10.5" font-family="sans-serif" font-size="5" stroke="none" fill="currentColor">2.</text><line x1="6" y1="8.5" x2="14" y2="8.5"/><text x="1" y="14" font-family="sans-serif" font-size="5" stroke="none" fill="currentColor">3.</text><line x1="6" y1="12" x2="14" y2="12"/>',
);

// Frame with mountain — image
const ICON_IMG = svg(
  '<rect x="2" y="3" width="12" height="10" rx="1"/><polyline points="2,10 5,7 8,9.5 11,6.5 14,10"/><circle cx="11.5" cy="6" r="1.5"/>',
);

// Play button — video
const ICON_VIDEO = svg(
  '<rect x="2" y="3" width="12" height="10" rx="1"/><polygon points="6.5,5.5 11,8 6.5,10.5" fill="currentColor" stroke="none"/>',
);

// Browser frame — iframe
const ICON_IFRAME = svg(
  '<rect x="2" y="2" width="12" height="12" rx="1"/><line x1="2" y1="5.5" x2="14" y2="5.5"/><circle cx="4.5" cy="3.75" r="0.75" fill="currentColor" stroke="none"/><circle cx="7" cy="3.75" r="0.75" fill="currentColor" stroke="none"/>',
);

// Diamond/polygon — SVG element
const ICON_SVG = svg(
  '<polygon points="8,2 14,8 8,14 2,8" /><circle cx="8" cy="8" r="2"/>',
);

// Clipboard — form
const ICON_FORM = svg(
  '<rect x="3" y="4" width="10" height="11" rx="1"/><path d="M6 4V3a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v1"/><line x1="5" y1="8" x2="11" y2="8"/><line x1="5" y1="11" x2="9" y2="11"/>',
);

// Tag label — label element
const ICON_LABEL = svg(
  '<path d="M2 5h7l4 3-4 3H2V5z"/><circle cx="5" cy="8" r="1" fill="currentColor" stroke="none"/>',
);

// Rounded rectangle — button
const ICON_BUTTON = svg(
  '<rect x="2" y="5" width="12" height="6" rx="2.5"/><line x1="5.5" y1="8" x2="10.5" y2="8"/>',
);

// Rectangle with vertical cursor line — text input
const ICON_INPUT_TEXT = svg(
  '<rect x="2" y="5" width="12" height="6" rx="1"/><line x1="5" y1="6.5" x2="5" y2="9.5"/>',
);

// Rectangle with @ symbol — email input
const ICON_INPUT_EMAIL = svg(
  '<rect x="2" y="5" width="12" height="6" rx="1"/><circle cx="8" cy="8" r="1.5"/><path d="M9.5 8a1.5 1.5 0 0 0 1.5 1.5V8"/>',
);

// Checkbox with tick — checkbox
const ICON_CHECKBOX = svg(
  '<rect x="3" y="3" width="10" height="10" rx="1.5"/><polyline points="5.5,8 7.5,10 11,6"/>',
);

// Filled dot in outer ring — radio
const ICON_RADIO = svg(
  '<circle cx="8" cy="8" r="5.5"/><circle cx="8" cy="8" r="2.5" fill="currentColor" stroke="none"/>',
);

// Multi-line text area with resize handle — textarea
const ICON_TEXTAREA = svg(
  '<rect x="2" y="3" width="12" height="10" rx="1"/><line x1="4" y1="6.5" x2="12" y2="6.5"/><line x1="4" y1="9" x2="12" y2="9"/><polyline points="10,13 13,13 13,10"/>',
);

// Dropdown arrow — select
const ICON_SELECT = svg(
  '<rect x="2" y="5" width="12" height="6" rx="1"/><polyline points="6,7.5 8,10 10,7.5"/>',
);

// Chevron disclosure — details
const ICON_DETAILS = svg(
  '<line x1="2" y1="5" x2="14" y2="5"/><polyline points="5,8.5 8,11.5 11,8.5"/><line x1="2" y1="13" x2="14" y2="13"/>',
);

// Dialog box — dialog
const ICON_DIALOG = svg(
  '<rect x="2" y="3" width="12" height="10" rx="1.5"/><line x1="2" y1="7" x2="14" y2="7"/><line x1="10" y1="5" x2="12" y2="5"/><line x1="5" y1="9.5" x2="11" y2="9.5"/><line x1="5" y1="11.5" x2="9" y2="11.5"/>',
);

// 3×3 grid — table
const ICON_TABLE = svg(
  '<rect x="2" y="2" width="12" height="12" rx="1"/><line x1="6" y1="2" x2="6" y2="14"/><line x1="10" y1="2" x2="10" y2="14"/><line x1="2" y1="6" x2="14" y2="6"/><line x1="2" y1="10" x2="14" y2="10"/>',
);

// 4-quadrant rectangle — generic project component glyph
export const ICON_PROJECT_COMPONENT = svg(
  '<rect x="2" y="2" width="12" height="12" rx="1"/><line x1="8" y1="2" x2="8" y2="14"/><line x1="2" y1="8" x2="14" y2="8"/>',
);

// ---------------------------------------------------------------------------
// Layout presets
// ---------------------------------------------------------------------------

/**
 * Build a proportional preview icon for a layout preset: partitions the icon
 * box into cells sized by `weights` along the given axis, so a "2/3 + 1/3"
 * preset reads as a wide cell next to a narrow one.
 */
function buildLayoutIcon(
  direction: 'row' | 'column',
  weights: readonly number[],
): string {
  const total = weights.reduce((s, w) => s + w, 0);
  const gap = 1;
  const n = weights.length;
  const ox = 2;
  const oy = 3;
  const boxW = 12;
  const boxH = 10;
  const span = direction === 'row' ? boxW : boxH;
  const cellSpan = span - gap * (n - 1);

  let cursor = direction === 'row' ? ox : oy;
  const rects: string[] = [];
  for (const w of weights) {
    const size = (w / total) * cellSpan;
    if (direction === 'row') {
      rects.push(`<rect x="${cursor.toFixed(1)}" y="${oy}" width="${size.toFixed(1)}" height="${boxH}" rx="0.5"/>`);
    } else {
      rects.push(`<rect x="${ox}" y="${cursor.toFixed(1)}" width="${boxW}" height="${size.toFixed(1)}" rx="0.5"/>`);
    }
    cursor += size + gap;
  }
  return svg(rects.join(''));
}

/**
 * Build a layout-preset catalog entry: a flex container in the given direction
 * with one child div per weight. Each child carries `flex: <weight>` so the
 * columns/rows render at the intended ratio, plus a min-size so empty cells
 * remain visible and clickable for further insertion. Per-child styles flow
 * through CompoundChildDescriptor.styles into both the live DOM and the diff.
 */
/** Gap between columns/rows in a layout preset container. */
const LAYOUT_PRESET_GAP = '16px';
/** Min size on each cell so empty columns/rows stay visible and clickable. */
const LAYOUT_PRESET_CELL_MIN = '40px';

function layoutPreset(
  label: string,
  direction: 'row' | 'column',
  weights: readonly number[],
): InsertCatalogEntry {
  const minProp = direction === 'row' ? 'min-height' : 'min-width';
  return {
    tag: 'div',
    label: `${label} (${direction === 'row' ? 'row' : 'column'})`,
    category: 'layouts',
    icon: buildLayoutIcon(direction, weights),
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
    defaultStyles: [
      { property: 'display', value: 'flex' },
      { property: 'flex-direction', value: direction },
      { property: 'gap', value: LAYOUT_PRESET_GAP },
    ],
    // Each cell is itself a flex column so the Insert tool treats it as a valid
    // drop target — content goes INSIDE the cell rather than adding another
    // sibling column to the container (same rationale as the "Container" entry).
    compoundChildren: weights.map((w) => ({
      tagName: 'div',
      styles: [
        { property: 'flex', value: String(w) },
        { property: minProp, value: LAYOUT_PRESET_CELL_MIN },
        { property: 'display', value: 'flex' },
        { property: 'flex-direction', value: 'column' },
      ],
    })),
  };
}

/**
 * Ratio presets for the Insert panel's "Layouts" category. Each ratio is
 * available in both row (side-by-side columns) and column (stacked rows)
 * orientation. Ratios use integer flex weights — `[2, 1]` renders 2/3 + 1/3.
 */
const LAYOUT_RATIOS: readonly { label: string; weights: number[] }[] = [
  // Halves
  { label: '50 / 50', weights: [1, 1] },
  // Thirds
  { label: '1/3 · 1/3 · 1/3', weights: [1, 1, 1] },
  { label: '2/3 + 1/3', weights: [2, 1] },
  { label: '1/3 + 2/3', weights: [1, 2] },
  // Fourths
  { label: '1/4 × 4', weights: [1, 1, 1, 1] },
  { label: '1/2 + 1/4 + 1/4', weights: [2, 1, 1] },
  { label: '3/4 + 1/4', weights: [3, 1] },
];

const LAYOUT_PRESETS: readonly InsertCatalogEntry[] = LAYOUT_RATIOS.flatMap(
  ({ label, weights }) => [
    layoutPreset(label, 'row', weights),
    layoutPreset(label, 'column', weights),
  ],
);

// ---------------------------------------------------------------------------
// Catalog
// ---------------------------------------------------------------------------

export const INSERT_CATALOG: readonly InsertCatalogEntry[] = [
  ...LAYOUT_PRESETS,
  // --- Layout ---
  // All layout elements default to display:flex so they immediately accept
  // child insertions and reparent drops without manual styling.
  {
    tag: 'div',
    label: 'Container',
    category: 'layout',
    icon: ICON_DIV,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
    defaultStyles: [{ property: 'display', value: 'flex' }],
  },
  {
    tag: 'section',
    label: 'Section',
    category: 'layout',
    icon: ICON_SECTION,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
    defaultStyles: [{ property: 'display', value: 'flex' }],
  },
  {
    tag: 'article',
    label: 'Article',
    category: 'layout',
    icon: ICON_ARTICLE,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
    defaultStyles: [{ property: 'display', value: 'flex' }],
  },
  {
    tag: 'header',
    label: 'Header',
    category: 'layout',
    icon: ICON_HEADER,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
    defaultStyles: [{ property: 'display', value: 'flex' }],
  },
  {
    tag: 'footer',
    label: 'Footer',
    category: 'layout',
    icon: ICON_FOOTER,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
    defaultStyles: [{ property: 'display', value: 'flex' }],
  },
  {
    tag: 'nav',
    label: 'Navigation',
    category: 'layout',
    icon: ICON_NAV,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
    defaultStyles: [{ property: 'display', value: 'flex' }],
  },
  {
    tag: 'main',
    label: 'Main',
    category: 'layout',
    icon: ICON_MAIN,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
    defaultStyles: [{ property: 'display', value: 'flex' }],
  },
  {
    tag: 'aside',
    label: 'Aside',
    category: 'layout',
    icon: ICON_ASIDE,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
    defaultStyles: [{ property: 'display', value: 'flex' }],
  },

  // --- Text ---
  {
    tag: 'h1',
    label: 'Heading 1',
    category: 'text',
    icon: ICON_H1,
    defaultWidthPreset: 'auto',
    defaultHeightPreset: 'auto',
  },
  {
    tag: 'h2',
    label: 'Heading 2',
    category: 'text',
    icon: ICON_H2,
    defaultWidthPreset: 'auto',
    defaultHeightPreset: 'auto',
  },
  {
    tag: 'h3',
    label: 'Heading 3',
    category: 'text',
    icon: ICON_H3,
    defaultWidthPreset: 'auto',
    defaultHeightPreset: 'auto',
  },
  {
    tag: 'h4',
    label: 'Heading 4',
    category: 'text',
    icon: ICON_H4,
    defaultWidthPreset: 'auto',
    defaultHeightPreset: 'auto',
  },
  {
    tag: 'h5',
    label: 'Heading 5',
    category: 'text',
    icon: ICON_H5,
    defaultWidthPreset: 'auto',
    defaultHeightPreset: 'auto',
  },
  {
    tag: 'h6',
    label: 'Heading 6',
    category: 'text',
    icon: ICON_H6,
    defaultWidthPreset: 'auto',
    defaultHeightPreset: 'auto',
  },
  {
    tag: 'p',
    label: 'Paragraph',
    category: 'text',
    icon: ICON_P,
    defaultWidthPreset: 'auto',
    defaultHeightPreset: 'auto',
  },
  {
    tag: 'span',
    label: 'Span',
    category: 'text',
    icon: ICON_SPAN,
    defaultWidthPreset: 'auto',
    defaultHeightPreset: 'auto',
  },
  {
    tag: 'a',
    label: 'Link',
    category: 'text',
    icon: ICON_A,
    defaultWidthPreset: 'auto',
    defaultHeightPreset: 'auto',
  },
  {
    tag: 'blockquote',
    label: 'Blockquote',
    category: 'text',
    icon: ICON_BLOCKQUOTE,
    defaultWidthPreset: 'auto',
    defaultHeightPreset: 'auto',
  },

  // --- List ---
  {
    tag: 'ul',
    label: 'Unordered List',
    category: 'list',
    icon: ICON_UL,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
    compoundChildren: [
      { tagName: 'li', textContent: 'Item 1' },
      { tagName: 'li', textContent: 'Item 2' },
    ],
  },
  {
    tag: 'ol',
    label: 'Ordered List',
    category: 'list',
    icon: ICON_OL,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
    compoundChildren: [
      { tagName: 'li', textContent: 'Item 1' },
      { tagName: 'li', textContent: 'Item 2' },
    ],
  },

  // --- Media ---
  {
    tag: 'img',
    label: 'Image',
    category: 'media',
    icon: ICON_IMG,
    defaultWidthPreset: 'fixed',
    defaultHeightPreset: 'fixed',
    defaultFixedWidth: 300,
    defaultFixedHeight: 200,
    defaultStyles: [{ property: 'object-fit', value: 'cover' }],
  },
  {
    tag: 'video',
    label: 'Video',
    category: 'media',
    icon: ICON_VIDEO,
    defaultWidthPreset: 'fixed',
    defaultHeightPreset: 'fixed',
    defaultFixedWidth: 300,
    defaultFixedHeight: 200,
  },
  {
    tag: 'iframe',
    label: 'Iframe',
    category: 'media',
    icon: ICON_IFRAME,
    defaultWidthPreset: 'fixed',
    defaultHeightPreset: 'fixed',
    defaultFixedWidth: 300,
    defaultFixedHeight: 200,
  },
  {
    tag: 'svg',
    label: 'SVG',
    category: 'media',
    icon: ICON_SVG,
    defaultWidthPreset: 'fixed',
    defaultHeightPreset: 'fixed',
    defaultFixedWidth: 300,
    defaultFixedHeight: 200,
  },

  // --- Form ---
  {
    tag: 'form',
    label: 'Form',
    category: 'form',
    icon: ICON_FORM,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
  },
  {
    tag: 'label',
    label: 'Label',
    category: 'form',
    icon: ICON_LABEL,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
  },
  {
    tag: 'button',
    label: 'Button',
    category: 'form',
    icon: ICON_BUTTON,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
    defaultStyles: [{ property: 'padding', value: '8px 16px' }],
  },
  {
    tag: 'input',
    label: 'Text Input',
    category: 'form',
    icon: ICON_INPUT_TEXT,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
    attributes: [{ name: 'type', value: 'text' }],
  },
  {
    tag: 'input',
    label: 'Email Input',
    category: 'form',
    icon: ICON_INPUT_EMAIL,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
    attributes: [{ name: 'type', value: 'email' }],
  },
  {
    tag: 'input',
    label: 'Checkbox',
    category: 'form',
    icon: ICON_CHECKBOX,
    defaultWidthPreset: 'auto',
    defaultHeightPreset: 'auto',
    attributes: [{ name: 'type', value: 'checkbox' }],
  },
  {
    tag: 'input',
    label: 'Radio',
    category: 'form',
    icon: ICON_RADIO,
    defaultWidthPreset: 'auto',
    defaultHeightPreset: 'auto',
    attributes: [{ name: 'type', value: 'radio' }],
  },
  {
    tag: 'textarea',
    label: 'Text Area',
    category: 'form',
    icon: ICON_TEXTAREA,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
  },
  {
    tag: 'select',
    label: 'Select',
    category: 'form',
    icon: ICON_SELECT,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
    compoundChildren: [
      { tagName: 'option', textContent: 'Option 1' },
      { tagName: 'option', textContent: 'Option 2' },
      { tagName: 'option', textContent: 'Option 3' },
    ],
  },

  // --- Interactive ---
  {
    tag: 'details',
    label: 'Details',
    category: 'interactive',
    icon: ICON_DETAILS,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
    compoundChildren: [{ tagName: 'summary', textContent: 'Summary' }],
  },
  {
    tag: 'dialog',
    label: 'Dialog',
    category: 'interactive',
    icon: ICON_DIALOG,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
  },

  // --- Table ---
  {
    tag: 'table',
    label: 'Table',
    category: 'table',
    icon: ICON_TABLE,
    defaultWidthPreset: 'stretch',
    defaultHeightPreset: 'auto',
    compoundChildren: [
      {
        tagName: 'thead',
        children: [
          {
            tagName: 'tr',
            children: [
              { tagName: 'th', textContent: 'Header 1' },
              { tagName: 'th', textContent: 'Header 2' },
              { tagName: 'th', textContent: 'Header 3' },
            ],
          },
        ],
      },
      {
        tagName: 'tbody',
        children: [
          {
            tagName: 'tr',
            children: [
              { tagName: 'td', textContent: 'Cell 1' },
              { tagName: 'td', textContent: 'Cell 2' },
              { tagName: 'td', textContent: 'Cell 3' },
            ],
          },
          {
            tagName: 'tr',
            children: [
              { tagName: 'td', textContent: 'Cell 4' },
              { tagName: 'td', textContent: 'Cell 5' },
              { tagName: 'td', textContent: 'Cell 6' },
            ],
          },
        ],
      },
    ],
  },
];

// ---------------------------------------------------------------------------
// Category metadata
// ---------------------------------------------------------------------------

export const INSERT_CATEGORIES: readonly InsertCategory[] = [
  'layout',
  'layouts',
  'text',
  'list',
  'media',
  'form',
  'interactive',
  'table',
  'components',
];

export const CATEGORY_LABELS: Record<InsertCategory, string> = {
  layout: 'Layout',
  layouts: 'Layout Presets',
  text: 'Text',
  list: 'List',
  media: 'Media',
  form: 'Form',
  interactive: 'Interactive',
  table: 'Table',
  components: 'Components',
};

/**
 * Build a ProjectComponentEntry from a discovered ProjectComponent (mcp-server side).
 * The catalog entry inserts a phantom `<div>` placeholder; the diff carries
 * the real component identity via `componentInsert`.
 */
export function buildProjectComponentEntry(args: {
  componentName: string;
  importPath: string;
  exportType: 'named' | 'default';
}): ProjectComponentEntry {
  return {
    tag: 'div',
    label: args.componentName,
    category: 'components',
    icon: ICON_PROJECT_COMPONENT,
    defaultWidthPreset: 'auto',
    defaultHeightPreset: 'auto',
    componentName: args.componentName,
    importPath: args.importPath,
    exportType: args.exportType,
  };
}

// ---------------------------------------------------------------------------
// Utility functions
// ---------------------------------------------------------------------------

/**
 * Filter the catalog by a search query, matching against both tag and label.
 * Case-insensitive. Returns all entries if query is empty.
 */
export function filterCatalog(query: string): InsertCatalogEntry[] {
  const q = query.trim().toLowerCase();
  if (!q) return INSERT_CATALOG as InsertCatalogEntry[];
  return INSERT_CATALOG.filter(
    (entry) =>
      entry.tag.toLowerCase().includes(q) ||
      entry.label.toLowerCase().includes(q),
  );
}

/**
 * Returns the default entry for the insert picker (the div / Container entry).
 */
export function getDefaultEntry(): InsertCatalogEntry {
  return INSERT_CATALOG.find((entry) => entry.tag === 'div')!;
}
