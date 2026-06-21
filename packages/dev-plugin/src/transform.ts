import { parse } from '@babel/parser';
import type { NodePath } from '@babel/traverse';
import type { JSXOpeningElement, Node } from '@babel/types';
import MagicString from 'magic-string';

// @babel/traverse ships CJS with a default wrapper under ESM — unwrap it.
// The types package exports a callable const as default; cast via `any` to preserve call signatures.
import _traverse from '@babel/traverse';
const traverse = ((_traverse as any).default ?? _traverse) as (
  parent: import('@babel/types').Node,
  opts?: import('@babel/traverse').TraverseOptions,
) => void;

export interface TransformResult {
  readonly code: string;
  readonly map: ReturnType<MagicString['generateMap']>;
}

/**
 * Transform JSX/TSX source code to inject data-source-* attributes.
 *
 * @param code     - Original source text
 * @param filePath - Relative path from project root (already computed by caller)
 * @returns Transformed code + sourcemap, or null if no JSX found
 */
export function transformJSX(
  code: string,
  filePath: string,
): TransformResult | null {
  const ast = parse(code, {
    sourceType: 'module',
    plugins: ['jsx', 'typescript'],
    ranges: true,
  });

  const s = new MagicString(code);
  let mutated = false;

  // Track JSX elements per (grandparent node, line number) for data-source-index
  const siblingMap = new Map<Node | null, Map<number, JSXOpeningElement[]>>();

  // Collect insertion points during traversal
  const insertions: Array<{
    element: JSXOpeningElement;
    line: number;
    insertPos: number;
  }> = [];

  traverse(ast, {
    JSXOpeningElement(path: NodePath<JSXOpeningElement>) {
      const node = path.node;

      // Skip fragments
      if (isFragment(node)) return;

      // Skip already-annotated elements (defensive)
      if (hasAttribute(node, 'data-source-file')) return;

      const loc = node.loc;
      if (!loc) return;

      const nameEnd = node.name.end;
      if (nameEnd == null) return;

      const line = loc.start.line;

      insertions.push({ element: node, line, insertPos: nameEnd });

      // Track siblings for data-source-index
      const parentNode = path.parentPath?.parentPath?.node ?? null;
      if (!siblingMap.has(parentNode)) {
        siblingMap.set(parentNode, new Map());
      }
      const lineMap = siblingMap.get(parentNode)!;
      if (!lineMap.has(line)) {
        lineMap.set(line, []);
      }
      lineMap.get(line)!.push(node);
    },
  });

  if (insertions.length === 0) return null;

  // Build index map: elements needing data-source-index
  const indexMap = new Map<JSXOpeningElement, number>();
  for (const [, lineMap] of siblingMap) {
    for (const [, elements] of lineMap) {
      if (elements.length > 1) {
        elements.forEach((el, idx) => indexMap.set(el, idx));
      }
    }
  }

  // Apply insertions descending by position to preserve offsets
  const sorted = insertions.sort((a, b) => b.insertPos - a.insertPos);

  for (const { element, line, insertPos } of sorted) {
    const index = indexMap.has(element) ? indexMap.get(element)! : undefined;
    let attrs = ` data-source-file="${filePath}" data-source-line="${line}"`;
    if (index !== undefined) {
      attrs += ` data-source-index="${index}"`;
    }
    // Build-time stable element identity (issue #27): a deterministic per-JSX
    // -element uid derived from file:line[:index]. Deterministic so it survives
    // HMR/re-render (the value is part of the emitted markup, so React preserves
    // it across reconciliation — the primary, reconciliation-stable identity
    // source per data-contracts § Stamping lifecycle 1). `.map()` runtime
    // instances share one JSX node and therefore one build-time uid; the content
    // script lazily mints per-instance uids for those (and for clones) at
    // runtime — build-time alone is intentionally not sufficient there.
    attrs += ` data-fe-uid="${buildUid(filePath, line, index)}"`;
    s.appendLeft(insertPos, attrs);
    mutated = true;
  }

  if (!mutated) return null;

  return {
    code: s.toString(),
    map: s.generateMap({ hires: true }),
  };
}

/**
 * Deterministic build-time uid for a JSX element, derived from its source
 * coordinate (file:line[:index]). FNV-1a 32-bit hash → base36, prefixed `fe-`.
 * Deterministic across builds/HMR so the same source element keeps the same uid
 * (issue #27). Note: `.map()` runtime instances share one JSX node and thus one
 * build-time uid by construction — runtime per-instance assignment handles that.
 */
function buildUid(filePath: string, line: number, index?: number): string {
  const key = `${filePath}:${line}${index !== undefined ? `:${index}` : ''}`;
  let hash = 0x811c9dc5;
  for (let i = 0; i < key.length; i++) {
    hash ^= key.charCodeAt(i);
    // FNV prime multiply, kept in 32-bit unsigned range.
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return `fe-${hash.toString(36)}`;
}

function isFragment(node: JSXOpeningElement): boolean {
  const name = node.name;

  // Note: JSX shorthand fragments (<>...</>) are parsed as JSXFragment nodes,
  // which never reach the JSXOpeningElement visitor — they are naturally excluded.
  if (name.type === 'JSXIdentifier') {
    if (name.name === 'Fragment') return true;
  }

  if (name.type === 'JSXMemberExpression') {
    if (
      name.object.type === 'JSXIdentifier' &&
      name.object.name === 'React' &&
      name.property.type === 'JSXIdentifier' &&
      name.property.name === 'Fragment'
    ) {
      return true;
    }
  }

  return false;
}

function hasAttribute(node: JSXOpeningElement, attrName: string): boolean {
  return node.attributes.some(
    (attr) =>
      attr.type === 'JSXAttribute' &&
      attr.name.type === 'JSXIdentifier' &&
      attr.name.name === attrName,
  );
}
