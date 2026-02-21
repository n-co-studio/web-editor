import type { ElementInfo } from '@frontend-editor/shared';
import { createElement, createText } from '../../../shared/ui-utils';
import { OVERLAY } from '../../../shared/constants';

type ElementSelectCallback = (element: Element) => void;
type ElementHoverCallback = (element: Element | null) => void;

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
}
