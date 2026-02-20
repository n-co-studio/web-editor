/**
 * Manages live preview of CSS edits by mutating element inline styles.
 * Uses element.style.setProperty (CSS custom property mutation pattern)
 * to minimize reflow cost during drag operations.
 *
 * Tracks original values so edits can be reverted on cancel.
 */
export class PreviewManager {
  private original = new Map<string, string>();
  private target: HTMLElement | null = null;

  /** Begin a preview session on an element. */
  begin(element: HTMLElement): void {
    this.revert(); // clean up any previous session
    this.target = element;
    this.original.clear();
  }

  /** Apply a CSS value change as a live preview. */
  apply(property: string, value: string): void {
    if (!this.target) return;

    // Capture original value on first touch of each property
    if (!this.original.has(property)) {
      this.original.set(property, this.target.style.getPropertyValue(property));
    }

    this.target.style.setProperty(property, value);
  }

  /**
   * Commit the preview — keep applied styles and return original values.
   * The caller uses originals to build the PropertyChange.fromValue.
   */
  commit(): Map<string, string> {
    const originals = new Map(this.original);
    this.original.clear();
    this.target = null;
    return originals;
  }

  /** Revert all previewed changes back to original values. */
  revert(): void {
    if (!this.target) return;

    for (const [prop, val] of this.original) {
      if (val) {
        this.target.style.setProperty(prop, val);
      } else {
        this.target.style.removeProperty(prop);
      }
    }

    this.original.clear();
    this.target = null;
  }

  /** Check if a preview session is active. */
  isActive(): boolean {
    return this.target !== null;
  }

  /** Get the element currently being previewed. */
  getTarget(): HTMLElement | null {
    return this.target;
  }
}
