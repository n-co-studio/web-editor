import type { ElementInfo } from '@frontend-editor/shared';
import { buildElementInfo, readSourceAttributes } from '../../shared/dom-utils';
import { createElement } from '../../shared/ui-utils';
import { OVERLAY } from '../../shared/constants';
import type { TokenStore } from '../tokens/store';

type SelectCallback = (info: ElementInfo, element: Element, rect: DOMRect) => void;
type DeselectCallback = () => void;

/**
 * Manages element selection. When the user clicks an element during
 * hover mode, this captures the ElementInfo and notifies listeners.
 */
export class SelectionManager {
  private selectedElement: Element | null = null;
  private selectedInfo: ElementInfo | null = null;
  private selectCbs: SelectCallback[] = [];
  private deselectCbs: DeselectCallback[] = [];
  private isStale = false;
  private highlight: HTMLDivElement;

  constructor(
    private readonly shadow: ShadowRoot,
    private readonly host: HTMLDivElement,
    private readonly tokenStore: TokenStore,
  ) {
    // Persistent selection highlight (stays visible while element is selected)
    this.highlight = createElement('div', {}, {
      position: 'fixed',
      pointerEvents: 'none',
      border: `2px solid ${OVERLAY.accent}`,
      background: 'rgba(251, 113, 133, 0.08)',
      borderRadius: OVERLAY.radiusSm,
      display: 'none',
      zIndex: '2',
    });
    shadow.appendChild(this.highlight);
  }

  /** Register a callback for when an element is selected. */
  onSelect(cb: SelectCallback): void {
    this.selectCbs.push(cb);
  }

  /** Register a callback for when the selection is cleared. */
  onDeselect(cb: DeselectCallback): void {
    this.deselectCbs.push(cb);
  }

  /** Called by the hover system when an element is clicked. */
  select(element: Element): void {
    // Deselect previous if any
    if (this.selectedElement) this.deselect();

    this.selectedElement = element;
    this.isStale = false;

    const info = buildElementInfo(element);
    this.selectedInfo = info;

    // Show persistent selection highlight
    const rect = element.getBoundingClientRect();
    this.highlight.style.left = `${rect.left}px`;
    this.highlight.style.top = `${rect.top}px`;
    this.highlight.style.width = `${rect.width}px`;
    this.highlight.style.height = `${rect.height}px`;
    this.highlight.style.display = 'block';

    for (const cb of this.selectCbs) cb(info, element, rect);
  }

  /** Refresh the highlight to match the element's current bounding rect. */
  refreshHighlight(): void {
    if (!this.selectedElement) return;
    const rect = this.selectedElement.getBoundingClientRect();
    this.highlight.style.left = `${rect.left}px`;
    this.highlight.style.top = `${rect.top}px`;
    this.highlight.style.width = `${rect.width}px`;
    this.highlight.style.height = `${rect.height}px`;
  }

  /** Clear the current selection. */
  deselect(): void {
    if (!this.selectedElement && !this.isStale) return;
    this.selectedElement = null;
    this.selectedInfo = null;
    this.isStale = false;
    this.highlight.style.display = 'none';
    for (const cb of this.deselectCbs) cb();
  }

  /** Hide the selection highlight without deselecting (used by page mode). */
  hideHighlight(): void {
    this.highlight.style.display = 'none';
  }

  /** Restore the selection highlight if an element is selected (used when returning from page mode). */
  restoreHighlight(): void {
    if (this.selectedElement) {
      this.refreshHighlight();
      this.highlight.style.display = 'block';
    }
  }

  /** Mark the current selection as stale (element removed from DOM). */
  markStale(): void {
    this.isStale = true;
    this.selectedElement = null;
  }

  /** Deactivate the selection manager (extension turning off). */
  deactivate(): void {
    this.deselect();
  }

  getSelectedElement(): Element | null {
    return this.selectedElement;
  }

  getSelectedInfo(): ElementInfo | null {
    return this.selectedInfo;
  }

  isSourceVerified(): boolean {
    if (!this.selectedElement) return false;
    return readSourceAttributes(this.selectedElement) !== null;
  }
}
