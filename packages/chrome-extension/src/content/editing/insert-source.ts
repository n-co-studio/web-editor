/**
 * Source-mapping data collection for insert operations.
 *
 * Reads data-source-* attributes from sibling elements to provide
 * Claude Code with the exact JSX insertion point (sibling bracket).
 */

import type {
  SiblingAnchor,
  ChildSnapshotEntry,
  CompoundChildDescriptor,
  ComponentInsertDescriptor,
  InsertChange,
  PropertyChange,
} from '@nco-studio/shared';
import { generateSelector, ensureUid, readUid } from '../../shared/dom-utils';

// ---------------------------------------------------------------------------
// Sibling bracket — prev/next anchors around the insert position
// ---------------------------------------------------------------------------

/**
 * Read source-mapping attributes from the children immediately before
 * and after `insertIndex` to form a "sibling bracket".
 */
export function collectSiblingBracket(
  container: HTMLElement,
  insertIndex: number,
): { prev: SiblingAnchor | null; next: SiblingAnchor | null } {
  const children = Array.from(container.children);
  const prev = insertIndex > 0 ? anchorFromElement(children[insertIndex - 1]) : null;
  const next = insertIndex < children.length ? anchorFromElement(children[insertIndex]) : null;
  return { prev, next };
}

/**
 * Check if all children with source attributes share the same
 * source file + line — indicates a .map() rendered list.
 */
export function detectSameSiblingSource(container: HTMLElement): boolean {
  const children = Array.from(container.children);
  let firstFile: string | null = null;
  let firstLine: string | null = null;
  let found = 0;

  for (const child of children) {
    const file = child.getAttribute('data-source-file');
    const line = child.getAttribute('data-source-line');
    if (!file || !line) continue;
    found++;
    if (firstFile === null) {
      firstFile = file;
      firstLine = line;
    } else if (file !== firstFile || line !== firstLine) {
      return false;
    }
  }

  return found >= 2;
}

/**
 * Check if the container's source file differs from its children's
 * source files — indicates a cross-file insertion.
 */
export function detectCrossFileInsertion(
  container: HTMLElement,
  prev: SiblingAnchor | null,
  next: SiblingAnchor | null,
): boolean {
  const containerFile = container.getAttribute('data-source-file');
  if (!containerFile) return false;

  if (prev && prev.sourceFile && prev.sourceFile !== containerFile) return true;
  if (next && next.sourceFile && next.sourceFile !== containerFile) return true;
  return false;
}

/**
 * Snapshot all children in the container — provides full context
 * for ambiguous insertion cases.
 */
export function collectChildSnapshot(container: HTMLElement): ChildSnapshotEntry[] {
  return Array.from(container.children)
    .filter((c): c is HTMLElement => c instanceof HTMLElement)
    .map((child) => {
      const file = child.getAttribute('data-source-file') ?? '';
      const line = parseInt(child.getAttribute('data-source-line') ?? '0', 10);
      const indexAttr = child.getAttribute('data-source-index');
      // Mint/repair the uid so each snapshot entry is per-instance distinct —
      // this is what lets the applier tell clone twins apart (issue #27).
      const entry: ChildSnapshotEntry = {
        uid: ensureUid(child),
        tagName: child.tagName.toLowerCase(),
        selector: generateSelector(child),
        sourceFile: file,
        sourceLine: line,
      };
      if (indexAttr != null) {
        return { ...entry, instanceIndex: parseInt(indexAttr, 10) };
      }
      return entry;
    });
}

// ---------------------------------------------------------------------------
// Assemble the complete InsertChange
// ---------------------------------------------------------------------------

/**
 * Build a complete InsertChange from the container and insert position.
 * Pass `compoundChildren` when inserting compound elements (ul+li, table, etc.).
 * Pass `componentInsert` when inserting a project-local React component;
 * the descriptor is threaded into `InsertChange.componentInsert` so the
 * receiving agent can resolve to a JSX usage + import at the source-level
 * insertion point.
 */
export function buildInsertChange(
  container: HTMLElement,
  insertIndex: number,
  tagName: string,
  initialStyles: readonly PropertyChange[],
  compoundChildren?: readonly CompoundChildDescriptor[],
  componentInsert?: ComponentInsertDescriptor,
  outerHTML?: string,
): InsertChange {
  const { prev, next } = collectSiblingBracket(container, insertIndex);
  const sameSiblingSource = detectSameSiblingSource(container);
  const crossFileInsertion = detectCrossFileInsertion(container, prev, next);
  const childSnapshot = collectChildSnapshot(container);

  let change: InsertChange = {
    type: 'insert',
    tagName,
    insertIndex,
    containerSelector: generateSelector(container),
    prevSibling: prev,
    nextSibling: next,
    sameSiblingSource,
    crossFileInsertion,
    initialStyles: [...initialStyles],
    childSnapshot,
  };

  if (compoundChildren?.length) {
    change = { ...change, compoundChildren };
  }
  if (componentInsert) {
    change = { ...change, componentInsert };
  }
  if (outerHTML) {
    change = { ...change, outerHTML };
  }

  // Source-anchored addressing (issue #27): anchor the insert to a stable
  // sibling uid + side instead of a positional index. Prefer the preceding
  // sibling (insert "after" it); fall back to the following sibling ("before").
  // All-or-nothing — only set when a sibling actually carries a uid; otherwise
  // the applier degrades to positional resolution.
  const anchor = anchorPairFromBracket(prev, next);
  if (anchor) {
    change = { ...change, anchorUid: anchor.uid, anchorPosition: anchor.position };
  }

  return change;
}

/**
 * Derive the source-anchored insert pair from the sibling bracket. Prefers the
 * previous sibling ("after" it); falls back to the next sibling ("before" it).
 * Returns null when neither carries a uid (positional fallback).
 */
function anchorPairFromBracket(
  prev: SiblingAnchor | null,
  next: SiblingAnchor | null,
): { uid: string; position: 'before' | 'after' } | null {
  if (prev?.uid) return { uid: prev.uid, position: 'after' };
  if (next?.uid) return { uid: next.uid, position: 'before' };
  return null;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function anchorFromElement(el: Element): SiblingAnchor | null {
  const file = el.getAttribute('data-source-file');
  const line = el.getAttribute('data-source-line');

  // An anchor is useful when the sibling carries a stable uid OR a source
  // coordinate. A uid-only sibling (e.g. a freshly pasted/runtime-stamped node
  // with no data-source-*) must still be anchorable so anchorUid resolution does
  // not silently fall back to positional addressing (issue #27). When there is
  // neither, degrade to positional — the applier handles that.
  const hasSource = Boolean(file && line);
  if (!hasSource && !readUid(el)) return null;

  const indexAttr = el.getAttribute('data-source-index');
  // Mint/repair the uid so the anchor (and its uid-preferring selector) resolve
  // by stable per-instance identity, and so InsertChange.anchorUid can read it.
  const anchor: SiblingAnchor = {
    uid: ensureUid(el),
    selector: generateSelector(el),
    sourceFile: file ?? '',
    sourceLine: line ? parseInt(line, 10) : 0,
  };
  if (indexAttr != null) {
    return { ...anchor, instanceIndex: parseInt(indexAttr, 10) };
  }
  return anchor;
}
