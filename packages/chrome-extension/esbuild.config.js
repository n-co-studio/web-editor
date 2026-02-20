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
  },
  {
    entryPoints: [resolve(__dirname, 'src/service-worker/index.ts')],
    outfile: resolve(__dirname, 'dist/service-worker.js'),
  },
];

// Copy static assets to dist
mkdirSync(resolve(__dirname, 'dist/icons'), { recursive: true });
cpSync(resolve(__dirname, 'manifest.json'), resolve(__dirname, 'dist/manifest.json'));
cpSync(resolve(__dirname, 'assets/icons'), resolve(__dirname, 'dist/icons'), { recursive: true });

if (isWatch) {
  for (const entry of entries) {
    const ctx = await context({ ...shared, ...entry });
    await ctx.watch();
  }
  console.log('[frontend-editor] Watching for changes...');
} else {
  await Promise.all(entries.map((entry) => build({ ...shared, ...entry })));
}
