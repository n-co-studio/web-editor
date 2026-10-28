/**
 * Pick-mode click handler for attaching a page element to a note.
 *
 * Extracted from content/index.ts so the isTrusted gate can be tested: a
 * synthetic click dispatched by page script must not add a reference (KL-4).
 */
export interface NotePickDeps {
  /** Rect of the notes panel, if open; clicks inside it pass through untouched. */
  getPanelRect(): { left: number; right: number; top: number; bottom: number } | null;
  /** The page element under the point, or null. */
  elementAt(x: number, y: number): Element | null;
  /** Attach the element to the note. */
  addElement(el: Element): void;
}

export function createNotePickHandler(deps: NotePickDeps): (e: MouseEvent) => void {
  return (e: MouseEvent) => {
    // A synthetic click from page script must not add a reference (KL-4).
    if (!e.isTrusted) return;
    // Let clicks within the notes panel through so buttons remain interactive
    const r = deps.getPanelRect();
    if (r && e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom) {
      return;
    }

    e.preventDefault();
    e.stopPropagation();

    const target = deps.elementAt(e.clientX, e.clientY);
    if (target) deps.addElement(target);
  };
}
