import type { ElementInfo } from '@frontend-editor/shared';
import { createElement, createText, createButton } from '../../shared/ui-utils';
import { buildElementInfo, createStyleSnapshot } from '../../shared/dom-utils';
import {
  OVERLAY,
  DEVTOOLS_DEFAULT_HEIGHT,
  DEVTOOLS_MIN_HEIGHT,
  DEVTOOLS_MAX_HEIGHT_RATIO,
  DEVTOOLS_DEFAULT_LEFT_RATIO,
  DEVTOOLS_DEFAULT_MIDDLE_RATIO,
  PANEL_TIER_COMPACT_MAX,
  PANEL_TIER_STANDARD_MAX,
} from '../../shared/constants';
import type { PanelSizeTier } from '../../shared/constants';
import type { TokenStore } from '../tokens/store';
import type { PendingQueue } from '../batching/queue';
import { DomTreePane } from './panes/dom-tree-pane';
import { SourcePane } from './panes/source-pane';
import { PropertiesPane } from './panes/properties-pane';
import { ConsolePane } from './panes/console-pane';

type ElementSelectCallback = (element: Element) => void;
type PropertyChangeCallback = (property: string, fromValue: string, toValue: string, token?: string) => void;
type MultiPropertyChangeCallback = (changes: Array<{ element: Element; property: string; fromValue: string; toValue: string; token?: string }>) => void;

const STORAGE_KEY_HEIGHT = 'frontend-editor-devtools-height';
const STORAGE_KEY_SPLIT = 'frontend-editor-devtools-split';
const MIN_PANE_WIDTH = 200;

/**
 * Chrome DevTools-style bottom panel with a three-column split view.
 * Delegates rendering to composable pane modules:
 * - Left: DomTreePane (tree) + SourcePane (file info)
 * - Middle: PropertiesPane (tab bar + CSS groups)
 * - Right: ConsolePane (log)
 */
export class DevToolsPanel {
  private container: HTMLDivElement | null = null;
  private leftPaneEl: HTMLDivElement | null = null;
  private middlePaneEl: HTMLDivElement | null = null;
  private rightPaneEl: HTMLDivElement | null = null;
  private divider1El: HTMLDivElement | null = null;
  private divider2El: HTMLDivElement | null = null;
  private currentElement: Element | null = null;
  private currentInfo: ElementInfo | null = null;
  private closeCb: (() => void) | null = null;
  private leftRatio = DEVTOOLS_DEFAULT_LEFT_RATIO;
  private middleRatio = DEVTOOLS_DEFAULT_MIDDLE_RATIO;
  private panelHeight = DEVTOOLS_DEFAULT_HEIGHT;
  private currentTier: PanelSizeTier = 'full';
  private resizeObserver: ResizeObserver | null = null;

  // Pane instances
  private domTreePane: DomTreePane;
  private sourcePane: SourcePane;
  private propertiesPane: PropertiesPane;
  private consolePane: ConsolePane;

  constructor(
    private readonly shadow: ShadowRoot,
    tokenStore: TokenStore,
    pendingQueue: PendingQueue,
  ) {
    this.domTreePane = new DomTreePane();
    this.sourcePane = new SourcePane();
    this.propertiesPane = new PropertiesPane(tokenStore, pendingQueue, shadow.host);
    this.consolePane = new ConsolePane();
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  onClose(cb: () => void): void {
    this.closeCb = cb;
  }

  onElementSelect(cb: ElementSelectCallback): void {
    this.domTreePane.onElementSelect(cb);
  }

  onElementHover(cb: (element: Element | null) => void): void {
    this.domTreePane.onElementHover(cb);
  }

  onPropertyChange(cb: PropertyChangeCallback): void {
    this.propertiesPane.onPropertyChange(cb);
  }

  onMultiPropertyChange(cb: MultiPropertyChangeCallback): void {
    this.propertiesPane.onMultiPropertyChange(cb);
  }

  isOpen(): boolean {
    return this.container != null;
  }

  async show(element?: Element, info?: ElementInfo): Promise<void> {
    await this.restorePreferences();

    if (element) {
      this.currentElement = element;
      this.currentInfo = info ?? null;
    }
    this.buildPanel();
  }

  updateElement(element: Element, info?: ElementInfo): void {
    this.currentElement = element;
    this.currentInfo = info ?? buildElementInfo(element);
    const snapshot = createStyleSnapshot(element);
    this.domTreePane.updateElement(element, this.currentInfo);
    this.sourcePane.updateElement(this.currentInfo);
    this.propertiesPane.updateElement(element, snapshot);
  }

  updateProperties(element: Element): void {
    this.currentElement = element;
    const snapshot = createStyleSnapshot(element);
    this.propertiesPane.updateElement(element, snapshot);
  }

  updateMultiProperties(elements: Element[]): void {
    this.currentElement = elements[0] ?? null;
    this.propertiesPane.updateMultiElements(elements);
  }

  clearElement(): void {
    this.currentElement = null;
    this.currentInfo = null;
    this.domTreePane.clearElement();
    this.sourcePane.clearElement();
    this.propertiesPane.clearElement();
  }

  clearProperties(): void {
    this.propertiesPane.clearElement();
  }

  refreshProperties(): void {
    this.propertiesPane.refreshProperties();
  }

  hide(): void {
    this.resizeObserver?.disconnect();
    this.resizeObserver = null;
    this.container?.remove();
    this.container = null;
    this.leftPaneEl = null;
    this.middlePaneEl = null;
    this.rightPaneEl = null;
    this.divider1El = null;
    this.divider2El = null;
    this.domTreePane.dispose();
    this.sourcePane.dispose();
    this.propertiesPane.dispose();
    this.consolePane.dispose();
  }

  log(text: string, level: 'info' | 'warn' | 'error' = 'info'): void {
    this.consolePane.log(text, level);
  }

  clearLog(): void {
    this.consolePane.clearLog();
  }

  // ---------------------------------------------------------------------------
  // Panel construction
  // ---------------------------------------------------------------------------

  private buildPanel(): void {
    this.container?.remove();

    const panel = createElement('div', { role: 'dialog', 'aria-label': 'DevTools' }, {
      position: 'fixed',
      bottom: '0',
      left: '0',
      right: '0',
      height: `${this.panelHeight}px`,
      background: OVERLAY.bg,
      borderTop: `1px solid ${OVERLAY.border}`,
      boxShadow: '0 -4px 12px rgba(0, 0, 0, 0.15)',
      zIndex: '150',
      pointerEvents: 'auto',
      display: 'flex',
      flexDirection: 'column',
      fontFamily: OVERLAY.fontFamily,
    });

    // Top resize handle (4px, cursor ns-resize)
    const resizeHandle = createElement('div', {}, {
      height: '4px',
      cursor: 'ns-resize',
      background: 'transparent',
      flexShrink: '0',
    });
    resizeHandle.addEventListener('dblclick', () => {
      this.panelHeight = DEVTOOLS_DEFAULT_HEIGHT;
      panel.style.height = `${this.panelHeight}px`;
      this.saveHeight(this.panelHeight);
    });
    this.initHeightDrag(resizeHandle, panel);
    panel.appendChild(resizeHandle);

    // Header bar with labels + close
    const headerBar = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      padding: '4px 8px',
      borderBottom: `1px solid ${OVERLAY.border}`,
      flexShrink: '0',
      gap: '8px',
    });

    const elementsLabel = createText('span', 'Elements', 'heading');
    elementsLabel.style.fontSize = '11px';
    headerBar.appendChild(elementsLabel);

    const dividerDot1 = createElement('div', {}, {
      width: '1px',
      height: '12px',
      background: OVERLAY.border,
    });
    headerBar.appendChild(dividerDot1);

    const propertiesLabel = createText('span', 'Properties', 'heading');
    propertiesLabel.style.fontSize = '11px';
    headerBar.appendChild(propertiesLabel);

    const dividerDot2 = createElement('div', {}, {
      width: '1px',
      height: '12px',
      background: OVERLAY.border,
    });
    headerBar.appendChild(dividerDot2);

    const consoleLabel = createText('span', 'Console', 'heading');
    consoleLabel.style.fontSize = '11px';
    consoleLabel.style.flex = '1';
    headerBar.appendChild(consoleLabel);

    const closeBtn = createButton('\u00d7', 'ghost', () => {
      this.hide();
      this.closeCb?.();
    });
    closeBtn.style.padding = '2px 6px';
    closeBtn.style.fontSize = '14px';
    closeBtn.style.flexShrink = '0';
    headerBar.appendChild(closeBtn);
    panel.appendChild(headerBar);

    // Split container (flex row)
    const splitContainer = createElement('div', {}, {
      display: 'flex',
      flex: '1',
      minHeight: '0',
      overflow: 'hidden',
    });

    // Left pane (DOM inspector)
    const leftPane = createElement('div', {}, {
      flex: `0 0 ${this.leftRatio * 100}%`,
      display: 'flex',
      flexDirection: 'column',
      overflow: 'hidden',
      borderRight: `1px solid ${OVERLAY.border}`,
    });
    this.leftPaneEl = leftPane;

    // Tree box (scrollable) — mount DomTreePane
    const treeBox = createElement('div', {}, {
      flex: '1',
      overflowY: 'auto',
      padding: '4px',
      fontFamily: OVERLAY.monoFamily,
      fontSize: '11px',
    });
    this.domTreePane.mount(treeBox);

    if (this.currentElement) {
      this.domTreePane.updateElement(this.currentElement, this.currentInfo ?? buildElementInfo(this.currentElement));
    } else {
      this.domTreePane.clearElement();
    }
    leftPane.appendChild(treeBox);

    // Source info (fixed at bottom of left pane) — mount SourcePane
    const sourceBox = createElement('div', {}, {
      borderTop: `1px solid ${OVERLAY.border}`,
      padding: '4px 8px',
      flexShrink: '0',
    });
    this.sourcePane.mount(sourceBox);
    if (this.currentInfo) {
      this.sourcePane.updateElement(this.currentInfo);
    }
    leftPane.appendChild(sourceBox);
    splitContainer.appendChild(leftPane);

    // Vertical divider 1 (between left and middle)
    const divider1 = createElement('div', {}, {
      width: '4px',
      cursor: 'col-resize',
      background: 'transparent',
      flexShrink: '0',
      transition: 'background 0.1s',
    });
    divider1.addEventListener('mouseenter', () => { divider1.style.background = OVERLAY.border; });
    divider1.addEventListener('mouseleave', () => { divider1.style.background = 'transparent'; });
    this.initLeftSplitDrag(divider1, leftPane, splitContainer);
    this.divider1El = divider1;
    splitContainer.appendChild(divider1);

    // Middle pane (Properties) — mount PropertiesPane
    const middlePane = createElement('div', {}, {
      flex: `0 0 ${this.middleRatio * 100}%`,
      display: 'flex',
      flexDirection: 'column',
      overflow: 'hidden',
      borderRight: `1px solid ${OVERLAY.border}`,
    });
    this.middlePaneEl = middlePane;
    this.propertiesPane.mount(middlePane);

    // Wire state simulator to DOM tree for orange dot indicator
    this.domTreePane.setStateSimulator(this.propertiesPane.getStateSimulator());

    // Populate initial properties content
    if (this.currentElement) {
      const snapshot = createStyleSnapshot(this.currentElement);
      this.propertiesPane.updateElement(this.currentElement, snapshot);
    }

    splitContainer.appendChild(middlePane);

    // Vertical divider 2 (between middle and right)
    const divider2 = createElement('div', {}, {
      width: '4px',
      cursor: 'col-resize',
      background: 'transparent',
      flexShrink: '0',
      transition: 'background 0.1s',
    });
    divider2.addEventListener('mouseenter', () => { divider2.style.background = OVERLAY.border; });
    divider2.addEventListener('mouseleave', () => { divider2.style.background = 'transparent'; });
    this.initMiddleSplitDrag(divider2, middlePane, splitContainer);
    this.divider2El = divider2;
    splitContainer.appendChild(divider2);

    // Right pane (console) — mount ConsolePane
    const rightPane = createElement('div', {}, {
      flex: '1',
      display: 'flex',
      flexDirection: 'column',
      overflow: 'hidden',
    });
    this.rightPaneEl = rightPane;
    this.consolePane.mount(rightPane);
    splitContainer.appendChild(rightPane);

    panel.appendChild(splitContainer);
    this.container = panel;
    this.shadow.appendChild(panel);

    // Set up ResizeObserver for tier-based graceful degradation
    this.resizeObserver?.disconnect();
    this.resizeObserver = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const height = entry.contentRect.height;
        const tier = this.computeTier(height);
        if (tier !== this.currentTier) {
          this.currentTier = tier;
          this.applyTier(tier);
        }
      }
    });
    this.resizeObserver.observe(panel);

    // Apply initial tier
    this.currentTier = this.computeTier(this.panelHeight);
    this.applyTier(this.currentTier);
  }

  // ---------------------------------------------------------------------------
  // Height drag (top edge resize)
  // ---------------------------------------------------------------------------

  private initHeightDrag(handle: HTMLDivElement, panel: HTMLDivElement): void {
    let startY = 0;
    let startHeight = 0;

    const onPointerDown = (e: PointerEvent) => {
      e.preventDefault();
      handle.setPointerCapture(e.pointerId);
      startY = e.clientY;
      startHeight = this.panelHeight;
    };

    const onPointerMove = (e: PointerEvent) => {
      if (!handle.hasPointerCapture(e.pointerId)) return;
      const dy = startY - e.clientY;
      const maxHeight = Math.floor(window.innerHeight * DEVTOOLS_MAX_HEIGHT_RATIO);
      const newHeight = Math.max(DEVTOOLS_MIN_HEIGHT, Math.min(startHeight + dy, maxHeight));
      this.panelHeight = newHeight;
      panel.style.height = `${newHeight}px`;
    };

    const onPointerUp = (e: PointerEvent) => {
      if (!handle.hasPointerCapture(e.pointerId)) return;
      handle.releasePointerCapture(e.pointerId);
      this.saveHeight(this.panelHeight);
    };

    handle.addEventListener('pointerdown', onPointerDown);
    handle.addEventListener('pointermove', onPointerMove);
    handle.addEventListener('pointerup', onPointerUp);
  }

  // ---------------------------------------------------------------------------
  // Split drag (left vertical divider — adjusts leftRatio)
  // ---------------------------------------------------------------------------

  private initLeftSplitDrag(
    divider: HTMLDivElement,
    leftPane: HTMLDivElement,
    splitContainer: HTMLDivElement,
  ): void {
    let startX = 0;
    let startRatio = 0;

    const onPointerDown = (e: PointerEvent) => {
      e.preventDefault();
      divider.setPointerCapture(e.pointerId);
      startX = e.clientX;
      startRatio = this.leftRatio;
    };

    const onPointerMove = (e: PointerEvent) => {
      if (!divider.hasPointerCapture(e.pointerId)) return;
      const containerWidth = splitContainer.offsetWidth;
      if (containerWidth === 0) return;
      const dx = e.clientX - startX;
      const deltaRatio = dx / containerWidth;
      const newRatio = startRatio + deltaRatio;
      const minRatio = MIN_PANE_WIDTH / containerWidth;
      const maxRatio = 1 - (2 * MIN_PANE_WIDTH) / containerWidth;
      this.leftRatio = Math.max(minRatio, Math.min(newRatio, maxRatio));
      leftPane.style.flex = `0 0 ${this.leftRatio * 100}%`;
    };

    const onPointerUp = (e: PointerEvent) => {
      if (!divider.hasPointerCapture(e.pointerId)) return;
      divider.releasePointerCapture(e.pointerId);
      this.saveSplit();
    };

    divider.addEventListener('pointerdown', onPointerDown);
    divider.addEventListener('pointermove', onPointerMove);
    divider.addEventListener('pointerup', onPointerUp);
  }

  // ---------------------------------------------------------------------------
  // Split drag (middle vertical divider — adjusts middleRatio)
  // ---------------------------------------------------------------------------

  private initMiddleSplitDrag(
    divider: HTMLDivElement,
    middlePane: HTMLDivElement,
    splitContainer: HTMLDivElement,
  ): void {
    let startX = 0;
    let startRatio = 0;

    const onPointerDown = (e: PointerEvent) => {
      e.preventDefault();
      divider.setPointerCapture(e.pointerId);
      startX = e.clientX;
      startRatio = this.middleRatio;
    };

    const onPointerMove = (e: PointerEvent) => {
      if (!divider.hasPointerCapture(e.pointerId)) return;
      const containerWidth = splitContainer.offsetWidth;
      if (containerWidth === 0) return;
      const dx = e.clientX - startX;
      const deltaRatio = dx / containerWidth;
      const newRatio = startRatio + deltaRatio;
      const minRatio = MIN_PANE_WIDTH / containerWidth;
      const maxRatio = 1 - this.leftRatio - MIN_PANE_WIDTH / containerWidth;
      this.middleRatio = Math.max(minRatio, Math.min(newRatio, maxRatio));
      middlePane.style.flex = `0 0 ${this.middleRatio * 100}%`;
    };

    const onPointerUp = (e: PointerEvent) => {
      if (!divider.hasPointerCapture(e.pointerId)) return;
      divider.releasePointerCapture(e.pointerId);
      this.saveSplit();
    };

    divider.addEventListener('pointerdown', onPointerDown);
    divider.addEventListener('pointermove', onPointerMove);
    divider.addEventListener('pointerup', onPointerUp);
  }

  // ---------------------------------------------------------------------------
  // Tier-based graceful degradation
  // ---------------------------------------------------------------------------

  private computeTier(height: number): PanelSizeTier {
    if (height <= PANEL_TIER_COMPACT_MAX) return 'compact';
    if (height <= PANEL_TIER_STANDARD_MAX) return 'standard';
    return 'full';
  }

  private applyTier(tier: PanelSizeTier): void {
    const hideColumns = tier === 'compact';

    if (this.leftPaneEl) {
      this.leftPaneEl.style.display = hideColumns ? 'none' : '';
    }
    if (this.divider1El) {
      this.divider1El.style.display = hideColumns ? 'none' : '';
    }
    if (this.rightPaneEl) {
      this.rightPaneEl.style.display = hideColumns ? 'none' : '';
    }
    if (this.divider2El) {
      this.divider2El.style.display = hideColumns ? 'none' : '';
    }

    // In compact mode, middle pane takes full width
    if (this.middlePaneEl) {
      if (hideColumns) {
        this.middlePaneEl.style.flex = '1';
        this.middlePaneEl.style.borderRight = 'none';
      } else {
        this.middlePaneEl.style.flex = `0 0 ${this.middleRatio * 100}%`;
        this.middlePaneEl.style.borderRight = `1px solid ${OVERLAY.border}`;
      }
    }

    this.propertiesPane.setTier(tier);
  }

  // ---------------------------------------------------------------------------
  // Persistence (chrome.storage.session)
  // ---------------------------------------------------------------------------

  private async restorePreferences(): Promise<void> {
    try {
      const result = await chrome.storage.session.get([STORAGE_KEY_HEIGHT, STORAGE_KEY_SPLIT]);
      const savedHeight = result[STORAGE_KEY_HEIGHT] as number | undefined;
      const savedSplit = result[STORAGE_KEY_SPLIT] as { left: number; middle: number } | number | undefined;
      if (typeof savedHeight === 'number' && savedHeight >= DEVTOOLS_MIN_HEIGHT) {
        const maxHeight = Math.floor(window.innerHeight * DEVTOOLS_MAX_HEIGHT_RATIO);
        this.panelHeight = Math.min(savedHeight, maxHeight);
      }
      if (typeof savedSplit === 'object' && savedSplit !== null) {
        if (typeof savedSplit.left === 'number' && savedSplit.left > 0 && savedSplit.left < 1) {
          this.leftRatio = savedSplit.left;
        }
        if (typeof savedSplit.middle === 'number' && savedSplit.middle > 0 && savedSplit.middle < 1) {
          this.middleRatio = savedSplit.middle;
        }
      } else if (typeof savedSplit === 'number' && savedSplit > 0 && savedSplit < 1) {
        this.leftRatio = savedSplit;
      }
    } catch {
      // Non-fatal — use defaults
    }
  }

  private async saveHeight(height: number): Promise<void> {
    try {
      await chrome.storage.session.set({ [STORAGE_KEY_HEIGHT]: height });
    } catch {
      // Non-fatal
    }
  }

  private async saveSplit(): Promise<void> {
    try {
      await chrome.storage.session.set({ [STORAGE_KEY_SPLIT]: { left: this.leftRatio, middle: this.middleRatio } });
    } catch {
      // Non-fatal
    }
  }
}
