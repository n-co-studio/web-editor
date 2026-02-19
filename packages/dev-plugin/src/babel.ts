import { relative } from 'node:path';
import type { PluginObj, PluginPass } from '@babel/core';
import type { NodePath } from '@babel/traverse';
import type { JSXOpeningElement, Program } from '@babel/types';
import type { DevPluginOptions } from './types.js';

/**
 * Babel plugin for @frontend-editor/dev-plugin.
 *
 * Usage: `{ "plugins": ["@frontend-editor/dev-plugin/babel"] }`
 */
export default function frontendEditorBabel(
  api: { types: typeof import('@babel/types') },
  options: DevPluginOptions,
): PluginObj {
  const t = api.types;

  // Production no-op (inline guard — not reliant on build tool)
  if (process.env.NODE_ENV === 'production') {
    return { name: 'frontend-editor-dev-plugin', visitor: {} };
  }

  const projectRoot = options?.root ?? process.cwd();
  const include = options?.include ?? ['.jsx', '.tsx'];
  const exclude = options?.exclude ?? [];

  return {
    name: 'frontend-editor-dev-plugin',
    visitor: {
      Program: {
        enter(programPath: NodePath<Program>, state: PluginPass) {
          const filename = state.filename;
          if (!filename) return;
          if (!include.some((ext) => filename.endsWith(ext))) return;
          if (filename.includes('node_modules')) return;
          if (exclude.some((pattern) =>
            typeof pattern === 'string' ? filename.includes(pattern) : pattern.test(filename),
          )) return;

          const relPath = relative(projectRoot, filename).replace(/\\/g, '/');

          // Track siblings for data-source-index
          const siblingMap = new Map<unknown, Map<number, NodePath<JSXOpeningElement>[]>>();
          const allPaths: NodePath<JSXOpeningElement>[] = [];

          // Pass 1: collect all JSX elements
          programPath.traverse({
            JSXOpeningElement(path: NodePath<JSXOpeningElement>) {
              const node = path.node;
              if (isFragmentBabel(node, t)) return;
              if (hasAttributeBabel(node, 'data-source-file')) return;

              const loc = node.loc;
              if (!loc) return;

              const line = loc.start.line;
              const parentNode = path.parentPath?.parentPath?.node ?? null;

              if (!siblingMap.has(parentNode)) {
                siblingMap.set(parentNode, new Map());
              }
              const lineMap = siblingMap.get(parentNode)!;
              if (!lineMap.has(line)) {
                lineMap.set(line, []);
              }
              lineMap.get(line)!.push(path);
              allPaths.push(path);
            },
          });

          // Build index map
          const indexMap = new Map<NodePath<JSXOpeningElement>, number>();
          for (const [, lineMap] of siblingMap) {
            for (const [, paths] of lineMap) {
              if (paths.length > 1) {
                paths.forEach((p, idx) => indexMap.set(p, idx));
              }
            }
          }

          // Pass 2: inject attributes
          for (const path of allPaths) {
            const node = path.node;
            const loc = node.loc;
            if (!loc) continue;

            node.attributes.push(
              t.jsxAttribute(
                t.jsxIdentifier('data-source-file'),
                t.stringLiteral(relPath),
              ),
              t.jsxAttribute(
                t.jsxIdentifier('data-source-line'),
                t.stringLiteral(String(loc.start.line)),
              ),
            );

            if (indexMap.has(path)) {
              node.attributes.push(
                t.jsxAttribute(
                  t.jsxIdentifier('data-source-index'),
                  t.stringLiteral(String(indexMap.get(path)!)),
                ),
              );
            }
          }
        },
      },
    },
  };
}

function isFragmentBabel(
  node: JSXOpeningElement,
  t: typeof import('@babel/types'),
): boolean {
  const name = node.name;
  if (t.isJSXIdentifier(name)) {
    if (name.name === 'Fragment') return true;
  }
  if (t.isJSXMemberExpression(name)) {
    if (
      t.isJSXIdentifier(name.object) &&
      name.object.name === 'React' &&
      t.isJSXIdentifier(name.property) &&
      name.property.name === 'Fragment'
    ) {
      return true;
    }
  }
  return false;
}

function hasAttributeBabel(
  node: JSXOpeningElement,
  attrName: string,
): boolean {
  return node.attributes.some(
    (attr) =>
      attr.type === 'JSXAttribute' &&
      attr.name.type === 'JSXIdentifier' &&
      attr.name.name === attrName,
  );
}
