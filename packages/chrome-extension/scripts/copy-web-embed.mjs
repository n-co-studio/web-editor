#!/usr/bin/env node
/**
 * Copy the built web-embed bundle into the portfolio site's public/ folder.
 *
 * Expected layout:
 *   /Users/Mark/Developer/
 *     markpreston/                       ← portfolio site
 *     _tools/_extensions/repo-os-frontend-editor/
 *       packages/chrome-extension/
 *         dist/web-embed.js              ← built artifact
 *         scripts/copy-web-embed.mjs     ← this file
 *
 * Destination: markpreston/public/frontend-editor/web-embed.js
 */
import { copyFileSync, mkdirSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const extensionRoot = resolve(__dirname, '..');
const distPath = resolve(extensionRoot, 'dist/web-embed.js');
const distMapPath = resolve(extensionRoot, 'dist/web-embed.js.map');

const portfolioRoot = resolve(extensionRoot, '../../../../../markpreston');
const destDir = resolve(portfolioRoot, 'public/frontend-editor');
const destPath = resolve(destDir, 'web-embed.js');
const destMapPath = resolve(destDir, 'web-embed.js.map');

if (!existsSync(distPath)) {
  console.error(`[copy-web-embed] build artifact not found: ${distPath}`);
  console.error('[copy-web-embed] run `npm run build` first');
  process.exit(1);
}

if (!existsSync(portfolioRoot)) {
  console.error(`[copy-web-embed] portfolio repo not found at: ${portfolioRoot}`);
  console.error('[copy-web-embed] this script assumes sibling-dir layout; update path if different');
  process.exit(1);
}

mkdirSync(destDir, { recursive: true });
copyFileSync(distPath, destPath);
console.log(`[copy-web-embed] copied → ${destPath}`);

if (existsSync(distMapPath)) {
  copyFileSync(distMapPath, destMapPath);
  console.log(`[copy-web-embed] copied → ${destMapPath}`);
}
