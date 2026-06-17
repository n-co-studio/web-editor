import type { PropertyChange } from '@nco-studio/shared';
import { createElement, createText, createButton } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY, TOOLBAR_WIDTH, INSERT_INDICATOR } from '../../shared/constants';
import { computeMeasurements } from '../selection/measure-overlay';
import type { TokenStore } from '../tokens/store';
import type { PreviewManager } from './preview';
import { getGroupBlockReason } from './group';
import { getDuplicateBlockReason } from './duplicate';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

type CommitCallback = (element: Element, changes: PropertyChange[]) => void;
type GroupCallback = (elements: Element[]) => void;
type DuplicateCallback = (elements: Element[]) => void;

function extractUnit(value: string): string | undefined {
  const match = value.match(/[\d.]+(.+)$/);
  return match?.[1] || undefined;
}

/** Determine which CSS property to modify for repositioning an element. */
function getPositionProperty(element: Element, axis: 'h' | 'v'): string {
  const pos = getComputedStyle(element).position;
  if (pos === 'absolute' || pos === 'fixed' || pos === 'relative') {
    return axis === 'h' ? 'left' : 'top';
  }
  return axis === 'h' ? 'margin-left' : 'margin-top';
}

/** Read the current numeric px value of a position/margin property. */
function readPositionValue(element: Element, property: string): number {
  return parseFloat(getComputedProperty(element, property)) || 0;
}

/** Determine spacing strategy between two specific elements. */
function determineSpacingStrategy(
  elA: Element,
  elB: Element,
  direction: 'horizontal' | 'vertical',
): { target: Element; property: string } {
  const parentA = elA.parentElement;
  const parentB = elB.parentElement;

  // Siblings in flex/grid parent → adjust gap on parent
  if (parentA && parentA === parentB) {
    const parentDisplay = getComputedStyle(parentA).display;
    if (parentDisplay.includes('flex') || parentDisplay.includes('grid')) {
      return { target: parentA, property: 'gap' };
    }
  }

  // Second element is positioned → adjust left/top
  const posB = getComputedStyle(elB).position;
  if (posB !== 'static') {
    return {
      target: elB,
      property: direction === 'horizontal' ? 'left' : 'top',
    };
  }

  // Default: adjust margin on second element
  return {
    target: elB,
    property: direction === 'horizontal' ? 'margin-left' : 'margin-top',
  };
}

// ---------------------------------------------------------------------------
// Alignment SVG icons (16×16)
// ---------------------------------------------------------------------------

const ALIGN_ICONS: Record<string, string> = {
  'align-left': '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><line x1="2" y1="2" x2="2" y2="14"/><rect x="4" y="4" width="8" height="3" rx="0.5"/><rect x="4" y="9" width="5" height="3" rx="0.5"/></svg>',
  'align-center-h': '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><line x1="8" y1="2" x2="8" y2="14"/><rect x="3" y="4" width="10" height="3" rx="0.5"/><rect x="5" y="9" width="6" height="3" rx="0.5"/></svg>',
  'align-right': '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><line x1="14" y1="2" x2="14" y2="14"/><rect x="4" y="4" width="8" height="3" rx="0.5"/><rect x="7" y="9" width="5" height="3" rx="0.5"/></svg>',
  'align-top': '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><line x1="2" y1="2" x2="14" y2="2"/><rect x="4" y="4" width="3" height="8" rx="0.5"/><rect x="9" y="4" width="3" height="5" rx="0.5"/></svg>',
  'align-center-v': '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><line x1="2" y1="8" x2="14" y2="8"/><rect x="4" y="3" width="3" height="10" rx="0.5"/><rect x="9" y="5" width="3" height="6" rx="0.5"/></svg>',
  'align-bottom': '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><line x1="2" y1="14" x2="14" y2="14"/><rect x="4" y="4" width="3" height="8" rx="0.5"/><rect x="9" y="7" width="3" height="5" rx="0.5"/></svg>',
  'distribute-h': '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><line x1="2" y1="2" x2="2" y2="14"/><line x1="14" y1="2" x2="14" y2="14"/><rect x="5" y="5" width="2" height="6" rx="0.5"/><rect x="9" y="5" width="2" height="6" rx="0.5"/></svg>',
  'distribute-v': '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><line x1="2" y1="2" x2="14" y2="2"/><line x1="2" y1="14" x2="14" y2="14"/><rect x="5" y="5" width="6" height="2" rx="0.5"/><rect x="5" y="9" width="6" height="2" rx="0.5"/></svg>',
};

// ---------------------------------------------------------------------------
// MultiSelectToolbar
// ---------------------------------------------------------------------------

/**
 * Mini-panel for multi-select operations: alignment, distribution,
 * spacing, and distance editing between selected elements.
 */
export class MultiSelectToolbar {
  private container: HTMLDivElement | null = null;
  private body: HTMLDivElement | null = null;
  private closeCb: (() => void) | null = null;
  private elements: Element[] = [];
  private onCommit: CommitCallback | null = null;
  private onGroupCb: GroupCallback | null = null;
  private onDuplicateCb: DuplicateCallback | null = null;
  private groupPreview: HTMLDivElement | null = null;

  constructor(
    private readonly shadow: ShadowRoot,
    private readonly tokenStore: TokenStore,
    private readonly preview: PreviewManager,
  ) {}

  onClose(cb: () => void): void {
    this.closeCb = cb;
  }

  onGroup(cb: GroupCallback): void {
    this.onGroupCb = cb;
  }

  onDuplicate(cb: DuplicateCallback): void {
    this.onDuplicateCb = cb;
  }

  render(
    elements: Element[],
    anchorPos: { x: number; y: number },
    onCommit: CommitCallback,
  ): HTMLDivElement {
    this.cleanup();
    this.elements = elements;
    this.onCommit = onCommit;

    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - 216,
    );
    const panelTop = Math.max(8, anchorPos.y);

    const container = createElement('div', {
      role: 'dialog',
      'aria-label': 'Multi-select tools',
    }, {
      position: 'fixed',
      left: `${panelLeft}px`,
      top: `${panelTop}px`,
      width: '200px',
      background: OVERLAY.bg,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusMd,
      boxShadow: OVERLAY.shadowLg,
      pointerEvents: 'auto',
      zIndex: '102',
      fontFamily: OVERLAY.fontFamily,
      overflow: 'hidden',
      display: 'flex',
      flexDirection: 'column',
    });

    // Header
    const header = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      padding: '6px 10px',
      borderBottom: `1px solid ${OVERLAY.border}`,
      background: 'rgba(59, 130, 246, 0.08)',
      flexShrink: '0',
    });
    const title = createText('span', `${elements.length} elements`, 'heading');
    title.style.fontSize = '12px';
    title.style.color = OVERLAY.info;
    header.appendChild(title);

    const closeBtn = createButton('\u00d7', 'ghost', () => {
      this.cleanup();
      this.closeCb?.();
    });
    closeBtn.style.padding = '2px 6px';
    closeBtn.style.fontSize = '14px';
    header.appendChild(closeBtn);
    container.appendChild(header);

    // Scrollable body
    const body = createElement('div', {}, {
      padding: '8px 10px',
      display: 'flex',
      flexDirection: 'column',
      gap: '10px',
      maxHeight: '400px',
      overflowY: 'auto',
    });

    this.buildAlignmentSection(body);

    if (elements.length >= 3) {
      this.buildDistributeSection(body);
    }

    this.buildSpacingSection(body);

    if (elements.length === 2) {
      this.buildDistanceSection(body, elements[0], elements[1]);
    }

    this.buildGroupSection(body);
    this.buildDuplicateSection(body);

    container.appendChild(body);

    this.body = body;
    this.container = container;
    return container;
  }

  updateElements(elements: Element[]): void {
    this.elements = elements;
    if (!this.container) return;

    const pos = {
      x: parseFloat(this.container.style.left),
      y: parseFloat(this.container.style.top),
    };
    const parent = this.container.parentNode;
    const onCommit = this.onCommit;
    this.cleanup();
    if (parent && onCommit) {
      parent.appendChild(this.render(elements, pos, onCommit));
    }
  }

  reposition(anchorPos: { x: number; y: number }): void {
    if (!this.container) return;
    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - 216,
    );
    const panelTop = Math.max(8, anchorPos.y);
    this.container.style.left = `${panelLeft}px`;
    this.container.style.top = `${panelTop}px`;
  }

  cleanup(): void {
    this.removeGroupPreview();
    this.container?.remove();
    this.container = null;
    this.body = null;
  }

  isOpen(): boolean {
    return this.container !== null;
  }

  // -----------------------------------------------------------------------
  // Group preview overlay
  // -----------------------------------------------------------------------

  private removeGroupPreview(): void {
    this.groupPreview?.remove();
    this.groupPreview = null;
  }

  private showGroupPreview(): void {
    this.removeGroupPreview();
    if (this.elements.length < 2) return;

    // Compute union bounding rect of all selected elements
    const rects = this.elements.map((el) => el.getBoundingClientRect());
    const left = Math.min(...rects.map((r) => r.left));
    const top = Math.min(...rects.map((r) => r.top));
    const right = Math.max(...rects.map((r) => r.right));
    const bottom = Math.max(...rects.map((r) => r.bottom));

    const overlay = createElement('div', {}, {
      position: 'fixed',
      left: `${left - 2}px`,
      top: `${top - 2}px`,
      width: `${right - left + 4}px`,
      height: `${bottom - top + 4}px`,
      border: `2px dashed ${INSERT_INDICATOR.phantomBorder}`,
      borderRadius: '4px',
      pointerEvents: 'none',
      zIndex: '100',
    });

    this.groupPreview = overlay;
    this.shadow.appendChild(overlay);
  }

  // -----------------------------------------------------------------------
  // Section builders
  // -----------------------------------------------------------------------

  private buildSectionLabel(text: string): HTMLElement {
    const lbl = createText('span', text, 'body');
    lbl.style.fontSize = '10px';
    lbl.style.color = OVERLAY.textMuted;
    lbl.style.textTransform = 'uppercase';
    lbl.style.letterSpacing = '0.5px';
    lbl.style.fontWeight = '600';
    return lbl;
  }

  private buildAlignmentSection(parent: HTMLDivElement): void {
    parent.appendChild(this.buildSectionLabel('Align'));

    const grid = createElement('div', {}, {
      display: 'grid',
      gridTemplateColumns: 'repeat(6, 1fr)',
      gap: '2px',
    });

    const alignOps = [
      { key: 'align-left', title: 'Align left edges', action: () => this.alignElements('left') },
      { key: 'align-center-h', title: 'Align horizontal centers', action: () => this.alignElements('center-h') },
      { key: 'align-right', title: 'Align right edges', action: () => this.alignElements('right') },
      { key: 'align-top', title: 'Align top edges', action: () => this.alignElements('top') },
      { key: 'align-center-v', title: 'Align vertical centers', action: () => this.alignElements('center-v') },
      { key: 'align-bottom', title: 'Align bottom edges', action: () => this.alignElements('bottom') },
    ];

    for (const op of alignOps) {
      const btn = createElement('button', { title: op.title }, {
        width: '28px',
        height: '28px',
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
      });
      btn.innerHTML = ALIGN_ICONS[op.key] ?? '';
      btn.addEventListener('click', (e) => { e.stopPropagation(); op.action(); });
      btn.addEventListener('mouseenter', () => { btn.style.background = 'rgba(255, 255, 255, 0.08)'; });
      btn.addEventListener('mouseleave', () => { btn.style.background = 'transparent'; });
      grid.appendChild(btn);
    }

    parent.appendChild(grid);
  }

  private buildDistributeSection(parent: HTMLDivElement): void {
    parent.appendChild(this.buildSectionLabel('Distribute'));

    const row = createElement('div', {}, {
      display: 'flex',
      gap: '4px',
    });

    const distOps = [
      { key: 'distribute-h', title: 'Distribute horizontally', action: () => this.distributeElements('horizontal') },
      { key: 'distribute-v', title: 'Distribute vertically', action: () => this.distributeElements('vertical') },
    ];

    for (const op of distOps) {
      const btn = createElement('button', { title: op.title }, {
        flex: '1',
        height: '28px',
        border: `1px solid ${OVERLAY.border}`,
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
      });
      btn.innerHTML = ALIGN_ICONS[op.key] ?? '';
      btn.addEventListener('click', (e) => { e.stopPropagation(); op.action(); });
      btn.addEventListener('mouseenter', () => { btn.style.background = 'rgba(255, 255, 255, 0.08)'; });
      btn.addEventListener('mouseleave', () => { btn.style.background = 'transparent'; });
      row.appendChild(btn);
    }

    parent.appendChild(row);
  }

  private buildSpacingSection(parent: HTMLDivElement): void {
    parent.appendChild(this.buildSectionLabel('Spacing'));

    const row = createElement('div', {}, {
      display: 'flex',
      gap: '4px',
      alignItems: 'center',
    });

    const tokens = this.tokenStore.getForCategory('spacing');

    if (tokens.length > 0) {
      const select = createElement('select', {}, {
        background: 'rgba(255, 255, 255, 0.1)',
        color: OVERLAY.text,
        border: `1px solid ${OVERLAY.border}`,
        borderRadius: OVERLAY.radiusSm,
        padding: '4px 6px',
        fontSize: '10px',
        fontFamily: OVERLAY.monoFamily,
        pointerEvents: 'auto',
        cursor: 'pointer',
        flex: '1',
        minWidth: '0',
      }) as HTMLSelectElement;

      const placeholder = document.createElement('option');
      placeholder.value = '';
      placeholder.textContent = 'Set spacing…';
      placeholder.disabled = true;
      placeholder.selected = true;
      select.appendChild(placeholder);

      for (const token of tokens) {
        const opt = document.createElement('option');
        opt.value = token.value;
        opt.textContent = `${token.value} (${token.name})`;
        select.appendChild(opt);
      }

      select.addEventListener('change', () => {
        if (select.value) {
          this.applyUniformSpacing(parseFloat(select.value));
          // Reset to placeholder
          select.selectedIndex = 0;
        }
      });

      row.appendChild(select);
    }

    // Custom input
    const input = createElement('input', {
      type: 'number',
      placeholder: 'px',
      min: '0',
    }, {
      width: tokens.length > 0 ? '52px' : '100%',
      background: 'rgba(255, 255, 255, 0.1)',
      color: OVERLAY.text,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '4px 6px',
      fontSize: '10px',
      fontFamily: OVERLAY.monoFamily,
      pointerEvents: 'auto',
      textAlign: 'right',
      outline: 'none',
    }) as HTMLInputElement;

    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        const v = parseFloat(input.value);
        if (!isNaN(v) && v >= 0) {
          this.applyUniformSpacing(v);
          input.value = '';
        }
      }
    });

    row.appendChild(input);
    parent.appendChild(row);
  }

  private buildDistanceSection(parent: HTMLDivElement, elA: Element, elB: Element): void {
    parent.appendChild(this.buildSectionLabel('Distance'));

    const rectA = elA.getBoundingClientRect();
    const rectB = elB.getBoundingClientRect();
    const measurements = computeMeasurements(rectA, rectB);

    if (measurements.length === 0) {
      const empty = createText('span', 'Elements overlap', 'body');
      empty.style.fontSize = '10px';
      empty.style.color = OVERLAY.textMuted;
      empty.style.fontStyle = 'italic';
      parent.appendChild(empty);
      return;
    }

    const tokens = this.tokenStore.getForCategory('spacing');

    for (const m of measurements) {
      if (m.distance < 1) continue;

      const row = createElement('div', {}, {
        display: 'flex',
        gap: '4px',
        alignItems: 'center',
      });

      // Direction label
      const dirLabel = createText('span',
        m.orientation === 'horizontal' ? 'H' : 'V',
        'mono',
      );
      dirLabel.style.fontSize = '10px';
      dirLabel.style.color = OVERLAY.info;
      dirLabel.style.fontWeight = '600';
      dirLabel.style.width = '12px';
      dirLabel.style.flexShrink = '0';
      row.appendChild(dirLabel);

      if (tokens.length > 0) {
        row.appendChild(this.buildDistanceTokenSelect(
          tokens, m.distance, elA, elB, m.orientation,
        ));
      } else {
        row.appendChild(this.buildDistanceInput(
          m.distance, elA, elB, m.orientation,
        ));
      }

      parent.appendChild(row);
    }
  }

  private buildDistanceTokenSelect(
    tokens: Array<{ name: string; value: string }>,
    currentDistance: number,
    elA: Element,
    elB: Element,
    direction: 'horizontal' | 'vertical',
  ): HTMLSelectElement {
    const select = createElement('select', {}, {
      background: 'rgba(255, 255, 255, 0.1)',
      color: OVERLAY.text,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '2px 3px',
      fontSize: '10px',
      fontFamily: OVERLAY.monoFamily,
      pointerEvents: 'auto',
      cursor: 'pointer',
      flex: '1',
      minWidth: '0',
    }) as HTMLSelectElement;

    const currentStr = `${Math.round(currentDistance)}px`;
    const hasMatch = tokens.some((t) => t.value === currentStr);
    if (!hasMatch) {
      const opt = document.createElement('option');
      opt.value = currentStr;
      opt.textContent = currentStr;
      select.appendChild(opt);
    }

    for (const token of tokens) {
      const opt = document.createElement('option');
      opt.value = token.value;
      opt.textContent = `${token.value} (${token.name})`;
      if (token.value === currentStr) opt.selected = true;
      select.appendChild(opt);
    }

    select.addEventListener('change', () => {
      const newDistance = parseFloat(select.value);
      if (!isNaN(newDistance)) {
        this.applyDistanceChange(elA, elB, currentDistance, newDistance, direction);
      }
    });

    return select;
  }

  private buildDistanceInput(
    currentDistance: number,
    elA: Element,
    elB: Element,
    direction: 'horizontal' | 'vertical',
  ): HTMLInputElement {
    const input = createElement('input', {
      type: 'number',
      value: `${Math.round(currentDistance)}`,
      min: '0',
    }, {
      background: 'rgba(255, 255, 255, 0.1)',
      color: OVERLAY.text,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '2px 3px',
      fontSize: '10px',
      fontFamily: OVERLAY.monoFamily,
      pointerEvents: 'auto',
      flex: '1',
      minWidth: '0',
      textAlign: 'right',
      outline: 'none',
    }) as HTMLInputElement;

    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        const newDistance = parseFloat(input.value);
        if (!isNaN(newDistance) && newDistance >= 0) {
          this.applyDistanceChange(elA, elB, currentDistance, newDistance, direction);
        }
      }
    });

    return input;
  }

  private buildGroupSection(parent: HTMLDivElement): void {
    const blockReason = getGroupBlockReason(this.elements);

    const section = createElement('div', {}, {
      borderTop: `1px solid ${OVERLAY.border}`,
      paddingTop: '8px',
    });

    const btn = createButton('Group', 'ghost', () => {
      if (!blockReason && this.onGroupCb) {
        this.onGroupCb([...this.elements]);
      }
    });
    btn.style.width = '100%';
    btn.style.justifyContent = 'center';
    btn.style.fontSize = '11px';
    btn.style.padding = '5px 0';
    btn.style.border = `1px solid ${OVERLAY.border}`;
    btn.style.borderRadius = OVERLAY.radiusSm;

    if (blockReason) {
      btn.style.opacity = '0.4';
      btn.style.cursor = 'not-allowed';
      btn.style.pointerEvents = 'none';
      btn.title = blockReason;
    } else {
      btn.title = 'Wrap selected elements in a flex container (⌘G)';
      btn.addEventListener('mouseenter', () => this.showGroupPreview());
      btn.addEventListener('mouseleave', () => this.removeGroupPreview());
    }

    section.appendChild(btn);
    parent.appendChild(section);
  }

  private buildDuplicateSection(parent: HTMLDivElement): void {
    // Disabled only when NO selected element can be duplicated; if some are
    // blocked (e.g. direct children of <body>), the valid ones still duplicate
    // and the blocked ones are skipped by the handler.
    const allBlocked =
      this.elements.length > 0 &&
      this.elements.every((el) => getDuplicateBlockReason(el) !== null);

    const section = createElement('div', {}, {
      borderTop: `1px solid ${OVERLAY.border}`,
      paddingTop: '8px',
    });

    const btn = createButton('Duplicate all', 'ghost', () => {
      if (!allBlocked && this.onDuplicateCb) {
        this.onDuplicateCb([...this.elements]);
      }
    });
    btn.style.width = '100%';
    btn.style.justifyContent = 'center';
    btn.style.fontSize = '11px';
    btn.style.padding = '5px 0';
    btn.style.border = `1px solid ${OVERLAY.border}`;
    btn.style.borderRadius = OVERLAY.radiusSm;

    if (allBlocked) {
      btn.style.opacity = '0.4';
      btn.style.cursor = 'not-allowed';
      btn.style.pointerEvents = 'none';
      btn.title = 'These elements cannot be duplicated';
    } else {
      btn.title = 'Duplicate each selected element in place (⌘D)';
    }

    section.appendChild(btn);
    parent.appendChild(section);
  }

  // -----------------------------------------------------------------------
  // Actions
  // -----------------------------------------------------------------------

  private alignElements(alignment: string): void {
    if (this.elements.length < 2 || !this.onCommit) return;

    const rects = this.elements.map((el) => ({
      el,
      rect: el.getBoundingClientRect(),
    }));

    // Compute target value based on alignment type
    let targetValue: number;

    switch (alignment) {
      case 'left':
        targetValue = Math.min(...rects.map((r) => r.rect.left));
        break;
      case 'center-h': {
        const minLeft = Math.min(...rects.map((r) => r.rect.left));
        const maxRight = Math.max(...rects.map((r) => r.rect.right));
        targetValue = (minLeft + maxRight) / 2;
        break;
      }
      case 'right':
        targetValue = Math.max(...rects.map((r) => r.rect.right));
        break;
      case 'top':
        targetValue = Math.min(...rects.map((r) => r.rect.top));
        break;
      case 'center-v': {
        const minTop = Math.min(...rects.map((r) => r.rect.top));
        const maxBottom = Math.max(...rects.map((r) => r.rect.bottom));
        targetValue = (minTop + maxBottom) / 2;
        break;
      }
      case 'bottom':
        targetValue = Math.max(...rects.map((r) => r.rect.bottom));
        break;
      default:
        return;
    }

    const isHorizontal = ['left', 'center-h', 'right'].includes(alignment);

    for (const { el, rect } of rects) {
      let currentEdge: number;
      switch (alignment) {
        case 'left': currentEdge = rect.left; break;
        case 'center-h': currentEdge = (rect.left + rect.right) / 2; break;
        case 'right': currentEdge = rect.right; break;
        case 'top': currentEdge = rect.top; break;
        case 'center-v': currentEdge = (rect.top + rect.bottom) / 2; break;
        case 'bottom': currentEdge = rect.bottom; break;
        default: continue;
      }

      const delta = targetValue - currentEdge;
      if (Math.abs(delta) < 0.5) continue; // already aligned

      const property = getPositionProperty(el, isHorizontal ? 'h' : 'v');
      const fromValue = getComputedProperty(el, property);
      const currentNum = parseFloat(fromValue) || 0;
      const newValue = `${currentNum + delta}px`;

      this.preview.begin(el as HTMLElement);
      this.preview.apply(property, newValue);
      this.preview.commit();

      this.onCommit(el, [{
        property,
        fromValue,
        toValue: newValue,
        unit: 'px',
      }]);
    }
  }

  private distributeElements(direction: 'horizontal' | 'vertical'): void {
    if (this.elements.length < 3 || !this.onCommit) return;

    const isH = direction === 'horizontal';
    const items = this.elements.map((el) => ({
      el,
      rect: el.getBoundingClientRect(),
    }));

    // Sort by position
    items.sort((a, b) => isH
      ? a.rect.left - b.rect.left
      : a.rect.top - b.rect.top,
    );

    const first = items[0].rect;
    const last = items[items.length - 1].rect;

    const totalSpan = isH
      ? last.right - first.left
      : last.bottom - first.top;

    const totalSize = items.reduce(
      (sum, i) => sum + (isH ? i.rect.width : i.rect.height),
      0,
    );

    const evenSpacing = (totalSpan - totalSize) / (items.length - 1);

    // Move middle elements (first and last stay fixed)
    let currentPos = isH
      ? first.right + evenSpacing
      : first.bottom + evenSpacing;

    for (let i = 1; i < items.length - 1; i++) {
      const { el, rect } = items[i];
      const currentEdge = isH ? rect.left : rect.top;
      const delta = currentPos - currentEdge;

      if (Math.abs(delta) >= 0.5) {
        const property = getPositionProperty(el, isH ? 'h' : 'v');
        const fromValue = getComputedProperty(el, property);
        const currentNum = parseFloat(fromValue) || 0;
        const newValue = `${currentNum + delta}px`;

        this.preview.begin(el as HTMLElement);
        this.preview.apply(property, newValue);
        this.preview.commit();

        this.onCommit(el, [{
          property,
          fromValue,
          toValue: newValue,
          unit: 'px',
        }]);
      }

      const size = isH ? rect.width : rect.height;
      currentPos += size + evenSpacing;
    }
  }

  private applyUniformSpacing(spacing: number): void {
    if (this.elements.length < 2 || !this.onCommit) return;

    // Detect layout direction from element positions
    const rects = this.elements.map((el) => ({
      el,
      rect: el.getBoundingClientRect(),
    }));

    const hSpread = Math.max(...rects.map((r) => r.rect.right)) -
                    Math.min(...rects.map((r) => r.rect.left));
    const vSpread = Math.max(...rects.map((r) => r.rect.bottom)) -
                    Math.min(...rects.map((r) => r.rect.top));

    const isH = hSpread >= vSpread;

    // Sort by position
    rects.sort((a, b) => isH
      ? a.rect.left - b.rect.left
      : a.rect.top - b.rect.top,
    );

    // Keep first element fixed, reposition subsequent elements
    for (let i = 1; i < rects.length; i++) {
      const prevRect = rects[i - 1].rect;
      const { el, rect } = rects[i];

      const targetPos = isH
        ? prevRect.right + spacing
        : prevRect.bottom + spacing;
      const currentEdge = isH ? rect.left : rect.top;
      const delta = targetPos - currentEdge;

      if (Math.abs(delta) < 0.5) continue;

      const property = getPositionProperty(el, isH ? 'h' : 'v');
      const fromValue = getComputedProperty(el, property);
      const currentNum = parseFloat(fromValue) || 0;
      const newValue = `${currentNum + delta}px`;

      this.preview.begin(el as HTMLElement);
      this.preview.apply(property, newValue);
      this.preview.commit();

      this.onCommit(el, [{
        property,
        fromValue,
        toValue: newValue,
        unit: 'px',
      }]);

      // Update the rect for the next iteration (element has moved)
      rects[i] = { el, rect: el.getBoundingClientRect() };
    }
  }

  private applyDistanceChange(
    elA: Element,
    elB: Element,
    currentDistance: number,
    newDistance: number,
    direction: 'horizontal' | 'vertical',
  ): void {
    if (!this.onCommit) return;

    const delta = newDistance - currentDistance;
    if (Math.abs(delta) < 0.5) return;

    const strategy = determineSpacingStrategy(elA, elB, direction);
    const { target, property } = strategy;

    const fromValue = getComputedProperty(target, property);
    const currentNum = parseFloat(fromValue) || 0;
    const newValue = `${currentNum + delta}px`;

    this.preview.begin(target as HTMLElement);
    this.preview.apply(property, newValue);
    this.preview.commit();

    const token = this.tokenStore.getForCategory('spacing')
      .find((t) => t.value === `${newDistance}px`);

    this.onCommit(target, [{
      property,
      fromValue,
      toValue: newValue,
      unit: 'px',
      toToken: token?.name,
    }]);
  }
}
