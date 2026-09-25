import { createElement, createButton, makeDraggable } from '../shared/ui-utils';
import { OVERLAY, TOOLBAR_WIDTH } from '../shared/constants';
import type { EditMode, InspectorMode, PanelPosition } from '../shared/types';

type ToolSelectCallback = (mode: EditMode) => void;
type VoidCallback = () => void;

// ---------------------------------------------------------------------------
// SVG Icons (16x16, fill/stroke = currentColor)
// ---------------------------------------------------------------------------

const ICONS: Record<string, string> = {
  collapse: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <polyline points="4,4 8,8 12,4"/>
    <polyline points="4,8 8,12 12,8"/>
  </svg>`,

  expand: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <polyline points="4,12 8,8 12,12"/>
    <polyline points="4,8 8,4 12,8"/>
  </svg>`,

  spacing: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round">
    <line x1="2" y1="8" x2="14" y2="8"/>
    <polyline points="2,8 4.5,5.5"/>
    <polyline points="2,8 4.5,10.5"/>
    <polyline points="14,8 11.5,5.5"/>
    <polyline points="14,8 11.5,10.5"/>
  </svg>`,

  dimensions: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <rect x="2.5" y="2.5" width="11" height="11" rx="1.5"/>
    <polyline points="9,13.5 13.5,13.5 13.5,9"/>
  </svg>`,

  layout: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <rect x="2.5" y="2.5" width="11" height="11" rx="1.5"/>
    <line x1="8.5" y1="2.5" x2="8.5" y2="13.5"/>
  </svg>`,

  typography: `<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
    <path d="M3 3h10v2.5h-1.5V4.5H9V12h1.5v1.5h-5V12H7V4.5H4.5V5.5H3V3z"/>
  </svg>`,

  colors: `<svg width="16" height="16" viewBox="0 0 16 16">
    <circle cx="8" cy="8" r="5.5" fill="none" stroke="currentColor" stroke-width="1.5"/>
    <path d="M8 2.5a5.5 5.5 0 0 0 0 11V2.5z" fill="currentColor"/>
  </svg>`,

  'border-radius': `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round">
    <path d="M3 12V7a4 4 0 0 1 4-4h5"/>
  </svg>`,

  position: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <path d="M8 2v12M2 8h12"/>
    <circle cx="8" cy="8" r="2" fill="currentColor" stroke="none"/>
  </svg>`,

  undo: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <path d="M3 6h7a3 3 0 0 1 0 6H8"/>
    <polyline points="5.5,3.5 3,6 5.5,8.5"/>
  </svg>`,

  redo: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <path d="M13 6H6a3 3 0 0 0 0 6h2"/>
    <polyline points="10.5,3.5 13,6 10.5,8.5"/>
  </svg>`,

  reset: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <path d="M3.5 2v4h4"/>
    <path d="M3.5 6a5.5 5.5 0 1 1 .87 3"/>
  </svg>`,


  review: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <rect x="3" y="2" width="10" height="12" rx="1.5"/>
    <line x1="6" y1="5.5" x2="10.5" y2="5.5"/>
    <line x1="6" y1="8" x2="10.5" y2="8"/>
    <line x1="6" y1="10.5" x2="9" y2="10.5"/>
  </svg>`,

  devtools: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <rect x="1.5" y="2" width="13" height="12" rx="1.5"/>
    <line x1="1.5" y1="8" x2="14.5" y2="8"/>
    <polyline points="4,10 5.5,11.5 4,13"/>
    <line x1="7" y1="13" x2="10" y2="13"/>
  </svg>`,

  grid: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round">
    <line x1="4" y1="1" x2="4" y2="15"/>
    <line x1="8" y1="1" x2="8" y2="15"/>
    <line x1="12" y1="1" x2="12" y2="15"/>
    <line x1="1" y1="4" x2="15" y2="4"/>
    <line x1="1" y1="8" x2="15" y2="8"/>
    <line x1="1" y1="12" x2="15" y2="12"/>
  </svg>`,

  notes: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <rect x="3" y="2" width="10" height="12" rx="1.5"/>
    <line x1="6" y1="6" x2="10" y2="6"/>
    <line x1="6" y1="9" x2="10" y2="9"/>
  </svg>`,

  cursor: `<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" stroke="none">
    <path d="M3.5 1.5l0 11.5 3.2-3.2 2.8 5.2 1.8-1-2.8-5.2h4.5z"/>
  </svg>`,

  reorder: `<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
    <circle cx="6" cy="4" r="1.25"/><circle cx="10" cy="4" r="1.25"/>
    <circle cx="6" cy="8" r="1.25"/><circle cx="10" cy="8" r="1.25"/>
    <circle cx="6" cy="12" r="1.25"/><circle cx="10" cy="12" r="1.25"/>
  </svg>`,

  reparent: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <rect x="1" y="2" width="5" height="5" rx="1"/>
    <rect x="10" y="9" width="5" height="5" rx="1"/>
    <path d="M6 4.5h3.5a1.5 1.5 0 0 1 1.5 1.5v3"/>
    <polyline points="9.5,7.5 11,9 12.5,7.5"/>
  </svg>`,

  insert: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round">
    <circle cx="8" cy="8" r="6.5"/>
    <line x1="8" y1="5" x2="8" y2="11"/>
    <line x1="5" y1="8" x2="11" y2="8"/>
  </svg>`,

  text: `<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" stroke="none">
    <path d="M4 3h8v2h-1V4.5H8.5V12H10v1H6v-1h1.5V4.5H5V5H4V3z"/>
    <path d="M11 10v4h1v-4h-1zm-1 1v2h-1v-2h1z"/>
  </svg>`,

  media: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <rect x="2" y="3" width="12" height="10" rx="1.5"/>
    <circle cx="5.5" cy="6.5" r="1.25" fill="currentColor" stroke="none"/>
    <polyline points="14,10 10.5,7 7,10"/>
    <polyline points="9,11 6.5,9 2,13"/>
  </svg>`,

  effects: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <path d="M8 1.5l1.2 3.3 3.3.3-2.6 2.2.8 3.4L8 8.8l-2.7 1.9.8-3.4-2.6-2.2 3.3-.3z" fill="currentColor" stroke="none"/>
    <circle cx="12.5" cy="12" r="2"/>
    <line x1="3" y1="13" x2="5" y2="11"/>
  </svg>`,

  appearance: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <rect x="2" y="2" width="12" height="12" rx="3" fill="none"/>
    <circle cx="8" cy="8" r="3" fill="currentColor" stroke="none" opacity="0.6"/>
    <path d="M12 4l1.5-1.5" stroke-width="1.5"/>
  </svg>`,

  delete: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <path d="M3 4.5h10"/>
    <path d="M6.5 2.5h3"/>
    <path d="M4.5 4.5l.5 8.5a1 1 0 0 0 1 1h4a1 1 0 0 0 1-1l.5-8.5"/>
    <line x1="6.5" y1="7" x2="6.5" y2="11.5"/>
    <line x1="9.5" y1="7" x2="9.5" y2="11.5"/>
  </svg>`,

  duplicate: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/>
    <path d="M10.5 5.5V4a1.5 1.5 0 0 0-1.5-1.5H4A1.5 1.5 0 0 0 2.5 4v5A1.5 1.5 0 0 0 4 10.5h1.5"/>
  </svg>`,

  camera: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <rect x="2" y="4.5" width="12" height="9" rx="1.5"/>
    <path d="M5.5 4.5L6.5 2.5h3l1 2"/>
    <circle cx="8" cy="9" r="2.5"/>
  </svg>`,

  ruler: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round">
    <rect x="1" y="1" width="14" height="5" rx="1"/>
    <line x1="4" y1="1" x2="4" y2="4"/>
    <line x1="7" y1="1" x2="7" y2="3"/>
    <line x1="10" y1="1" x2="10" y2="4"/>
    <line x1="13" y1="1" x2="13" y2="3"/>
    <line x1="3" y1="9" x2="13" y2="9" stroke-dasharray="1.5 2"/>
    <line x1="3" y1="13" x2="13" y2="13" stroke-dasharray="1.5 2"/>
  </svg>`,

  'chevron-down': `<svg width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <polyline points="3,6 8,11 13,6"/>
  </svg>`,

  'chevron-right': `<svg width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <polyline points="6,3 11,8 6,13"/>
  </svg>`,
};

const TOOL_LABELS: Record<EditMode, string> = {
  cursor: 'Select',
  spacing: 'Spacing',
  layout: 'Layout',
  dimensions: 'Dimensions',
  typography: 'Type',
  colors: 'Colors',
  'border-radius': 'Radius',
  position: 'Position',
  reorder: 'Reorder',
  reparent: 'Move to',
  insert: 'Insert',
  text: 'Text',
  media: 'Media',
  effects: 'Effects',
  appearance: 'Appearance',
};

const TOOLBAR_STORAGE_KEY = 'nco-web-editor-toolbar-position';

// ---------------------------------------------------------------------------
// Collapsible sections
// ---------------------------------------------------------------------------

type ToolbarSectionId = 'view' | 'tools' | 'actions';

/** Top-to-bottom visual order; auto-fit collapses in reverse (bottom-up). */
const SECTION_ORDER: ToolbarSectionId[] = ['view', 'tools', 'actions'];

const SECTION_LABELS: Record<ToolbarSectionId, string> = {
  view: 'View utilities',
  tools: 'Edit tools',
  actions: 'Actions',
};

interface SectionState {
  body: HTMLDivElement;
  headerBtn: HTMLButtonElement;
  chevron: HTMLElement;
  collapsed: boolean;
  /** True once the operator toggled this section explicitly — auto-fit then leaves it alone. */
  manual: boolean;
}

const AUTO_FIT_DEBOUNCE_MS = 150;

const TOOL_ORDER: EditMode[] = [
  'cursor',
  'spacing',
  'layout',
  'dimensions',
  'typography',
  'colors',
  'border-radius',
  'position',
  'reorder',
  'reparent',
  'insert',
  'text',
  'media',
  'effects',
  'appearance',
];

// ---------------------------------------------------------------------------
// FloatingToolbar
// ---------------------------------------------------------------------------

export class FloatingToolbar {
  private container: HTMLDivElement | null = null;
  private toolButtons = new Map<EditMode, HTMLButtonElement>();
  private disabledTools = new Map<EditMode, string>();
  private activeMode: EditMode | null = null;
  private collapsed = false;
  private visible = false;
  private toolCb: ToolSelectCallback | null = null;
  private moveCb: ((pos: { x: number; y: number }) => void) | null = null;
  private undoCb: VoidCallback | null = null;
  private redoCb: VoidCallback | null = null;
  private resetCb: VoidCallback | null = null;
  private collapseCb: ((collapsed: boolean) => void) | null = null;
  private reviewToggleCb: VoidCallback | null = null;
  private inspectorToggleCbs = new Map<InspectorMode, VoidCallback>();
  private notesToggleCb: VoidCallback | null = null;
  private gridToggleCb: ((enabled: boolean) => void) | null = null;
  private gridSettingsToggleCb: VoidCallback | null = null;
  private deleteCb: VoidCallback | null = null;
  private deleteBtn: HTMLButtonElement | null = null;
  private duplicateCb: VoidCallback | null = null;
  private duplicateBtn: HTMLButtonElement | null = null;

  private reviewOpen = false;
  private contentWrapper: HTMLDivElement | null = null;
  private sections = new Map<ToolbarSectionId, SectionState>();
  private autoFitTimer: ReturnType<typeof setTimeout> | null = null;
  private readonly onWindowResize = (): void => this.scheduleSectionAutoFit();
  private toggleArrow: HTMLElement | null = null;
  private toggleBtn: HTMLButtonElement | null = null;
  private undoBtn: HTMLButtonElement | null = null;
  private redoBtn: HTMLButtonElement | null = null;
  private resetBtn: HTMLButtonElement | null = null;
  private reviewBtn: HTMLButtonElement | null = null;
  private inspectorButtons = new Map<InspectorMode, HTMLButtonElement>();
  private activeInspectors = new Set<InspectorMode>();
  private notesBtn: HTMLButtonElement | null = null;
  private notesBadge: HTMLSpanElement | null = null;
  private gridBtn: HTMLButtonElement | null = null;
  private gridEnabled = false;
  private gridBlockReason: string | null = null;
  private rulersToggleCb: ((enabled: boolean) => void) | null = null;
  private rulersBtn: HTMLButtonElement | null = null;
  private rulersEnabled = false;
  private screenshotCb: VoidCallback | null = null;
  private screenshotBtn: HTMLButtonElement | null = null;
  private screenshotBusy = false;
  private reviewBadge: HTMLSpanElement | null = null;
  private confirmOverlay: HTMLDivElement | null = null;

  constructor(private readonly shadow: ShadowRoot) {}

  onToolSelect(cb: ToolSelectCallback): void {
    this.toolCb = cb;
  }

  /** Called continuously while toolbar is being dragged. */
  onMove(cb: (pos: { x: number; y: number }) => void): void {
    this.moveCb = cb;
  }

  onUndo(cb: VoidCallback): void {
    this.undoCb = cb;
  }

  onRedo(cb: VoidCallback): void {
    this.redoCb = cb;
  }

  onReset(cb: VoidCallback): void {
    this.resetCb = cb;
  }

  onCollapse(cb: (collapsed: boolean) => void): void {
    this.collapseCb = cb;
  }

  onReviewToggle(cb: VoidCallback): void {
    this.reviewToggleCb = cb;
  }

  onInspectorToggle(mode: InspectorMode, cb: VoidCallback): void {
    this.inspectorToggleCbs.set(mode, cb);
  }

  onNotesToggle(cb: VoidCallback): void {
    this.notesToggleCb = cb;
  }

  onGridToggle(cb: (enabled: boolean) => void): void {
    this.gridToggleCb = cb;
  }

  onGridSettingsToggle(cb: VoidCallback): void {
    this.gridSettingsToggleCb = cb;
  }

  onRulersToggle(cb: (enabled: boolean) => void): void {
    this.rulersToggleCb = cb;
  }

  onScreenshot(cb: VoidCallback): void {
    this.screenshotCb = cb;
  }

  setScreenshotBusy(busy: boolean): void {
    this.screenshotBusy = busy;
    if (!this.screenshotBtn) return;
    this.screenshotBtn.style.opacity = busy ? '0.5' : '1';
    this.screenshotBtn.style.cursor = busy ? 'wait' : 'pointer';
  }

  /** Sync rulers button active state. */
  setRulersEnabled(enabled: boolean): void {
    this.rulersEnabled = enabled;
    if (!this.rulersBtn) return;
    this.rulersBtn.setAttribute('aria-pressed', String(enabled));
    if (enabled) {
      this.rulersBtn.style.background = 'rgba(6, 182, 212, 0.12)';
      this.rulersBtn.style.color = OVERLAY.primary;
    } else {
      this.rulersBtn.style.background = 'transparent';
      this.rulersBtn.style.color = OVERLAY.textMuted;
    }
    // Record the resting background so hover restore (mouseleave) keeps the
    // active highlight instead of clearing it to transparent.
    this.rulersBtn.dataset.restBg = this.rulersBtn.style.background;
    this.updateSectionAutoFit();
  }

  onDelete(cb: VoidCallback): void {
    this.deleteCb = cb;
  }

  /** Enable/disable the delete button based on whether an element is selected. */
  setDeleteEnabled(enabled: boolean): void {
    if (!this.deleteBtn) return;
    this.deleteBtn.style.opacity = enabled ? '1' : '0.3';
    this.deleteBtn.style.cursor = enabled ? 'pointer' : 'not-allowed';
  }

  onDuplicate(cb: VoidCallback): void {
    this.duplicateCb = cb;
  }

  /** Enable/disable the duplicate button based on whether an element is selected. */
  setDuplicateEnabled(enabled: boolean): void {
    if (!this.duplicateBtn) return;
    this.duplicateBtn.style.opacity = enabled ? '1' : '0.3';
    this.duplicateBtn.style.cursor = enabled ? 'pointer' : 'not-allowed';
  }

  /** Update the notes count badge on the notes button. */
  setNotesCount(count: number): void {
    if (!this.notesBadge) return;
    if (count === 0) {
      this.notesBadge.style.display = 'none';
    } else {
      this.notesBadge.textContent = String(count);
      this.notesBadge.style.display = 'flex';
    }
  }

  /** Sync notes button active state with panel open/closed. */
  setNotesOpen(open: boolean): void {
    if (!this.notesBtn) return;
    this.notesBtn.setAttribute('aria-pressed', String(open));
    if (open) {
      this.notesBtn.style.background = 'rgba(6, 182, 212, 0.12)';
      this.notesBtn.style.color = OVERLAY.primary;
    } else {
      this.notesBtn.style.background = 'transparent';
      this.notesBtn.style.color = OVERLAY.textMuted;
    }
    this.notesBtn.dataset.restBg = this.notesBtn.style.background;
  }

  /** Sync grid button active state. */
  setGridEnabled(enabled: boolean): void {
    this.gridEnabled = enabled;
    if (!this.gridBtn) return;
    this.gridBtn.setAttribute('aria-pressed', String(enabled));
    if (enabled) {
      this.gridBtn.style.background = 'rgba(6, 182, 212, 0.12)';
      this.gridBtn.style.color = OVERLAY.primary;
    } else {
      this.gridBtn.style.background = 'transparent';
      this.gridBtn.style.color = OVERLAY.textMuted;
    }
    this.gridBtn.dataset.restBg = this.gridBtn.style.background;
    this.updateSectionAutoFit();
  }

  /** Set grid block reason (disables button with tooltip). */
  setGridBlockReason(reason: string | null): void {
    this.gridBlockReason = reason;
    if (!this.gridBtn) return;
    if (reason) {
      this.gridBtn.style.opacity = '0.3';
      this.gridBtn.style.cursor = 'not-allowed';
      this.gridBtn.title = `Grid \u2014 ${reason}`;
    } else {
      this.gridBtn.style.opacity = '1';
      this.gridBtn.style.cursor = 'pointer';
      this.gridBtn.title = 'Toggle design grid';
    }
  }

  /** Sync inspector button active state with panel open/closed. */
  setInspectorOpen(mode: InspectorMode, open: boolean): void {
    if (open) this.activeInspectors.add(mode);
    else this.activeInspectors.delete(mode);
    this.updateSectionAutoFit();
    const btn = this.inspectorButtons.get(mode);
    if (!btn) return;
    btn.setAttribute('aria-pressed', String(open));
    if (open) {
      btn.style.background = 'rgba(6, 182, 212, 0.12)';
      btn.style.color = OVERLAY.primary;
    } else {
      btn.style.background = 'transparent';
      btn.style.color = OVERLAY.textMuted;
    }
    btn.dataset.restBg = btn.style.background;
  }


  /** Update the pending count badge on the review button. */
  setPendingCount(count: number): void {
    if (!this.reviewBadge) return;
    if (count === 0) {
      this.reviewBadge.style.display = 'none';
    } else {
      this.reviewBadge.textContent = count > 99 ? '99+' : String(count);
      this.reviewBadge.style.display = 'flex';
    }
  }

  /** Sync review button active state with panel open/closed. */
  setReviewPanelOpen(open: boolean): void {
    this.reviewOpen = open;
    if (!this.reviewBtn) return;
    this.reviewBtn.setAttribute('aria-pressed', String(open));
    if (open) {
      this.reviewBtn.style.background = `rgba(251, 113, 133, 0.15)`;
      this.reviewBtn.style.color = OVERLAY.accent;
    } else {
      this.reviewBtn.style.background = 'transparent';
      this.reviewBtn.style.color = OVERLAY.textMuted;
    }
    this.reviewBtn.dataset.restBg = this.reviewBtn.style.background;
  }

  /** Update undo/redo button enabled states. */
  setUndoRedoState(canUndo: boolean, canRedo: boolean): void {
    if (this.undoBtn) {
      this.undoBtn.style.opacity = canUndo ? '1' : '0.3';
      this.undoBtn.style.cursor = canUndo ? 'pointer' : 'not-allowed';
    }
    if (this.redoBtn) {
      this.redoBtn.style.opacity = canRedo ? '1' : '0.3';
      this.redoBtn.style.cursor = canRedo ? 'pointer' : 'not-allowed';
    }
  }

  setActiveMode(mode: EditMode | null): void {
    this.activeMode = mode;
    this.refreshButtonStates();
    // Activating a tool can make the tools section active — re-run fit
    // synchronously so callers can measure the button straight after.
    this.updateSectionAutoFit();
  }

  getActiveMode(): EditMode | null {
    return this.activeMode;
  }

  setDisabledTools(disabled: Partial<Record<EditMode, string>>): void {
    this.disabledTools.clear();
    for (const [mode, reason] of Object.entries(disabled)) {
      if (reason) this.disabledTools.set(mode as EditMode, reason);
    }
    this.refreshButtonStates();
  }

  getContainerElement(): HTMLDivElement | null {
    return this.container;
  }

  getPosition(): { x: number; y: number } {
    if (!this.container) return { x: 16, y: 16 };
    const rect = this.container.getBoundingClientRect();
    return { x: rect.left, y: rect.top };
  }

  /** Get the position of a specific toolbar button (for anchoring mini-panels next to it). */
  getButtonPosition(key: EditMode | InspectorMode | 'review' | 'notes' | 'grid' | 'rulers'): { x: number; y: number } {
    let btn: HTMLButtonElement | null | undefined = null;
    if (key === 'review') btn = this.reviewBtn;
    else if (key === 'notes') btn = this.notesBtn;
    else if (key === 'grid') btn = this.gridBtn;
    else if (key === 'rulers') btn = this.rulersBtn;
    else if (key === 'devtools') btn = this.inspectorButtons.get(key);
    else btn = this.toolButtons.get(key);
    if (!btn || !this.container) return this.getPosition();

    // A button inside a collapsed section is display:none — its rect collapses
    // to 0×0 at the origin, which would anchor a mini-panel to the top-left of
    // the viewport. Callers read this position *before* activating the tool
    // (index.ts activateToolForElement), so resolve the section here rather
    // than relying on activation to re-expand it.
    const sectionId = this.sectionForButton(btn);
    const section = sectionId ? this.sections.get(sectionId) : undefined;
    if (section?.collapsed) {
      if (section.manual) {
        // The operator collapsed this section deliberately — leave it closed
        // and anchor to its header, which is the section's visible stand-in.
        // The header is itself hidden when the whole toolbar is minimized.
        if (section.headerBtn.offsetParent === null) return this.getPosition();
        const containerRect = this.container.getBoundingClientRect();
        return { x: containerRect.left, y: section.headerBtn.getBoundingClientRect().top };
      }
      // Auto-collapsed: reveal it so the anchor is accurate. The caller is
      // about to activate this tool, which keeps the section open on the next
      // auto-fit pass.
      this.setSectionCollapsed(sectionId!, false, false);
    }

    if (btn.offsetParent === null) return this.getPosition();
    const containerRect = this.container.getBoundingClientRect();
    const btnRect = btn.getBoundingClientRect();
    return { x: containerRect.left, y: btnRect.top };
  }

  async show(): Promise<void> {
    if (this.visible && this.container) return;

    const container = this.buildToolbar();
    this.container = container;
    this.shadow.appendChild(container);
    this.visible = true;

    // Restore saved position
    const saved = await this.loadPosition();
    if (saved) {
      container.style.left = `${saved.x}px`;
      container.style.top = `${saved.y}px`;
    }

    // Auto-collapse sections when the viewport is shorter than the toolbar.
    window.addEventListener('resize', this.onWindowResize);
    this.updateSectionAutoFit();
  }

  hide(): void {
    window.removeEventListener('resize', this.onWindowResize);
    if (this.autoFitTimer !== null) {
      clearTimeout(this.autoFitTimer);
      this.autoFitTimer = null;
    }
    this.confirmOverlay?.remove();
    this.confirmOverlay = null;
    this.container?.remove();
    this.container = null;
    this.contentWrapper = null;
    this.sections.clear();
    this.toolButtons.clear();
    this.toggleArrow = null;
    this.toggleBtn = null;

    this.undoBtn = null;
    this.redoBtn = null;
    this.resetBtn = null;
    this.reviewBtn = null;
    this.reviewBadge = null;
    this.inspectorButtons.clear();
    this.activeInspectors.clear();
    this.notesBtn = null;
    this.notesBadge = null;
    this.gridBtn = null;
    this.gridEnabled = false;
    this.rulersBtn = null;
    this.rulersEnabled = false;
    this.screenshotBtn = null;
    this.screenshotBusy = false;
    this.deleteBtn = null;
    this.duplicateBtn = null;
    this.visible = false;
    this.activeMode = null;
    this.collapsed = false;
    this.reviewOpen = false;
  }

  destroy(): void {
    this.hide();
    this.toolCb = null;
    this.moveCb = null;
    this.undoCb = null;
    this.redoCb = null;
    this.resetCb = null;
    this.collapseCb = null;
    this.reviewToggleCb = null;
    this.inspectorToggleCbs.clear();
    this.notesToggleCb = null;
    this.gridToggleCb = null;
    this.gridSettingsToggleCb = null;
    this.rulersToggleCb = null;
    this.screenshotCb = null;
    this.deleteCb = null;
    this.duplicateCb = null;
  }

  // -----------------------------------------------------------------------
  // Build
  // -----------------------------------------------------------------------

  private buildToolbar(): HTMLDivElement {
    const container = createElement('div', { role: 'toolbar', 'aria-label': 'Edit tools' }, {
      position: 'fixed',
      top: '16px',
      left: '16px',
      width: `${TOOLBAR_WIDTH}px`,
      background: OVERLAY.bg,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusMd,
      boxShadow: OVERLAY.shadowLg,
      pointerEvents: 'auto',
      zIndex: '101',
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      padding: '4px',
      gap: '2px',
    });

    // Drag grip
    const grip = createElement('div', {}, {
      width: '100%',
      height: '10px',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      flexShrink: '0',
    });
    const dots = createElement('div', {}, {
      width: '12px',
      height: '3px',
      backgroundImage: `radial-gradient(circle, ${OVERLAY.textMuted} 1px, transparent 1px)`,
      backgroundSize: '4px 3px',
    });
    grip.appendChild(dots);
    container.appendChild(grip);

    makeDraggable(
      grip,
      container,
      (pos) => this.savePosition(pos),
      (pos) => this.moveCb?.(pos),
    );

    // Collapse button — minimizes entire toolbar to just this button
    this.toggleBtn = this.buildIconButton('collapse', 'Collapse toolbar', () => {
      this.toggleCollapse();
    });
    this.toggleArrow = this.toggleBtn.querySelector('span');
    container.appendChild(this.toggleBtn);

    // Content wrapper — everything below collapse button, hidden when collapsed
    const contentWrapper = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      gap: '2px',
    });
    this.contentWrapper = contentWrapper;

    // Grid toggle button — click to toggle, long-press (500ms) for settings
    this.gridBtn = this.buildIconButton('grid', 'Toggle grid (hold for settings)', () => {
      // Click handled by pointerup below
    });
    {
      let gridPressTimer: ReturnType<typeof setTimeout> | null = null;
      let gridLongPressed = false;

      this.gridBtn.addEventListener('pointerdown', (e) => {
        e.stopPropagation();
        gridLongPressed = false;
        gridPressTimer = setTimeout(() => {
          gridLongPressed = true;
          this.gridSettingsToggleCb?.();
        }, 500);
      });

      this.gridBtn.addEventListener('pointerup', () => {
        if (gridPressTimer) {
          clearTimeout(gridPressTimer);
          gridPressTimer = null;
        }
        if (!gridLongPressed) {
          if (this.gridBlockReason) return;
          this.gridEnabled = !this.gridEnabled;
          this.setGridEnabled(this.gridEnabled);
          this.gridToggleCb?.(this.gridEnabled);
        }
      });

      this.gridBtn.addEventListener('pointerleave', () => {
        if (gridPressTimer) {
          clearTimeout(gridPressTimer);
          gridPressTimer = null;
        }
      });
    }
    // View section — inspection utilities (grid, rulers, screenshot, devtools)
    const viewBody = this.buildSection('view', contentWrapper);

    viewBody.appendChild(this.gridBtn);

    // Rulers toggle button
    this.rulersBtn = this.buildIconButton('ruler', 'Toggle rulers & guides', () => {
      this.rulersEnabled = !this.rulersEnabled;
      this.setRulersEnabled(this.rulersEnabled);
      this.rulersToggleCb?.(this.rulersEnabled);
    });
    viewBody.appendChild(this.rulersBtn);

    // Screenshot button
    this.screenshotBtn = this.buildIconButton('camera', 'Capture full-page screenshot', () => {
      if (this.screenshotBusy) return;
      this.screenshotCb?.();
    });
    viewBody.appendChild(this.screenshotBtn);

    // DevTools panel button (DOM inspector + properties + console)
    const devtoolsBtn = this.buildIconButton('devtools', 'DevTools panel', () => {
      this.inspectorToggleCbs.get('devtools')?.();
    });
    this.inspectorButtons.set('devtools', devtoolsBtn);
    viewBody.appendChild(devtoolsBtn);

    // Tools section — the editing tool radiogroup
    const toolsBody = this.buildSection('tools', contentWrapper);

    // Tools wrapper — a radio group: exactly one editing tool is active at a time.
    const wrapper = createElement('div', { role: 'radiogroup', 'aria-label': 'Editing tool' }, {
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      gap: '2px',
    });

    for (const mode of TOOL_ORDER) {
      const btn = this.buildIconButton(mode, TOOL_LABELS[mode], () => {
        if (this.disabledTools.has(mode)) return;

        // Cursor is the default — can't toggle off, only switch to
        if (mode === 'cursor' && this.activeMode === 'cursor') return;

        if (this.activeMode === mode) {
          // Toggle off → fall back to cursor
          this.toolCb?.('cursor');
        } else {
          this.toolCb?.(mode);
        }
      });
      btn.setAttribute('role', 'radio');
      btn.addEventListener('keydown', (e) => this.onToolKeydown(e, mode));
      this.toolButtons.set(mode, btn);
      wrapper.appendChild(btn);
    }

    toolsBody.appendChild(wrapper);

    // Actions section — undo/redo, reset, duplicate, delete
    const actionsBody = this.buildSection('actions', contentWrapper);

    // Notes button (with count badge)
    this.notesBtn = this.buildIconButton('notes', 'Session notes', () => {
      this.notesToggleCb?.();
    });
    this.notesBtn.style.position = 'relative';

    this.notesBadge = createElement('span', {}, {
      position: 'absolute',
      top: '2px',
      right: '2px',
      minWidth: '14px',
      height: '14px',
      borderRadius: '7px',
      background: OVERLAY.primary,
      color: '#000',
      fontSize: '9px',
      fontWeight: '600',
      fontFamily: OVERLAY.fontFamily,
      display: 'none',
      alignItems: 'center',
      justifyContent: 'center',
      padding: '0 3px',
      lineHeight: '1',
      pointerEvents: 'none',
    }) as HTMLSpanElement;
    this.notesBtn.appendChild(this.notesBadge);
    contentWrapper.appendChild(this.notesBtn);

    // Review changes button (always visible, with count badge)
    this.reviewBtn = this.buildIconButton('review', 'Review changes', () => {
      this.reviewToggleCb?.();
    });
    this.reviewBtn.style.position = 'relative';

    // Count badge pip
    this.reviewBadge = createElement('span', {}, {
      position: 'absolute',
      top: '2px',
      right: '2px',
      minWidth: '14px',
      height: '14px',
      borderRadius: '7px',
      background: OVERLAY.accent,
      color: '#fff',
      fontSize: '9px',
      fontWeight: '600',
      fontFamily: OVERLAY.fontFamily,
      display: 'none',
      alignItems: 'center',
      justifyContent: 'center',
      padding: '0 3px',
      lineHeight: '1',
      pointerEvents: 'none',
    }) as HTMLSpanElement;
    this.reviewBtn.appendChild(this.reviewBadge);
    contentWrapper.appendChild(this.reviewBtn);

    // Undo/Redo row
    const undoRedoRow = createElement('div', {}, {
      display: 'flex',
      gap: '0px',
      alignItems: 'center',
    });

    this.undoBtn = this.buildIconButton('undo', 'Undo', () => {
      if (this.undoBtn?.style.opacity !== '0.3') this.undoCb?.();
    });
    this.undoBtn.style.width = '20px';
    this.undoBtn.style.height = '28px';
    undoRedoRow.appendChild(this.undoBtn);

    this.redoBtn = this.buildIconButton('redo', 'Redo', () => {
      if (this.redoBtn?.style.opacity !== '0.3') this.redoCb?.();
    });
    this.redoBtn.style.width = '20px';
    this.redoBtn.style.height = '28px';
    undoRedoRow.appendChild(this.redoBtn);

    actionsBody.appendChild(undoRedoRow);

    // Reset button
    this.resetBtn = this.buildIconButton('reset', 'Reset all changes', () => {
      this.showResetConfirmation();
    });
    actionsBody.appendChild(this.resetBtn);

    // Duplicate element button
    this.duplicateBtn = this.buildIconButton('duplicate', 'Duplicate element (⌘D)', () => {
      if (this.duplicateBtn?.style.opacity !== '0.3') this.duplicateCb?.();
    });
    this.duplicateBtn.style.color = OVERLAY.textMuted;
    actionsBody.appendChild(this.duplicateBtn);
    this.setDuplicateEnabled(false);

    // Delete element button
    this.deleteBtn = this.buildIconButton('delete', 'Delete element (Del)', () => {
      if (this.deleteBtn?.style.opacity !== '0.3') this.deleteCb?.();
    });
    this.deleteBtn.style.color = OVERLAY.textMuted;
    actionsBody.appendChild(this.deleteBtn);
    this.setDeleteEnabled(false);

    container.appendChild(contentWrapper);

    this.refreshButtonStates();
    // Initialize undo/redo as disabled
    this.setUndoRedoState(false, false);

    // Seed toggle buttons with an explicit aria-pressed so assistive tech
    // announces them as toggles from first render; index.ts re-syncs real state.
    this.setGridEnabled(this.gridEnabled);
    this.setRulersEnabled(this.rulersEnabled);
    this.setNotesOpen(false);
    this.setReviewPanelOpen(this.reviewOpen);
    this.setInspectorOpen('devtools', this.activeInspectors.has('devtools'));

    return container;
  }

  private buildIconButton(
    iconKey: string,
    title: string,
    onClick: () => void,
  ): HTMLButtonElement {
    // `aria-label` mirrors the visible `title` so the icon-only button carries a
    // stable accessible name even when the tooltip text is later reassigned (e.g.
    // disabled-state titles). State is layered on per button kind: tool buttons
    // get radio semantics (aria-checked) via applyButtonStyle; the toggle buttons
    // (grid/rulers/notes/review/devtools) get aria-pressed via their setters.
    const btn = createElement('button', { title, 'aria-label': title }, {
      width: '32px',
      height: '32px',
      border: 'none',
      borderRadius: OVERLAY.radiusSm,
      background: 'transparent',
      color: OVERLAY.textMuted,
      cursor: 'pointer',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      padding: '0',
      pointerEvents: 'auto',
      transition: 'background 0.1s, color 0.1s',
    }) as HTMLButtonElement;

    // Decorative glyph — the accessible name comes from the button's aria-label.
    const iconSpan = createElement('span', { 'aria-hidden': 'true' }, {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      width: '16px',
      height: '16px',
      transition: 'transform 0.15s ease',
    });
    iconSpan.innerHTML = ICONS[iconKey] ?? '';
    btn.appendChild(iconSpan);

    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      onClick();
    });

    btn.addEventListener('mouseenter', () => {
      if (btn.style.opacity !== '0.3') {
        btn.style.background = OVERLAY.hover;
      }
    });
    btn.addEventListener('mouseleave', () => {
      // applyButtonStyle re-styles TOOL buttons from their active/disabled state.
      // Non-tool icon buttons (grid, ruler, collapse, undo, redo, reset, notes,
      // review, devtools, screenshot, duplicate, delete) are not in TOOL_LABELS,
      // so routing them here would set `title = TOOL_LABELS[iconKey]` → the string
      // "undefined". Just clear the hover background; their title/state is owned
      // by their own setters.
      if (this.toolButtons.get(iconKey as EditMode) === btn) {
        this.applyButtonStyle(btn, iconKey as EditMode);
      } else if (btn.style.opacity !== '0.3') {
        // Restore the resting background. Toggle buttons (grid/rulers/notes/
        // review/devtools) record their active cyan/pink in dataset.restBg via
        // their setters; everything else falls back to transparent.
        btn.style.background = btn.dataset.restBg ?? 'transparent';
      }
    });

    return btn;
  }

  /**
   * Build a collapsible section: a thin chevron header the operator can toggle,
   * above a body that holds the section's buttons. The root is appended to
   * `parent`; the body is returned for the caller to populate.
   */
  private buildSection(id: ToolbarSectionId, parent: HTMLElement): HTMLDivElement {
    const label = SECTION_LABELS[id];

    const root = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      gap: '2px',
      width: '100%',
    });

    const headerBtn = createElement('button', {
      title: `Collapse ${label}`,
      'aria-label': `${label} section`,
      'aria-expanded': 'true',
    }, {
      width: '32px',
      height: '24px',
      border: 'none',
      borderTop: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      background: 'transparent',
      color: OVERLAY.textMuted,
      cursor: 'pointer',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      padding: '0',
      pointerEvents: 'auto',
      transition: 'background 0.1s',
    }) as HTMLButtonElement;

    const chevron = createElement('span', { 'aria-hidden': 'true' }, {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      width: '10px',
      height: '10px',
    });
    chevron.innerHTML = ICONS['chevron-down'] ?? '';
    headerBtn.appendChild(chevron);

    headerBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      const state = this.sections.get(id);
      if (state) this.setSectionCollapsed(id, !state.collapsed, true);
    });
    headerBtn.addEventListener('mouseenter', () => {
      headerBtn.style.background = OVERLAY.hover;
    });
    headerBtn.addEventListener('mouseleave', () => {
      headerBtn.style.background = 'transparent';
    });

    const body = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      gap: '2px',
    });

    root.appendChild(headerBtn);
    root.appendChild(body);
    parent.appendChild(root);

    this.sections.set(id, { body, headerBtn, chevron, collapsed: false, manual: false });
    return body;
  }

  // -----------------------------------------------------------------------
  // State rendering
  // -----------------------------------------------------------------------

  private refreshButtonStates(): void {
    for (const [mode, btn] of this.toolButtons) {
      this.applyButtonStyle(btn, mode);
    }
  }

  private applyButtonStyle(btn: HTMLButtonElement, mode: EditMode): void {
    const isActive = this.activeMode === mode;
    const disabledReason = this.disabledTools.get(mode);

    // Radio semantics apply only to real tool buttons. buildIconButton's
    // mouseleave handler calls this for every icon button (grid, rulers, undo…),
    // so guard against writing radio ARIA onto non-tool buttons — that would
    // clobber their aria-pressed and drop them from the tab order.
    if (this.toolButtons.get(mode) === btn) {
      // aria-checked reflects the single active tool; a roving tabindex keeps
      // exactly one tool in the tab order (the active one, or the default cursor
      // before any tool is chosen).
      btn.setAttribute('aria-checked', String(isActive));
      const tabbable = isActive || (this.activeMode === null && mode === TOOL_ORDER[0]);
      btn.setAttribute('tabindex', tabbable ? '0' : '-1');
    }

    if (disabledReason) {
      btn.style.opacity = '0.3';
      btn.style.cursor = 'not-allowed';
      btn.style.pointerEvents = 'auto'; // Keep auto so title tooltip works
      btn.style.background = 'transparent';
      btn.style.color = OVERLAY.textMuted;
      btn.title = `${TOOL_LABELS[mode]} — ${disabledReason}`;
    } else if (isActive) {
      btn.style.opacity = '1';
      btn.style.cursor = 'pointer';
      btn.style.pointerEvents = 'auto';
      btn.style.background = 'rgba(6, 182, 212, 0.12)';
      btn.style.color = OVERLAY.primary;
      btn.title = TOOL_LABELS[mode];
    } else {
      btn.style.opacity = '1';
      btn.style.cursor = 'pointer';
      btn.style.pointerEvents = 'auto';
      btn.style.background = 'transparent';
      btn.style.color = OVERLAY.textMuted;
      btn.title = TOOL_LABELS[mode];
    }
  }

  /**
   * Radio-group keyboard navigation (ARIA tabs/radio pattern): arrow keys move to
   * the next/previous enabled tool (wrapping), Home/End jump to the first/last.
   * Moving selects the tool and shifts focus, keeping the roving tabindex intact.
   */
  private onToolKeydown(e: KeyboardEvent, current: EditMode): void {
    const n = TOOL_ORDER.length;
    let dir: number;
    let start = TOOL_ORDER.indexOf(current);
    switch (e.key) {
      case 'ArrowDown': case 'ArrowRight': dir = 1; break;
      case 'ArrowUp': case 'ArrowLeft': dir = -1; break;
      case 'Home': dir = 1; start = -1; break;
      case 'End': dir = -1; start = n; break;
      default: return;
    }
    e.preventDefault();
    let idx = start;
    for (let i = 0; i < n; i++) {
      idx = (idx + dir + n) % n;
      const mode = TOOL_ORDER[idx];
      if (!this.disabledTools.has(mode)) {
        this.toolCb?.(mode);
        this.toolButtons.get(mode)?.focus();
        return;
      }
    }
  }

  // -----------------------------------------------------------------------
  // Collapse / expand toolbar
  // -----------------------------------------------------------------------

  /** Toggle collapse state programmatically (e.g., from keyboard shortcut). */
  toggle(): void {
    this.toggleCollapse();
  }

  isCollapsed(): boolean {
    return this.collapsed;
  }

  private toggleCollapse(): void {
    if (!this.collapsed) {
      // Collapsing — minimize toolbar to just grip + collapse button
      this.collapsed = true;

      if (this.contentWrapper) {
        this.contentWrapper.style.display = 'none';
      }

      if (this.toggleArrow) {
        this.toggleArrow.innerHTML = ICONS['expand'] ?? '';
      }
      if (this.toggleBtn) {
        this.toggleBtn.title = 'Expand toolbar';
      }

      this.collapseCb?.(true);
    } else {
      // Expanding — restore full toolbar
      this.collapsed = false;

      if (this.contentWrapper) {
        this.contentWrapper.style.display = 'flex';
      }

      if (this.toggleArrow) {
        this.toggleArrow.innerHTML = ICONS['collapse'] ?? '';
      }
      if (this.toggleBtn) {
        this.toggleBtn.title = 'Collapse toolbar';
      }

      this.collapseCb?.(false);

      // Content is measurable again — re-evaluate section fit.
      this.updateSectionAutoFit();
    }
  }

  // -----------------------------------------------------------------------
  // Collapsible sections — manual toggle + viewport-height auto-fit
  // -----------------------------------------------------------------------

  /** Collapse/expand one section. `manual` marks the operator's explicit choice. */
  private setSectionCollapsed(id: ToolbarSectionId, collapsed: boolean, manual: boolean): void {
    const state = this.sections.get(id);
    if (!state) return;
    if (manual) state.manual = true;
    if (state.collapsed === collapsed) return;
    state.collapsed = collapsed;

    // Explicit 'flex' on expand — an empty string would revert to the CSS
    // default (block) and destroy the column layout.
    state.body.style.display = collapsed ? 'none' : 'flex';
    state.chevron.innerHTML = ICONS[collapsed ? 'chevron-right' : 'chevron-down'] ?? '';
    state.headerBtn.setAttribute('aria-expanded', String(!collapsed));
    this.refreshSectionHeader(id);
  }

  /**
   * Header tooltip + tint. A collapsed section whose tools are still engaged is
   * tinted, so the operator keeps a visible signal that (say) the spacing tool
   * is active even though its button is hidden.
   */
  private refreshSectionHeader(id: ToolbarSectionId): void {
    const state = this.sections.get(id);
    if (!state) return;
    const label = SECTION_LABELS[id];
    const active = this.isSectionActive(id);
    const hiddenActive = state.collapsed && active;

    state.headerBtn.title = hiddenActive
      ? `Expand ${label} — in use`
      : `${state.collapsed ? 'Expand' : 'Collapse'} ${label}`;
    state.headerBtn.setAttribute(
      'aria-label',
      hiddenActive ? `${label} section, in use` : `${label} section`,
    );
    state.headerBtn.style.color = hiddenActive ? OVERLAY.primary : OVERLAY.textMuted;
  }

  /** Which section's body holds this button, if any. */
  private sectionForButton(btn: HTMLElement): ToolbarSectionId | null {
    for (const [id, state] of this.sections) {
      if (state.body.contains(btn)) return id;
    }
    return null;
  }

  /**
   * A section is "active" when a tool it hosts is currently engaged — auto-fit
   * never collapses an active section (the operator still can, manually).
   * `actions` is never active: undo/redo/reset are one-shot commands, not modes,
   * so it stays the first candidate for the bottom-up collapse order.
   */
  private isSectionActive(id: ToolbarSectionId): boolean {
    switch (id) {
      case 'tools':
        return this.activeMode !== null && this.activeMode !== 'cursor';
      case 'view':
        return this.gridEnabled || this.rulersEnabled || this.activeInspectors.size > 0;
      case 'actions':
        return false;
    }
  }

  private scheduleSectionAutoFit(): void {
    if (this.autoFitTimer !== null) clearTimeout(this.autoFitTimer);
    this.autoFitTimer = setTimeout(() => {
      this.autoFitTimer = null;
      this.updateSectionAutoFit();
    }, AUTO_FIT_DEBOUNCE_MS);
  }

  /**
   * Auto-fit: when the viewport is shorter than the toolbar, collapse sections
   * bottom-up (actions → tools → view), skipping active sections and sections
   * the operator has toggled manually. When space allows again, auto-collapsed
   * sections re-expand (top-down). Manually-toggled sections are never touched.
   */
  private updateSectionAutoFit(): void {
    if (!this.container || !this.visible || this.collapsed) return;

    // Start from the all-open baseline for auto-managed sections, then measure.
    for (const id of SECTION_ORDER) {
      const state = this.sections.get(id);
      if (state && state.collapsed && !state.manual) {
        this.setSectionCollapsed(id, false, false);
      }
    }

    const fits = (): boolean => this.container!.offsetHeight <= window.innerHeight;

    if (!fits()) {
      for (let i = SECTION_ORDER.length - 1; i >= 0; i--) {
        const id = SECTION_ORDER[i];
        const state = this.sections.get(id);
        if (!state || state.collapsed || state.manual || this.isSectionActive(id)) continue;
        this.setSectionCollapsed(id, true, false);
        if (fits()) break;
      }
    }

    // Activity may have changed without any collapse state changing (a
    // manually-collapsed section whose tool just became active), so refresh
    // every header rather than relying on setSectionCollapsed.
    for (const id of SECTION_ORDER) this.refreshSectionHeader(id);
  }

  // -----------------------------------------------------------------------
  // Reset confirmation modal
  // -----------------------------------------------------------------------

  private showResetConfirmation(): void {
    if (this.confirmOverlay) return;

    // Full-screen overlay backdrop
    const overlay = createElement('div', {}, {
      position: 'fixed',
      top: '0',
      left: '0',
      width: '100vw',
      height: '100vh',
      background: 'rgba(0, 0, 0, 0.5)',
      zIndex: '200',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      pointerEvents: 'auto',
    });

    // Modal
    const modal = createElement('div', {
      role: 'alertdialog',
      'aria-modal': 'true',
      'aria-labelledby': 'nco-reset-heading',
      'aria-describedby': 'nco-reset-desc',
    }, {
      background: OVERLAY.bg,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusMd,
      boxShadow: OVERLAY.shadowLg,
      padding: '20px',
      width: '280px',
      fontFamily: OVERLAY.fontFamily,
      color: OVERLAY.text,
      display: 'flex',
      flexDirection: 'column',
      gap: '12px',
    });

    const heading = createElement('div', { id: 'nco-reset-heading' }, {
      fontSize: OVERLAY.headingSize,
      fontWeight: OVERLAY.headingWeight,
      color: OVERLAY.text,
      fontFamily: OVERLAY.fontFamily,
    });
    heading.textContent = 'Reset all changes?';
    modal.appendChild(heading);

    const desc = createElement('div', { id: 'nco-reset-desc' }, {
      fontSize: OVERLAY.bodySize,
      color: OVERLAY.textMuted,
      fontFamily: OVERLAY.fontFamily,
      lineHeight: '1.5',
    });
    desc.textContent = 'This will revert all visual edits and clear the pending queue. This action cannot be undone.';
    modal.appendChild(desc);

    const actions = createElement('div', {}, {
      display: 'flex',
      gap: '8px',
      justifyContent: 'flex-end',
    });

    const cancelBtn = createButton('Cancel', 'ghost', () => {
      this.hideResetConfirmation();
    });
    actions.appendChild(cancelBtn);

    const confirmBtn = createButton('Reset', 'destructive', () => {
      this.hideResetConfirmation();
      this.resetCb?.();
    });
    actions.appendChild(confirmBtn);

    modal.appendChild(actions);
    overlay.appendChild(modal);

    // Close on backdrop click
    overlay.addEventListener('click', (e) => {
      if (e.target === overlay) this.hideResetConfirmation();
    });

    // Modal keyboard contract: Escape cancels; Tab/Shift+Tab are trapped within
    // the two action buttons so focus cannot escape the dialog to the page behind.
    const focusables = [cancelBtn, confirmBtn];
    modal.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        this.hideResetConfirmation();
        return;
      }
      if (e.key !== 'Tab') return;
      e.preventDefault();
      const active = this.shadow.activeElement as HTMLElement | null;
      const idx = active ? focusables.indexOf(active as HTMLButtonElement) : -1;
      if (idx === -1) {
        // Focus escaped the trap — re-enter at the natural end (first for Tab,
        // last for Shift+Tab). Don't feed a synthetic index into the wrap math.
        focusables[e.shiftKey ? focusables.length - 1 : 0].focus();
        return;
      }
      const nextIdx = (idx + (e.shiftKey ? -1 : 1) + focusables.length) % focusables.length;
      focusables[nextIdx].focus();
    });

    this.confirmOverlay = overlay;
    this.shadow.appendChild(overlay);
    // Initial focus lands on the non-destructive action (ARIA alertdialog pattern).
    cancelBtn.focus();
  }

  private hideResetConfirmation(): void {
    this.confirmOverlay?.remove();
    this.confirmOverlay = null;
    // Restore focus to the control that opened the dialog.
    this.resetBtn?.focus();
  }

  // -----------------------------------------------------------------------
  // Position persistence
  // -----------------------------------------------------------------------

  private async savePosition(pos: PanelPosition): Promise<void> {
    try {
      await chrome.storage.session.set({ [TOOLBAR_STORAGE_KEY]: pos });
    } catch {
      // Non-fatal
    }
  }

  private async loadPosition(): Promise<PanelPosition | null> {
    try {
      const result = await chrome.storage.session.get(TOOLBAR_STORAGE_KEY);
      return (result[TOOLBAR_STORAGE_KEY] as PanelPosition) ?? null;
    } catch {
      return null;
    }
  }
}
