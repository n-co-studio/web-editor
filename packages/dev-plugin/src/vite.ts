import { relative } from 'node:path';
import { transformJSX } from './transform.js';
import type { DevPluginOptions } from './types.js';
import type { Plugin } from 'vite';

const DEFAULT_INCLUDE = ['.jsx', '.tsx'];

/**
 * Vite plugin for @frontend-editor/dev-plugin.
 *
 * ```ts
 * import { frontendEditor } from '@frontend-editor/dev-plugin'
 * export default defineConfig({ plugins: [frontendEditor()] })
 * ```
 */
export function frontendEditor(options?: DevPluginOptions): Plugin {
  let projectRoot: string;
  let disabled = false;
  const include = options?.include ?? DEFAULT_INCLUDE;
  const exclude = options?.exclude ?? [];

  return {
    name: 'frontend-editor-dev-plugin',
    enforce: 'pre',

    configResolved(config) {
      projectRoot = options?.root ?? config.root;
      disabled = config.mode !== 'development';
    },

    transform(code, id) {
      if (disabled) return null;
      if (id.includes('node_modules')) return null;

      const hasMatchingExt = include.some((ext) => id.endsWith(ext));
      if (!hasMatchingExt) return null;

      if (exclude.some((pattern) =>
        typeof pattern === 'string' ? id.includes(pattern) : pattern.test(id),
      )) {
        return null;
      }

      const relPath = relative(projectRoot, id).replace(/\\/g, '/');
      const result = transformJSX(code, relPath);
      if (!result) return null;

      return { code: result.code, map: result.map };
    },
  };
}
