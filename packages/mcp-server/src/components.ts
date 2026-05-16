import { readFile, readdir, stat } from 'node:fs/promises';
import { resolve, join, relative, basename, extname } from 'node:path';
import { watch, type FSWatcher } from 'chokidar';
import { parse as docgenParse } from 'react-docgen';
import type {
  ProjectComponent,
  ComponentSourceStatus,
} from '@frontend-editor/shared';

// ---------------------------------------------------------------------------
// Discovery roots — convention-gated, project-scoped
// ---------------------------------------------------------------------------

const DEFAULT_COMPONENT_ROOTS: readonly string[] = [
  'src/components',
  'src/ui',
  'components',
];

const SKIP_DIRS = new Set(['node_modules', 'dist', 'build', '.cache', '.git']);

/**
 * Resolve component scan roots — operator override via target project's
 * `package.json` `frontend-editor.componentRoots` replaces defaults entirely.
 */
async function resolveRoots(cwd: string): Promise<string[]> {
  const pkgPath = resolve(cwd, 'package.json');
  try {
    const raw = await readFile(pkgPath, 'utf-8');
    const pkg = JSON.parse(raw) as Record<string, unknown>;
    const editorCfg = pkg['frontend-editor'];
    if (
      editorCfg &&
      typeof editorCfg === 'object' &&
      Array.isArray((editorCfg as Record<string, unknown>).componentRoots)
    ) {
      const roots = (editorCfg as { componentRoots: unknown[] }).componentRoots;
      const stringRoots = roots.filter((r): r is string => typeof r === 'string');
      if (stringRoots.length > 0) return stringRoots;
    }
  } catch {
    // No package.json or unreadable — fall through to defaults
  }
  return [...DEFAULT_COMPONENT_ROOTS];
}

const COMPONENT_EXT = new Set(['.jsx', '.tsx']);

/** Cheap pre-filter: file must contain a PascalCase export to be worth parsing. */
const PASCAL_EXPORT_PATTERN =
  /export\s+(?:default\s+(?:function\s+)?|const\s+|function\s+|class\s+)([A-Z][A-Za-z0-9]*)/;

async function walkRoot(dir: string, results: string[]): Promise<void> {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const fullPath = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      await walkRoot(fullPath, results);
    } else if (entry.isFile() && COMPONENT_EXT.has(extname(entry.name))) {
      results.push(fullPath);
    }
  }
}

interface DiscoveredComponentFile {
  readonly file: string;
}

/**
 * Walk the resolved root globs and surface JSX/TSX files that look like they
 * contain a component export (cheap PascalCase regex pre-filter).
 */
async function findComponentFiles(cwd: string, roots: string[]): Promise<DiscoveredComponentFile[]> {
  const files: string[] = [];
  for (const root of roots) {
    const abs = resolve(cwd, root);
    if (!(await pathExists(abs))) continue;
    const stats = await stat(abs).catch(() => null);
    if (!stats) continue;
    if (stats.isDirectory()) {
      await walkRoot(abs, files);
    } else if (stats.isFile() && COMPONENT_EXT.has(extname(abs))) {
      files.push(abs);
    }
  }

  const filtered: DiscoveredComponentFile[] = [];
  for (const file of files) {
    try {
      const src = await readFile(file, 'utf-8');
      if (PASCAL_EXPORT_PATTERN.test(src)) {
        filtered.push({ file });
      }
    } catch {
      // unreadable — skip
    }
  }
  return filtered;
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Component parsing (react-docgen v7)
// ---------------------------------------------------------------------------

const DEFAULT_EXPORT_PATTERN = /export\s+default\b/;

function inferExportType(src: string): 'named' | 'default' {
  return DEFAULT_EXPORT_PATTERN.test(src) ? 'default' : 'named';
}

function pascalCaseFromFilename(file: string): string {
  const stem = basename(file).replace(/\.(jsx|tsx)$/i, '');
  // Strip non-alphanumeric, PascalCase the rest
  const parts = stem.split(/[^A-Za-z0-9]+/).filter(Boolean);
  if (parts.length === 0) return 'Component';
  return parts
    .map((p) => p.charAt(0).toUpperCase() + p.slice(1))
    .join('');
}

/**
 * Parse one JSX/TSX file with react-docgen and emit one ProjectComponent
 * per exported component. v1 always emits `props: []` — prop schema lives in
 * data contracts so feature-008.1 can land without migration.
 *
 * Per-file try/catch: parse failures degrade to empty components + error
 * status so one bad file cannot poison the registry or the transport.
 */
export async function parseComponentFile(
  cwd: string,
  filePath: string,
): Promise<{ components: ProjectComponent[]; status: ComponentSourceStatus }> {
  const relFile = relative(cwd, filePath);
  let src: string;
  try {
    src = await readFile(filePath, 'utf-8');
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    return {
      components: [],
      status: { file: relFile, status: 'error', error: message, componentCount: 0 },
    };
  }

  try {
    const documentation = docgenParse(src, {
      filename: filePath,
      babelOptions: { babelrc: false, configFile: false },
    });

    const exportType = inferExportType(src);
    const fallbackName = pascalCaseFromFilename(filePath);
    const components: ProjectComponent[] = documentation
      .map((doc) => {
        const componentName =
          (typeof doc.displayName === 'string' && doc.displayName) || fallbackName;
        return {
          componentName,
          importPath: relFile,
          exportType,
          props: [],
          source: 'local' as const,
        };
      });

    return {
      components,
      status: {
        file: relFile,
        status: 'parsed',
        componentCount: components.length,
      },
    };
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[frontend-editor] Component parse error: ${relFile}: ${message}`);
    return {
      components: [],
      status: { file: relFile, status: 'error', error: message, componentCount: 0 },
    };
  }
}

// ---------------------------------------------------------------------------
// Top-level discovery
// ---------------------------------------------------------------------------

export interface ComponentDiscoveryResult {
  readonly components: Map<string, ProjectComponent[]>;
  readonly statuses: ComponentSourceStatus[];
  readonly discoveredFiles: string[];
  readonly roots: string[];
}

/**
 * Discover and parse all project-local components rooted at convention-gated
 * (or operator-configured) directories. Mirrors `discoverTokens` in tokens.ts.
 */
export async function discoverComponents(cwd: string): Promise<ComponentDiscoveryResult> {
  const roots = await resolveRoots(cwd);
  const discovered = await findComponentFiles(cwd, roots);

  const components = new Map<string, ProjectComponent[]>();
  const statuses: ComponentSourceStatus[] = [];
  for (const { file } of discovered) {
    const result = await parseComponentFile(cwd, file);
    components.set(file, result.components);
    statuses.push(result.status);
  }

  const total = Array.from(components.values()).reduce((sum, list) => sum + list.length, 0);
  console.error(
    `[frontend-editor] Discovered ${total} components from ${discovered.length} files (roots: ${roots.join(', ')})`,
  );

  return {
    components,
    statuses,
    discoveredFiles: discovered.map((d) => d.file),
    roots,
  };
}

// ---------------------------------------------------------------------------
// File watching — chokidar with 300ms debounce on root globs
// ---------------------------------------------------------------------------

export type ComponentWatchEvent =
  | { kind: 'change' | 'add'; file: string }
  | { kind: 'unlink'; file: string };

/**
 * Watch all configured component roots for JSX/TSX changes.
 * Watches the root globs (not individual discovered files), so newly added
 * files are picked up automatically. Per-file rebuild granularity.
 */
export function watchComponentSources(
  cwd: string,
  roots: readonly string[],
  onChange: (event: ComponentWatchEvent) => void,
): FSWatcher {
  const watchTargets = roots
    .map((root) => resolve(cwd, root))
    .map((abs) => join(abs, '**', '*.{jsx,tsx}'));

  const watcher = watch(watchTargets, {
    ignoreInitial: true,
    ignored: (path) => SKIP_DIRS.has(basename(path)),
    awaitWriteFinish: { stabilityThreshold: 300, pollInterval: 50 },
  });

  const handler = (kind: ComponentWatchEvent['kind']) => (changedPath: string) => {
    console.error(`[frontend-editor] Component source ${kind}: ${changedPath}`);
    onChange({ kind, file: changedPath });
  };

  watcher.on('change', handler('change'));
  watcher.on('add', handler('add'));
  watcher.on('unlink', handler('unlink'));

  return watcher;
}
