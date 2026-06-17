import type { ElementInfo } from '@nco-studio/shared';
import { createElement, createText } from '../../../shared/ui-utils';
import { OVERLAY } from '../../../shared/constants';
import { createStyleSnapshot } from '../../../shared/dom-utils';
import type { StateSimulator } from '../../inspection/state-simulator';

type ElementSelectCallback = (element: Element) => void;
type ElementHoverCallback = (element: Element | null) => void;
type LayoutBadgeClickCallback = (element: Element, layout: string) => void;

/**
 * DOM tree pane — top of the left column.
 * Renders a collapsible tree of DOM nodes starting from document.body,
 * highlights the selected element, and fires callbacks on click/hover.
 *
 * Lifecycle: pane instances are long-lived (created in the shell constructor).
 * `dispose()` tears down DOM references only — registered callbacks survive
 * across hide/show cycles since the shell registers them once during activate().
 */
export class DomTreePane {
  private container: HTMLDivElement | null = null;
  private expandedNodes = new Set<Element>();
  private currentElement: Element | null = null;
  private elementSelectCb: ElementSelectCallback | null = null;
  private elementHoverCb: ElementHoverCallback | null = null;
  private layoutBadgeClickCb: LayoutBadgeClickCallback | null = null;
  private stateSimulator: StateSimulator | null = null;
  private attributeDetailExpanded = true;

  mount(container: HTMLDivElement): void {
    this.container = container;
  }

  /** Tear down DOM refs only — callbacks intentionally survive for remount. */
  dispose(): void {
    this.expandedNodes.clear();
    this.currentElement = null;
    this.container = null;
  }

  updateElement(el: Element, _info: ElementInfo): void {
    this.currentElement = el;
    this.attributeDetailExpanded = true;
    this.expandedNodes.clear();
    this.autoExpandAncestors(el);
    if (this.container) this.renderTree(this.container, el);
  }

  clearElement(): void {
    this.currentElement = null;
    this.expandedNodes.clear();
    if (this.container) {
      this.container.innerHTML = '';
      const empty = createText('div', 'No element selected', 'mono');
      empty.style.color = OVERLAY.textMuted;
      empty.style.padding = '8px';
      this.container.appendChild(empty);
    }
  }

  onElementSelect(cb: ElementSelectCallback): void {
    this.elementSelectCb = cb;
  }

  onElementHover(cb: ElementHoverCallback): void {
    this.elementHoverCb = cb;
  }

  onLayoutBadgeClick(cb: LayoutBadgeClickCallback): void {
    this.layoutBadgeClickCb = cb;
  }

  setStateSimulator(sim: StateSimulator): void {
    this.stateSimulator = sim;
    sim.onChange(() => this.refreshTree());
  }

  // ---------------------------------------------------------------------------
  // Tree rendering
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
    if (!this.container || !this.currentElement) return;
    this.renderTree(this.container, this.currentElement);
  }

  private renderTree(container: HTMLDivElement, selectedElement: Element): void {
    container.innerHTML = '';
    const root = document.body;
    if (!root) return;
    this.renderNode(container, root, 0, selectedElement);

    // Scroll the selected row into view (centered)
    requestAnimationFrame(() => {
      const selectedRow = container.querySelector('[data-fe-selected]');
      if (selectedRow) {
        selectedRow.scrollIntoView({ block: 'center', behavior: 'instant' });
      }
    });
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

    // Collapsible attribute detail below selected row
    if (isSelected) {
      const attrDetail = this.buildAttributeDetail(element, depth);
      if (attrDetail) container.appendChild(attrDetail);
    }

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
    const row = createElement('div', isSelected ? { 'data-fe-selected': '' } : {}, {
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

    // Status cluster (layout badge + state indicator, right-aligned)
    const statusCluster = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
      marginLeft: 'auto',
      flexShrink: '0',
    });
    const layoutBadge = this.buildLayoutBadge(element);
    if (layoutBadge) statusCluster.appendChild(layoutBadge);
    if (this.stateSimulator?.hasActiveStates(element)) {
      const dot = createElement('span', { title: 'Pseudo-state active' }, {
        width: '6px',
        height: '6px',
        borderRadius: '50%',
        background: OVERLAY.warning,
        flexShrink: '0',
        display: 'inline-block',
      });
      statusCluster.appendChild(dot);
    }
    if (statusCluster.childElementCount > 0) {
      labelArea.appendChild(statusCluster);
    }

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

  private buildLayoutBadge(element: Element): HTMLSpanElement | null {
    const snapshot = createStyleSnapshot(element);
    const display = snapshot.display;
    let label: string | null = null;
    if (display === 'flex' || display === 'inline-flex') label = 'flex';
    else if (display === 'grid' || display === 'inline-grid') label = 'grid';
    if (!label) return null;

    const badge = createElement('span', {}, {
      fontSize: '10px',
      fontFamily: OVERLAY.monoFamily,
      color: OVERLAY.textMuted,
      background: 'rgba(255, 255, 255, 0.08)',
      borderRadius: '3px',
      padding: '0 4px',
      lineHeight: '14px',
      flexShrink: '0',
      cursor: 'pointer',
      pointerEvents: 'auto',
    }) as HTMLSpanElement;
    badge.textContent = label;
    badge.addEventListener('click', (e) => {
      e.stopPropagation();
      this.layoutBadgeClickCb?.(element, label!);
    });
    return badge;
  }

  // ---------------------------------------------------------------------------
  // Collapsible attribute detail (below selected row)
  // ---------------------------------------------------------------------------

  private buildAttributeDetail(element: Element, depth: number): HTMLDivElement | null {
    const attrs = this.gatherDisplayAttributes(element);
    if (attrs.length === 0) return null;

    const wrapper = createElement('div', {}, {
      paddingLeft: `${depth * 16 + 14}px`,
      borderBottom: `1px solid ${OVERLAY.border}`,
      marginBottom: '2px',
    });

    // Toggle header
    const header = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
      padding: '2px 4px',
      cursor: 'pointer',
      pointerEvents: 'auto',
    });

    const chevron = createText('span', '\u25B6', 'mono');
    chevron.style.fontSize = '7px';
    chevron.style.display = 'inline-block';
    chevron.style.transition = 'transform 0.12s ease';
    chevron.style.color = OVERLAY.textMuted;
    if (this.attributeDetailExpanded) chevron.style.transform = 'rotate(90deg)';
    header.appendChild(chevron);

    const label = createText('span', 'ATTRIBUTES', 'mono');
    label.style.fontSize = '10px';
    label.style.color = OVERLAY.textMuted;
    label.style.letterSpacing = '0.5px';
    header.appendChild(label);

    const countBadge = createText('span', `${attrs.length}`, 'mono');
    countBadge.style.fontSize = '9px';
    countBadge.style.color = OVERLAY.textMuted;
    countBadge.style.background = 'rgba(255, 255, 255, 0.06)';
    countBadge.style.borderRadius = '3px';
    countBadge.style.padding = '0 3px';
    header.appendChild(countBadge);

    wrapper.appendChild(header);

    // Content area
    const content = createElement('div', {}, {
      display: this.attributeDetailExpanded ? 'block' : 'none',
      padding: '0 4px 4px',
    });

    for (const [key, value] of attrs) {
      content.appendChild(this.buildAttrRow(key, value));
    }

    wrapper.appendChild(content);

    header.addEventListener('click', (e) => {
      e.stopPropagation();
      this.attributeDetailExpanded = !this.attributeDetailExpanded;
      chevron.style.transform = this.attributeDetailExpanded ? 'rotate(90deg)' : '';
      content.style.display = this.attributeDetailExpanded ? 'block' : 'none';
    });

    return wrapper;
  }

  private gatherDisplayAttributes(element: Element): Array<[string, string]> {
    const priorityKeys = ['id', 'class', 'role', 'src', 'href', 'alt', 'type', 'name', 'placeholder'];
    const result: Array<[string, string]> = [];
    const seen = new Set<string>();

    // Priority attributes first
    for (const key of priorityKeys) {
      if (element.hasAttribute(key)) {
        const val = element.getAttribute(key) ?? '';
        if (key === 'style') continue;
        result.push([key, val]);
        seen.add(key);
      }
    }

    // data-* and aria-* (excluding internal data-source-*)
    for (const attr of element.attributes) {
      if (seen.has(attr.name)) continue;
      if (attr.name === 'style') continue;
      if (attr.name.startsWith('data-source-')) continue;
      if (attr.name.startsWith('data-') || attr.name.startsWith('aria-')) {
        result.push([attr.name, attr.value]);
        seen.add(attr.name);
      }
    }

    // Remaining attributes
    for (const attr of element.attributes) {
      if (seen.has(attr.name)) continue;
      if (attr.name === 'style') continue;
      result.push([attr.name, attr.value]);
      seen.add(attr.name);
    }

    return result;
  }

  private buildAttrRow(key: string, value: string): HTMLDivElement {
    const MAX_LEN = 60;
    const truncated = value.length > MAX_LEN;
    const displayValue = truncated ? value.slice(0, MAX_LEN) + '\u2026' : value;

    const row = createElement('div', {
      ...(truncated ? { title: `${key}="${value}"` } : {}),
    }, {
      display: 'flex',
      alignItems: 'baseline',
      gap: '2px',
      padding: '1px 0',
      fontSize: '10px',
      fontFamily: OVERLAY.monoFamily,
      cursor: 'pointer',
      pointerEvents: 'auto',
      borderRadius: '2px',
    });

    const keyEl = createText('span', key, 'mono');
    keyEl.style.color = OVERLAY.primary;
    keyEl.style.fontSize = '10px';
    keyEl.style.flexShrink = '0';
    row.appendChild(keyEl);

    const eq = createText('span', '=', 'mono');
    eq.style.color = OVERLAY.textMuted;
    eq.style.fontSize = '10px';
    row.appendChild(eq);

    const valEl = createText('span', `"${displayValue}"`, 'mono');
    valEl.style.color = OVERLAY.text;
    valEl.style.fontSize = '10px';
    valEl.style.overflow = 'hidden';
    valEl.style.textOverflow = 'ellipsis';
    valEl.style.whiteSpace = 'nowrap';
    row.appendChild(valEl);

    // Hover effect
    row.addEventListener('mouseenter', () => {
      row.style.background = 'rgba(255, 255, 255, 0.06)';
    });
    row.addEventListener('mouseleave', () => {
      row.style.background = 'transparent';
    });

    // Click-to-copy
    row.addEventListener('click', (e) => {
      e.stopPropagation();
      const copyText = `${key}="${value}"`;
      navigator.clipboard.writeText(copyText).then(() => {
        // Green flash confirmation
        row.style.background = 'rgba(34, 197, 94, 0.15)';
        setTimeout(() => { row.style.background = 'transparent'; }, 300);
      }).catch(() => {
        // Silent fail
      });
    });

    return row;
  }
}
