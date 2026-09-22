import { readFile, writeFile, mkdtemp } from 'node:fs/promises';
import { rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { transform } from 'esbuild';

const DEFAULT_TIMEOUT_MS = 5000;

// ---------------------------------------------------------------------------
// Private per-process temp directory
// ---------------------------------------------------------------------------

/** Lazily-initialised private temp dir. Created once per process, mode 0700. */
let privateTmpDirPromise: Promise<string> | null = null;

function getPrivateTmpDir(): Promise<string> {
  if (!privateTmpDirPromise) {
    privateTmpDirPromise = mkdtemp(join(tmpdir(), 'nco-web-editor-')).then((dir) => {
      // Best-effort synchronous cleanup on exit (sync-only exit handlers).
      process.once('exit', () => {
        try {
          rmSync(dir, { recursive: true, force: true });
        } catch {
          // non-fatal — OS will reclaim on reboot
        }
      });
      return dir;
    });
  }
  return privateTmpDirPromise;
}

/**
 * Compile a TypeScript config file (e.g. `tailwind.config.ts/.mts/.cts`) with
 * esbuild, evaluate it via a dynamic `import()`, and return the module's config
 * value.
 *
 * SECURITY: compiling and evaluating the config executes arbitrary user code in
 * the MCP server process. This is an accepted trust boundary — the server
 * already runs in the project's trust context (same as `npm install` / `npx`),
 * documented in `boundaries.md` ("Token discovery executes user code"). Callers
 * that surface the result to untrusted input must not rely on this being a
 * sandbox.
 *
 * The compile+eval is bounded by `timeoutMs` (default 5s) via `Promise.race`
 * semantics so a config with a hanging top-level `await` cannot wedge the
 * server. On any failure (compile error, eval throw, or timeout) the error
 * propagates to the caller; `parseTokenSource` records it as an errored
 * `TokenSourceStatus` (feature-005 error isolation) without crashing the WS/MCP
 * transport. The compiled temp file persists in a private per-process directory
 * (created once by `getPrivateTmpDir` via `mkdtemp`) and is cleaned up at
 * process exit via a `process.once('exit', rmSync(...))` handler.
 *
 * Note: esbuild `transform` (not `build`) does NOT resolve or bundle imports.
 * A config that imports sibling modules (`import colors from './colors'`) will
 * fail to evaluate from the temp location and degrade to no-tokens for that
 * source — a documented limitation, acceptable for the common single-file
 * Tailwind v3 config.
 */
export async function loadTsConfig(
  filePath: string,
  timeoutMs: number = DEFAULT_TIMEOUT_MS,
): Promise<unknown> {
  const source = await readFile(filePath, 'utf-8');

  // Strip TS types and emit ESM so Node's dynamic import() can evaluate it.
  const nodeMajor = process.versions.node.split('.')[0];
  const { code } = await transform(source, {
    loader: 'ts',
    format: 'esm',
    platform: 'node',
    target: `node${nodeMajor}`,
    sourcefile: filePath,
  });

  // Content-hashed temp filename: identical config content maps to the same
  // module URL, so Node's ESM module cache serves repeat loads without re-eval.
  // When the config changes (chokidar rebuild), the hash changes → a fresh URL
  // → a fresh import, so there is no stale-cache hazard across edits.
  const hash = createHash('sha256').update(code).digest('hex').slice(0, 16);
  // Write into a private per-process directory (mode 0700, created by mkdtemp)
  // so no other process can predict or race the temp file path.
  const dir = await getPrivateTmpDir();
  const tmpPath = join(dir, `tw-config-${hash}.mjs`);

  // 'wx' = exclusive create: fails with EEXIST if the file is already present.
  // Same hash → same content → the existing file is a valid cache entry; treat
  // EEXIST as a hit and skip the write.
  try {
    await writeFile(tmpPath, code, { encoding: 'utf-8', flag: 'wx' });
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'EEXIST') throw err;
    // Cache hit — file already written by this process for this content hash.
  }

  const mod = await withTimeout(
    import(pathToFileURL(tmpPath).href),
    timeoutMs,
    `evaluating ${filePath}`,
  );
  // Export duality: an ESM `export default config` surfaces on `.default`;
  // fall back to the namespace object for configs that attach the shape
  // directly.
  const record = mod as Record<string, unknown>;
  return record.default ?? record;
}

/**
 * Reject with a timeout error if `p` has not settled within `ms`. The underlying
 * promise is abandoned (not cancellable); the compiled temp file persists in the
 * private per-process directory and is cleaned up at process exit.
 */
function withTimeout<T>(p: Promise<T>, ms: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`Timed out after ${ms}ms ${label}`));
    }, ms);
    // Do not keep the event loop alive solely for this guard timer.
    if (typeof timer.unref === 'function') timer.unref();
    p.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}
