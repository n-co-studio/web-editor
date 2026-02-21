/**
 * Multi-element inline style tracker for reorder preview.
 *
 * Standalone class — does NOT extend or modify PreviewManager.
 * Tracks original inline styles for multiple siblings so CSS `order`
 * and FLIP transforms can be applied and reverted cleanly.
 */
export class OrderPreview {
  private originals = new Map<HTMLElement, Map<string, string>>();

  /**
   * Begin a preview session — snapshot original inline values
   * for `order`, `transform`, and `transition` on each element.
   */
  begin(elements: HTMLElement[]): void {
    this.revertAll();
    for (const el of elements) {
      const snap = new Map<string, string>();
      snap.set('order', el.style.getPropertyValue('order'));
      snap.set('transform', el.style.getPropertyValue('transform'));
      snap.set('transition', el.style.getPropertyValue('transition'));
      this.originals.set(el, snap);
    }
  }

  /**
   * Apply an inline style to an element in the session.
   * Captures the original value on first touch of each property.
   */
  apply(el: HTMLElement, property: string, value: string): void {
    const snap = this.originals.get(el);
    if (!snap) return; // element not in session

    // Capture original on first touch of this property
    if (!snap.has(property)) {
      snap.set(property, el.style.getPropertyValue(property));
    }

    el.style.setProperty(property, value);
  }

  /** Revert all tracked elements to their original inline styles. */
  revertAll(): void {
    for (const [el, snap] of this.originals) {
      for (const [prop, val] of snap) {
        if (val) {
          el.style.setProperty(prop, val);
        } else {
          el.style.removeProperty(prop);
        }
      }
    }
    this.originals.clear();
  }

  /** Check if a preview session is active. */
  isActive(): boolean {
    return this.originals.size > 0;
  }
}
