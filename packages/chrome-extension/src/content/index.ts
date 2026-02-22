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
import { MoveEditor, getMoveBlockReason } from './editing/move';
import { ReorderEditor, getReorderBlockReason } from './editing/reorder';
import type { ReorderCommitCallback } from './editing/reorder';
import { GridSettingsPanel } from './grid-settings';
import { MeasureOverlay } from './selection/measure-overlay';
import { MultiSelectManager } from './selection/multi-select';
import { MultiSelectToolbar } from './editing/multi-select-toolbar';
import { buildElementInfo, getTopElementAt, generateSelector } from '../shared/dom-utils';
import type { VisualDiff, PropertyChange, ReorderChange } from '@frontend-editor/shared';
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
let moveEditor: MoveEditor | null = null;
let reorderEditor: ReorderEditor | null = null;
let gridSettingsPanel: GridSettingsPanel | null = null;
let measureOverlay: MeasureOverlay | null = null;
let measureRafId: number | null = null;
let devtoolsUserClosed = false;
let devtoolsOpenBeforeCollapse = false;
let gridVisibleBeforeCollapse = false;
let multiSelect: MultiSelectManager | null = null;
let multiSelectToolbar: MultiSelectToolbar | null = null;
let multiSelectClickHandler: ((e: MouseEvent) => void) | null = null;
let notePickMode: { noteIndex: number; handler: (e: MouseEvent) => void } | null = null;

// Tab session ID — stable for the tab's lifetime
let tabId: string | null = null;

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

async function activate(): Promise<void> {
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
      queue!.reconcile(payload.knownDiffIds);
      badge!.update();
    },
    onDiffAck: (payload) => {
      queue!.acknowledge(payload.diffIds);
      badge!.update();
      reviewPanel?.refresh();
      devtoolsPanel?.log(`${payload.diffIds.length} diff(s) acknowledged`);
    },
    onTokenData: (payload) => {
      tokenStore!.setAll(payload.tokens, payload.sources);
      devtoolsPanel?.log(`Received ${payload.tokens.length} design tokens`);
    },
    onTokenUpdate: (payload) => {
      tokenStore!.update(payload.tokens, payload.sources);
      devtoolsPanel?.log(`Token update: ${payload.tokens.length} tokens`);
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
  handles = new DragHandleManager(shadow, snapping, preview);
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
  positionEditor = new PositionEditor(preview);
  notesEditor = new NotesEditor(notesStore, shadow);
  gridOverlay = new GridOverlay(shadow, tokenStore);
  moveEditor = new MoveEditor(shadow, preview);
  reorderEditor = new ReorderEditor(shadow);
  gridSettingsPanel = new GridSettingsPanel(gridOverlay.getEffectiveSettings());
  measureOverlay = new MeasureOverlay(shadow, host);
  multiSelect = new MultiSelectManager(shadow, host);
  multiSelectToolbar = new MultiSelectToolbar(tokenStore, preview);

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

  // Wire selection → panel, toolbar, handles, stale detection
  selection.onSelect((info, element, _rect) => {
    // Exit multi-select on normal (non-Option) selection
    if (multiSelect?.isActive()) {
      exitMultiSelectMode();
    }

    // Auto-open DevTools on element select (replaces old floating properties auto-open)
    if (!devtoolsUserClosed && !devtoolsPanel!.isOpen()) {
      devtoolsPanel!.show(element, info);
      toolbar!.setInspectorOpen('devtools', true);
    } else if (devtoolsPanel!.isOpen()) {
      devtoolsPanel!.updateElement(element, info);
    }
    toolbar!.setDeleteEnabled(true);
    handles!.hideHandles();
    typographyEditor!.cleanup();
    colorEditor!.cleanup();
    dimensionsEditor!.cleanup();
    spacingEditor!.cleanup();
    positionEditor!.cleanup();
    moveEditor!.cleanup();
    reorderEditor!.cleanup();
    staleDetector!.watch(element, () => {
      selection!.markStale();
      handles!.hideHandles();
    });

    // Determine disabled tools
    const dimBlock = getDimensionBlockReason(element);
    const moveBlock = getMoveBlockReason(element);
    const reorderBlock = getReorderBlockReason(element);
    const disabled: Partial<Record<EditMode, string>> = {};
    if (dimBlock) disabled['dimensions'] = dimBlock;
    if (moveBlock) disabled['move'] = moveBlock;
    if (reorderBlock) disabled['reorder'] = reorderBlock;
    toolbar!.setDisabledTools(disabled);

    // Auto-activate dimensions if not blocked
    if (!dimBlock) {
      handles!.showHandles(element, 'dimensions');
      const pos = toolbar!.getButtonPosition('dimensions');
      const dimControls = dimensionsEditor!.render(element, pos, (changes) => {
        const info = buildElementInfo(element);
        const diff = diffBuilder!.build(info, changes);
        commitEdit(element, changes, diff);
        selection!.refreshHighlight();
        handles!.refreshHandles();
      });
      shadow!.appendChild(dimControls);
      toolbar!.setActiveMode('dimensions');
    } else {
      toolbar!.setActiveMode(null);
    }
  });

  selection.onDeselect(() => {
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
    moveEditor!.cleanup();
    reorderEditor!.cleanup();
    measureOverlay!.disable();
    measureOverlay!.clear();
    staleDetector!.cleanup();
    preview!.revert();
    toolbar!.setActiveMode(null);
    toolbar!.setDisabledTools({});
  });

  // Wire toolbar tool selection → handles or floating editors
  toolbar.onToolSelect((selectedMode) => {
    if (multiSelect?.isActive()) return; // ignore tool changes during multi-select
    const el = selection!.getSelectedElement();
    if (!el) return;

    // Clean up previous edit mode
    handles!.hideHandles();
    typographyEditor!.cleanup();
    colorEditor!.cleanup();
    dimensionsEditor!.cleanup();
    spacingEditor!.cleanup();
    positionEditor!.cleanup();
    moveEditor!.cleanup();
    reorderEditor!.cleanup();

    // Toggle off if clicking the active tool
    if (selectedMode === toolbar!.getActiveMode()) {
      toolbar!.setActiveMode(null);
      return;
    }

    if (selectedMode === 'typography') {
      const pos = toolbar!.getButtonPosition('typography');
      const controls = typographyEditor!.render(el, pos, (changes) => {
        const info = buildElementInfo(el);
        const diff = diffBuilder!.build(info, changes);
        commitEdit(el, changes, diff);
      });
      shadow!.appendChild(controls);
      toolbar!.setActiveMode('typography');
    } else if (selectedMode === 'colors') {
      const pos = toolbar!.getButtonPosition('colors');
      const controls = colorEditor!.render(el, 'color', pos, (changes) => {
        const info = buildElementInfo(el);
        const diff = diffBuilder!.build(info, changes);
        commitEdit(el, changes, diff);
      });
      shadow!.appendChild(controls);
      toolbar!.setActiveMode('colors');
    } else if (selectedMode === 'dimensions') {
      // Dimensions: handles for drag + mini panel for presets
      handles!.showHandles(el, selectedMode);
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
    } else if (selectedMode === 'spacing') {
      // Spacing: handles for drag + mini panel for token-based value selection
      handles!.showHandles(el, selectedMode);
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
    } else if (selectedMode === 'position') {
      const pos = toolbar!.getButtonPosition('position');
      const controls = positionEditor!.render(el, pos, (changes) => {
        const info = buildElementInfo(el);
        const diff = diffBuilder!.build(info, changes);
        commitEdit(el, changes, diff);
        selection!.refreshHighlight();
      });
      shadow!.appendChild(controls);
      toolbar!.setActiveMode('position');
    } else if (selectedMode === 'move') {
      moveEditor!.render(el, (changes) => {
        const info = buildElementInfo(el);
        const diff = diffBuilder!.build(info, changes);
        commitEdit(el, changes, diff);
        selection!.refreshHighlight();
        moveEditor!.refreshOverlay();
      });
      toolbar!.setActiveMode('move');
    } else if (selectedMode === 'reorder') {
      reorderEditor!.render(el, makeReorderCommit(el));
      toolbar!.setActiveMode('reorder');
    } else {
      handles!.showHandles(el, selectedMode);
      toolbar!.setActiveMode(selectedMode);
    }
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

      // Pause inspection — let user interact with the page normally
      hover!.disable();
      selection!.hideHighlight();
      handles!.hideHandles();
      typographyEditor!.cleanup();
      colorEditor!.cleanup();
      dimensionsEditor!.cleanup();
      spacingEditor!.cleanup();
      positionEditor!.cleanup();
      moveEditor!.cleanup();
      reorderEditor!.cleanup();
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
    }
  });

  // Wire toolbar drag → reposition open mini panels next to their buttons
  toolbar.onMove(() => {
    typographyEditor!.reposition(toolbar!.getButtonPosition('typography'));
    colorEditor!.reposition(toolbar!.getButtonPosition('colors'));
    dimensionsEditor!.reposition(toolbar!.getButtonPosition('dimensions'));
    spacingEditor!.reposition(toolbar!.getButtonPosition('spacing'));
    positionEditor!.reposition(toolbar!.getButtonPosition('position'));
    notesEditor!.reposition(toolbar!.getButtonPosition('notes'));
    moveEditor!.reposition(toolbar!.getButtonPosition('move'));
    reorderEditor!.reposition(toolbar!.getButtonPosition('reorder'));
    gridSettingsPanel!.reposition(toolbar!.getButtonPosition('grid'));
    multiSelectToolbar!.reposition(toolbar!.getPosition());
    reviewPanel!.reposition(toolbar!.getButtonPosition('review'));
  });

  // Wire editor close buttons → deactivate tool
  typographyEditor.onClose(() => {
    toolbar!.setActiveMode(null);
  });
  colorEditor.onClose(() => {
    toolbar!.setActiveMode(null);
  });
  dimensionsEditor.onClose(() => {
    handles!.hideHandles();
    toolbar!.setActiveMode(null);
  });
  spacingEditor.onClose(() => {
    handles!.hideHandles();
    toolbar!.setActiveMode(null);
  });
  positionEditor.onClose(() => {
    toolbar!.setActiveMode(null);
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

  // Wire move editor close → deactivate tool
  moveEditor.onClose(() => {
    toolbar!.setActiveMode(null);
  });

  // Wire reorder editor close → deactivate tool
  reorderEditor.onClose(() => {
    toolbar!.setActiveMode(null);
  });

  // Wire delete element
  toolbar.onDelete(() => {
    deleteSelectedElement();
  });

  // Push pending count to toolbar badge
  queue.onChange(() => {
    toolbar?.setPendingCount(queue!.count);
  });
  // Initialize count from any restored queue items
  toolbar.setPendingCount(queue.count);

  // Wire undo/redo/reset
  toolbar.onUndo(() => {
    const entry = editHistory!.undo();
    if (entry) {
      queue!.remove(entry.diff.id);
      badge!.update();
      reviewPanel!.refresh();
      selection?.refreshHighlight();
      refreshReorderAfterHistoryChange(entry);
      devtoolsPanel?.log('Undo');
    }
  });

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
    queue!.clear();
    badge!.update();
    reviewPanel!.refresh();
    selection?.deselect();
    devtoolsPanel?.log('All changes reset');
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
    toolbar!.setActiveMode(null);
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

function deactivate(): void {
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
  moveEditor?.cleanup();
  reorderEditor?.cleanup();
  notesEditor?.cleanup();
  gridOverlay?.hide();
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
  moveEditor = null;
  reorderEditor = null;
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
// Reorder editor refresh after undo/redo — keeps drop zones in sync with DOM
// ---------------------------------------------------------------------------

function refreshReorderAfterHistoryChange(entry: HistoryEntry): void {
  if (entry.type !== 'reorder') return;
  if (!reorderEditor?.isActive()) return;
  const el = selection?.getSelectedElement();
  if (el) {
    reorderEditor.render(el, makeReorderCommit(el));
  }
}

// ---------------------------------------------------------------------------
// Delete element helper — removes from DOM, tracked as a diff
// ---------------------------------------------------------------------------

function deleteSelectedElement(): void {
  const el = selection?.getSelectedElement();
  if (!el) return;

  const fromValue = getComputedStyle(el).display;
  if (fromValue === 'none') return; // already hidden

  // Capture insertion context before removal
  const parent = el.parentNode;
  const nextSibling = el.nextSibling;
  if (!parent) return;

  const info = buildElementInfo(el);
  const changes: PropertyChange[] = [{
    property: 'display',
    fromValue,
    toValue: 'none',
  }];
  const diff = diffBuilder!.build(info, changes);

  // Remove element from DOM
  el.remove();

  commitEdit(el, changes, diff, { parent, nextSibling });
  selection?.deselect();
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
    moveEditor?.refreshOverlay();
    reorderEditor?.refreshOverlay();
    if (measureOverlay?.isActive()) measureOverlay.clear();
    if (notesEditor?.isOpen()) {
      notesEditor.refreshHighlights();
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
  moveEditor?.cleanup();
  reorderEditor?.cleanup();
  toolbar?.setActiveMode(null);

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
    return;
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
        const dimBlock = getDimensionBlockReason(primary);
        if (!dimBlock) {
          handles?.showHandles(primary, 'dimensions');
          const pos = toolbar!.getButtonPosition('dimensions');
          const dimControls = dimensionsEditor!.render(primary, pos, (changes) => {
            const dimInfo = buildElementInfo(primary);
            const diff = diffBuilder!.build(dimInfo, changes);
            commitEdit(primary, changes, diff);
            selection!.refreshHighlight();
            handles!.refreshHandles();
          });
          shadow!.appendChild(dimControls);
          toolbar?.setActiveMode('dimensions');
        } else {
          toolbar?.setActiveMode(null);
        }
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
    } else if (reorderEditor?.isDragging()) {
      // Level 1a: cancel reorder drag — revert preview, stay in reorder mode
      reorderEditor.cancelDrag();
    } else if (moveEditor?.isDragging()) {
      // Level 1b: cancel move drag — revert and stay in move mode
      moveEditor.cleanup();
      const el = selection?.getSelectedElement();
      if (el) {
        moveEditor.render(el, (changes) => {
          const info = buildElementInfo(el);
          const diff = diffBuilder!.build(info, changes);
          commitEdit(el, changes, diff);
          selection!.refreshHighlight();
          moveEditor!.refreshOverlay();
        });
      }
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
