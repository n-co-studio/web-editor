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
    let attrs = ` data-source-file="${filePath}" data-source-line="${line}"`;
    if (indexMap.has(element)) {
      attrs += ` data-source-index="${indexMap.get(element)!}"`;
    }
    s.appendLeft(insertPos, attrs);
    mutated = true;
  }

  if (!mutated) return null;

  return {
    code: s.toString(),
    map: s.generateMap({ hires: true }),
  };
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
