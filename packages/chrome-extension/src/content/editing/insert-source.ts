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
} from '@frontend-editor/shared';
import { generateSelector } from '../../shared/dom-utils';

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
      const entry: ChildSnapshotEntry = {
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
  return change;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function anchorFromElement(el: Element): SiblingAnchor | null {
  const file = el.getAttribute('data-source-file');
  const line = el.getAttribute('data-source-line');
  if (!file || !line) return null;

  const indexAttr = el.getAttribute('data-source-index');
  const anchor: SiblingAnchor = {
    selector: generateSelector(el),
    sourceFile: file,
    sourceLine: parseInt(line, 10),
  };
  if (indexAttr != null) {
    return { ...anchor, instanceIndex: parseInt(indexAttr, 10) };
  }
  return anchor;
}
