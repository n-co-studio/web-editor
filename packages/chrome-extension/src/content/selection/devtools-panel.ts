import type { DesignToken, ElementInfo } from '@frontend-editor/shared';
import { createElement, createText, createButton } from '../../shared/ui-utils';
import { buildElementInfo, getComputedProperty } from '../../shared/dom-utils';
import {
  OVERLAY,
  DEVTOOLS_DEFAULT_HEIGHT,
  DEVTOOLS_MIN_HEIGHT,
  DEVTOOLS_MAX_HEIGHT_RATIO,
  DEVTOOLS_DEFAULT_LEFT_RATIO,
  DEVTOOLS_DEFAULT_MIDDLE_RATIO,
  SELECTOR_TRUNCATE_LENGTH,
} from '../../shared/constants';
import type { TokenStore } from '../tokens/store';

type ElementSelectCallback = (element: Element) => void;
type PropertyChangeCallback = (property: string, fromValue: string, toValue: string, token?: string) => void;
type MultiPropertyChangeCallback = (changes: Array<{ element: Element; property: string; fromValue: string; toValue: string; token?: string }>) => void;

const STORAGE_KEY_HEIGHT = 'frontend-editor-devtools-height';
const STORAGE_KEY_SPLIT = 'frontend-editor-devtools-split';
const MAX_LOG_ENTRIES = 50;
const MIN_PANE_WIDTH = 200;

/**
 * Chrome DevTools-style bottom panel with a three-column split view.
 * Left: DOM inspector (tree + source info).
 * Middle: CSS properties panel (ported from PropertiesPanel).
 * Right: console log.
 * Supports dragging the top edge to resize height and both vertical
 * dividers to adjust the split ratios. All are persisted in chrome.storage.session.
 */
export class DevToolsPanel {
  private container: HTMLDivElement | null = null;
  private treeBox: HTMLDivElement | null = null;
  private sourceBox: HTMLDivElement | null = null;
  private logContainer: HTMLDivElement | null = null;
  private leftPane: HTMLDivElement | null = null;
  private middlePane: HTMLDivElement | null = null;
  private rightPane: HTMLDivElement | null = null;
  private propertiesPane: HTMLDivElement | null = null;
  private currentElement: Element | null = null;
  private currentInfo: ElementInfo | null = null;
  private currentElements: Element[] | null = null;
  private expandedNodes = new Set<Element>();
  private logEntries: Array<{ level: 'info' | 'warn' | 'error'; text: string; time: number }> = [];
  private closeCb: (() => void) | null = null;
  private elementSelectCb: ElementSelectCallback | null = null;
  private elementHoverCb: ((element: Element | null) => void) | null = null;
  private propChangeCb: PropertyChangeCallback | null = null;
  private multiPropChangeCb: MultiPropertyChangeCallback | null = null;
  private leftRatio = DEVTOOLS_DEFAULT_LEFT_RATIO;
  private middleRatio = DEVTOOLS_DEFAULT_MIDDLE_RATIO;
  private panelHeight = DEVTOOLS_DEFAULT_HEIGHT;

  constructor(
    private readonly shadow: ShadowRoot,
    private readonly tokenStore: TokenStore,
  ) {}

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  onClose(cb: () => void): void {
    this.closeCb = cb;
  }

  onElementSelect(cb: ElementSelectCallback): void {
    this.elementSelectCb = cb;
  }

  onElementHover(cb: (element: Element | null) => void): void {
    this.elementHoverCb = cb;
  }

  onPropertyChange(cb: PropertyChangeCallback): void {
    this.propChangeCb = cb;
  }

  onMultiPropertyChange(cb: MultiPropertyChangeCallback): void {
    this.multiPropChangeCb = cb;
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
    this.currentElements = null;
    this.expandedNodes.clear();
    this.autoExpandAncestors(element);
    if (this.treeBox) this.renderTree(this.treeBox, element);
    if (this.sourceBox && this.currentInfo) this.refreshSourceSection(this.currentInfo);
    if (this.propertiesPane) this.renderPropertiesContent(this.propertiesPane, element);
  }

  updateProperties(element: Element): void {
    this.currentElement = element;
    this.currentElements = null;
    if (this.propertiesPane) this.renderPropertiesContent(this.propertiesPane, element);
  }

  updateMultiProperties(elements: Element[]): void {
    this.currentElements = elements;
    this.currentElement = elements[0] ?? null;
    if (this.propertiesPane) this.renderMultiPropertiesContent(this.propertiesPane, elements);
  }

  clearElement(): void {
    this.currentElement = null;
    this.currentInfo = null;
    this.currentElements = null;
    this.expandedNodes.clear();
    if (this.treeBox) {
      this.treeBox.innerHTML = '';
      const empty = createText('div', 'No element selected', 'mono');
      empty.style.color = OVERLAY.textMuted;
      empty.style.padding = '8px';
      this.treeBox.appendChild(empty);
    }
    if (this.sourceBox) {
      this.sourceBox.innerHTML = '';
    }
    this.clearProperties();
  }

  clearProperties(): void {
    this.currentElements = null;
    if (this.propertiesPane) {
      this.propertiesPane.innerHTML = '';
      const empty = createText('div', 'No element selected', 'mono');
      empty.style.color = OVERLAY.textMuted;
      empty.style.padding = '8px';
      this.propertiesPane.appendChild(empty);
    }
  }

  refreshProperties(): void {
    if (!this.propertiesPane || !this.currentElement) return;
    if (this.currentElements && this.currentElements.length > 1) {
      this.renderMultiPropertiesContent(this.propertiesPane, this.currentElements);
    } else if (this.currentElement) {
      this.renderPropertiesContent(this.propertiesPane, this.currentElement);
    }
  }

  hide(): void {
    this.container?.remove();
    this.container = null;
    this.treeBox = null;
    this.sourceBox = null;
    this.logContainer = null;
    this.leftPane = null;
    this.middlePane = null;
    this.propertiesPane = null;
    this.rightPane = null;
  }

  log(text: string, level: 'info' | 'warn' | 'error' = 'info'): void {
    const prefix = '[frontend-editor]';
    if (level === 'error') console.error(prefix, text);
    else if (level === 'warn') console.warn(prefix, text);
    else console.log(prefix, text);
    this.logEntries.push({ level, text, time: Date.now() });
    if (this.logEntries.length > MAX_LOG_ENTRIES) this.logEntries.shift();
    this.refreshLogDisplay();
  }

  clearLog(): void {
    this.logEntries = [];
    this.refreshLogDisplay();
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
    this.leftPane = leftPane;

    // Tree box (scrollable)
    const treeBox = createElement('div', {}, {
      flex: '1',
      overflowY: 'auto',
      padding: '4px',
      fontFamily: OVERLAY.monoFamily,
      fontSize: '11px',
    });
    this.treeBox = treeBox;

    if (this.currentElement) {
      this.autoExpandAncestors(this.currentElement);
      this.renderTree(treeBox, this.currentElement);
    } else {
      const empty = createText('div', 'No element selected', 'mono');
      empty.style.color = OVERLAY.textMuted;
      empty.style.padding = '8px';
      treeBox.appendChild(empty);
    }
    leftPane.appendChild(treeBox);

    // Source info (fixed at bottom of left pane)
    const sourceBox = createElement('div', {}, {
      borderTop: `1px solid ${OVERLAY.border}`,
      padding: '4px 8px',
      flexShrink: '0',
    });
    this.sourceBox = sourceBox;
    if (this.currentInfo) {
      this.renderSourceContent(sourceBox, this.currentInfo);
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
    splitContainer.appendChild(divider1);

    // Middle pane (Properties)
    const middlePane = createElement('div', {}, {
      flex: `0 0 ${this.middleRatio * 100}%`,
      display: 'flex',
      flexDirection: 'column',
      overflow: 'hidden',
      borderRight: `1px solid ${OVERLAY.border}`,
    });
    this.middlePane = middlePane;

    // Properties content (scrollable)
    const propertiesPane = createElement('div', {}, {
      flex: '1',
      overflowY: 'auto',
      padding: '0',
      fontFamily: OVERLAY.monoFamily,
      fontSize: '11px',
    });
    this.propertiesPane = propertiesPane;

    if (this.currentElements && this.currentElements.length > 1) {
      this.renderMultiPropertiesContent(propertiesPane, this.currentElements);
    } else if (this.currentElement) {
      this.renderPropertiesContent(propertiesPane, this.currentElement);
    } else {
      const empty = createText('div', 'No element selected', 'mono');
      empty.style.color = OVERLAY.textMuted;
      empty.style.padding = '8px';
      propertiesPane.appendChild(empty);
    }
    middlePane.appendChild(propertiesPane);
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
    splitContainer.appendChild(divider2);

    // Right pane (console)
    const rightPane = createElement('div', {}, {
      flex: '1',
      display: 'flex',
      flexDirection: 'column',
      overflow: 'hidden',
    });
    this.rightPane = rightPane;

    const logBox = createElement('div', {}, {
      flex: '1',
      overflowY: 'auto',
      padding: '4px 8px',
      fontFamily: OVERLAY.monoFamily,
      fontSize: '11px',
    });
    this.logContainer = logBox;
    this.refreshLogDisplay();
    rightPane.appendChild(logBox);

    // Clear button at bottom of console
    const clearBar = createElement('div', {}, {
      display: 'flex',
      justifyContent: 'flex-end',
      padding: '2px 8px',
      borderTop: `1px solid ${OVERLAY.border}`,
      flexShrink: '0',
    });
    const clearBtn = createButton('Clear', 'ghost', () => this.clearLog());
    clearBtn.style.fontSize = '10px';
    clearBtn.style.padding = '2px 6px';
    clearBar.appendChild(clearBtn);
    rightPane.appendChild(clearBar);
    splitContainer.appendChild(rightPane);

    panel.appendChild(splitContainer);
    this.container = panel;
    this.shadow.appendChild(panel);
  }

  // ---------------------------------------------------------------------------
  // DOM tree
  // ---------------------------------------------------------------------------

  private autoExpandAncestors(element: Element): void {
    let current: Element | null = element.parentElement;
    while (current && current !== document.documentElement) {
      this.expandedNodes.add(current);
      current = current.parentElement;
    }
    if (element.children.length > 0) {
      this.expandedNodes.add(element);
    }
  }

  private refreshTree(): void {
    if (!this.treeBox || !this.currentElement) return;
    this.renderTree(this.treeBox, this.currentElement);
  }

  private renderTree(container: HTMLDivElement, selectedElement: Element): void {
    container.innerHTML = '';
    const root = document.body;
    if (!root) return;
    this.renderNode(container, root, 0, selectedElement);
  }

  private renderNode(
    container: HTMLDivElement,
    element: Element,
    depth: number,
    selectedElement: Element,
  ): void {
    const isSelected = element === selectedElement;
    const hasChildren = element.children.length > 0;
    const isExpanded = this.expandedNodes.has(element);
    const row = this.buildTreeRow(element, depth, isSelected, hasChildren, isExpanded);
    container.appendChild(row);
    if (hasChildren && isExpanded) {
      const children = Array.from(element.children);
      const maxChildren = 20;
      const shown = children.slice(0, maxChildren);
      for (const child of shown) {
        this.renderNode(container, child, depth + 1, selectedElement);
      }
      if (children.length > maxChildren) {
        const more = createText('div', `\u2026 ${children.length - maxChildren} more`, 'mono');
        more.style.color = OVERLAY.textMuted;
        more.style.fontSize = '10px';
        more.style.padding = '1px 0';
        more.style.paddingLeft = `${(depth + 1) * 16 + 18}px`;
        container.appendChild(more);
      }
    }
  }

  private buildTreeRow(
    element: Element,
    depth: number,
    isSelected: boolean,
    hasChildren: boolean,
    isExpanded: boolean,
  ): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      padding: '1px 4px',
      paddingLeft: `${depth * 16}px`,
      borderRadius: OVERLAY.radiusSm,
      background: isSelected ? 'rgba(6, 182, 212, 0.12)' : 'transparent',
      transition: 'background 0.1s',
      pointerEvents: 'auto',
    });

    if (hasChildren) {
      const chevronBtn = createElement('button', { title: isExpanded ? 'Collapse' : 'Expand' }, {
        background: 'transparent',
        border: 'none',
        padding: '0',
        width: '14px',
        height: '14px',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        cursor: 'pointer',
        pointerEvents: 'auto',
        flexShrink: '0',
        color: OVERLAY.textMuted,
      }) as HTMLButtonElement;
      const chevron = createText('span', '\u25B6', 'mono');
      chevron.style.fontSize = '7px';
      chevron.style.transition = 'transform 0.12s ease';
      chevron.style.display = 'inline-block';
      if (isExpanded) chevron.style.transform = 'rotate(90deg)';
      chevronBtn.appendChild(chevron);
      chevronBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        if (this.expandedNodes.has(element)) this.expandedNodes.delete(element);
        else this.expandedNodes.add(element);
        this.refreshTree();
      });
      row.appendChild(chevronBtn);
    } else {
      const spacer = createElement('span', {}, {
        width: '14px',
        flexShrink: '0',
        display: 'inline-block',
      });
      row.appendChild(spacer);
    }

    const labelArea = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      flex: '1',
      minWidth: '0',
      padding: '1px 2px',
      borderRadius: '2px',
      cursor: isSelected ? 'default' : 'pointer',
      gap: '2px',
    });

    const tag = element.tagName.toLowerCase();
    const tagEl = createText('span', tag, 'mono');
    tagEl.style.color = isSelected ? OVERLAY.primary : OVERLAY.text;
    tagEl.style.fontSize = '11px';
    tagEl.style.flexShrink = '0';
    labelArea.appendChild(tagEl);

    const descriptor = this.getElementDescriptor(element);
    if (descriptor) {
      const descEl = createText('span', descriptor, 'mono');
      descEl.style.color = isSelected ? OVERLAY.primary : OVERLAY.textMuted;
      descEl.style.fontSize = '10px';
      descEl.style.overflow = 'hidden';
      descEl.style.textOverflow = 'ellipsis';
      descEl.style.whiteSpace = 'nowrap';
      labelArea.appendChild(descEl);
    }

    // Hover highlight on page for all rows (selected or not)
    labelArea.addEventListener('mouseenter', () => {
      if (!isSelected) row.style.background = 'rgba(255, 255, 255, 0.06)';
      this.elementHoverCb?.(element);
    });
    labelArea.addEventListener('mouseleave', () => {
      if (!isSelected) row.style.background = 'transparent';
      this.elementHoverCb?.(null);
    });

    if (!isSelected) {
      labelArea.addEventListener('click', (e) => {
        e.stopPropagation();
        this.elementSelectCb?.(element);
      });
    }

    row.appendChild(labelArea);
    return row;
  }

  private getElementDescriptor(element: Element): string {
    const parts: string[] = [];
    if (element.id) parts.push(`#${element.id}`);
    const classes = Array.from(element.classList).slice(0, 3);
    for (const cls of classes) {
      if (cls.length <= 30) parts.push(`.${cls}`);
    }
    return parts.join('');
  }

  // ---------------------------------------------------------------------------
  // Source section
  // ---------------------------------------------------------------------------

  private renderSourceContent(container: HTMLDivElement, info: ElementInfo): void {
    container.innerHTML = '';
    if (info.sourceFile) {
      const fileLine = createText('div', `${info.sourceFile}:${info.sourceLine}`, 'mono');
      fileLine.style.color = OVERLAY.textMuted;
      container.appendChild(fileLine);
    } else {
      const warning = createElement('div', {}, {
        background: 'rgba(245, 158, 11, 0.15)',
        border: `1px solid ${OVERLAY.warning}`,
        borderRadius: OVERLAY.radiusSm,
        padding: '4px 8px',
        fontSize: OVERLAY.bodySize,
        color: OVERLAY.warning,
        fontFamily: OVERLAY.fontFamily,
      });
      warning.textContent = 'Source mapping unavailable \u2014 install the dev-plugin for precise file targeting.';
      container.appendChild(warning);
    }
    const selectorText = info.selector.length > SELECTOR_TRUNCATE_LENGTH
      ? info.selector.slice(0, SELECTOR_TRUNCATE_LENGTH) + '\u2026'
      : info.selector;
    const selector = createText('div', selectorText, 'mono');
    selector.style.color = OVERLAY.textMuted;
    selector.style.marginTop = '4px';
    selector.title = info.selector;
    container.appendChild(selector);
  }

  private refreshSourceSection(info: ElementInfo): void {
    if (!this.sourceBox) return;
    this.renderSourceContent(this.sourceBox, info);
  }

  // ---------------------------------------------------------------------------
  // Console log
  // ---------------------------------------------------------------------------

  private refreshLogDisplay(): void {
    if (!this.logContainer) return;
    this.logContainer.innerHTML = '';
    if (this.logEntries.length === 0) {
      const empty = createText('div', 'No log entries', 'mono');
      empty.style.color = OVERLAY.textMuted;
      empty.style.padding = '4px 0';
      this.logContainer.appendChild(empty);
      return;
    }
    for (const entry of this.logEntries) {
      const line = createElement('div', {}, {
        padding: '1px 0',
        borderBottom: '1px solid rgba(255,255,255,0.05)',
        wordBreak: 'break-word',
      });
      const colorMap: Record<'info' | 'warn' | 'error', string> = {
        info: OVERLAY.text,
        warn: OVERLAY.warning,
        error: '#f87171',
      };
      line.style.color = colorMap[entry.level];
      const time = new Date(entry.time);
      const ts = `${String(time.getHours()).padStart(2, '0')}:${String(time.getMinutes()).padStart(2, '0')}:${String(time.getSeconds()).padStart(2, '0')}`;
      const timeSpan = createText('span', ts, 'mono');
      timeSpan.style.color = OVERLAY.textMuted;
      timeSpan.style.marginRight = '6px';
      timeSpan.style.fontSize = '10px';
      line.appendChild(timeSpan);
      const textSpan = document.createTextNode(entry.text);
      line.appendChild(textSpan);
      this.logContainer.appendChild(line);
    }
    this.logContainer.scrollTop = this.logContainer.scrollHeight;
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
      // Dragging up (smaller clientY) increases height
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
      // Clamp so left pane and remaining space each have at least MIN_PANE_WIDTH
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
      // Clamp so middle pane and right pane each have at least MIN_PANE_WIDTH,
      // and left pane keeps its existing space
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
        // New format: { left, middle }
        if (typeof savedSplit.left === 'number' && savedSplit.left > 0 && savedSplit.left < 1) {
          this.leftRatio = savedSplit.left;
        }
        if (typeof savedSplit.middle === 'number' && savedSplit.middle > 0 && savedSplit.middle < 1) {
          this.middleRatio = savedSplit.middle;
        }
      } else if (typeof savedSplit === 'number' && savedSplit > 0 && savedSplit < 1) {
        // Old format: single split number mapped to leftRatio for backwards compatibility
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

  // ---------------------------------------------------------------------------
  // Property rendering — ported from PropertiesPanel
  // ---------------------------------------------------------------------------

  private renderPropertiesContent(container: HTMLDivElement, element: Element): void {
    container.innerHTML = '';
    container.appendChild(this.buildClassesSection(element));
    container.appendChild(this.buildCssPropertiesSection(element));
  }

  private renderMultiPropertiesContent(container: HTMLDivElement, elements: Element[]): void {
    container.innerHTML = '';

    // Show count badge + "elements selected" header
    const header = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      padding: '6px 10px',
      borderBottom: `1px solid ${OVERLAY.border}`,
      background: 'rgba(59, 130, 246, 0.08)',
      gap: '6px',
    });
    const badge = createElement('span', {}, {
      background: OVERLAY.info,
      color: '#fff',
      padding: '1px 6px',
      borderRadius: '10px',
      fontSize: '10px',
      fontFamily: OVERLAY.monoFamily,
      fontWeight: '600',
      flexShrink: '0',
    });
    badge.textContent = `${elements.length}`;
    header.appendChild(badge);

    const title = createText('span', 'elements selected', 'heading');
    title.style.fontSize = '12px';
    title.style.flex = '1';
    header.appendChild(title);

    container.appendChild(header);
    container.appendChild(this.buildMultiCssPropertiesSection(elements));
  }

  // -------------------------------------------------------------------------
  // Classes & ID section
  // -------------------------------------------------------------------------

  private buildClassesSection(element: Element): HTMLDivElement {
    const section = createElement('div', {}, {
      padding: '6px 10px',
      borderBottom: `1px solid ${OVERLAY.border}`,
      display: 'flex',
      flexWrap: 'wrap',
      gap: '4px',
      alignItems: 'center',
    });

    const id = element.id;
    const classes = Array.from(element.classList);

    if (!id && classes.length === 0) {
      const empty = createText('span', 'No classes or ID', 'mono');
      empty.style.color = OVERLAY.textMuted;
      empty.style.fontSize = '10px';
      section.appendChild(empty);
      return section;
    }

    if (id) {
      const pill = createElement('span', {}, {
        background: 'rgba(245, 158, 11, 0.15)',
        border: '1px solid rgba(245, 158, 11, 0.4)',
        borderRadius: '3px',
        padding: '1px 5px',
        fontSize: '10px',
        fontFamily: OVERLAY.monoFamily,
        color: OVERLAY.warning,
        lineHeight: '1.4',
        whiteSpace: 'nowrap',
      });
      pill.textContent = `#${id}`;
      section.appendChild(pill);
    }

    for (const cls of classes) {
      const pill = createElement('span', {}, {
        background: 'rgba(255, 255, 255, 0.08)',
        border: `1px solid ${OVERLAY.border}`,
        borderRadius: '3px',
        padding: '1px 5px',
        fontSize: '10px',
        fontFamily: OVERLAY.monoFamily,
        color: OVERLAY.text,
        lineHeight: '1.4',
        whiteSpace: 'nowrap',
      });
      pill.textContent = `.${cls}`;
      section.appendChild(pill);
    }

    return section;
  }

  // -------------------------------------------------------------------------
  // Single-select CSS properties
  // -------------------------------------------------------------------------

  private buildCssPropertiesSection(element: Element): HTMLDivElement {
    const section = createElement('div', {}, {
      padding: '8px 10px',
    });

    const groups: Array<{ label: string; props: Array<{ name: string; value: string }> }> = [
      {
        label: 'Dimensions',
        props: [
          { name: 'width', value: getComputedProperty(element, 'width') },
          { name: 'height', value: getComputedProperty(element, 'height') },
        ],
      },
      {
        label: 'Spacing',
        props: [
          { name: 'padding-top', value: getComputedProperty(element, 'padding-top') },
          { name: 'padding-right', value: getComputedProperty(element, 'padding-right') },
          { name: 'padding-bottom', value: getComputedProperty(element, 'padding-bottom') },
          { name: 'padding-left', value: getComputedProperty(element, 'padding-left') },
          { name: 'margin-top', value: getComputedProperty(element, 'margin-top') },
          { name: 'margin-right', value: getComputedProperty(element, 'margin-right') },
          { name: 'margin-bottom', value: getComputedProperty(element, 'margin-bottom') },
          { name: 'margin-left', value: getComputedProperty(element, 'margin-left') },
        ],
      },
      {
        label: 'Typography',
        props: [
          { name: 'font-family', value: getComputedProperty(element, 'font-family') },
          { name: 'font-size', value: getComputedProperty(element, 'font-size') },
          { name: 'font-weight', value: getComputedProperty(element, 'font-weight') },
          { name: 'line-height', value: getComputedProperty(element, 'line-height') },
          { name: 'color', value: getComputedProperty(element, 'color') },
        ],
      },
      {
        label: 'Background',
        props: [
          { name: 'background-color', value: getComputedProperty(element, 'background-color') },
        ],
      },
      {
        label: 'Position',
        props: [
          { name: 'position', value: getComputedProperty(element, 'position') },
          { name: 'top', value: getComputedProperty(element, 'top') },
          { name: 'right', value: getComputedProperty(element, 'right') },
          { name: 'bottom', value: getComputedProperty(element, 'bottom') },
          { name: 'left', value: getComputedProperty(element, 'left') },
        ],
      },
      {
        label: 'Border',
        props: [
          { name: 'border-radius', value: getComputedProperty(element, 'border-radius') },
          { name: 'border-color', value: getComputedProperty(element, 'border-color') },
          { name: 'border-width', value: getComputedProperty(element, 'border-width') },
        ],
      },
    ];

    for (const group of groups) {
      const groupLabel = createText('div', group.label, 'heading');
      groupLabel.style.marginTop = '8px';
      groupLabel.style.marginBottom = '4px';
      groupLabel.style.fontSize = OVERLAY.monoSize;
      groupLabel.style.color = OVERLAY.textMuted;
      groupLabel.style.textTransform = 'uppercase';
      groupLabel.style.letterSpacing = '0.5px';
      section.appendChild(groupLabel);

      const propsGrid = createElement('div', {}, {
        display: 'grid',
        gridTemplateColumns: 'repeat(auto-fill, minmax(180px, 1fr))',
        gap: '0 16px',
      });
      for (const prop of group.props) {
        propsGrid.appendChild(this.buildPropertyRow(prop.name, prop.value));
      }
      section.appendChild(propsGrid);
    }

    return section;
  }

  private buildPropertyRow(name: string, value: string): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'center',
      padding: '2px 0',
      gap: '8px',
    });

    const nameEl = createText('span', name, 'mono');
    nameEl.style.color = OVERLAY.textMuted;
    nameEl.style.flexShrink = '0';
    row.appendChild(nameEl);

    const valueContainer = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
      overflow: 'hidden',
      cursor: 'pointer',
      pointerEvents: 'auto',
    });

    const valueEl = createText('span', value, 'mono');
    valueEl.style.textOverflow = 'ellipsis';
    valueEl.style.overflow = 'hidden';
    valueEl.style.whiteSpace = 'nowrap';
    valueContainer.appendChild(valueEl);

    const token = this.resolveToken(name, value);
    if (token) {
      const badge = createElement('span', {}, {
        background: 'rgba(6, 182, 212, 0.2)',
        color: OVERLAY.primary,
        padding: '1px 4px',
        borderRadius: '2px',
        fontSize: '10px',
        fontFamily: OVERLAY.monoFamily,
        whiteSpace: 'nowrap',
        flexShrink: '0',
      });
      badge.textContent = token.name;
      valueContainer.appendChild(badge);
    }

    valueContainer.addEventListener('click', () => {
      this.openInlineEditor(row, valueContainer, name, value);
    });

    valueContainer.addEventListener('mouseenter', () => {
      valueEl.style.textDecoration = 'underline';
      valueEl.style.textDecorationStyle = 'dotted';
    });
    valueContainer.addEventListener('mouseleave', () => {
      valueEl.style.textDecoration = '';
    });

    row.appendChild(valueContainer);
    return row;
  }

  /**
   * Replace the value display with an inline editor.
   * Shows a token dropdown when tokens are available for this property,
   * plus a freeform text input fallback.
   */
  private openInlineEditor(
    row: HTMLDivElement,
    valueContainer: HTMLDivElement,
    property: string,
    currentValue: string,
  ): void {
    const editor = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '4px',
      flex: '1',
      pointerEvents: 'auto',
    });

    const tokens = this.tokenStore.getForProperty(property);

    if (tokens.length > 0) {
      const select = createElement('select', {}, {
        background: 'rgba(255, 255, 255, 0.1)',
        color: OVERLAY.text,
        border: `1px solid ${OVERLAY.primary}`,
        borderRadius: OVERLAY.radiusSm,
        padding: '2px 4px',
        fontSize: OVERLAY.monoSize,
        fontFamily: OVERLAY.monoFamily,
        pointerEvents: 'auto',
        cursor: 'pointer',
        width: '100%',
      }) as HTMLSelectElement;

      const customOpt = document.createElement('option');
      customOpt.value = '__custom__';
      customOpt.textContent = 'Custom value...';
      select.appendChild(customOpt);

      let hasMatch = false;
      for (const t of tokens) {
        const opt = document.createElement('option');
        opt.value = t.value;
        opt.textContent = `${t.name} (${t.value})`;
        if (t.value === currentValue) {
          opt.selected = true;
          hasMatch = true;
        }
        select.appendChild(opt);
      }

      if (!hasMatch) {
        const currentOpt = document.createElement('option');
        currentOpt.value = currentValue;
        currentOpt.textContent = `${currentValue} (current)`;
        currentOpt.selected = true;
        select.insertBefore(currentOpt, customOpt.nextSibling);
      }

      select.addEventListener('change', () => {
        if (select.value === '__custom__') {
          select.style.display = 'none';
          freeform.style.display = '';
          freeform.focus();
          return;
        }
        const newValue = select.value;
        const selectedToken = tokens.find((t) => t.value === newValue);
        this.applyPropertyChange(property, currentValue, newValue, selectedToken?.name);
        this.closeInlineEditor(row, valueContainer, editor, property);
      });

      editor.appendChild(select);
    }

    const freeform = createElement('input', {
      type: 'text',
      value: currentValue,
    }, {
      background: 'rgba(255, 255, 255, 0.1)',
      color: OVERLAY.text,
      border: `1px solid ${OVERLAY.primary}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '2px 4px',
      fontSize: OVERLAY.monoSize,
      fontFamily: OVERLAY.monoFamily,
      width: '100%',
      pointerEvents: 'auto',
      display: tokens.length > 0 ? 'none' : '',
    }) as HTMLInputElement;

    freeform.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        const newValue = freeform.value.trim();
        if (newValue && newValue !== currentValue) {
          this.applyPropertyChange(property, currentValue, newValue);
        }
        this.closeInlineEditor(row, valueContainer, editor, property);
      }
      if (e.key === 'Escape') {
        e.preventDefault();
        this.closeInlineEditor(row, valueContainer, editor, property);
      }
    });

    editor.appendChild(freeform);

    valueContainer.style.display = 'none';
    row.appendChild(editor);

    if (tokens.length > 0) {
      (editor.querySelector('select') as HTMLSelectElement)?.focus();
    } else {
      freeform.focus();
      freeform.select();
    }
  }

  private closeInlineEditor(
    row: HTMLDivElement,
    valueContainer: HTMLDivElement,
    editor: HTMLDivElement,
    property: string,
  ): void {
    editor.remove();
    valueContainer.style.display = '';

    if (this.currentElement) {
      const newValue = getComputedProperty(this.currentElement, property);
      const valueEl = valueContainer.querySelector('span');
      if (valueEl) valueEl.textContent = newValue;
    }
  }

  private applyPropertyChange(
    property: string,
    fromValue: string,
    toValue: string,
    tokenName?: string,
  ): void {
    if (this.currentElement) {
      (this.currentElement as HTMLElement).style.setProperty(property, toValue);
    }
    this.propChangeCb?.(property, fromValue, toValue, tokenName);
  }

  // -------------------------------------------------------------------------
  // Multi-select CSS properties
  // -------------------------------------------------------------------------

  private buildMultiCssPropertiesSection(elements: Element[]): HTMLDivElement {
    const section = createElement('div', {}, {
      padding: '8px 10px',
    });

    const propGroups = [
      { label: 'Dimensions', props: ['width', 'height'] },
      { label: 'Spacing', props: ['padding-top', 'padding-right', 'padding-bottom', 'padding-left', 'margin-top', 'margin-right', 'margin-bottom', 'margin-left'] },
      { label: 'Typography', props: ['font-family', 'font-size', 'font-weight', 'line-height', 'color'] },
      { label: 'Background', props: ['background-color'] },
      { label: 'Position', props: ['position', 'top', 'right', 'bottom', 'left'] },
      { label: 'Border', props: ['border-radius', 'border-color', 'border-width'] },
    ];

    for (const group of propGroups) {
      const groupLabel = createText('div', group.label, 'heading');
      groupLabel.style.marginTop = '8px';
      groupLabel.style.marginBottom = '4px';
      groupLabel.style.fontSize = OVERLAY.monoSize;
      groupLabel.style.color = OVERLAY.textMuted;
      groupLabel.style.textTransform = 'uppercase';
      groupLabel.style.letterSpacing = '0.5px';
      section.appendChild(groupLabel);

      const propsGrid = createElement('div', {}, {
        display: 'grid',
        gridTemplateColumns: 'repeat(auto-fill, minmax(180px, 1fr))',
        gap: '0 16px',
      });
      for (const prop of group.props) {
        const values = elements.map((el) => getComputedProperty(el, prop));
        const allSame = values.every((v) => v === values[0]);
        const displayValue = allSame ? (values[0] ?? '') : 'Mixed';

        propsGrid.appendChild(this.buildMultiPropertyRow(prop, displayValue, !allSame, elements));
      }
      section.appendChild(propsGrid);
    }

    return section;
  }

  private buildMultiPropertyRow(
    name: string,
    value: string,
    isMixed: boolean,
    elements: Element[],
  ): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'center',
      padding: '2px 0',
      gap: '8px',
    });

    const nameEl = createText('span', name, 'mono');
    nameEl.style.color = OVERLAY.textMuted;
    nameEl.style.flexShrink = '0';
    row.appendChild(nameEl);

    const valueContainer = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
      overflow: 'hidden',
      cursor: 'pointer',
      pointerEvents: 'auto',
    });

    const valueEl = createText('span', value, 'mono');
    valueEl.style.textOverflow = 'ellipsis';
    valueEl.style.overflow = 'hidden';
    valueEl.style.whiteSpace = 'nowrap';
    if (isMixed) {
      valueEl.style.fontStyle = 'italic';
      valueEl.style.color = OVERLAY.textMuted;
    }
    valueContainer.appendChild(valueEl);

    if (!isMixed) {
      const token = this.resolveToken(name, value);
      if (token) {
        const badge = createElement('span', {}, {
          background: 'rgba(6, 182, 212, 0.2)',
          color: OVERLAY.primary,
          padding: '1px 4px',
          borderRadius: '2px',
          fontSize: '10px',
          fontFamily: OVERLAY.monoFamily,
          whiteSpace: 'nowrap',
          flexShrink: '0',
        });
        badge.textContent = token.name;
        valueContainer.appendChild(badge);
      }
    }

    valueContainer.addEventListener('click', () => {
      this.openMultiInlineEditor(row, valueContainer, name, value, elements);
    });

    valueContainer.addEventListener('mouseenter', () => {
      valueEl.style.textDecoration = 'underline';
      valueEl.style.textDecorationStyle = 'dotted';
    });
    valueContainer.addEventListener('mouseleave', () => {
      valueEl.style.textDecoration = '';
    });

    row.appendChild(valueContainer);
    return row;
  }

  private openMultiInlineEditor(
    row: HTMLDivElement,
    valueContainer: HTMLDivElement,
    property: string,
    currentValue: string,
    elements: Element[],
  ): void {
    const editor = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '4px',
      flex: '1',
      pointerEvents: 'auto',
    });

    const tokens = this.tokenStore.getForProperty(property);

    if (tokens.length > 0) {
      const select = createElement('select', {}, {
        background: 'rgba(255, 255, 255, 0.1)',
        color: OVERLAY.text,
        border: `1px solid ${OVERLAY.primary}`,
        borderRadius: OVERLAY.radiusSm,
        padding: '2px 4px',
        fontSize: OVERLAY.monoSize,
        fontFamily: OVERLAY.monoFamily,
        pointerEvents: 'auto',
        cursor: 'pointer',
        width: '100%',
      }) as HTMLSelectElement;

      const customOpt = document.createElement('option');
      customOpt.value = '__custom__';
      customOpt.textContent = 'Custom value...';
      select.appendChild(customOpt);

      let hasMatch = false;
      for (const t of tokens) {
        const opt = document.createElement('option');
        opt.value = t.value;
        opt.textContent = `${t.name} (${t.value})`;
        if (t.value === currentValue) {
          opt.selected = true;
          hasMatch = true;
        }
        select.appendChild(opt);
      }

      if (!hasMatch && currentValue !== 'Mixed') {
        const currentOpt = document.createElement('option');
        currentOpt.value = currentValue;
        currentOpt.textContent = `${currentValue} (current)`;
        currentOpt.selected = true;
        select.insertBefore(currentOpt, customOpt.nextSibling);
      }

      select.addEventListener('change', () => {
        if (select.value === '__custom__') {
          select.style.display = 'none';
          freeform.style.display = '';
          freeform.focus();
          return;
        }
        const newValue = select.value;
        const selectedToken = tokens.find((t) => t.value === newValue);
        this.applyMultiPropertyChange(property, newValue, elements, selectedToken?.name);
        this.closeMultiInlineEditor(row, valueContainer, editor, property, elements);
      });

      editor.appendChild(select);
    }

    const freeform = createElement('input', {
      type: 'text',
      value: currentValue === 'Mixed' ? '' : currentValue,
      placeholder: currentValue === 'Mixed' ? 'Set value for all\u2026' : '',
    }, {
      background: 'rgba(255, 255, 255, 0.1)',
      color: OVERLAY.text,
      border: `1px solid ${OVERLAY.primary}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '2px 4px',
      fontSize: OVERLAY.monoSize,
      fontFamily: OVERLAY.monoFamily,
      width: '100%',
      pointerEvents: 'auto',
      display: tokens.length > 0 ? 'none' : '',
    }) as HTMLInputElement;

    freeform.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        const newValue = freeform.value.trim();
        if (newValue) {
          this.applyMultiPropertyChange(property, newValue, elements);
        }
        this.closeMultiInlineEditor(row, valueContainer, editor, property, elements);
      }
      if (e.key === 'Escape') {
        e.preventDefault();
        this.closeMultiInlineEditor(row, valueContainer, editor, property, elements);
      }
    });

    editor.appendChild(freeform);

    valueContainer.style.display = 'none';
    row.appendChild(editor);

    if (tokens.length > 0) {
      (editor.querySelector('select') as HTMLSelectElement)?.focus();
    } else {
      freeform.focus();
      freeform.select();
    }
  }

  private closeMultiInlineEditor(
    row: HTMLDivElement,
    valueContainer: HTMLDivElement,
    editor: HTMLDivElement,
    property: string,
    elements: Element[],
  ): void {
    editor.remove();
    valueContainer.style.display = '';

    const values = elements.map((el) => getComputedProperty(el, property));
    const allSame = values.every((v) => v === values[0]);
    const valueEl = valueContainer.querySelector('span');
    if (valueEl) {
      valueEl.textContent = allSame ? (values[0] ?? '') : 'Mixed';
      valueEl.style.fontStyle = allSame ? '' : 'italic';
      valueEl.style.color = allSame ? '' : OVERLAY.textMuted;
    }
  }

  private applyMultiPropertyChange(
    property: string,
    toValue: string,
    elements: Element[],
    tokenName?: string,
  ): void {
    const changes: Array<{ element: Element; property: string; fromValue: string; toValue: string; token?: string }> = [];

    for (const el of elements) {
      const fromValue = getComputedProperty(el, property);
      (el as HTMLElement).style.setProperty(property, toValue);
      changes.push({ element: el, property, fromValue, toValue, token: tokenName });
    }

    this.multiPropChangeCb?.(changes);
  }

  // -------------------------------------------------------------------------
  // Token resolution
  // -------------------------------------------------------------------------

  private resolveToken(property: string, value: string): DesignToken | null {
    if (!this.tokenStore.loaded) return null;
    const result = this.tokenStore.resolveValue(property, value);
    if (result.token) {
      const tokens = this.tokenStore.getAll();
      return tokens.find((t) => t.name === result.token) ?? null;
    }
    return null;
  }
}
