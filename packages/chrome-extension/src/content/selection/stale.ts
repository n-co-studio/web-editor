/**
 * Watches a selected element for removal from the DOM.
 * Uses MutationObserver on document.body to detect when the
 * target element is no longer in the document tree.
 */
export class StaleDetector {
  private observer: MutationObserver | null = null;
  private target: Element | null = null;

  /** Start watching an element. Calls onStale when it leaves the DOM. */
  watch(element: Element, onStale: () => void): void {
    this.cleanup();
    this.target = element;

    this.observer = new MutationObserver(() => {
      if (this.target && !document.contains(this.target)) {
        onStale();
        this.cleanup();
      }
    });

    this.observer.observe(document.body, {
      childList: true,
      subtree: true,
    });
  }

  /** Stop watching. */
  cleanup(): void {
    if (this.observer) {
      this.observer.disconnect();
      this.observer = null;
    }
    this.target = null;
  }
}
