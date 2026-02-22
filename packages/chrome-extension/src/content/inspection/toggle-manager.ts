// ---------------------------------------------------------------------------
// Property toggle manager — exploration-only CSS overrides
// ---------------------------------------------------------------------------

import { generateSelector } from '../../shared/dom-utils';

/**
 * Manages temporary CSS property toggles using a Constructable StyleSheet.
 *
 * Toggle OFF inserts an element-scoped override rule:
 *   `<selector> { <property>: unset !important; }`
 *
 * Toggle ON removes that rule. Toggles are exploration-only (not persisted as diffs).
 * All toggles are cleared on element deselect; override sheet is removed on dispose.
 *
 * Coordination with PreviewManager: when inline editing starts on a toggled property,
 * call clearPropertyToggle() to remove the toggle so element.style.setProperty works.
 */
export class ToggleManager {
  private sheet: CSSStyleSheet | null = null;
  private toggleMap = new Map<string, number>(); // "selector|||property" → rule index

  /** Initialize the override sheet and append to document.adoptedStyleSheets. */
  init(): void {
    if (this.sheet) return;
    this.sheet = new CSSStyleSheet();
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, this.sheet];
  }

  /**
   * Toggle OFF a property — insert an override rule that unsets it.
   * The property's authored value becomes inactive.
   */
  toggleOff(el: Element, property: string): void {
    if (!this.sheet) this.init();
    const key = this.makeKey(el, property);
    if (this.toggleMap.has(key)) return; // already toggled off

    const selector = generateSelector(el);
    const ruleText = `${selector} { ${property}: unset !important; }`;
    const idx = this.sheet!.insertRule(ruleText, this.sheet!.cssRules.length);
    this.toggleMap.set(key, idx);
  }

  /**
   * Toggle ON a property — remove the override rule.
   * The property's authored value becomes active again.
   */
  toggleOn(el: Element, property: string): void {
    if (!this.sheet) return;
    const key = this.makeKey(el, property);
    const idx = this.toggleMap.get(key);
    if (idx === undefined) return;

    this.sheet.deleteRule(idx);
    this.toggleMap.delete(key);

    // Reindex: indices shift after deletion
    this.rebuildIndexMap();
  }

  /** Check if a property is currently toggled off for an element. */
  isToggledOff(el: Element, property: string): boolean {
    return this.toggleMap.has(this.makeKey(el, property));
  }

  /**
   * Clear a single property toggle (called by InlineEditor when editing starts
   * on a toggled property to prevent conflict with element.style.setProperty).
   */
  clearPropertyToggle(el: Element, property: string): void {
    this.toggleOn(el, property);
  }

  /** Remove all toggles for a specific element. */
  clearElement(el: Element): void {
    if (!this.sheet) return;
    const selector = generateSelector(el);
    const prefix = selector + '|||';
    const toRemove: string[] = [];

    for (const key of this.toggleMap.keys()) {
      if (key.startsWith(prefix)) {
        toRemove.push(key);
      }
    }

    if (toRemove.length === 0) return;

    // Remove in reverse index order to avoid shifting issues
    const indices = toRemove.map((k) => this.toggleMap.get(k)!).sort((a, b) => b - a);
    for (const idx of indices) {
      this.sheet.deleteRule(idx);
    }
    for (const key of toRemove) {
      this.toggleMap.delete(key);
    }
    this.rebuildIndexMap();
  }

  /** Remove all toggle rules from the override sheet. */
  clearAll(): void {
    if (!this.sheet) return;
    while (this.sheet.cssRules.length > 0) {
      this.sheet.deleteRule(0);
    }
    this.toggleMap.clear();
  }

  /** Get the override sheet (for exclusion from rule matching). */
  getSheet(): CSSStyleSheet | null {
    return this.sheet;
  }

  /**
   * Remove the override sheet from document.adoptedStyleSheets and clean up.
   * Called on extension deactivation.
   */
  dispose(): void {
    this.clearAll();
    if (this.sheet) {
      document.adoptedStyleSheets = document.adoptedStyleSheets.filter((s) => s !== this.sheet);
      this.sheet = null;
    }
    this.toggleMap.clear();
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  private makeKey(el: Element, property: string): string {
    return generateSelector(el) + '|||' + property;
  }

  /** Rebuild the index map after rule deletions shift indices. */
  private rebuildIndexMap(): void {
    if (!this.sheet) return;
    // Sort remaining entries by original index (ascending) to preserve rule order,
    // then reassign consecutive indices. Avoids reading back browser-normalized
    // selectorText which may differ from generateSelector() output.
    const sorted = [...this.toggleMap.entries()].sort((a, b) => a[1] - b[1]);
    this.toggleMap.clear();
    for (let i = 0; i < sorted.length; i++) {
      this.toggleMap.set(sorted[i][0], i);
    }
  }
}
