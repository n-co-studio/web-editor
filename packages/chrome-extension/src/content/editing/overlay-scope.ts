/**
 * Overlay scope detection (issue #30).
 *
 * The extension has no native overlay concept — an "overlay" is a page-level
 * element on the target site (a modal dialog, a popover, a drawer). Reparent
 * drags must stay contained to the overlay the dragged element lives in: a drop
 * outside that overlay is not a valid target, so the element snaps back to its
 * origin instead of reparenting into a page-root container.
 *
 * `findOverlayRoot` walks up from the element through a layered heuristic and
 * returns the overlay boundary, or `document.body` when no overlay is detected.
 * The body fallback preserves the previous, unconstrained behavior on ordinary
 * (non-modal) pages — no regression. The function never throws: any failure in
 * a heuristic falls through to the body fallback.
 */

/**
 * Find the active overlay boundary that contains `element`.
 *
 * Heuristic layers, most-specific first:
 *   1. Native `<dialog>` in the top layer (`:modal`), or an open `<dialog>`.
 *   2. ARIA overlay markers — `[aria-modal="true"]`, `[role="dialog"]`,
 *      `[role="alertdialog"]`.
 *   3. Nearest positioned (`fixed`/`absolute`) ancestor with a positive
 *      `z-index` whose rect is NOT the full viewport (skips full-screen
 *      scrims / backdrops that would otherwise swallow the whole page).
 *   4. Fallback: `document.body` (unconstrained — current behavior).
 *
 * @returns the overlay root element, or `document.body`. Never throws.
 */
export function findOverlayRoot(element: HTMLElement): HTMLElement {
  try {
    // Layers 1 + 2 — walk ancestors for dialog / ARIA overlay markers.
    let node: HTMLElement | null = element;
    while (node && node !== document.body && node !== document.documentElement) {
      if (node.tagName.toLowerCase() === 'dialog') {
        // Prefer a top-layer modal dialog; :modal may be unsupported.
        try {
          if (node.matches(':modal')) return node;
        } catch {
          /* :modal unsupported — fall through to the open check */
        }
        if (node.hasAttribute('open')) return node;
      }

      const role = node.getAttribute('role');
      if (
        node.getAttribute('aria-modal') === 'true' ||
        role === 'dialog' ||
        role === 'alertdialog'
      ) {
        return node;
      }

      node = node.parentElement;
    }

    // Layer 3 — nearest positioned, high-z, non-full-viewport ancestor.
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    node = element.parentElement;
    while (node && node !== document.body && node !== document.documentElement) {
      const cs = getComputedStyle(node);
      if (cs.position === 'fixed' || cs.position === 'absolute') {
        const z = parseInt(cs.zIndex, 10);
        if (Number.isFinite(z) && z > 0) {
          const rect = node.getBoundingClientRect();
          const coversViewport =
            rect.left <= 1 &&
            rect.top <= 1 &&
            rect.width >= vw - 1 &&
            rect.height >= vh - 1;
          if (!coversViewport && rect.width > 0 && rect.height > 0) {
            return node;
          }
        }
      }
      node = node.parentElement;
    }
  } catch {
    /* never throw — degrade to the body fallback below */
  }

  // Layer 4 — no overlay detected: unconstrained (page-wide) scope.
  return document.body;
}
