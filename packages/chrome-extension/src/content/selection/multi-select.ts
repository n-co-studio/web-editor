import { createElement } from '../../shared/ui-utils';
import { OVERLAY, MEASURE_INDICATOR } from '../../shared/constants';

type SelectionChangeCb = (elements: Element[]) => void;

// Shares the measure blue on purpose — both are secondary on-page
// indicators, and both must stay fixed rather than follow the panel theme.
const MULTI_SELECT_COLOR = MEASURE_INDICATOR.color;

/**
 * Manages secondary selected elements for multi-select mode.
 * The primary selection stays in SelectionManager (pink highlight).
 * Secondary elements get blue highlights managed here.
 */
export class MultiSelectManager {
  private elements: Element[] = [];
  private highlights = new Map<Element, HTMLDivElement>();
  private changeCbs: SelectionChangeCb[] = [];

  constructor(
    private readonly shadow: ShadowRoot,
    private readonly host: HTMLDivElement,
  ) {}

  /**
   * Add element to the multi-selection.
   * Returns false if already present, is the primary, or is a root element.
   */
  add(element: Element, primaryElement: Element | null): boolean {
    if (element === primaryElement) return false;
    if (this.highlights.has(element)) return false;
    if (element === document.documentElement || element === document.body) return false;

    this.elements.push(element);

    // Create highlight box
    const rect = element.getBoundingClientRect();
    const highlight = createElement('div', {}, {
      position: 'fixed',
      left: `${rect.left}px`,
      top: `${rect.top}px`,
      width: `${rect.width}px`,
      height: `${rect.height}px`,
      border: `2px solid ${MULTI_SELECT_COLOR}`,
      background: MEASURE_INDICATOR.fill,
      borderRadius: OVERLAY.radiusSm,
      pointerEvents: 'none',
      zIndex: '2',
    });
    this.shadow.appendChild(highlight);
    this.highlights.set(element, highlight);

    this.notify();
    return true;
  }

  /** Remove element from multi-selection. */
  remove(element: Element): void {
    const idx = this.elements.indexOf(element);
    if (idx === -1) return;

    this.elements.splice(idx, 1);
    const highlight = this.highlights.get(element);
    highlight?.remove();
    this.highlights.delete(element);

    this.notify();
  }

  /** Clear all secondary selections. */
  clear(): void {
    for (const highlight of this.highlights.values()) {
      highlight.remove();
    }
    this.elements = [];
    this.highlights.clear();
    this.notify();
  }

  /** Get all secondary selected elements (does NOT include primary). */
  getElements(): Element[] {
    return [...this.elements];
  }

  /** Get ALL selected elements (primary + secondaries). */
  getAllElements(primaryElement: Element | null): Element[] {
    const all: Element[] = [];
    if (primaryElement) all.push(primaryElement);
    all.push(...this.elements);
    return all;
  }

  /** Count of secondary selections. */
  count(): number {
    return this.elements.length;
  }

  /** Whether any secondary elements are selected. */
  isActive(): boolean {
    return this.elements.length > 0;
  }

  /** Reposition all highlight boxes (call on scroll, resize). */
  refreshHighlights(): void {
    for (const [element, highlight] of this.highlights) {
      const rect = element.getBoundingClientRect();
      highlight.style.left = `${rect.left}px`;
      highlight.style.top = `${rect.top}px`;
      highlight.style.width = `${rect.width}px`;
      highlight.style.height = `${rect.height}px`;
    }
  }

  /** Register callback for when selection changes. */
  onSelectionChange(cb: SelectionChangeCb): void {
    this.changeCbs.push(cb);
  }

  private notify(): void {
    const elements = [...this.elements];
    for (const cb of this.changeCbs) cb(elements);
  }
}
