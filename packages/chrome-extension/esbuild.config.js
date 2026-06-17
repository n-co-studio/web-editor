import { build, context } from 'esbuild';
import { cpSync, mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const isWatch = process.argv.includes('--watch');

/** @type {import('esbuild').BuildOptions} */
const shared = {
  bundle: true,
  platform: 'browser',
  target: 'chrome116',
  format: 'esm',
  sourcemap: true,
  logLevel: 'info',
};

const entries = [
  {
    entryPoints: [resolve(__dirname, 'src/content/index.ts')],
    outfile: resolve(__dirname, 'dist/content.js'),
    format: 'iife',
    globalName: '__ncoWebEditorContent',
  },
  {
    entryPoints: [resolve(__dirname, 'src/service-worker/index.ts')],
    outfile: resolve(__dirname, 'dist/service-worker.js'),
  },
  {
    // Toolbar icon popup (default_popup). IIFE so popup.html can load it via a
    // plain <script src> tag.
    entryPoints: [resolve(__dirname, 'src/popup/popup.ts')],
    outfile: resolve(__dirname, 'dist/popup.js'),
    format: 'iife',
  },
  {
    // Web-embed bundle for the portfolio site. IIFE so a <script> tag can
    // execute it immediately; chrome.* APIs are shimmed at runtime via
    // installChromeShim() in web-env.ts.
    entryPoints: [resolve(__dirname, 'src/content/web-embed.ts')],
    outfile: resolve(__dirname, 'dist/web-embed.js'),
    format: 'iife',
    globalName: '__ncoWebEditorBundle',
    minify: !isWatch,
  },
];

// Copy static assets to dist
mkdirSync(resolve(__dirname, 'dist/icons'), { recursive: true });
cpSync(resolve(__dirname, 'manifest.json'), resolve(__dirname, 'dist/manifest.json'));
cpSync(resolve(__dirname, 'src/popup/popup.html'), resolve(__dirname, 'dist/popup.html'));
cpSync(resolve(__dirname, 'assets/icons'), resolve(__dirname, 'dist/icons'), { recursive: true });
// Operator-provided status icons (repo root /icon) → dist/icons/status — used by
// chrome.action.setIcon to reflect editor/connection state.
cpSync(resolve(__dirname, '../../icon'), resolve(__dirname, 'dist/icons/status'), { recursive: true });

if (isWatch) {
  for (const entry of entries) {
    const ctx = await context({ ...shared, ...entry });
    await ctx.watch();
  }
  console.log('[nco-web-editor] Watching for changes...');
} else {
  await Promise.all(entries.map((entry) => build({ ...shared, ...entry })));
}
