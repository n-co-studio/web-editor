import type { ElementInfo, DesignToken, PropertyChange } from '@frontend-editor/shared';
import { createElement, createText, createButton, makeDraggable } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY, PANEL_MAX_WIDTH, SELECTOR_TRUNCATE_LENGTH } from '../../shared/constants';
import type { PanelPosition } from '../../shared/types';
import type { TokenStore } from '../tokens/store';

type PropertyChangeCallback = (property: string, fromValue: string, toValue: string, token?: string) => void;
type ElementSelectCallback = (element: Element) => void;

const PANEL_STORAGE_KEY = 'frontend-editor-panel-position';

/**
 * Floating property panel that displays computed styles for the selected element.
 * Draggable, positioned right-side by default, persists position in chrome.storage.session.
 */
export class PropertyPanel {
  private container: HTMLDivElement | null = null;
  private visible = false;
  private collapsed = false;
  private closeCb: (() => void) | null = null;
  private propChangeCb: PropertyChangeCallback | null = null;
  private multiPropChangeCb: ((changes: Array<{ element: Element; property: string; fromValue: string; toValue: string; token?: string }>) => void) | null = null;
  private elementSelectCb: ElementSelectCallback | null = null;
  private currentElement: Element | null = null;
  private currentElements: Element[] | null = null;
  private panelBody: HTMLDivElement | null = null;
  private propsSection: HTMLDivElement | null = null;
  private treeSection: HTMLDivElement | null = null;
  private treeBox: HTMLDivElement | null = null;
  private expandedNodes = new Set<Element>();
  private logEntries: Array<{ level: 'info' | 'warn' | 'error'; text: string; time: number }> = [];
  private logContainer: HTMLDivElement | null = null;
  private logVisible = false;
  private treeExpanded = true;
  private static readonly MAX_LOG_ENTRIES = 50;

  constructor(
    private readonly shadow: ShadowRoot,
    private readonly tokenStore: TokenStore,
  ) {}

  onClose(cb: () => void): void {
    this.closeCb = cb;
  }

  onPropertyChange(cb: PropertyChangeCallback): void {
    this.propChangeCb = cb;
  }

  /** Register a callback for when the user selects an element from the DOM tree. */
  onElementSelect(cb: ElementSelectCallback): void {
    this.elementSelectCb = cb;
  }

  /** Register a callback for when a shared property is edited in multi-select mode. */
  onMultiPropertyChange(cb: (changes: Array<{ element: Element; property: string; fromValue: string; toValue: string; token?: string }>) => void): void {
    this.multiPropChangeCb = cb;
  }

  /** Add a log entry to the embedded console. Also logs to the real console. */
  log(text: string, level: 'info' | 'warn' | 'error' = 'info'): void {
    const prefix = '[frontend-editor]';
    if (level === 'error') console.error(prefix, text);
    else if (level === 'warn') console.warn(prefix, text);
    else console.log(prefix, text);

    this.logEntries.push({ level, text, time: Date.now() });
    if (this.logEntries.length > PropertyPanel.MAX_LOG_ENTRIES) {
      this.logEntries.shift();
    }
    this.refreshLogDisplay();
  }

  isVisible(): boolean {
    return this.visible;
  }

  async show(info: ElementInfo, element: Element): Promise<void> {
    this.hide();
    this.currentElement = element;

    const panel = this.buildPanel(info, element);
    this.container = panel;
    this.shadow.appendChild(panel);
    this.visible = true;

    // Restore saved position or use default
    const savedPos = await this.loadPosition();
    if (savedPos) {
      panel.style.left = `${savedPos.x}px`;
      panel.style.top = `${savedPos.y}px`;
      panel.style.right = 'auto';
    }
  }

  /** Show shared properties for multiple selected elements. */
  async showMultiSelect(elements: Element[]): Promise<void> {
    this.hide();
    this.currentElements = elements;
    this.currentElement = elements[0] ?? null;

    const panel = this.buildMultiSelectPanel(elements);
    this.container = panel;
    this.shadow.appendChild(panel);
    this.visible = true;

    const savedPos = await this.loadPosition();
    if (savedPos) {
      panel.style.left = `${savedPos.x}px`;
      panel.style.top = `${savedPos.y}px`;
      panel.style.right = 'auto';
    }
  }

  hide(): void {
    if (this.container) {
      this.container.remove();
      this.container = null;
    }
    this.visible = false;
    this.currentElement = null;
    this.currentElements = null;
    this.panelBody = null;
    this.propsSection = null;
    this.treeSection = null;
    this.treeBox = null;
  }

  /** Toggle panel visibility without destroying it (used by toolbar toggle). */
  setVisible(visible: boolean): void {
    if (!this.container) return;
    this.container.style.display = visible ? '' : 'none';
  }

  /** Re-read computed styles and rebuild the properties section in-place. */
  refreshProperties(): void {
    if (!this.container || !this.currentElement || !this.propsSection) return;
    const newSection = this.buildPropertiesSection(this.currentElement);
    this.propsSection.replaceWith(newSection);
    this.propsSection = newSection;
  }

  showStaleWarning(): void {
    if (!this.container) return;
    const warning = createElement('div', {}, {
      background: OVERLAY.warning,
      color: '#000',
      padding: '6px 8px',
      fontSize: OVERLAY.bodySize,
      fontFamily: OVERLAY.fontFamily,
      borderRadius: OVERLAY.radiusSm,
      marginTop: '8px',
    });
    warning.textContent = 'Element no longer in DOM';
    this.container.appendChild(warning);
  }

  // -----------------------------------------------------------------------
  // Panel construction
  // -----------------------------------------------------------------------

  private buildPanel(info: ElementInfo, element: Element): HTMLDivElement {
    const panel = createElement('div', { role: 'dialog', 'aria-label': 'Property panel' }, {
      position: 'fixed',
      top: '16px',
      right: '16px',
      width: `${PANEL_MAX_WIDTH}px`,
      maxHeight: `${window.innerHeight - 32}px`,
      overflowY: 'auto',
      background: OVERLAY.bg,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusMd,
      boxShadow: OVERLAY.shadowLg,
      pointerEvents: 'auto',
      zIndex: '100',
      fontFamily: OVERLAY.fontFamily,
    });

    // Header (draggable, with collapse toggle + close)
    const header = this.buildHeader(info, panel);
    panel.appendChild(header);

    // Collapsible body wrapper
    const body = createElement('div', {}, {
      display: this.collapsed ? 'none' : '',
    });
    this.panelBody = body;

    // DOM tree explorer
    this.treeSection = this.buildTreeSection(element);
    body.appendChild(this.treeSection);

    // Source info
    const sourceSection = this.buildSourceSection(info);
    body.appendChild(sourceSection);

    // Computed properties
    this.propsSection = this.buildPropertiesSection(element);
    body.appendChild(this.propsSection);

    // Console log viewer
    const consoleSection = this.buildConsoleSection();
    body.appendChild(consoleSection);

    panel.appendChild(body);

    // Responsive: use compact/standard breakpoint
    if (window.innerWidth < OVERLAY.compactBreakpoint) {
      // Bottom sheet mode
      panel.style.top = 'auto';
      panel.style.right = '0';
      panel.style.bottom = '0';
      panel.style.left = '0';
      panel.style.width = '100%';
      panel.style.maxHeight = '50vh';
      panel.style.borderRadius = `${OVERLAY.radiusMd} ${OVERLAY.radiusMd} 0 0`;
    }

    return panel;
  }

  private buildMultiSelectPanel(elements: Element[]): HTMLDivElement {
    const panel = createElement('div', { role: 'dialog', 'aria-label': 'Multi-select properties' }, {
      position: 'fixed',
      top: '16px',
      right: '16px',
      width: `${PANEL_MAX_WIDTH}px`,
      maxHeight: `${window.innerHeight - 32}px`,
      overflowY: 'auto',
      background: OVERLAY.bg,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusMd,
      boxShadow: OVERLAY.shadowLg,
      pointerEvents: 'auto',
      zIndex: '100',
      fontFamily: OVERLAY.fontFamily,
    });

    // Header
    const header = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      padding: '8px 12px',
      borderBottom: `1px solid ${OVERLAY.border}`,
      background: 'rgba(59, 130, 246, 0.08)',
      cursor: 'grab',
      gap: '6px',
    });

    makeDraggable(header, panel, (pos) => this.savePosition(pos));

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

    const closeBtn = createButton('\u00d7', 'ghost', () => {
      this.hide();
      this.closeCb?.();
    });
    closeBtn.style.padding = '2px 6px';
    closeBtn.style.fontSize = '14px';
    closeBtn.style.flexShrink = '0';
    header.appendChild(closeBtn);

    panel.appendChild(header);

    // Collapsible body
    const body = createElement('div', {}, {
      display: this.collapsed ? 'none' : '',
    });
    this.panelBody = body;

    // Properties section — shared properties
    this.propsSection = this.buildMultiPropertiesSection(elements);
    body.appendChild(this.propsSection);

    // Console
    const consoleSection = this.buildConsoleSection();
    body.appendChild(consoleSection);

    panel.appendChild(body);

    // Responsive
    if (window.innerWidth < OVERLAY.compactBreakpoint) {
      panel.style.top = 'auto';
      panel.style.right = '0';
      panel.style.bottom = '0';
      panel.style.left = '0';
      panel.style.width = '100%';
      panel.style.maxHeight = '50vh';
      panel.style.borderRadius = `${OVERLAY.radiusMd} ${OVERLAY.radiusMd} 0 0`;
    }

    return panel;
  }

  private buildMultiPropertiesSection(elements: Element[]): HTMLDivElement {
    const section = createElement('div', {}, {
      padding: '8px 12px',
      borderBottom: `1px solid ${OVERLAY.border}`,
    });

    const propNames = [
      { label: 'Dimensions', props: ['width', 'height'] },
      { label: 'Spacing', props: ['padding-top', 'padding-right', 'padding-bottom', 'padding-left', 'margin-top', 'margin-right', 'margin-bottom', 'margin-left'] },
      { label: 'Typography', props: ['font-family', 'font-size', 'font-weight', 'line-height', 'color'] },
      { label: 'Background', props: ['background-color'] },
      { label: 'Position', props: ['position', 'top', 'right', 'bottom', 'left'] },
      { label: 'Border', props: ['border-radius', 'border-color', 'border-width'] },
    ];

    for (const group of propNames) {
      const groupLabel = createText('div', group.label, 'heading');
      groupLabel.style.marginTop = '8px';
      groupLabel.style.marginBottom = '4px';
      groupLabel.style.fontSize = OVERLAY.monoSize;
      groupLabel.style.color = OVERLAY.textMuted;
      groupLabel.style.textTransform = 'uppercase';
      groupLabel.style.letterSpacing = '0.5px';
      section.appendChild(groupLabel);

      for (const prop of group.props) {
        const values = elements.map((el) => getComputedProperty(el, prop));
        const allSame = values.every((v) => v === values[0]);
        const displayValue = allSame ? values[0] : 'Mixed';

        const row = this.buildMultiPropertyRow(prop, displayValue, !allSame, elements);
        section.appendChild(row);
      }
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

    // Token badge (only when all same)
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

    // Click to edit (applies to all elements)
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
      placeholder: currentValue === 'Mixed' ? 'Set value for all…' : '',
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

    // Update displayed value
    const values = elements.map((el) => getComputedProperty(el, property));
    const allSame = values.every((v) => v === values[0]);
    const valueEl = valueContainer.querySelector('span');
    if (valueEl) {
      valueEl.textContent = allSame ? values[0] : 'Mixed';
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

  private buildHeader(info: ElementInfo, panel: HTMLDivElement): HTMLDivElement {
    const header = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      padding: '8px 12px',
      borderBottom: `1px solid ${OVERLAY.border}`,
      cursor: 'grab',
      gap: '6px',
    });

    // Collapse toggle chevron
    const chevron = createText('span', '\u25BC', 'mono');
    chevron.style.fontSize = '8px';
    chevron.style.color = OVERLAY.textMuted;
    chevron.style.transition = 'transform 0.15s ease';
    chevron.style.cursor = 'pointer';
    chevron.style.flexShrink = '0';
    if (this.collapsed) chevron.style.transform = 'rotate(-90deg)';

    const collapseBtn = createElement('button', { title: 'Collapse panel' }, {
      background: 'transparent',
      border: 'none',
      padding: '2px 4px',
      cursor: 'pointer',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      pointerEvents: 'auto',
      flexShrink: '0',
    }) as HTMLButtonElement;
    collapseBtn.appendChild(chevron);
    collapseBtn.addEventListener('click', () => {
      this.collapsed = !this.collapsed;
      chevron.style.transform = this.collapsed ? 'rotate(-90deg)' : '';
      if (this.panelBody) {
        this.panelBody.style.display = this.collapsed ? 'none' : '';
      }
    });
    header.appendChild(collapseBtn);

    const title = createText('span', `<${info.tagName}>`, 'heading');
    title.style.flex = '1';
    header.appendChild(title);

    const closeBtn = createButton('\u00d7', 'ghost', () => {
      if (this.closeCb) {
        this.closeCb(); // Triggers deselect flow which calls hide()
      } else {
        this.hide();
      }
    });
    closeBtn.style.padding = '2px 6px';
    closeBtn.style.fontSize = '16px';
    closeBtn.style.flexShrink = '0';
    header.appendChild(closeBtn);

    // Make panel draggable via header
    makeDraggable(header, panel, (pos) => this.savePosition(pos));

    return header;
  }

  private buildSourceSection(info: ElementInfo): HTMLDivElement {
    const section = createElement('div', {}, {
      padding: '8px 12px',
      borderBottom: `1px solid ${OVERLAY.border}`,
    });

    if (info.sourceFile) {
      const fileLine = createText(
        'div',
        `${info.sourceFile}:${info.sourceLine}`,
        'mono',
      );
      fileLine.style.color = OVERLAY.textMuted;
      section.appendChild(fileLine);
    } else {
      // Source unverified warning
      const warning = createElement('div', {}, {
        background: 'rgba(245, 158, 11, 0.15)',
        border: `1px solid ${OVERLAY.warning}`,
        borderRadius: OVERLAY.radiusSm,
        padding: '4px 8px',
        fontSize: OVERLAY.bodySize,
        color: OVERLAY.warning,
        fontFamily: OVERLAY.fontFamily,
      });
      warning.textContent =
        'Source mapping unavailable — install the dev-plugin for precise file targeting.';
      section.appendChild(warning);
    }

    // Selector
    const selectorText =
      info.selector.length > SELECTOR_TRUNCATE_LENGTH
        ? info.selector.slice(0, SELECTOR_TRUNCATE_LENGTH) + '\u2026'
        : info.selector;
    const selector = createText('div', selectorText, 'mono');
    selector.style.color = OVERLAY.textMuted;
    selector.style.marginTop = '4px';
    selector.title = info.selector; // full selector in tooltip
    section.appendChild(selector);

    return section;
  }

  private buildPropertiesSection(element: Element): HTMLDivElement {
    const section = createElement('div', {}, {
      padding: '8px 12px',
      borderBottom: `1px solid ${OVERLAY.border}`,
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

      for (const prop of group.props) {
        const row = this.buildPropertyRow(prop.name, prop.value);
        section.appendChild(row);
      }
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

    // Token badge if tokens loaded
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

    // Click to edit
    valueContainer.addEventListener('click', () => {
      this.openInlineEditor(row, valueContainer, name, value);
    });

    // Hover hint
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
   * Shows a token dropdown if tokens are available for this property,
   * plus a freeform text input.
   */
  private openInlineEditor(
    row: HTMLDivElement,
    valueContainer: HTMLDivElement,
    property: string,
    currentValue: string,
  ): void {
    // Build editor container
    const editor = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '4px',
      flex: '1',
      pointerEvents: 'auto',
    });

    // Get tokens for this property
    const tokens = this.tokenStore.getForProperty(property);

    if (tokens.length > 0) {
      // Token select dropdown
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

      // Custom value option
      const customOpt = document.createElement('option');
      customOpt.value = '__custom__';
      customOpt.textContent = 'Custom value...';
      select.appendChild(customOpt);

      // Token options
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

      // Current value option if no token match
      if (!hasMatch) {
        const currentOpt = document.createElement('option');
        currentOpt.value = currentValue;
        currentOpt.textContent = `${currentValue} (current)`;
        currentOpt.selected = true;
        select.insertBefore(currentOpt, customOpt.nextSibling);
      }

      select.addEventListener('change', () => {
        if (select.value === '__custom__') {
          // Show freeform input
          select.style.display = 'none';
          freeform.style.display = '';
          freeform.focus();
          return;
        }
        // Apply token value and live preview
        const newValue = select.value;
        const selectedToken = tokens.find((t) => t.value === newValue);
        this.applyPropertyChange(property, currentValue, newValue, selectedToken?.name);
        this.closeInlineEditor(row, valueContainer, editor, property);
      });

      editor.appendChild(select);
    }

    // Freeform text input
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

    // Swap value display with editor
    valueContainer.style.display = 'none';
    row.appendChild(editor);

    // Focus the visible input
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

    // Update the displayed value to the current computed value
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
    // Apply live preview
    if (this.currentElement) {
      (this.currentElement as HTMLElement).style.setProperty(property, toValue);
    }
    // Notify the change callback
    this.propChangeCb?.(property, fromValue, toValue, tokenName);
  }

  // -----------------------------------------------------------------------
  // DOM tree explorer
  // -----------------------------------------------------------------------

  private buildTreeSection(element: Element): HTMLDivElement {
    const section = createElement('div', {}, {
      borderBottom: `1px solid ${OVERLAY.border}`,
    });

    // Toggle bar
    const toggle = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      padding: '6px 12px',
      cursor: 'pointer',
      pointerEvents: 'auto',
    });

    const label = createText('span', 'Layers', 'mono');
    label.style.color = OVERLAY.textMuted;
    label.style.fontSize = '10px';
    label.style.textTransform = 'uppercase';
    label.style.letterSpacing = '0.5px';
    toggle.appendChild(label);

    const arrow = createText('span', '\u25B6', 'mono');
    arrow.style.color = OVERLAY.textMuted;
    arrow.style.fontSize = '10px';
    arrow.style.transition = 'transform 0.15s ease';
    if (this.treeExpanded) arrow.style.transform = 'rotate(90deg)';
    toggle.appendChild(arrow);

    // Tree container
    const treeBox = createElement('div', {}, {
      maxHeight: '240px',
      overflowY: 'auto',
      padding: '0 4px 8px',
      display: this.treeExpanded ? 'block' : 'none',
      fontFamily: OVERLAY.monoFamily,
      fontSize: '11px',
    });
    this.treeBox = treeBox;

    // Auto-expand ancestor chain so the selected element is visible
    this.autoExpandAncestors(element);
    this.renderTree(treeBox, element);

    toggle.addEventListener('click', () => {
      this.treeExpanded = !this.treeExpanded;
      treeBox.style.display = this.treeExpanded ? 'block' : 'none';
      arrow.style.transform = this.treeExpanded ? 'rotate(90deg)' : '';
    });

    section.appendChild(toggle);
    section.appendChild(treeBox);
    return section;
  }

  /** Expand all ancestors of the selected element so it's visible in the tree. */
  private autoExpandAncestors(element: Element): void {
    let current: Element | null = element.parentElement;
    while (current && current !== document.documentElement) {
      this.expandedNodes.add(current);
      current = current.parentElement;
    }
    // Also expand the selected element itself to show its children
    if (element.children.length > 0) {
      this.expandedNodes.add(element);
    }
  }

  /** Re-render the entire tree. Called after expand/collapse toggle. */
  private refreshTree(): void {
    if (!this.treeBox || !this.currentElement) return;
    this.renderTree(this.treeBox, this.currentElement);
  }

  /** Render the full tree starting from body, recursively showing expanded nodes. */
  private renderTree(container: HTMLDivElement, selectedElement: Element): void {
    container.innerHTML = '';

    // Find the root (body)
    const root = document.body;
    if (!root) return;

    this.renderNode(container, root, 0, selectedElement);
  }

  /** Recursively render a tree node and its children if expanded. */
  private renderNode(
    container: HTMLDivElement,
    element: Element,
    depth: number,
    selectedElement: Element,
  ): void {
    const isSelected = element === selectedElement;
    const hasChildren = element.children.length > 0;
    const isExpanded = this.expandedNodes.has(element);

    // Render the row
    const row = this.buildTreeRow(element, depth, isSelected, hasChildren, isExpanded);
    container.appendChild(row);

    // Render children if expanded
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
        more.style.paddingLeft = `${(depth + 1) * 16 + 18}px`;
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

    // Chevron (expand/collapse) or spacer
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
        if (this.expandedNodes.has(element)) {
          this.expandedNodes.delete(element);
        } else {
          this.expandedNodes.add(element);
        }
        this.refreshTree();
      });

      row.appendChild(chevronBtn);
    } else {
      // Spacer matching chevron width
      const spacer = createElement('span', {}, {
        width: '14px',
        flexShrink: '0',
        display: 'inline-block',
      });
      row.appendChild(spacer);
    }

    // Clickable label area (tag + descriptor)
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

    // Tag name
    const tag = element.tagName.toLowerCase();
    const tagEl = createText('span', tag, 'mono');
    tagEl.style.color = isSelected ? OVERLAY.primary : OVERLAY.text;
    tagEl.style.fontSize = '11px';
    tagEl.style.flexShrink = '0';
    labelArea.appendChild(tagEl);

    // Class/ID descriptor
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

    // Click label → select this element
    if (!isSelected) {
      labelArea.addEventListener('mouseenter', () => {
        row.style.background = 'rgba(255, 255, 255, 0.06)';
      });
      labelArea.addEventListener('mouseleave', () => {
        row.style.background = 'transparent';
      });
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

    if (element.id) {
      parts.push(`#${element.id}`);
    }

    const classes = Array.from(element.classList).slice(0, 3);
    for (const cls of classes) {
      if (cls.length <= 30) {
        parts.push(`.${cls}`);
      }
    }

    return parts.join('');
  }

  // -----------------------------------------------------------------------
  // Console section
  // -----------------------------------------------------------------------

  private buildConsoleSection(): HTMLDivElement {
    const section = createElement('div', {}, {
      borderTop: `1px solid ${OVERLAY.border}`,
    });

    // Toggle bar
    const toggle = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      padding: '6px 12px',
      cursor: 'pointer',
      pointerEvents: 'auto',
    });

    const label = createText('span', 'Console', 'mono');
    label.style.color = OVERLAY.textMuted;
    label.style.fontSize = '10px';
    label.style.textTransform = 'uppercase';
    label.style.letterSpacing = '0.5px';
    toggle.appendChild(label);

    const arrow = createText('span', '\u25B6', 'mono');
    arrow.style.color = OVERLAY.textMuted;
    arrow.style.fontSize = '10px';
    arrow.style.transition = 'transform 0.15s ease';
    toggle.appendChild(arrow);

    // Log container (initially hidden)
    const logBox = createElement('div', {}, {
      maxHeight: '150px',
      overflowY: 'auto',
      padding: '0 12px 8px',
      display: 'none',
      fontFamily: OVERLAY.monoFamily,
      fontSize: '11px',
    });
    this.logContainer = logBox;

    toggle.addEventListener('click', () => {
      this.logVisible = !this.logVisible;
      logBox.style.display = this.logVisible ? 'block' : 'none';
      arrow.style.transform = this.logVisible ? 'rotate(90deg)' : '';
      if (this.logVisible) this.refreshLogDisplay();
    });

    section.appendChild(toggle);
    section.appendChild(logBox);

    return section;
  }

  private refreshLogDisplay(): void {
    if (!this.logContainer || !this.logVisible) return;

    // Clear existing entries
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

      const colorMap = {
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

    // Auto-scroll to bottom
    this.logContainer.scrollTop = this.logContainer.scrollHeight;
  }

  // -----------------------------------------------------------------------
  // Token resolution
  // -----------------------------------------------------------------------

  private resolveToken(property: string, value: string): DesignToken | null {
    if (!this.tokenStore.loaded) return null;
    const result = this.tokenStore.resolveValue(property, value);
    if (result.token) {
      const tokens = this.tokenStore.getAll();
      return tokens.find((t) => t.name === result.token) ?? null;
    }
    return null;
  }

  // -----------------------------------------------------------------------
  // Position persistence
  // -----------------------------------------------------------------------

  private async savePosition(pos: PanelPosition): Promise<void> {
    try {
      await chrome.storage.session.set({ [PANEL_STORAGE_KEY]: pos });
    } catch {
      // Non-fatal
    }
  }

  private async loadPosition(): Promise<PanelPosition | null> {
    try {
      const result = await chrome.storage.session.get(PANEL_STORAGE_KEY);
      return (result[PANEL_STORAGE_KEY] as PanelPosition) ?? null;
    } catch {
      return null;
    }
  }
}
