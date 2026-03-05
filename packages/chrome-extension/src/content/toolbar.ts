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

  insert: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round">
    <circle cx="8" cy="8" r="6.5"/>
    <line x1="8" y1="5" x2="8" y2="11"/>
    <line x1="5" y1="8" x2="11" y2="8"/>
  </svg>`,

  media: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <rect x="2" y="3" width="12" height="10" rx="1.5"/>
    <circle cx="5.5" cy="6.5" r="1.25" fill="currentColor" stroke="none"/>
    <polyline points="14,10 10.5,7 7,10"/>
    <polyline points="9,11 6.5,9 2,13"/>
  </svg>`,

  delete: `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <path d="M3 4.5h10"/>
    <path d="M6.5 2.5h3"/>
    <path d="M4.5 4.5l.5 8.5a1 1 0 0 0 1 1h4a1 1 0 0 0 1-1l.5-8.5"/>
    <line x1="6.5" y1="7" x2="6.5" y2="11.5"/>
    <line x1="9.5" y1="7" x2="9.5" y2="11.5"/>
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
};

const TOOL_LABELS: Record<EditMode, string> = {
  cursor: 'Select',
  spacing: 'Spacing',
  dimensions: 'Size',
  typography: 'Type',
  colors: 'Colors',
  'border-radius': 'Radius',
  position: 'Position',
  reorder: 'Reorder',
  insert: 'Insert',
  media: 'Media',
};

const TOOLBAR_STORAGE_KEY = 'frontend-editor-toolbar-position';

const TOOL_ORDER: EditMode[] = [
  'cursor',
  'spacing',
  'dimensions',
  'typography',
  'colors',
  'border-radius',
  'position',
  'reorder',
  'insert',
  'media',
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

  private reviewOpen = false;
  private contentWrapper: HTMLDivElement | null = null;
  private toolsSection: HTMLDivElement | null = null;
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

  /** Sync rulers button active state. */
  setRulersEnabled(enabled: boolean): void {
    this.rulersEnabled = enabled;
    if (!this.rulersBtn) return;
    if (enabled) {
      this.rulersBtn.style.background = 'rgba(6, 182, 212, 0.12)';
      this.rulersBtn.style.color = OVERLAY.primary;
    } else {
      this.rulersBtn.style.background = 'transparent';
      this.rulersBtn.style.color = OVERLAY.textMuted;
    }
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
    if (open) {
      this.notesBtn.style.background = 'rgba(6, 182, 212, 0.12)';
      this.notesBtn.style.color = OVERLAY.primary;
    } else {
      this.notesBtn.style.background = 'transparent';
      this.notesBtn.style.color = OVERLAY.textMuted;
    }
  }

  /** Sync grid button active state. */
  setGridEnabled(enabled: boolean): void {
    this.gridEnabled = enabled;
    if (!this.gridBtn) return;
    if (enabled) {
      this.gridBtn.style.background = 'rgba(6, 182, 212, 0.12)';
      this.gridBtn.style.color = OVERLAY.primary;
    } else {
      this.gridBtn.style.background = 'transparent';
      this.gridBtn.style.color = OVERLAY.textMuted;
    }
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
    const btn = this.inspectorButtons.get(mode);
    if (!btn) return;
    if (open) {
      btn.style.background = 'rgba(6, 182, 212, 0.12)';
      btn.style.color = OVERLAY.primary;
    } else {
      btn.style.background = 'transparent';
      btn.style.color = OVERLAY.textMuted;
    }
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
    if (open) {
      this.reviewBtn.style.background = `rgba(251, 113, 133, 0.15)`;
      this.reviewBtn.style.color = OVERLAY.accent;
    } else {
      this.reviewBtn.style.background = 'transparent';
      this.reviewBtn.style.color = OVERLAY.textMuted;
    }
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
  }

  hide(): void {
    this.confirmOverlay?.remove();
    this.confirmOverlay = null;
    this.container?.remove();
    this.container = null;
    this.contentWrapper = null;
    this.toolsSection = null;
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
    this.deleteBtn = null;
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
    this.deleteCb = null;
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
    // Tools section — grid, devtools, editing tools + separators, hidden during page mode
    const toolsSection = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      gap: '2px',
    });
    this.toolsSection = toolsSection;

    toolsSection.appendChild(this.gridBtn);

    // Rulers toggle button
    this.rulersBtn = this.buildIconButton('ruler', 'Toggle rulers & guides', () => {
      this.rulersEnabled = !this.rulersEnabled;
      this.setRulersEnabled(this.rulersEnabled);
      this.rulersToggleCb?.(this.rulersEnabled);
    });
    toolsSection.appendChild(this.rulersBtn);

    // DevTools panel button (DOM inspector + properties + console)
    const devtoolsBtn = this.buildIconButton('devtools', 'DevTools panel', () => {
      this.inspectorToggleCbs.get('devtools')?.();
    });
    this.inspectorButtons.set('devtools', devtoolsBtn);
    toolsSection.appendChild(devtoolsBtn);

    // Separator
    const sep = createElement('div', {}, {
      width: '24px',
      height: '1px',
      background: OVERLAY.border,
      margin: '2px 0',
    });
    toolsSection.appendChild(sep);

    // Tools wrapper
    const wrapper = createElement('div', {}, {
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
      this.toolButtons.set(mode, btn);
      wrapper.appendChild(btn);
    }

    toolsSection.appendChild(wrapper);

    // Separator after tools
    const sep2 = createElement('div', {}, {
      width: '24px',
      height: '1px',
      background: OVERLAY.border,
      margin: '2px 0',
    });
    toolsSection.appendChild(sep2);

    contentWrapper.appendChild(toolsSection);

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

    toolsSection.appendChild(undoRedoRow);

    // Reset button
    this.resetBtn = this.buildIconButton('reset', 'Reset all changes', () => {
      this.showResetConfirmation();
    });
    toolsSection.appendChild(this.resetBtn);

    // Delete element button
    this.deleteBtn = this.buildIconButton('delete', 'Delete element (Del)', () => {
      if (this.deleteBtn?.style.opacity !== '0.3') this.deleteCb?.();
    });
    this.deleteBtn.style.color = OVERLAY.textMuted;
    toolsSection.appendChild(this.deleteBtn);
    this.setDeleteEnabled(false);

    container.appendChild(contentWrapper);

    this.refreshButtonStates();
    // Initialize undo/redo as disabled
    this.setUndoRedoState(false, false);

    return container;
  }

  private buildIconButton(
    iconKey: string,
    title: string,
    onClick: () => void,
  ): HTMLButtonElement {
    const btn = createElement('button', { title }, {
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

    const iconSpan = createElement('span', {}, {
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
        btn.style.background = 'rgba(255, 255, 255, 0.08)';
      }
    });
    btn.addEventListener('mouseleave', () => {
      // Re-apply the correct state
      this.applyButtonStyle(btn, iconKey as EditMode);
    });

    return btn;
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

  // -----------------------------------------------------------------------
  // Collapse / expand toolbar
  // -----------------------------------------------------------------------

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
    }
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
    const modal = createElement('div', { role: 'alertdialog', 'aria-label': 'Confirm reset' }, {
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

    const heading = createElement('div', {}, {
      fontSize: OVERLAY.headingSize,
      fontWeight: OVERLAY.headingWeight,
      color: OVERLAY.text,
      fontFamily: OVERLAY.fontFamily,
    });
    heading.textContent = 'Reset all changes?';
    modal.appendChild(heading);

    const desc = createElement('div', {}, {
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

    this.confirmOverlay = overlay;
    this.shadow.appendChild(overlay);
  }

  private hideResetConfirmation(): void {
    this.confirmOverlay?.remove();
    this.confirmOverlay = null;
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
