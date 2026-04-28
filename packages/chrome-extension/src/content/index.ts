import { mountShadowHost, unmountShadowHost } from './shadow-host';
import { WebSocketClient } from './websocket-client';
import { HoverHighlight } from './selection/hover';
import { SelectionManager } from './selection/select';
import { DevToolsPanel } from './selection/devtools-panel';
import { StaleDetector } from './selection/stale';
import { TokenStore } from './tokens/store';
import { SnappingEngine } from './tokens/snapping';
import { PreviewManager } from './editing/preview';
import { DragHandleManager, getDimensionBlockReason } from './editing/handles';
import { DimensionsEditor } from './editing/dimensions';
import { SpacingEditor } from './editing/spacing';
import { PositionEditor } from './editing/position';
import { KeyboardHandler } from './editing/keyboard';
import { DiffBuilder } from './batching/diff-builder';
import { PendingQueue } from './batching/queue';
import { BadgeUpdater } from './batching/badge';
import { ReviewPanel } from './batching/review-panel';
import { TypographyEditor } from './editing/typography';
import { ColorEditor } from './editing/colors';
import { FloatingToolbar } from './toolbar';
import { EditHistory } from './history';
import type { HistoryEntry } from './history';
import { NotesStore } from './batching/notes-store';
import { NotesEditor } from './editing/notes';
import { GridOverlay } from './grid-overlay';
import { RulerOverlay } from './ruler-overlay';
import { ReorderEditor, getReorderBlockReason } from './editing/reorder';
import type { ReorderCommitCallback } from './editing/reorder';
import { ReparentEditor, getReparentBlockReason } from './editing/reparent';
import type { ReparentCommitCallback } from './editing/reparent';
import { InsertEditor, getInsertBlockReason } from './editing/insert';
import { TextEditor, getTextBlockReason } from './editing/text';
import { MediaEditor } from './editing/media';
import { EffectsEditor } from './editing/effects';
import { AppearanceEditor } from './editing/appearance';
import { captureFullPage } from './screenshot';
import type { InsertCommitCallback } from './editing/insert';
import { buildInsertChange } from './editing/insert-source';
import { groupElements, getGroupBlockReason } from './editing/group';
import { GridSettingsPanel } from './grid-settings';
import { MeasureOverlay } from './selection/measure-overlay';
import { MultiSelectManager } from './selection/multi-select';
import { MultiSelectToolbar } from './editing/multi-select-toolbar';
import { buildElementInfo, getTopElementAt, generateSelector } from '../shared/dom-utils';
import type { VisualDiff, PropertyChange, AttributeChange, TextChange, ReorderChange, ReparentChange, GroupChange, RemoveChange } from '@frontend-editor/shared';
import type { ExtensionMode, ConnectionStatus, EditMode } from '../shared/types';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let mode: ExtensionMode = 'inactive';
let host: HTMLDivElement | null = null;
let shadow: ShadowRoot | null = null;

// Subsystems (initialized on first activation)
let wsClient: WebSocketClient | null = null;
let hover: HoverHighlight | null = null;
let selection: SelectionManager | null = null;
let devtoolsPanel: DevToolsPanel | null = null;
let toolbar: FloatingToolbar | null = null;
let staleDetector: StaleDetector | null = null;
let tokenStore: TokenStore | null = null;
let snapping: SnappingEngine | null = null;
let preview: PreviewManager | null = null;
let handles: DragHandleManager | null = null;
let keyboard: KeyboardHandler | null = null;
let diffBuilder: DiffBuilder | null = null;
let queue: PendingQueue | null = null;
let badge: BadgeUpdater | null = null;
let reviewPanel: ReviewPanel | null = null;
let typographyEditor: TypographyEditor | null = null;
let colorEditor: ColorEditor | null = null;
let dimensionsEditor: DimensionsEditor | null = null;
let spacingEditor: SpacingEditor | null = null;
let positionEditor: PositionEditor | null = null;
let editHistory: EditHistory | null = null;
let notesStore: NotesStore | null = null;
let notesEditor: NotesEditor | null = null;
let gridOverlay: GridOverlay | null = null;
let reorderEditor: ReorderEditor | null = null;
let reparentEditor: ReparentEditor | null = null;
let insertEditor: InsertEditor | null = null;
let textEditor: TextEditor | null = null;
let mediaEditor: MediaEditor | null = null;
let effectsEditor: EffectsEditor | null = null;
let appearanceEditor: AppearanceEditor | null = null;
let gridSettingsPanel: GridSettingsPanel | null = null;
let measureOverlay: MeasureOverlay | null = null;
let measureRafId: number | null = null;
let devtoolsUserClosed = false;
let devtoolsOpenBeforeCollapse = false;
let gridVisibleBeforeCollapse = false;
let rulerOverlay: RulerOverlay | null = null;
let rulersVisibleBeforeCollapse = false;
let multiSelect: MultiSelectManager | null = null;
let multiSelectToolbar: MultiSelectToolbar | null = null;
let multiSelectClickHandler: ((e: MouseEvent) => void) | null = null;
let notePickMode: { noteIndex: number; handler: (e: MouseEvent) => void } | null = null;

// Element clipboard for copy/paste
let elementClipboard: { html: string; tagName: string } | null = null;

// Preserved tool mode across deselect→reselect cycle (selection.select() calls
// deselect() before onSelect fires, so onDeselect would reset the toolbar mode).
let preservedToolMode: EditMode | null = null;

// Tab session ID — stable for the tab's lifetime
let tabId: string | null = null;

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

export async function activate(): Promise<void> {
  if (mode !== 'inactive') return;

  // Get or create tab session ID
  tabId = await getOrCreateTabId();

  // Mount Shadow DOM
  const mounted = mountShadowHost();
  host = mounted.host;
  shadow = mounted.shadow;

  // Initialize subsystems
  tokenStore = new TokenStore();
  queue = new PendingQueue();
  await queue.restore();

  badge = new BadgeUpdater(queue);
  diffBuilder = new DiffBuilder(tabId, tokenStore);
  snapping = new SnappingEngine(tokenStore);
  preview = new PreviewManager();
  staleDetector = new StaleDetector();

  // WebSocket client
  wsClient = new WebSocketClient({
    tabId,
    getPendingDiffIds: () => queue!.getDiffIds(),
    onStatusChange: handleStatusChange,
    onServerHello: (payload) => {
      queue!.reconcile(payload.pendingDiffIds, payload.appliedDiffIds);
      badge!.update();
      reviewPanel?.refresh();
    },
    onDiffAck: (payload) => {
      queue!.acknowledge(payload.diffIds);
      badge!.update();
      reviewPanel?.refresh();
      devtoolsPanel?.log(`${payload.diffIds.length} diff(s) acknowledged`);
    },
    onDiffApplied: (payload) => {
      queue!.markApplied(payload.diffIds);
      badge!.update();
      reviewPanel?.refresh();
      devtoolsPanel?.log(`${payload.diffIds.length} diff(s) applied`);
    },
    onTokenData: (payload) => {
      tokenStore!.setAll(payload.tokens, payload.sources);
      devtoolsPanel?.log(`Received ${payload.tokens.length} design tokens`);
    },
    onTokenUpdate: (payload) => {
      tokenStore!.update(payload.tokens, payload.sources);
      devtoolsPanel?.log(`Token update: ${payload.tokens.length} tokens`);
    },
    onStatusResponse: (payload) => {
      queue!.updateFromServerStatus(payload.perDiff);
      badge!.update();
      reviewPanel?.refresh();
      devtoolsPanel?.log(`Status: ${payload.pendingCount} pending, last activity: ${payload.lastToolCallAt ?? 'none'}`);
    },
    onError: (payload) => {
      devtoolsPanel?.log(`Server error: ${payload.code} — ${payload.message}`, 'error');
    },
  });
  wsClient.connect();

  // Edit history (undo/redo)
  editHistory = new EditHistory();

  // Notes store (shared between notes panel and review panel)
  notesStore = new NotesStore();
  await notesStore.restore();

  // UI components
  hover = new HoverHighlight(shadow, host);
  selection = new SelectionManager(shadow, host, tokenStore);
  devtoolsPanel = new DevToolsPanel(shadow!, tokenStore!, queue!);
  toolbar = new FloatingToolbar(shadow);
  handles = new DragHandleManager(shadow, snapping, preview, () => rulerOverlay?.getGuidePositions() ?? { x: [], y: [] });
  keyboard = new KeyboardHandler(shadow, handles, null as any, selection);
  reviewPanel = new ReviewPanel(shadow!, queue!, wsClient!, diffBuilder!, notesStore!, (selector) => {
    const el = document.querySelector(selector);
    if (el) {
      hover?.showProgrammaticHighlight(el);
      setTimeout(() => hover?.clearProgrammaticHighlight(), 3000);
    }
  });
  typographyEditor = new TypographyEditor(tokenStore, preview);
  colorEditor = new ColorEditor(tokenStore, snapping, preview);
  dimensionsEditor = new DimensionsEditor(preview);
  spacingEditor = new SpacingEditor(tokenStore, preview);
  positionEditor = new PositionEditor(shadow, preview);
  notesEditor = new NotesEditor(notesStore, shadow);
  gridOverlay = new GridOverlay(shadow, tokenStore);
  rulerOverlay = new RulerOverlay(shadow, () => gridOverlay!.getEffectiveSettings(), () => gridOverlay?.isVisible() ?? false);
  reorderEditor = new ReorderEditor(shadow);
  reparentEditor = new ReparentEditor(shadow);
  insertEditor = new InsertEditor(shadow);
  textEditor = new TextEditor();
  mediaEditor = new MediaEditor(preview);
  MediaEditor.restoreHandle();
  effectsEditor = new EffectsEditor(preview);
  appearanceEditor = new AppearanceEditor(preview);
  gridSettingsPanel = new GridSettingsPanel(gridOverlay.getEffectiveSettings());
  measureOverlay = new MeasureOverlay(shadow, host);
  multiSelect = new MultiSelectManager(shadow, host);
  multiSelectToolbar = new MultiSelectToolbar(shadow, tokenStore, preview);
  multiSelectToolbar.onGroup((elements) => makeGroupCommit(elements));

  // Wire hover click → selection
  hover.onClick((el) => selection!.select(el));

  // Wire DevTools DOM tree clicks → re-select different element
  devtoolsPanel.onElementSelect((el) => selection!.select(el));

  // Wire DevTools DOM tree hover → highlight element on page
  devtoolsPanel.onElementHover((el) => {
    if (el) {
      hover!.highlightElement(el);
    } else {
      hover!.unhighlightElement();
    }
  });

  // Wire DevTools property edits → diff creation → queue + history
  devtoolsPanel.onPropertyChange((property, fromValue, toValue, tokenName) => {
    const el = selection!.getSelectedElement();
    if (!el) return;
    const info = buildElementInfo(el);
    const changes = [{
      property,
      fromValue,
      toValue,
      toToken: tokenName,
    }];
    const diff = diffBuilder!.build(info, changes);
    commitEdit(el, changes, diff);
    selection!.refreshHighlight();
  });

  // Wire DevTools multi-select shared property edits → diff per element
  devtoolsPanel.onMultiPropertyChange((changes) => {
    for (const c of changes) {
      const info = buildElementInfo(c.element);
      const propChanges: PropertyChange[] = [{
        property: c.property,
        fromValue: c.fromValue,
        toValue: c.toValue,
        toToken: c.token,
      }];
      const diff = diffBuilder!.build(info, propChanges);
      commitEdit(c.element, propChanges, diff);
    }
    selection?.refreshHighlight();
    multiSelect?.refreshHighlights();
  });

  // Wire multi-select selection changes
  multiSelect.onSelectionChange(() => {
    const primary = selection!.getSelectedElement();
    if (!primary) return;
    const allElements = multiSelect!.getAllElements(primary);

    // Update persistent measurement lines
    measureOverlay?.clear();
    measureOverlay?.renderPersistentLines(allElements);

    // Update multi-select toolbar
    if (multiSelectToolbar?.isOpen()) {
      multiSelectToolbar.updateElements(allElements);
    }

    // Update properties in DevTools panel
    if (devtoolsPanel?.isOpen()) {
      devtoolsPanel.updateMultiProperties(allElements);
    }
  });

  // Show toolbar immediately (stays visible for entire active session)
  toolbar.show();

  // Wire ruler overlay hover suppression
  rulerOverlay!.setHoverSuppressor(
    () => { hover!.disable(); if (host) host.style.pointerEvents = 'none'; },
    () => { hover!.enable(); if (host) host.style.pointerEvents = ''; },
  );

  // Wire selection → panel, toolbar, handles, stale detection
  selection.onSelect((info, element, _rect) => {
    // Exit multi-select on normal (non-Option) selection
    if (multiSelect?.isActive()) {
      exitMultiSelectMode();
    }

    // Only update DevTools if already open; selection no longer auto-opens the panel.
    if (devtoolsPanel!.isOpen()) {
      devtoolsPanel!.updateElement(element, info);
    }
    toolbar!.setDeleteEnabled(true);
    handles!.hideHandles();
    typographyEditor!.cleanup();
    colorEditor!.cleanup();
    dimensionsEditor!.cleanup();
    spacingEditor!.cleanup();
    positionEditor!.cleanup();
    reorderEditor!.cleanup();
    reparentEditor!.cleanup();
    insertEditor!.cleanup();
    textEditor!.cleanup();
    mediaEditor!.cleanup();
    effectsEditor!.cleanup();
    staleDetector!.watch(element, () => {
      selection!.markStale();
      handles!.hideHandles();
      // Transition notes panel from element → toolbar mode
      if (notesEditor?.isOpen() && notesEditor.getPositionMode() === 'element') {
        notesEditor.clearAnchoredElement();
        notesEditor.reposition(toolbar!.getButtonPosition('notes'));
      }
    });

    // Determine disabled tools
    const dimBlock = getDimensionBlockReason(element);
    const reorderBlock = getReorderBlockReason(element);
    const reparentBlock = getReparentBlockReason(element);
    const insertBlock = getInsertBlockReason(element);
    const textBlock = getTextBlockReason(element);
    const disabled: Partial<Record<EditMode, string>> = {};
    if (dimBlock) disabled['dimensions'] = dimBlock;
    if (reorderBlock) disabled['reorder'] = reorderBlock;
    if (reparentBlock) disabled['reparent'] = reparentBlock;
    if (insertBlock) disabled['insert'] = insertBlock;
    if (textBlock) disabled['text'] = textBlock;
    toolbar!.setDisabledTools(disabled);

    // Re-apply the previous active tool for the new element (preserve tool state).
    // onDeselect fires before onSelect during re-selection and resets toolbar to cursor,
    // so we read from the preserved mode that onDeselect captured before resetting.
    const previousMode = preservedToolMode ?? toolbar!.getActiveMode();
    preservedToolMode = null;
    const modeToApply = (previousMode && !disabled[previousMode]) ? previousMode : 'cursor';
    activateToolForElement(element, modeToApply);
  });

  selection.onDeselect(() => {
    // Preserve active tool mode so onSelect can restore it (select() calls
    // deselect() before onSelect fires, which would otherwise lose the mode).
    preservedToolMode = toolbar!.getActiveMode();

    if (multiSelect?.isActive()) {
      exitMultiSelectMode();
    }
    devtoolsPanel?.clearElement();
    toolbar!.setDeleteEnabled(false);
    handles!.hideHandles();
    typographyEditor!.cleanup();
    colorEditor!.cleanup();
    dimensionsEditor!.cleanup();
    spacingEditor!.cleanup();
    positionEditor!.cleanup();
    reorderEditor!.cleanup();
    reparentEditor!.cleanup();
    insertEditor!.cleanup();
    textEditor!.cleanup();
    mediaEditor!.cleanup();
    effectsEditor!.cleanup();
    measureOverlay!.disable();
    measureOverlay!.clear();
    staleDetector!.cleanup();
    preview!.revert();
    toolbar!.setActiveMode('cursor');
    toolbar!.setDisabledTools({});
    // Transition notes panel from element → toolbar mode
    if (notesEditor?.isOpen() && notesEditor.getPositionMode() === 'element') {
      notesEditor.clearAnchoredElement();
      notesEditor.reposition(toolbar!.getButtonPosition('notes'));
    }
  });

  // Wire toolbar tool selection → handles or floating editors
  toolbar.onToolSelect((selectedMode) => {
    if (multiSelect?.isActive()) return; // ignore tool changes during multi-select
    const el = selection!.getSelectedElement();
    if (!el) return;
    activateToolForElement(el, selectedMode);
  });

  // Wire DevTools toggle button
  toolbar.onInspectorToggle('devtools', () => {
    if (devtoolsPanel!.isOpen()) {
      devtoolsPanel!.hide();
      toolbar!.setInspectorOpen('devtools', false);
      devtoolsUserClosed = true;
    } else {
      const el = selection?.getSelectedElement() ?? undefined;
      const info = el ? buildElementInfo(el) : undefined;
      devtoolsPanel!.show(el, info);
      toolbar!.setInspectorOpen('devtools', true);
      devtoolsUserClosed = false;
    }
  });

  // Wire devtools panel close (via × button)
  devtoolsPanel.onClose(() => {
    toolbar!.setInspectorOpen('devtools', false);
    devtoolsUserClosed = true;
  });

  // Wire collapse → hide/restore all overlay UI when toolbar is collapsed/expanded.
  toolbar.onCollapse((collapsed) => {
    if (collapsed) {
      // Save DevTools state before hiding
      devtoolsOpenBeforeCollapse = devtoolsPanel!.isOpen();
      if (devtoolsOpenBeforeCollapse) {
        devtoolsPanel!.hide();
        toolbar!.setInspectorOpen('devtools', false);
      }

      // Save grid overlay state
      gridVisibleBeforeCollapse = gridOverlay!.isVisible();
      if (gridVisibleBeforeCollapse) {
        gridOverlay!.hide();
      }

      // Save rulers overlay state
      rulersVisibleBeforeCollapse = rulerOverlay!.isVisible();
      if (rulersVisibleBeforeCollapse) {
        rulerOverlay!.hide();
      }

      // Pause inspection — let user interact with the page normally
      hover!.disable();
      selection!.hideHighlight();
      handles!.hideHandles();
      typographyEditor!.cleanup();
      colorEditor!.cleanup();
      dimensionsEditor!.cleanup();
      spacingEditor!.cleanup();
      positionEditor!.cleanup();
      reorderEditor!.cleanup();
    reparentEditor!.cleanup();
      insertEditor!.cleanup();
      textEditor!.cleanup();
      mediaEditor!.cleanup();
      effectsEditor!.cleanup();
      notesEditor!.cleanup();
      gridSettingsPanel!.cleanup();
      multiSelectToolbar!.cleanup();
      toolbar!.setNotesOpen(false);
      if (reviewPanel!.isOpen()) {
        reviewPanel!.hide();
        toolbar!.setReviewPanelOpen(false);
      }
      document.body.style.cursor = '';
      if (host) host.style.pointerEvents = 'none';
      // Re-enable pointer events on toolbar container only
      const toolbarEl = toolbar!.getContainerElement();
      if (toolbarEl) toolbarEl.style.pointerEvents = 'auto';
    } else {
      // Resume DOM inspection
      if (host) host.style.pointerEvents = '';
      document.body.style.cursor = 'crosshair';
      hover!.enable();
      selection!.restoreHighlight();

      // Restore DevTools if it was open before page mode
      if (devtoolsOpenBeforeCollapse && !devtoolsUserClosed) {
        const el = selection?.getSelectedElement() ?? undefined;
        const info = el ? buildElementInfo(el) : undefined;
        devtoolsPanel!.show(el, info);
        toolbar!.setInspectorOpen('devtools', true);
      }

      // Restore grid overlay if it was visible
      if (gridVisibleBeforeCollapse) {
        gridOverlay!.show();
        toolbar!.setGridEnabled(true);
      }

      // Restore rulers overlay if it was visible
      if (rulersVisibleBeforeCollapse) {
        rulerOverlay!.show();
        toolbar!.setRulersEnabled(true);
      }
    }
  });

  // Wire toolbar drag → reposition open mini panels next to their buttons
  toolbar.onMove(() => {
    typographyEditor!.reposition(toolbar!.getButtonPosition('typography'));
    colorEditor!.reposition(toolbar!.getButtonPosition('colors'));
    dimensionsEditor!.reposition(toolbar!.getButtonPosition('dimensions'));
    spacingEditor!.reposition(toolbar!.getButtonPosition('spacing'));
    positionEditor!.reposition(toolbar!.getButtonPosition('position'));
    if (notesEditor!.getPositionMode() === 'toolbar') {
      notesEditor!.reposition(toolbar!.getButtonPosition('notes'));
    }
    reorderEditor!.reposition(toolbar!.getButtonPosition('reorder'));
    reparentEditor!.reposition({ x: 0, y: 0 }); // no-op — reparent has no positioned panel
    mediaEditor!.reposition(toolbar!.getButtonPosition('media'));
    effectsEditor!.reposition(toolbar!.getButtonPosition('effects'));
    appearanceEditor!.reposition(toolbar!.getButtonPosition('appearance'));
    gridSettingsPanel!.reposition(toolbar!.getButtonPosition('grid'));
    multiSelectToolbar!.reposition(toolbar!.getPosition());
    reviewPanel!.reposition(toolbar!.getButtonPosition('review'));
  });

  // Wire editor close buttons → fall back to cursor tool
  typographyEditor.onClose(() => {
    const el = selection?.getSelectedElement();
    if (el) { activateToolForElement(el, 'cursor'); }
    else { toolbar!.setActiveMode('cursor'); }
  });
  colorEditor.onClose(() => {
    const el = selection?.getSelectedElement();
    if (el) { activateToolForElement(el, 'cursor'); }
    else { toolbar!.setActiveMode('cursor'); }
  });
  dimensionsEditor.onClose(() => {
    handles!.hideHandles();
    const el = selection?.getSelectedElement();
    if (el) { activateToolForElement(el, 'cursor'); }
    else { toolbar!.setActiveMode('cursor'); }
  });
  spacingEditor.onClose(() => {
    handles!.hideHandles();
    const el = selection?.getSelectedElement();
    if (el) { activateToolForElement(el, 'cursor'); }
    else { toolbar!.setActiveMode('cursor'); }
  });
  positionEditor.onClose(() => {
    const el = selection?.getSelectedElement();
    if (el) { activateToolForElement(el, 'cursor'); }
    else { toolbar!.setActiveMode('cursor'); }
  });
  mediaEditor.onClose(() => {
    const el = selection?.getSelectedElement();
    if (el) { activateToolForElement(el, 'cursor'); }
    else { toolbar!.setActiveMode('cursor'); }
  });
  effectsEditor.onClose(() => {
    const el = selection?.getSelectedElement();
    if (el) { activateToolForElement(el, 'cursor'); }
    else { toolbar!.setActiveMode('cursor'); }
  });
  appearanceEditor.onClose(() => {
    const el = selection?.getSelectedElement();
    if (el) { activateToolForElement(el, 'cursor'); }
    else { toolbar!.setActiveMode('cursor'); }
  });

  // Wire review panel toggle
  toolbar.onReviewToggle(() => {
    if (reviewPanel!.isOpen()) {
      reviewPanel!.hide();
      toolbar!.setReviewPanelOpen(false);
    } else {
      reviewPanel!.show(toolbar!.getButtonPosition('review'));
      toolbar!.setReviewPanelOpen(true);
    }
  });

  // Sync review button state when panel is closed via its own × button
  reviewPanel.onClose(() => {
    toolbar!.setReviewPanelOpen(false);
  });

  // Wire notes toggle
  toolbar.onNotesToggle(() => {
    if (notesEditor!.isOpen()) {
      notesEditor!.cleanup();
      toolbar!.setNotesOpen(false);
    } else {
      const selectedEl = selection?.getSelectedElement();
      const isMulti = multiSelect?.isActive();

      // Element mode only for single selection (no multi-select)
      if (selectedEl && !isMulti) {
        const info = buildElementInfo(selectedEl);
        notesEditor!.setAnchoredElement(selectedEl, {
          selector: info.selector,
          tagName: info.tagName,
          textContent: info.textContent,
          sourceFile: info.sourceFile,
          sourceLine: info.sourceLine,
          instanceIndex: info.instanceIndex,
        });
      } else {
        notesEditor!.clearAnchoredElement();
      }

      const pos = toolbar!.getButtonPosition('notes');
      const notePanel = notesEditor!.render(pos);
      shadow!.appendChild(notePanel);
      toolbar!.setNotesOpen(true);
    }
  });

  notesEditor.onClose(() => {
    exitNotePickMode();
    toolbar!.setNotesOpen(false);
  });

  // Wire notes pick mode — sticky: each click adds an element, Escape exits
  notesEditor.onStartPick((noteIndex) => {
    if (notePickMode) {
      if (notePickMode.noteIndex === noteIndex) {
        exitNotePickMode();
        return;
      }
      exitNotePickMode();
    }

    hover?.disable();
    if (host) host.style.pointerEvents = 'none';
    document.body.style.cursor = 'cell';
    // Keep notes panel interactive
    const notePanel = notesEditor!.getContainerElement();
    if (notePanel) notePanel.style.pointerEvents = 'auto';

    const pickHandler = (e: MouseEvent) => {
      // Let clicks within the notes panel through so buttons remain interactive
      const noteEl = notesEditor!.getContainerElement();
      if (noteEl) {
        const r = noteEl.getBoundingClientRect();
        if (e.clientX >= r.left && e.clientX <= r.right &&
            e.clientY >= r.top && e.clientY <= r.bottom) {
          return;
        }
      }

      e.preventDefault();
      e.stopPropagation();

      const target = getTopElementAt(e.clientX, e.clientY, host!);
      if (target && target !== document.documentElement && target !== document.body) {
        const info = buildElementInfo(target);
        notesStore!.addElementToNote(noteIndex, {
          selector: info.selector,
          tagName: info.tagName,
          textContent: info.textContent,
          sourceFile: info.sourceFile,
          sourceLine: info.sourceLine,
          instanceIndex: info.instanceIndex,
        });
      }
    };

    notePickMode = { noteIndex, handler: pickHandler };
    notesEditor!.setPickActive(noteIndex);
    document.addEventListener('click', pickHandler, true);
  });

  // Wire notes "+ Selected" — add current selection to a note
  notesEditor.onAddSelected((noteIndex) => {
    const primary = selection?.getSelectedElement();
    if (!primary) return;
    const elements = multiSelect?.isActive()
      ? multiSelect.getAllElements(primary)
      : [primary];
    for (const el of elements) {
      const info = buildElementInfo(el);
      notesStore!.addElementToNote(noteIndex, {
        selector: info.selector,
        tagName: info.tagName,
        textContent: info.textContent,
        sourceFile: info.sourceFile,
        sourceLine: info.sourceLine,
        instanceIndex: info.instanceIndex,
      });
    }
  });

  // Wire notes "has selection" check
  notesEditor.setHasSelection(() => {
    return selection?.getSelectedElement() != null;
  });

  notesStore.onChange(() => {
    toolbar?.setNotesCount(notesStore!.count);
  });
  toolbar.setNotesCount(notesStore.count);

  // Wire grid toggle
  toolbar.onGridToggle((enabled) => {
    if (enabled) {
      gridOverlay!.show();
    } else {
      gridOverlay!.hide();
    }
  });
  toolbar.setGridBlockReason(gridOverlay.getBlockReason());

  // Wire rulers toggle
  toolbar.onRulersToggle((enabled) => {
    if (enabled) {
      rulerOverlay!.show();
    } else {
      rulerOverlay!.hide();
    }
  });

  toolbar.onScreenshot(async () => {
    if (!host) return;
    toolbar!.setScreenshotBusy(true);
    try {
      await captureFullPage(host);
    } catch (err) {
      console.error('[frontend-editor] Screenshot failed:', err);
    } finally {
      toolbar!.setScreenshotBusy(false);
    }
  });

  // Wire grid settings panel (long-press on grid button)
  toolbar.onGridSettingsToggle(() => {
    if (gridSettingsPanel!.isOpen()) {
      gridSettingsPanel!.cleanup();
    } else {
      const pos = toolbar!.getButtonPosition('grid');
      const settingsEl = gridSettingsPanel!.render(pos);
      shadow!.appendChild(settingsEl);
    }
  });

  gridSettingsPanel.onChange((settings) => {
    gridOverlay!.applySettings(settings);
    // Auto-show grid when settings change
    if (!gridOverlay!.isVisible()) {
      gridOverlay!.show();
      toolbar!.setGridEnabled(true);
    }
    toolbar!.setGridBlockReason(gridOverlay!.getBlockReason());
  });

  // Re-check grid block reason when tokens update
  tokenStore.onUpdate(() => {
    toolbar?.setGridBlockReason(gridOverlay!.getBlockReason());
    gridOverlay?.refresh();
    const effective = gridOverlay!.getEffectiveSettings();
    gridSettingsPanel?.updateDefaults(effective.baseSpacing, effective.majorSpacing);
  });

  // Wire reorder editor close → fall back to cursor tool
  reorderEditor.onClose(() => {
    const el = selection?.getSelectedElement();
    if (el) { activateToolForElement(el, 'cursor'); }
    else { toolbar!.setActiveMode('cursor'); }
  });

  // Wire insert editor close → fall back to cursor tool
  insertEditor.onClose(() => {
    const el = selection?.getSelectedElement();
    if (el) { activateToolForElement(el, 'cursor'); }
    else { toolbar!.setActiveMode('cursor'); }
  });

  // Wire text editor close → fall back to cursor tool
  textEditor.onClose(() => {
    const el = selection?.getSelectedElement();
    if (el) { activateToolForElement(el, 'cursor'); }
    else { toolbar!.setActiveMode('cursor'); }
  });

  // Wire delete element
  toolbar.onDelete(() => {
    deleteSelectedElement();
  });

  // Push pending count to toolbar badge (only unsent items)
  queue.onChange(() => {
    toolbar?.setPendingCount(queue!.pendingCount);
  });
  // Initialize count from any restored queue items
  toolbar.setPendingCount(queue.pendingCount);

  // Wire undo/redo/reset
  toolbar.onUndo(() => tryUndo());

  toolbar.onRedo(() => {
    const entry = editHistory!.redo();
    if (entry) {
      queue!.restoreItem(entry.diff.id);
      badge!.update();
      reviewPanel!.refresh();
      selection?.refreshHighlight();
      refreshReorderAfterHistoryChange(entry);
      devtoolsPanel?.log('Redo');
    }
  });

  toolbar.onReset(() => {
    editHistory!.resetAll();
    queue!.clearPending();
    badge!.update();
    reviewPanel!.refresh();
    selection?.deselect();
    devtoolsPanel?.log('Pending changes reset');
  });

  // Update toolbar undo/redo button states when history changes
  editHistory.onChange(() => {
    toolbar?.setUndoRedoState(editHistory!.canUndo, editHistory!.canRedo);
  });

  // Wire drag updates → refresh selection highlight + reposition handles
  handles.onDragUpdate(() => {
    selection!.refreshHighlight();
    handles!.refreshHandles();
  });

  // Wire disabled mode feedback (e.g. dimension resize blocked by layout)
  handles.onDisabled((reason) => {
    devtoolsPanel?.log(`Edit mode blocked: ${reason}`, 'warn');
    toolbar!.setActiveMode('cursor');
  });

  // Wire editing → diff creation → queue + history
  handles.onEditCommit((elementInfo, changes) => {
    const el = selection!.getSelectedElement();
    const diff = diffBuilder!.build(elementInfo, changes);
    commitEdit(el, changes, diff);
  });

  // Enter selection mode
  mode = 'selecting';
  hover.enable();
  document.body.style.cursor = 'crosshair';

  // Save focus for restoration on deactivate
  savedFocus = document.activeElement as HTMLElement | null;

  // Register global keyboard handler + scroll tracking
  document.addEventListener('keydown', handleGlobalKeydown, true);
  document.addEventListener('scroll', handleScroll, true);

  badge.update();
  devtoolsPanel.log('Extension activated');
  devtoolsPanel.log(`WebSocket connecting to localhost…`);
}

export function deactivate(): void {
  if (mode === 'inactive') return;

  // Remove global listeners
  document.removeEventListener('keydown', handleGlobalKeydown, true);
  document.removeEventListener('scroll', handleScroll, true);
  document.body.style.cursor = '';

  // Tear down subsystems
  exitNotePickMode();
  hover?.disable();
  selection?.deactivate();
  devtoolsPanel?.hide();
  toolbar?.destroy();
  handles?.hideHandles();
  typographyEditor?.cleanup();
  colorEditor?.cleanup();
  dimensionsEditor?.cleanup();
  spacingEditor?.cleanup();
  positionEditor?.cleanup();
  reorderEditor?.cleanup();
  insertEditor?.cleanup();
  textEditor?.cleanup();
  mediaEditor?.cleanup();
  effectsEditor?.cleanup();
  appearanceEditor?.cleanup();
  notesEditor?.cleanup();
  gridOverlay?.hide();
  rulerOverlay?.hide();
  gridSettingsPanel?.cleanup();
  multiSelect?.clear();
  multiSelectToolbar?.cleanup();
  cleanupMeasurement();
  staleDetector?.cleanup();
  keyboard?.destroy();
  preview?.revert();
  reviewPanel?.hide();
  wsClient?.destroy();

  // Unmount Shadow DOM
  if (host) {
    unmountShadowHost(host);
    host = null;
    shadow = null;
  }

  // Restore focus
  savedFocus?.focus();
  savedFocus = null;

  // Reset state
  devtoolsUserClosed = false;
  devtoolsOpenBeforeCollapse = false;
  gridVisibleBeforeCollapse = false;
  rulersVisibleBeforeCollapse = false;
  mode = 'inactive';
  wsClient = null;
  hover = null;
  selection = null;
  devtoolsPanel = null;
  toolbar = null;
  staleDetector = null;
  tokenStore = null;
  snapping = null;
  preview = null;
  handles = null;
  keyboard = null;
  diffBuilder = null;
  queue = null;
  badge = null;
  reviewPanel = null;
  typographyEditor = null;
  colorEditor = null;
  dimensionsEditor = null;
  spacingEditor = null;
  positionEditor = null;
  editHistory = null;
  notesStore = null;
  notesEditor = null;
  gridOverlay = null;
  rulerOverlay = null;
  reorderEditor = null;
  insertEditor = null;
  textEditor = null;
  mediaEditor = null;
  effectsEditor = null;
  appearanceEditor = null;
  gridSettingsPanel = null;
  measureOverlay = null;
  measureRafId = null;
  multiSelect = null;
  multiSelectToolbar = null;
  multiSelectClickHandler = null;
  notePickMode = null;

  // Panel is already destroyed at this point, so use console directly
  console.log('[frontend-editor] Extension deactivated');
}

function toggleActive(): void {
  if (mode === 'inactive') {
    activate();
  } else {
    deactivate();
  }
}

// ---------------------------------------------------------------------------
// Activate tool for element — shared by onSelect and onToolSelect
// ---------------------------------------------------------------------------

function activateToolForElement(el: Element, mode: EditMode): void {
  // Clean up previous edit mode
  handles!.hideHandles();
  typographyEditor!.cleanup();
  colorEditor!.cleanup();
  dimensionsEditor!.cleanup();
  spacingEditor!.cleanup();
  positionEditor!.cleanup();
  reorderEditor!.cleanup();
  reparentEditor!.cleanup();
  insertEditor!.cleanup();
  textEditor!.cleanup();
  mediaEditor!.cleanup();
  effectsEditor!.cleanup();
  appearanceEditor!.cleanup();

  if (mode === 'cursor') {
    // Cursor/select mode: show dimension handles only (no mini panel)
    const dimBlock = getDimensionBlockReason(el);
    if (!dimBlock) {
      handles!.showHandles(el, 'dimensions');
    }
    toolbar!.setActiveMode('cursor');
  } else if (mode === 'typography') {
    const pos = toolbar!.getButtonPosition('typography');
    const controls = typographyEditor!.render(el, pos, (changes) => {
      const info = buildElementInfo(el);
      const diff = diffBuilder!.build(info, changes);
      commitEdit(el, changes, diff);
    });
    shadow!.appendChild(controls);
    toolbar!.setActiveMode('typography');
  } else if (mode === 'colors') {
    const pos = toolbar!.getButtonPosition('colors');
    const controls = colorEditor!.render(el, 'color', pos, (changes) => {
      const info = buildElementInfo(el);
      const diff = diffBuilder!.build(info, changes);
      commitEdit(el, changes, diff);
    });
    shadow!.appendChild(controls);
    toolbar!.setActiveMode('colors');
  } else if (mode === 'dimensions') {
    handles!.showHandles(el, mode);
    const pos = toolbar!.getButtonPosition('dimensions');
    const controls = dimensionsEditor!.render(el, pos, (changes) => {
      const info = buildElementInfo(el);
      const diff = diffBuilder!.build(info, changes);
      commitEdit(el, changes, diff);
      selection!.refreshHighlight();
      handles!.refreshHandles();
    });
    shadow!.appendChild(controls);
    toolbar!.setActiveMode('dimensions');
  } else if (mode === 'spacing') {
    handles!.showHandles(el, mode);
    const pos = toolbar!.getButtonPosition('spacing');
    const controls = spacingEditor!.render(el, pos, (changes) => {
      const info = buildElementInfo(el);
      const diff = diffBuilder!.build(info, changes);
      commitEdit(el, changes, diff);
      selection!.refreshHighlight();
      handles!.refreshHandles();
    });
    shadow!.appendChild(controls);
    toolbar!.setActiveMode('spacing');
  } else if (mode === 'position') {
    const pos = toolbar!.getButtonPosition('position');
    const controls = positionEditor!.render(el, pos, (changes) => {
      const info = buildElementInfo(el);
      const diff = diffBuilder!.build(info, changes);
      commitEdit(el, changes, diff);
      selection!.refreshHighlight();
    });
    shadow!.appendChild(controls);
    toolbar!.setActiveMode('position');
  } else if (mode === 'reorder') {
    reorderEditor!.render(el, makeReorderCommit(el));
    toolbar!.setActiveMode('reorder');
  } else if (mode === 'reparent') {
    reparentEditor!.render(el, makeReparentCommit(el));
    toolbar!.setActiveMode('reparent');
  } else if (mode === 'insert') {
    insertEditor!.enter(el as HTMLElement, makeInsertCommit(el));
    toolbar!.setActiveMode('insert');
  } else if (mode === 'text') {
    textEditor!.editElement(el as HTMLElement, (change: TextChange) => {
      const info = buildElementInfo(el);
      const diff = diffBuilder!.buildText(info, change);
      commitTextEdit(el as HTMLElement, change, diff);
    });
    toolbar!.setActiveMode('text');
  } else if (mode === 'media') {
    const pos = toolbar!.getButtonPosition('media');
    const controls = mediaEditor!.render(el, pos, (changes) => {
      const info = buildElementInfo(el);
      const diff = diffBuilder!.build(info, changes);
      commitEdit(el, changes, diff);
    }, (attrChanges) => {
      const info = buildElementInfo(el);
      const diff = diffBuilder!.buildAttribute(info, attrChanges);
      commitAttributeEdit(el, attrChanges, diff);
    });
    shadow!.appendChild(controls);
    toolbar!.setActiveMode('media');
  } else if (mode === 'effects') {
    const pos = toolbar!.getButtonPosition('effects');
    const controls = effectsEditor!.render(el, pos, (changes) => {
      const info = buildElementInfo(el);
      const diff = diffBuilder!.build(info, changes);
      commitEdit(el, changes, diff);
    }, (changes, relatedChanges) => {
      const info = buildElementInfo(el);
      const diff = diffBuilder!.buildWithRelatedChanges(info, changes, relatedChanges);
      commitEdit(el, changes, diff);
    });
    shadow!.appendChild(controls);
    toolbar!.setActiveMode('effects');
  } else if (mode === 'appearance') {
    const pos = toolbar!.getButtonPosition('appearance');
    const controls = appearanceEditor!.render(el, pos, (changes) => {
      const info = buildElementInfo(el);
      const diff = diffBuilder!.build(info, changes);
      commitEdit(el, changes, diff);
    });
    shadow!.appendChild(controls);
    toolbar!.setActiveMode('appearance');
  } else {
    handles!.showHandles(el, mode);
    toolbar!.setActiveMode(mode);
  }
}

// ---------------------------------------------------------------------------
// Edit commit helper — pushes to queue + history
// ---------------------------------------------------------------------------

function commitEdit(
  element: Element | null,
  changes: readonly PropertyChange[],
  diff: VisualDiff,
  removal?: { parent: Node; nextSibling: Node | null },
): void {
  queue!.add(diff);
  if (element) {
    const changeList = changes.map((c) => ({
      property: c.property,
      fromValue: c.fromValue,
      toValue: c.toValue,
    }));
    if (removal) {
      editHistory!.push({
        type: 'removal',
        element: element as HTMLElement,
        changes: changeList,
        diff,
        parent: removal.parent,
        nextSibling: removal.nextSibling,
      });
    } else {
      editHistory!.push({
        type: 'css',
        element: element as HTMLElement,
        changes: changeList,
        diff,
      });
    }
  }
  badge!.update();
  reviewPanel!.refresh();
  devtoolsPanel?.refreshProperties();
}

function commitAttributeEdit(
  element: Element,
  attrChanges: readonly AttributeChange[],
  diff: VisualDiff,
): void {
  queue!.add(diff);
  editHistory!.push({
    type: 'attribute',
    element: element as HTMLElement,
    attributeChanges: attrChanges,
    diff,
  });
  badge!.update();
  reviewPanel!.refresh();
  devtoolsPanel?.refreshProperties();
}

function commitTextEdit(
  element: HTMLElement,
  change: TextChange,
  diff: VisualDiff,
): void {
  queue!.add(diff);
  editHistory!.push({
    type: 'text',
    element,
    fromText: change.fromText,
    toText: change.toText,
    diff,
  });
  badge!.update();
  reviewPanel!.refresh();
  devtoolsPanel?.refreshProperties();
}

// ---------------------------------------------------------------------------
// Reorder commit helper — builds diff + history entry, re-renders reorder mode
// ---------------------------------------------------------------------------

function makeReorderCommit(el: Element): ReorderCommitCallback {
  return (element, container, fromIndex, toIndex, originalChildOrder) => {
    const info = buildElementInfo(element);

    const reorderChange: ReorderChange = {
      type: 'reorder',
      fromIndex,
      toIndex,
      siblingSelectors: originalChildOrder.map((c) => generateSelector(c)),
      containerSelector: generateSelector(container),
      containerDirection: getComputedStyle(container).display.includes('grid')
        ? (getComputedStyle(container).gridAutoFlow?.includes('column') ? 'column' : 'row')
        : (getComputedStyle(container).flexDirection || 'row'),
    };

    const diff = diffBuilder!.buildReorder(info, reorderChange);

    queue!.add(diff);
    editHistory!.push({
      type: 'reorder',
      element,
      container,
      fromIndex,
      toIndex,
      originalChildOrder,
      diff,
    });
    badge!.update();
    reviewPanel!.refresh();
    devtoolsPanel?.refreshProperties();
    selection?.refreshHighlight();

    // Re-render reorder mode on the element at its new position
    reorderEditor!.render(el, makeReorderCommit(el));
  };
}

// ---------------------------------------------------------------------------
// Reparent commit helper — builds diff + history entry, re-renders reparent mode
// ---------------------------------------------------------------------------

function makeReparentCommit(el: Element): ReparentCommitCallback {
  return (element, sourceContainer, sourceIndex, targetContainer, targetIndex) => {
    const info = buildElementInfo(element);

    // Build sibling selectors from target container's children (pre-move — element not yet in target)
    const targetChildren = Array.from(targetContainer.children)
      .filter((c): c is HTMLElement => c instanceof HTMLElement && c !== element);
    const siblingSelectors = targetChildren.map((c) => generateSelector(c));

    // Build sibling anchors at the insert position (pre-move state)
    const prevEl = targetIndex > 0 ? targetChildren[targetIndex - 1] : null;
    const nextEl = targetIndex < targetChildren.length ? targetChildren[targetIndex] : null;

    const buildAnchor = (anchorEl: Element | null) => {
      if (!anchorEl || anchorEl === element) return null;
      const anchorInfo = buildElementInfo(anchorEl);
      return {
        selector: anchorInfo.selector,
        sourceFile: anchorInfo.sourceFile,
        sourceLine: anchorInfo.sourceLine,
        instanceIndex: anchorInfo.instanceIndex,
      };
    };

    const reparentChange: ReparentChange = {
      type: 'reparent',
      sourceContainerSelector: generateSelector(sourceContainer),
      sourceIndex,
      targetContainerSelector: generateSelector(targetContainer),
      targetIndex,
      siblingSelectors,
      prevSibling: buildAnchor(prevEl),
      nextSibling: buildAnchor(nextEl),
    };

    const diff = diffBuilder!.buildReparent(info, reparentChange);

    queue!.add(diff);
    editHistory!.push({
      type: 'reparent',
      element,
      sourceContainer,
      sourceIndex,
      targetContainer,
      targetIndex,
      diff,
    });
    badge!.update();
    reviewPanel!.refresh();
    devtoolsPanel?.refreshProperties();
    selection?.refreshHighlight();

    // Re-render reparent mode on the element at its new position
    reparentEditor!.render(el, makeReparentCommit(el));
  };
}

// ---------------------------------------------------------------------------
// Insert commit helper — builds diff + history entry
// ---------------------------------------------------------------------------

function makeInsertCommit(_containerEl: Element): InsertCommitCallback {
  // Callback fires BEFORE DOM insertion — container children are pre-insert state.
  // The element is built but not yet in the DOM, so buildInsertChange reads
  // correct sibling anchors and child snapshot.
  return (element, container, insertIndex, config) => {
    const containerInfo = buildElementInfo(container);

    const tagName = config?.tagName ?? 'div';
    const initialStyles = config?.initialStyles ?? [];

    const insertChange = buildInsertChange(
      container, insertIndex, tagName, initialStyles, config?.compoundChildren,
    );

    const diff = diffBuilder!.buildInsert(containerInfo, insertChange);

    queue!.add(diff);
    editHistory!.push({
      type: 'insertion',
      element,
      container,
      insertIndex,
      diff,
    });
    badge!.update();
    reviewPanel!.refresh();
    devtoolsPanel?.refreshProperties();
    selection?.refreshHighlight();

    // Auto-select is deferred — element will be in DOM after callback returns
    // (commitInsert inserts after callback). Schedule via microtask.
    queueMicrotask(() => selection?.select(element));
  };
}

// ---------------------------------------------------------------------------
// Group commit helper — wraps selected elements in a flex container
// ---------------------------------------------------------------------------

function makeGroupCommit(elements: Element[]): void {
  const htmlElements = elements as HTMLElement[];

  // Capture all element data BEFORE DOM mutation
  const parent = htmlElements[0].parentElement!;
  const containerSelector = generateSelector(parent);

  // Sort by DOM order to determine insert index
  const childList = Array.from(parent.children);
  const sorted = [...htmlElements].sort(
    (a, b) => childList.indexOf(a) - childList.indexOf(b),
  );
  const insertIndex = childList.indexOf(sorted[0]);

  // Capture sibling anchors (prev/next around the group range)
  const firstIdx = childList.indexOf(sorted[0]);
  const lastIdx = childList.indexOf(sorted[sorted.length - 1]);
  const prevEl = firstIdx > 0 ? childList[firstIdx - 1] : null;
  const nextEl = lastIdx < childList.length - 1 ? childList[lastIdx + 1] : null;

  const buildAnchor = (el: Element | null) => {
    if (!el) return null;
    const info = buildElementInfo(el);
    return {
      selector: info.selector,
      sourceFile: info.sourceFile,
      sourceLine: info.sourceLine,
      instanceIndex: info.instanceIndex,
    };
  };

  const wrappedSelectors = sorted.map((el) => generateSelector(el));

  // Perform DOM mutation
  const result = groupElements(htmlElements, shadow!);

  // Build diff using the wrapper as the element
  const wrapperInfo = buildElementInfo(result.wrapper);

  const groupChange: GroupChange = {
    type: 'group',
    wrapperTagName: 'div',
    wrapperInitialStyles: [
      { property: 'display', fromValue: '', toValue: 'flex' },
      { property: 'flex-direction', fromValue: '', toValue: result.wrapper.style.flexDirection },
      { property: 'gap', fromValue: '', toValue: '0px' },
    ],
    containerSelector,
    insertIndex,
    wrappedSelectors,
    prevSibling: buildAnchor(prevEl),
    nextSibling: buildAnchor(nextEl),
  };

  const diff = diffBuilder!.buildGroup(wrapperInfo, groupChange);

  queue!.add(diff);
  editHistory!.push({
    type: 'group',
    wrapper: result.wrapper,
    originalParent: parent as HTMLElement,
    originalPositions: result.originalPositions,
    diff,
  });
  badge!.update();
  reviewPanel!.refresh();
  devtoolsPanel?.refreshProperties();

  // Exit multi-select before selecting wrapper to avoid deselect→reselect cycle
  exitMultiSelectMode();
  selection!.select(result.wrapper);
}

// ---------------------------------------------------------------------------
// Reorder editor refresh after undo/redo — keeps drop zones in sync with DOM
// ---------------------------------------------------------------------------

function refreshReorderAfterHistoryChange(entry: HistoryEntry): void {
  if (entry.type === 'reorder') {
    if (!reorderEditor?.isActive()) return;
    const el = selection?.getSelectedElement();
    if (el) {
      reorderEditor.render(el, makeReorderCommit(el));
    }
  } else if (entry.type === 'reparent') {
    if (!reparentEditor?.isActive()) return;
    const el = selection?.getSelectedElement();
    if (el) {
      reparentEditor.render(el, makeReparentCommit(el));
    }
  }
}

// ---------------------------------------------------------------------------
// Undo helper — blocks undo for diffs already sent to the server
// ---------------------------------------------------------------------------

function tryUndo(): void {
  const top = editHistory?.peekUndo();
  if (top && queue) {
    const status = queue.getLifecycleStatus(top.diff.id);
    if (status !== 'pending') {
      devtoolsPanel?.log('Cannot undo — change already sent to server', 'warn');
      return;
    }
  }
  const entry = editHistory?.undo();
  if (entry) {
    queue?.remove(entry.diff.id);
    badge?.update();
    reviewPanel?.refresh();
    selection?.refreshHighlight();
    refreshReorderAfterHistoryChange(entry);
    devtoolsPanel?.log('Undo');
  }
}

// ---------------------------------------------------------------------------
// Delete element helper — removes from DOM, tracked as a diff
// ---------------------------------------------------------------------------

function deleteSelectedElement(): void {
  const el = selection?.getSelectedElement();
  if (!el) return;

  // Capture insertion context before removal
  const parent = el.parentNode;
  const nextSibling = el.nextSibling;
  if (!(parent instanceof Element)) return;

  const removedIndex = Array.from(parent.children).indexOf(el);
  const info = buildElementInfo(el);
  const removeChange: RemoveChange = {
    type: 'remove',
    tagName: el.tagName.toLowerCase(),
    containerSelector: buildElementInfo(parent).selector,
    removedIndex,
  };
  const diff = diffBuilder!.buildRemove(info, removeChange);

  // Remove element from DOM
  el.remove();

  commitEdit(el, [], diff, { parent, nextSibling });
  selection?.deselect();
}

// ---------------------------------------------------------------------------
// Paste element helper — clones clipboard HTML and inserts after selection
// ---------------------------------------------------------------------------

function pasteElement(): void {
  if (!elementClipboard) return;

  const selectedEl = selection?.getSelectedElement();
  const container = selectedEl?.parentElement ?? document.body;
  const insertIndex = selectedEl
    ? Array.from(container.children).indexOf(selectedEl) + 1
    : container.children.length;

  // Parse clipboard HTML into a live element
  const template = document.createElement('template');
  template.innerHTML = elementClipboard.html;
  const clone = template.content.firstElementChild as HTMLElement;
  if (!clone) return;

  // Build diff before DOM insertion (sibling bracket reads pre-insert state)
  const containerInfo = buildElementInfo(container);
  const insertChange = buildInsertChange(
    container, insertIndex, clone.tagName.toLowerCase(), [],
  );
  const diff = diffBuilder!.buildInsert(containerInfo, insertChange);

  // Insert into DOM
  const refNode = container.children[insertIndex] ?? null;
  container.insertBefore(clone, refNode);

  // Track in history + queue
  queue!.add(diff);
  editHistory!.push({
    type: 'insertion',
    element: clone,
    container,
    insertIndex,
    diff,
  });
  badge!.update();
  reviewPanel!.refresh();
  devtoolsPanel?.log(`Pasted <${clone.tagName.toLowerCase()}>`);

  // Select the pasted element
  queueMicrotask(() => selection?.select(clone));
}

// ---------------------------------------------------------------------------
// Status & focus
// ---------------------------------------------------------------------------

let savedFocus: HTMLElement | null = null;

function handleStatusChange(status: ConnectionStatus): void {
  reviewPanel?.updateConnectionStatus(status);
  if (status === 'connected') {
    devtoolsPanel?.log('WebSocket connected');
  } else if (status === 'disconnected') {
    devtoolsPanel?.log('WebSocket disconnected', 'warn');
  } else if (status === 'connecting') {
    devtoolsPanel?.log('WebSocket reconnecting…');
  }
}

// ---------------------------------------------------------------------------
// Scroll tracking — refresh all overlay positions
// ---------------------------------------------------------------------------

let scrollRafId: number | null = null;

function handleScroll(): void {
  if (scrollRafId != null) return; // rAF gate
  scrollRafId = requestAnimationFrame(() => {
    scrollRafId = null;
    selection?.refreshHighlight();
    hover?.refreshHighlight();
    handles?.refreshHandles();
    positionEditor?.refreshMoveOverlay();
    reorderEditor?.refreshOverlay();
    reparentEditor?.refreshOverlay();
    insertEditor?.refreshOverlay();
    gridOverlay?.refreshScroll();
    rulerOverlay?.refreshGuides();
    if (measureOverlay?.isActive()) measureOverlay.clear();
    if (notesEditor?.isOpen()) {
      notesEditor.refreshHighlights();
      if (notesEditor.getPositionMode() === 'element') {
        notesEditor.repositionToElement();
      }
    }
    if (multiSelect?.isActive()) {
      multiSelect.refreshHighlights();
      const primary = selection?.getSelectedElement();
      if (primary) {
        measureOverlay?.clear();
        measureOverlay?.renderPersistentLines(multiSelect.getAllElements(primary));
      }
    }
  });
}

// ---------------------------------------------------------------------------
// Measurement mousemove (active while Option is held)
// ---------------------------------------------------------------------------

function handleMeasureMouseMove(e: MouseEvent): void {
  if (measureRafId != null) return;
  measureRafId = requestAnimationFrame(() => {
    measureRafId = null;
    const selectedEl = selection?.getSelectedElement();
    if (!selectedEl || !measureOverlay?.isActive()) return;
    measureOverlay.update(selectedEl, e.clientX, e.clientY);
  });
}

function cleanupMeasurement(): void {
  if (measureOverlay?.isActive()) {
    measureOverlay.disable();
    measureOverlay.clear();
  }
  document.removeEventListener('mousemove', handleMeasureMouseMove, true);
  if (measureRafId != null) {
    cancelAnimationFrame(measureRafId);
    measureRafId = null;
  }
}

// ---------------------------------------------------------------------------
// Note pick mode helpers
// ---------------------------------------------------------------------------

function exitNotePickMode(): void {
  if (!notePickMode) return;
  document.removeEventListener('click', notePickMode.handler, true);
  notePickMode = null;
  hover?.enable();
  if (host) host.style.pointerEvents = '';
  document.body.style.cursor = mode !== 'inactive' ? 'crosshair' : '';
  notesEditor?.setPickActive(null);
}

// ---------------------------------------------------------------------------
// Multi-select helpers
// ---------------------------------------------------------------------------

function handleMultiSelectClick(e: MouseEvent): void {
  if (!e.altKey) return;

  const target = getTopElementAt(e.clientX, e.clientY, host!);
  if (!target || target === document.documentElement || target === document.body) return;

  e.preventDefault();
  e.stopPropagation();

  const primary = selection?.getSelectedElement();

  if (!primary) {
    // No primary yet — single-select this element
    selection?.select(target);
    return;
  }

  if (target === primary) return;

  // Add to multi-select
  const added = multiSelect!.add(target, primary);
  if (!added) return;

  // Enter multi-select mode (or update if already active)
  enterMultiSelectMode();
}

function enterMultiSelectMode(): void {
  const primary = selection?.getSelectedElement();
  if (!primary || !multiSelect?.isActive()) return;

  const allElements = multiSelect.getAllElements(primary);

  // Stop hover measurement (persistent lines replace it)
  if (measureOverlay?.isActive()) {
    measureOverlay.disable();
  }
  measureOverlay?.clear();
  document.removeEventListener('mousemove', handleMeasureMouseMove, true);

  // Render persistent measurement lines
  measureOverlay?.renderPersistentLines(allElements);

  // Hide single-select editing tools
  handles?.hideHandles();
  typographyEditor?.cleanup();
  colorEditor?.cleanup();
  dimensionsEditor?.cleanup();
  spacingEditor?.cleanup();
  positionEditor?.cleanup();
  reorderEditor?.cleanup();
  toolbar?.setActiveMode('cursor');

  // Show multi-select toolbar (or update it)
  if (multiSelectToolbar?.isOpen()) {
    multiSelectToolbar.updateElements(allElements);
  } else {
    const pos = toolbar!.getPosition();
    const msToolbar = multiSelectToolbar!.render(allElements, pos, (element, changes) => {
      const info = buildElementInfo(element);
      const diff = diffBuilder!.build(info, changes);
      commitEdit(element, changes, diff);
      // Refresh highlights after alignment/spacing changes
      selection?.refreshHighlight();
      multiSelect?.refreshHighlights();
      measureOverlay?.clear();
      measureOverlay?.renderPersistentLines(multiSelect!.getAllElements(primary));
    });
    shadow!.appendChild(msToolbar);
  }

  // Switch DevTools properties to multi-select mode
  if (devtoolsPanel?.isOpen()) {
    devtoolsPanel.updateMultiProperties(allElements);
  }
}

function exitMultiSelectMode(): void {
  multiSelect?.clear();
  multiSelectToolbar?.cleanup();
  measureOverlay?.clear();
}

// ---------------------------------------------------------------------------
// Global keyboard handling
// ---------------------------------------------------------------------------

function handleGlobalKeydown(e: KeyboardEvent): void {
  // While the inline text editor is active, every keystroke belongs to the
  // operator's typing — bail before any shortcut runs. This is stricter than
  // the DOM-inspection guard below because it does not depend on the event's
  // target resolving to the contenteditable element (e.g. after the shortcut
  // steals focus or the selection moves).
  if (textEditor?.isActive()) return;

  // Skip all shortcuts when user is typing in a text field/input/contenteditable.
  // Use composedPath() to pierce Shadow DOM boundaries — e.target is retargeted
  // to the shadow host at document level, hiding the actual input element.
  const composedTarget = e.composedPath()[0] as HTMLElement | undefined;
  if (composedTarget?.tagName) {
    const tag = composedTarget.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || composedTarget.isContentEditable) {
      return;
    }
  }

  // Alt/Option key — measurement mode (with selection) or pause (without)
  if (e.key === 'Alt') {
    if (mode === 'selecting' && !multiSelect?.isActive()) {
      const selectedEl = selection?.getSelectedElement();
      mode = 'paused';
      hover?.disable();
      if (host) host.style.pointerEvents = 'none';
      if (selectedEl && measureOverlay) {
        measureOverlay.enable();
        document.addEventListener('mousemove', handleMeasureMouseMove, true);
      }
      // Add click listener for multi-select
      multiSelectClickHandler = handleMultiSelectClick;
      document.addEventListener('click', multiSelectClickHandler, true);
    }
    return;
  }

  // Ctrl+Z / Cmd+Z — undo; Ctrl+Shift+Z / Cmd+Shift+Z — redo
  if (e.key === 'z' && (e.ctrlKey || e.metaKey)) {
    e.preventDefault();
    e.stopPropagation();
    if (e.shiftKey) {
      const entry = editHistory?.redo();
      if (entry) {
        queue?.restoreItem(entry.diff.id);
        badge?.update();
        reviewPanel?.refresh();
        selection?.refreshHighlight();
        refreshReorderAfterHistoryChange(entry);
        devtoolsPanel?.log('Redo');
      }
    } else {
      tryUndo();
    }
    return;
  }

  // Cmd+G / Ctrl+G — group/wrap selected elements
  if (e.key === 'g' && (e.metaKey || e.ctrlKey)) {
    e.preventDefault();
    e.stopPropagation();
    const primary = selection?.getSelectedElement();
    if (primary) {
      const allElements = multiSelect?.isActive()
        ? multiSelect.getAllElements(primary)
        : [primary];
      if (!getGroupBlockReason(allElements)) {
        makeGroupCommit(allElements);
      }
    }
    return;
  }

  // Cmd+R — toggle Ruler overlay
  if (e.key === 'r' && (e.metaKey || e.ctrlKey) && !e.shiftKey) {
    e.preventDefault();
    e.stopPropagation();
    const enabled = !rulerOverlay!.isVisible();
    if (enabled) {
      rulerOverlay!.show();
    } else {
      rulerOverlay!.hide();
    }
    toolbar!.setRulersEnabled(enabled);
    return;
  }

  // Cmd+S — submit (apply) pending changes
  if (e.key === 's' && (e.metaKey || e.ctrlKey) && !e.shiftKey) {
    e.preventDefault();
    e.stopPropagation();
    if (!reviewPanel!.isOpen()) {
      reviewPanel!.show(toolbar!.getButtonPosition('review'));
      toolbar!.setReviewPanelOpen(true);
    }
    reviewPanel!.triggerSend();
    return;
  }

  // Cmd+C — copy selected element
  if (e.key === 'c' && (e.metaKey || e.ctrlKey) && !e.shiftKey) {
    const el = selection?.getSelectedElement();
    if (el) {
      e.preventDefault();
      e.stopPropagation();
      elementClipboard = { html: el.outerHTML, tagName: el.tagName.toLowerCase() };
      devtoolsPanel?.log(`Copied <${elementClipboard.tagName}>`);
    }
    return;
  }

  // Cmd+P — paste copied element after selection
  if (e.key === 'p' && (e.metaKey || e.ctrlKey) && !e.shiftKey) {
    e.preventDefault();
    e.stopPropagation();
    if (elementClipboard) {
      pasteElement();
    }
    return;
  }

  // v — collapse/expand toolbar (no modifiers)
  if (e.key === 'v' && !e.metaKey && !e.ctrlKey && !e.shiftKey && !e.altKey) {
    e.preventDefault();
    e.stopPropagation();
    toolbar!.toggle();
    return;
  }

  // Delete / Backspace — delete selected element
  if ((e.key === 'Delete' || e.key === 'Backspace') && !e.metaKey && !e.ctrlKey) {
    const el = selection?.getSelectedElement();
    if (el) {
      e.preventDefault();
      e.stopPropagation();
      deleteSelectedElement();
    }
    return;
  }

  // Number keys 1–0 — quick tool switching (no modifiers)
  if (!e.metaKey && !e.ctrlKey && !e.shiftKey && !e.altKey) {
    const TOOL_KEYS: Record<string, EditMode> = {
      '1': 'cursor',
      '2': 'spacing',
      '3': 'dimensions',
      '4': 'typography',
      '5': 'colors',
      '6': 'border-radius',
      '7': 'position',
      '8': 'reorder',
      '9': 'insert',
      '0': 'media',
    };
    const toolMode = TOOL_KEYS[e.key];
    if (toolMode) {
      e.preventDefault();
      e.stopPropagation();
      if (!multiSelect?.isActive()) {
        const el = selection?.getSelectedElement();
        if (el) {
          activateToolForElement(el, toolMode);
        } else {
          toolbar!.setActiveMode(toolMode);
        }
      }
      return;
    }

    // g — toggle grid overlay (no modifiers)
    if (e.key === 'g') {
      e.preventDefault();
      e.stopPropagation();
      const enabled = !gridOverlay!.isVisible();
      if (enabled) {
        gridOverlay!.show();
      } else {
        gridOverlay!.hide();
      }
      toolbar!.setGridEnabled(enabled);
      return;
    }

    // d — toggle DevTools panel (no modifiers)
    if (e.key === 'd') {
      e.preventDefault();
      e.stopPropagation();
      if (devtoolsPanel!.isOpen()) {
        devtoolsPanel!.hide();
        toolbar!.setInspectorOpen('devtools', false);
        devtoolsUserClosed = true;
      } else {
        const el = selection?.getSelectedElement() ?? undefined;
        const info = el ? buildElementInfo(el) : undefined;
        devtoolsPanel!.show(el, info);
        toolbar!.setInspectorOpen('devtools', true);
        devtoolsUserClosed = false;
      }
      return;
    }

    // n — toggle Notes panel (no modifiers)
    if (e.key === 'n') {
      e.preventDefault();
      e.stopPropagation();
      if (notesEditor!.isOpen()) {
        notesEditor!.cleanup();
        toolbar!.setNotesOpen(false);
      } else {
        const selectedEl = selection?.getSelectedElement();
        const isMulti = multiSelect?.isActive();
        if (selectedEl && !isMulti) {
          const info = buildElementInfo(selectedEl);
          notesEditor!.setAnchoredElement(selectedEl, {
            selector: info.selector,
            tagName: info.tagName,
            textContent: info.textContent,
            sourceFile: info.sourceFile,
            sourceLine: info.sourceLine,
            instanceIndex: info.instanceIndex,
          });
        } else {
          notesEditor!.clearAnchoredElement();
        }
        const pos = toolbar!.getButtonPosition('notes');
        const notePanel = notesEditor!.render(pos);
        shadow!.appendChild(notePanel);
        toolbar!.setNotesOpen(true);
      }
      return;
    }

    // t — activate Typography tool (no modifiers)
    if (e.key === 't') {
      e.preventDefault();
      e.stopPropagation();
      const el = selection?.getSelectedElement();
      if (el) {
        activateToolForElement(el, 'typography');
      } else {
        toolbar!.setActiveMode('typography');
      }
      return;
    }
  }

  // Escape ladder: cancel edit → close review → dismiss panel → deactivate
  if (e.key === 'Escape') {
    e.preventDefault();
    e.stopPropagation();

    if (multiSelect?.isActive()) {
      // Level 0: exit multi-select mode, restore single-select tools
      exitMultiSelectMode();
      const primary = selection?.getSelectedElement();
      if (primary) {
        // Restore single-element properties in DevTools
        if (devtoolsPanel?.isOpen()) {
          devtoolsPanel.updateProperties(primary);
        }
        activateToolForElement(primary, 'cursor');
      }
    } else if (notePickMode) {
      // Level 0a: exit note pick mode (notes panel stays open)
      exitNotePickMode();
      return;
    } else if (measureOverlay?.isActive()) {
      // Level 0b: exit measurement mode
      cleanupMeasurement();
      mode = 'selecting';
      hover?.enable();
    } else if (gridSettingsPanel?.isOpen()) {
      // Level 0b: close grid settings panel
      gridSettingsPanel.cleanup();
    } else if (insertEditor?.isActive() && insertEditor.getState() === 'configuring') {
      // Level 0c: cancel insert configuring → return to scanning
      insertEditor.cancel();
    } else if (insertEditor?.isActive()) {
      // Level 0d: exit insert scanning → cursor
      insertEditor.cleanup();
      const el = selection?.getSelectedElement();
      if (el) { activateToolForElement(el, 'cursor'); }
      else { toolbar?.setActiveMode('cursor'); }
    } else if (rulerOverlay?.isDragging()) {
      // Level 1a: cancel guide drag
      rulerOverlay.cancelDrag();
    } else if (reorderEditor?.isDragging()) {
      // Level 1a: cancel reorder drag — revert preview, stay in reorder mode
      reorderEditor.cancelDrag();
    } else if (reparentEditor?.isDragging()) {
      // Level 1a: cancel reparent drag — revert, stay in reparent mode
      reparentEditor.cancelDrag();
    } else if (positionEditor?.isMoveDragging()) {
      // Level 1b: cancel move drag — overlay stays, panel stays, toggle stays active
      positionEditor.cancelMoveDrag();
    } else if (positionEditor?.isMoveActive()) {
      // Level 1c: deactivate Move toggle — overlay removed, insets restored, panel stays
      positionEditor.deactivateMove();
    } else if (handles?.isEditing()) {
      // Level 1b: cancel active edit
      handles.cancelEdit();
      preview?.revert();
    } else if (notesEditor?.isOpen()) {
      // Level 2a: close notes panel
      notesEditor.cleanup();
      toolbar?.setNotesOpen(false);
    } else if (reviewPanel?.isOpen()) {
      // Level 2b: close review panel
      reviewPanel.hide();
      toolbar?.setReviewPanelOpen(false);
    } else if (devtoolsPanel?.isOpen()) {
      // Level 3: dismiss DevTools panel
      devtoolsPanel.hide();
      toolbar?.setInspectorOpen('devtools', false);
      devtoolsUserClosed = true;
    } else {
      // Level 4: deactivate extension
      deactivate();
    }
    return;
  }
}

// Listen for Alt release to unpause
document.addEventListener(
  'keyup',
  (e: KeyboardEvent) => {
    if (e.key === 'Alt' && mode === 'paused') {
      // Remove multi-select click listener
      if (multiSelectClickHandler) {
        document.removeEventListener('click', multiSelectClickHandler, true);
        multiSelectClickHandler = null;
      }

      mode = 'selecting';
      hover?.enable();
      if (host) host.style.pointerEvents = '';

      if (!multiSelect?.isActive()) {
        // No multi-select clicks happened — original behavior
        cleanupMeasurement();
      } else {
        // Multi-select active — keep persistent lines, stop hover measurement
        cleanupMeasurement();
      }
    }
  },
  true,
);

// ---------------------------------------------------------------------------
// Tab ID management
// ---------------------------------------------------------------------------

const TAB_ID_KEY = 'frontend-editor-tab-id';

async function getOrCreateTabId(): Promise<string> {
  try {
    const result = await chrome.storage.session.get(TAB_ID_KEY);
    if (result[TAB_ID_KEY]) return result[TAB_ID_KEY] as string;
  } catch {
    // storage.session not available (e.g., testing outside extension context)
  }

  const id = crypto.randomUUID();
  try {
    await chrome.storage.session.set({ [TAB_ID_KEY]: id });
  } catch {
    // Non-fatal
  }
  return id;
}

// ---------------------------------------------------------------------------
// Chrome runtime messaging
// ---------------------------------------------------------------------------

chrome.runtime.onMessage.addListener(
  (msg: { type: string }, _sender, sendResponse) => {
    if (msg.type === 'TOGGLE_EXTENSION') {
      toggleActive();
      sendResponse({ active: mode !== 'inactive' });
    }
    return true; // keep sendResponse channel open for async
  },
);

console.log('[frontend-editor] Content script loaded');
