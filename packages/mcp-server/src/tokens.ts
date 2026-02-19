import { readFile, readdir, stat } from 'node:fs/promises';
import { resolve, join, relative, extname } from 'node:path';
import { watch, type FSWatcher } from 'chokidar';
import type {
  DesignToken,
  TokenCategory,
  TokenSourceStatus,
} from '@frontend-editor/shared';
import type { TokenSourceType } from './types.js';

// ---------------------------------------------------------------------------
// Category inference from CSS custom property names
// ---------------------------------------------------------------------------

const CATEGORY_PATTERNS: ReadonlyArray<[RegExp, TokenCategory]> = [
  [/color|bg-|text-(?!sm|base|lg|xl|2xl|3xl)|border-color|fill|stroke/, 'colors'],
  [/spac(?:e|ing)|gap|padding|margin|inset/, 'spacing'],
  [/font|text|leading|tracking|line-height/, 'typography'],
  [/radius|rounded/, 'radii'],
  [/shadow/, 'shadows'],
  [/screen|breakpoint/, 'breakpoints'],
];

function inferCategory(name: string): TokenCategory {
  for (const [pattern, category] of CATEGORY_PATTERNS) {
    if (pattern.test(name)) return category;
  }
  return 'colors'; // default fallback
}

// ---------------------------------------------------------------------------
// CSS properties mapping per category
// ---------------------------------------------------------------------------

const CATEGORY_CSS_PROPERTIES: Readonly<Record<TokenCategory, readonly string[]>> = {
  spacing: [
    'padding', 'padding-top', 'padding-right', 'padding-bottom', 'padding-left',
    'margin', 'margin-top', 'margin-right', 'margin-bottom', 'margin-left',
    'gap', 'row-gap', 'column-gap', 'top', 'right', 'bottom', 'left',
    'width', 'height', 'min-width', 'min-height', 'max-width', 'max-height',
  ],
  typography: [
    'font-size', 'font-weight', 'font-family', 'line-height',
    'letter-spacing', 'word-spacing',
  ],
  colors: [
    'color', 'background-color', 'border-color',
    'border-top-color', 'border-right-color', 'border-bottom-color', 'border-left-color',
    'outline-color', 'fill', 'stroke',
  ],
  radii: [
    'border-radius',
    'border-top-left-radius', 'border-top-right-radius',
    'border-bottom-left-radius', 'border-bottom-right-radius',
  ],
  shadows: ['box-shadow', 'text-shadow'],
  breakpoints: [],
};

// ---------------------------------------------------------------------------
// Token source discovery
// ---------------------------------------------------------------------------

interface DiscoveredSource {
  readonly file: string;
  readonly type: TokenSourceType;
}

/**
 * Scan CWD for known token source files.
 */
async function findTokenSources(cwd: string): Promise<DiscoveredSource[]> {
  const sources: DiscoveredSource[] = [];

  // Tailwind config
  for (const name of ['tailwind.config.js', 'tailwind.config.ts', 'tailwind.config.mjs']) {
    const file = resolve(cwd, name);
    if (await fileExists(file)) {
      sources.push({ file, type: 'tailwind' });
      break; // only use the first match
    }
  }

  // tokens.json / design-tokens.json
  for (const name of ['tokens.json', 'design-tokens.json']) {
    const file = resolve(cwd, name);
    if (await fileExists(file)) {
      sources.push({ file, type: 'tokens-json' });
    }
  }

  // design-system.md
  const designSystemPaths = [
    resolve(cwd, 'design-system.md'),
    resolve(cwd, 'docs/design-system.md'),
  ];
  for (const file of designSystemPaths) {
    if (await fileExists(file)) {
      sources.push({ file, type: 'design-system-md' });
    }
  }

  // CSS files with custom properties (src/**/*.css, max 200)
  const cssFiles = await findCssFiles(cwd);
  for (const file of cssFiles) {
    sources.push({ file, type: 'css' });
  }

  return sources;
}

async function fileExists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

async function findCssFiles(cwd: string, maxFiles = 200): Promise<string[]> {
  const results: string[] = [];
  const srcDir = resolve(cwd, 'src');
  if (!(await fileExists(srcDir))) return results;

  await walkDir(srcDir, results, maxFiles);

  if (results.length >= maxFiles) {
    console.error(`[frontend-editor] Warning: truncated CSS file discovery at ${maxFiles} files`);
  }
  return results;
}

async function walkDir(dir: string, results: string[], maxFiles: number): Promise<void> {
  if (results.length >= maxFiles) return;

  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }

  for (const entry of entries) {
    if (results.length >= maxFiles) return;

    const fullPath = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === 'node_modules') continue;
      await walkDir(fullPath, results, maxFiles);
    } else if (extname(entry.name) === '.css') {
      results.push(fullPath);
    }
  }
}

// ---------------------------------------------------------------------------
// Token parsers
// ---------------------------------------------------------------------------

/**
 * Parse tokens from a single source file.
 * Wrapped in try/catch — errors degrade to empty tokens + error status.
 */
export async function parseTokenSource(
  filePath: string,
  type: TokenSourceType,
): Promise<{ tokens: DesignToken[]; status: TokenSourceStatus }> {
  const relPath = filePath;

  try {
    let tokens: DesignToken[];

    switch (type) {
      case 'tokens-json':
        tokens = await parseTokensJson(filePath);
        break;
      case 'css':
        tokens = await parseCssFile(filePath);
        break;
      case 'design-system-md':
        tokens = await parseDesignSystemMd(filePath);
        break;
      case 'tailwind':
        tokens = await parseTailwindConfig(filePath);
        break;
      default:
        tokens = [];
    }

    return {
      tokens,
      status: { file: relPath, status: 'parsed', tokenCount: tokens.length },
    };
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`[frontend-editor] Token parse error (${type}): ${filePath}: ${message}`);
    return {
      tokens: [],
      status: { file: relPath, status: 'error', error: message, tokenCount: 0 },
    };
  }
}

/**
 * Parse a JSON token file (Style Dictionary format or flat key-value).
 */
async function parseTokensJson(filePath: string): Promise<DesignToken[]> {
  const raw = await readFile(filePath, 'utf-8');
  const data: unknown = JSON.parse(raw);
  const tokens: DesignToken[] = [];

  if (typeof data !== 'object' || data === null) return tokens;

  // Flat format: { "token-name": { "value": "...", "type": "..." } }
  // Or nested: { "spacing": { "4": { "value": "16px" } } }
  flattenTokens(data as Record<string, unknown>, [], filePath, tokens);
  return tokens;
}

function flattenTokens(
  obj: Record<string, unknown>,
  path: string[],
  source: string,
  tokens: DesignToken[],
): void {
  for (const [key, val] of Object.entries(obj)) {
    if (typeof val !== 'object' || val === null) continue;

    const record = val as Record<string, unknown>;

    if ('value' in record && typeof record.value === 'string') {
      // Leaf token node
      const name = [...path, key].join('-');
      const category = inferCategory(name);
      tokens.push({
        name,
        category,
        value: record.value,
        cssProperties: [...CATEGORY_CSS_PROPERTIES[category]],
        source,
      });
    } else {
      // Recurse into nested group
      flattenTokens(record, [...path, key], source, tokens);
    }
  }
}

/**
 * Parse CSS custom properties from a single CSS file.
 */
async function parseCssFile(filePath: string): Promise<DesignToken[]> {
  const raw = await readFile(filePath, 'utf-8');
  const tokens: DesignToken[] = [];
  const pattern = /--([a-zA-Z0-9-_]+)\s*:\s*([^;]+)/g;

  let match;
  while ((match = pattern.exec(raw)) !== null) {
    const name = match[1];
    const value = match[2].trim();
    const category = inferCategory(name);
    tokens.push({
      name,
      category,
      value,
      cssProperties: [...CATEGORY_CSS_PROPERTIES[category]],
      source: filePath,
    });
  }

  return tokens;
}

/**
 * Parse design tokens from a markdown table in design-system.md.
 * Expected format: | Token | Category | Value | CSS Properties |
 */
async function parseDesignSystemMd(filePath: string): Promise<DesignToken[]> {
  const raw = await readFile(filePath, 'utf-8');
  const lines = raw.split('\n');
  const tokens: DesignToken[] = [];

  let inTable = false;
  let headerParsed = false;
  let cols: { name: number; category: number; value: number; cssProperties: number } | null = null;

  for (const line of lines) {
    const trimmed = line.trim();

    // Detect pipe-delimited table rows
    if (!trimmed.startsWith('|')) {
      if (inTable) {
        inTable = false;
        headerParsed = false;
        cols = null;
      }
      continue;
    }

    const cells = trimmed
      .split('|')
      .map((c) => c.trim())
      .filter((c) => c.length > 0);

    if (!inTable) {
      // Try to find header row with token columns
      const lower = cells.map((c) => c.toLowerCase());
      const nameIdx = lower.findIndex((c) => c === 'token' || c === 'name');
      const catIdx = lower.findIndex((c) => c === 'category' || c === 'type');
      const valIdx = lower.findIndex((c) => c === 'value');
      const cssIdx = lower.findIndex((c) => c.includes('css') || c.includes('properties'));

      if (nameIdx >= 0 && valIdx >= 0) {
        cols = { name: nameIdx, category: catIdx, value: valIdx, cssProperties: cssIdx };
        inTable = true;
        continue;
      }
      continue;
    }

    if (!headerParsed) {
      // Skip the separator row (|---|---|...)
      if (trimmed.includes('---')) {
        headerParsed = true;
        continue;
      }
    }

    if (!cols || !headerParsed) continue;

    const name = cells[cols.name];
    const value = cells[cols.value];
    if (!name || !value) continue;

    const categoryStr = cols.category >= 0 ? cells[cols.category] : undefined;
    const category = isTokenCategory(categoryStr) ? categoryStr : inferCategory(name);
    const cssStr = cols.cssProperties >= 0 ? cells[cols.cssProperties] : undefined;
    const cssProperties = cssStr
      ? cssStr.split(',').map((s) => s.trim()).filter(Boolean)
      : [...CATEGORY_CSS_PROPERTIES[category]];

    tokens.push({ name, category, value, cssProperties, source: filePath });
  }

  return tokens;
}

const TOKEN_CATEGORIES = new Set<string>([
  'spacing', 'typography', 'colors', 'radii', 'shadows', 'breakpoints',
]);

function isTokenCategory(val: string | undefined): val is TokenCategory {
  return typeof val === 'string' && TOKEN_CATEGORIES.has(val);
}

/**
 * Parse Tailwind config (JS only — TS configs log a warning and skip).
 *
 * SECURITY: This uses dynamic import() which executes the config file as
 * a Node.js module. The MCP server runs in the project's trust context
 * (same as `npm install` or `npx`), so this is an accepted boundary
 * limitation. Full esbuild-based evaluation is deferred to a future version.
 */
async function parseTailwindConfig(filePath: string): Promise<DesignToken[]> {
  if (filePath.endsWith('.ts')) {
    console.error(
      `[frontend-editor] Tailwind TS config not supported in v1 — skipping ${filePath}`,
    );
    return [];
  }

  const tokens: DesignToken[] = [];

  try {
    const configModule = await import(filePath);
    const config = configModule.default ?? configModule;

    if (!config?.theme?.extend && !config?.theme) return tokens;

    const theme = { ...config.theme, ...config.theme?.extend };

    // Extract known theme keys
    const themeKeyMap: Array<[string, TokenCategory]> = [
      ['colors', 'colors'],
      ['spacing', 'spacing'],
      ['fontSize', 'typography'],
      ['fontWeight', 'typography'],
      ['fontFamily', 'typography'],
      ['borderRadius', 'radii'],
      ['boxShadow', 'shadows'],
      ['screens', 'breakpoints'],
    ];

    for (const [key, category] of themeKeyMap) {
      const section = theme[key];
      if (typeof section !== 'object' || section === null) continue;

      for (const [name, value] of Object.entries(section as Record<string, unknown>)) {
        if (typeof value === 'string') {
          tokens.push({
            name: `${key}-${name}`,
            category,
            value,
            cssProperties: [...CATEGORY_CSS_PROPERTIES[category]],
            source: filePath,
          });
        } else if (typeof value === 'object' && value !== null) {
          // Nested (e.g., colors: { blue: { 500: '#3b82f6' } })
          for (const [subName, subValue] of Object.entries(value as Record<string, unknown>)) {
            if (typeof subValue === 'string') {
              tokens.push({
                name: `${key}-${name}-${subName}`,
                category,
                value: subValue,
                cssProperties: [...CATEGORY_CSS_PROPERTIES[category]],
                source: filePath,
              });
            }
          }
        }
      }
    }
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`[frontend-editor] Tailwind config import failed: ${message}`);
  }

  return tokens;
}

// ---------------------------------------------------------------------------
// Token discovery (full scan)
// ---------------------------------------------------------------------------

/**
 * Discover and parse all token sources in the project.
 * Returns the discovered sources alongside parsed tokens so callers
 * can set up file watchers (including for sources that failed to parse).
 */
export async function discoverTokens(cwd: string): Promise<{
  tokens: Map<string, DesignToken[]>;
  sources: TokenSourceStatus[];
  discovered: DiscoveredSource[];
}> {
  const discovered = await findTokenSources(cwd);
  const tokenMap = new Map<string, DesignToken[]>();
  const statuses: TokenSourceStatus[] = [];

  for (const { file, type } of discovered) {
    const { tokens, status } = await parseTokenSource(file, type);
    tokenMap.set(file, tokens);
    statuses.push(status);
  }

  const totalTokens = Array.from(tokenMap.values()).reduce((sum, t) => sum + t.length, 0);
  console.error(`[frontend-editor] Discovered ${totalTokens} tokens from ${discovered.length} sources`);

  return { tokens: tokenMap, sources: statuses, discovered };
}

// ---------------------------------------------------------------------------
// Token resolution
// ---------------------------------------------------------------------------

/**
 * Resolve a (property, value) pair to the nearest design token.
 */
export function resolveToToken(
  property: string,
  value: string,
  allTokens: DesignToken[],
): { token?: string; exactMatch: boolean; nearestValue: string } {
  // Filter tokens that apply to this CSS property
  const relevant = allTokens.filter((t) => t.cssProperties.includes(property));

  if (relevant.length === 0) {
    return { token: undefined, exactMatch: false, nearestValue: value };
  }

  // Check for exact string match
  const normalizedValue = normalizeValue(value);
  const exact = relevant.find((t) => normalizeValue(t.value) === normalizedValue);
  if (exact) {
    return { token: exact.name, exactMatch: true, nearestValue: exact.value };
  }

  // Numeric proximity check
  const numericValue = parseNumeric(value);
  if (numericValue !== null) {
    let closest: DesignToken | undefined;
    let closestDist = Infinity;

    for (const token of relevant) {
      const tokenNum = parseNumeric(token.value);
      if (tokenNum === null) continue;

      const dist = Math.abs(tokenNum - numericValue);
      if (dist < closestDist) {
        closestDist = dist;
        closest = token;
      }
    }

    if (closest) {
      return { token: closest.name, exactMatch: false, nearestValue: closest.value };
    }
  }

  // Color normalization attempt
  const normalizedColor = normalizeHexColor(value);
  if (normalizedColor) {
    const colorMatch = relevant.find(
      (t) => normalizeHexColor(t.value) === normalizedColor,
    );
    if (colorMatch) {
      return { token: colorMatch.name, exactMatch: true, nearestValue: colorMatch.value };
    }
  }

  return { token: undefined, exactMatch: false, nearestValue: value };
}

function normalizeValue(v: string): string {
  return v.trim().toLowerCase();
}

function parseNumeric(v: string): number | null {
  const match = /^(-?[\d.]+)\s*(px|rem|em|%|pt|vw|vh)?$/.exec(v.trim());
  if (!match) return null;
  const num = parseFloat(match[1]);
  return Number.isFinite(num) ? num : null;
}

function normalizeHexColor(v: string): string | null {
  const trimmed = v.trim().toLowerCase();
  // #rgb → #rrggbb
  const short = /^#([0-9a-f])([0-9a-f])([0-9a-f])$/.exec(trimmed);
  if (short) {
    return `#${short[1]}${short[1]}${short[2]}${short[2]}${short[3]}${short[3]}`;
  }
  // Already #rrggbb
  if (/^#[0-9a-f]{6}$/.test(trimmed)) {
    return trimmed;
  }
  return null;
}

// ---------------------------------------------------------------------------
// File watching
// ---------------------------------------------------------------------------

/**
 * Start file watchers on discovered token sources.
 * Returns the FSWatcher instance for cleanup.
 */
export function watchTokenSources(
  sources: DiscoveredSource[],
  onChange: (file: string, type: TokenSourceType) => void,
): FSWatcher {
  const filePaths = sources.map((s) => s.file);
  const typeMap = new Map(sources.map((s) => [s.file, s.type]));

  const watcher = watch(filePaths, {
    ignoreInitial: true,
    awaitWriteFinish: { stabilityThreshold: 300 },
  });

  watcher.on('change', (changedPath: string) => {
    const type = typeMap.get(changedPath);
    if (type) {
      console.error(`[frontend-editor] Token source changed: ${changedPath}`);
      onChange(changedPath, type);
    }
  });

  return watcher;
}

// Re-export DiscoveredSource for use by server.ts
export type { DiscoveredSource };
