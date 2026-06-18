#!/usr/bin/env node
/**
 * package-extension.mjs — Build + zip the Chrome extension for Web Store submission.
 *
 * Produces: dist-zip/nco-studio-web-editor-<version>.zip
 *
 * The zip contains an explicit allowlist of artifacts only — no source maps,
 * no web-embed.js, no TypeScript source files. The production esbuild gate
 * (NODE_ENV=production) ensures source maps and web-embed are never emitted.
 *
 * Usage: node packages/chrome-extension/scripts/package-extension.mjs
 *        (Run from the monorepo root, or from packages/chrome-extension/)
 */

import { execSync } from 'node:child_process';
import {
  cpSync,
  mkdirSync,
  rmSync,
  existsSync,
  readdirSync,
  statSync,
  readFileSync,
} from 'node:fs';
import { createWriteStream } from 'node:fs';
import { resolve, dirname, relative, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PKG_DIR = resolve(__dirname, '..');
const REPO_ROOT = resolve(PKG_DIR, '../..');

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function log(msg) {
  process.stdout.write(`[package-extension] ${msg}\n`);
}

function fail(msg) {
  process.stderr.write(`[package-extension] ERROR: ${msg}\n`);
  process.exit(1);
}

/** Recursively list all files under a directory. */
function listFiles(dir) {
  const results = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      results.push(...listFiles(full));
    } else {
      results.push(full);
    }
  }
  return results;
}

// ---------------------------------------------------------------------------
// Step 1: Production build
// ---------------------------------------------------------------------------

log('Running production build (NODE_ENV=production)...');
execSync('node esbuild.config.js', {
  cwd: PKG_DIR,
  env: { ...process.env, NODE_ENV: 'production' },
  stdio: 'inherit',
});
log('Build complete.');

// ---------------------------------------------------------------------------
// Step 2: Read manifest version
// ---------------------------------------------------------------------------

const manifest = JSON.parse(readFileSync(resolve(PKG_DIR, 'dist/manifest.json'), 'utf8'));
const version = manifest.version;
if (!version) fail('manifest.json has no version field');
log(`Extension version: ${version}`);

// ---------------------------------------------------------------------------
// Step 3: Assemble staging directory with explicit allowlist
// ---------------------------------------------------------------------------

const STAGING = resolve(PKG_DIR, 'dist-zip-staging');
rmSync(STAGING, { recursive: true, force: true });
mkdirSync(STAGING, { recursive: true });

const DIST = resolve(PKG_DIR, 'dist');

/**
 * Explicit allowlist — only these files ship to the store.
 * Side-panel entries are included only if the corresponding files exist;
 * they are omitted gracefully for extension variants that don't ship a side panel.
 */
const ALLOWLIST = [
  // Bundled scripts
  { src: join(DIST, 'content.js'),      dst: 'content.js' },
  { src: join(DIST, 'service-worker.js'), dst: 'service-worker.js' },
  { src: join(DIST, 'popup.js'),        dst: 'popup.js' },
  // HTML pages
  { src: join(DIST, 'popup.html'),      dst: 'popup.html' },
  // Extension manifest
  { src: join(DIST, 'manifest.json'),   dst: 'manifest.json' },
];

// Side panel — include only if built
if (existsSync(join(DIST, 'side-panel.js'))) {
  ALLOWLIST.push({ src: join(DIST, 'side-panel.js'), dst: 'side-panel.js' });
}
if (existsSync(join(DIST, 'side-panel.html'))) {
  ALLOWLIST.push({ src: join(DIST, 'side-panel.html'), dst: 'side-panel.html' });
}

// Copy allowlisted files
for (const { src, dst } of ALLOWLIST) {
  if (!existsSync(src)) fail(`Required artifact missing: ${src}`);
  cpSync(src, join(STAGING, dst));
  log(`  ✓ ${dst}`);
}

// Icons directory — copy recursively
const iconsDir = join(DIST, 'icons');
if (!existsSync(iconsDir)) fail(`Icons directory missing: ${iconsDir}`);
cpSync(iconsDir, join(STAGING, 'icons'), { recursive: true });
log('  ✓ icons/**');

// ---------------------------------------------------------------------------
// Step 4: Verify no forbidden artifacts in staging
// ---------------------------------------------------------------------------

log('Verifying staging directory — checking for forbidden artifacts...');
const staged = listFiles(STAGING);
const forbidden = [];

for (const f of staged) {
  const rel = relative(STAGING, f);
  if (rel.endsWith('.map'))        forbidden.push(`source map: ${rel}`);
  if (rel === 'web-embed.js')      forbidden.push(`web-embed: ${rel}`);
  if (rel.endsWith('.ts'))         forbidden.push(`TypeScript source: ${rel}`);
}

if (forbidden.length > 0) {
  fail(`Forbidden artifacts found in staging:\n  ${forbidden.join('\n  ')}`);
}
log('Staging verification passed — no source maps, no web-embed, no .ts files.');

// ---------------------------------------------------------------------------
// Step 5: Zip to dist-zip/
// ---------------------------------------------------------------------------

const OUT_DIR = resolve(PKG_DIR, 'dist-zip');
mkdirSync(OUT_DIR, { recursive: true });

const ZIP_NAME = `nco-studio-web-editor-${version}.zip`;
const ZIP_PATH = join(OUT_DIR, ZIP_NAME);

// Remove any pre-existing archive first — `zip -r` ADDS to an existing zip
// rather than replacing it, so a stale archive would retain entries no longer
// staged (e.g. old-brand icons from a prior build), leaking them into the store
// package. Deleting guarantees the zip mirrors the freshly-verified staging dir.
rmSync(ZIP_PATH, { force: true });

// Use system zip (available on macOS/Linux). Paths relative to staging dir.
execSync(`zip -r "${ZIP_PATH}" .`, {
  cwd: STAGING,
  stdio: 'inherit',
});
log(`Zip created: dist-zip/${ZIP_NAME}`);

// ---------------------------------------------------------------------------
// Step 6: Verify the zip
// ---------------------------------------------------------------------------

log('Verifying zip contents...');
const zipList = execSync(`unzip -l "${ZIP_PATH}"`, { encoding: 'utf8' });

const zipForbidden = [];
for (const line of zipList.split('\n')) {
  const trimmed = line.trim();
  if (trimmed.endsWith('.map'))        zipForbidden.push(`source map: ${trimmed}`);
  if (trimmed.includes('web-embed.js')) zipForbidden.push(`web-embed: ${trimmed}`);
  if (trimmed.endsWith('.ts'))         zipForbidden.push(`TypeScript source: ${trimmed}`);
}

if (zipForbidden.length > 0) {
  fail(`Forbidden artifacts found in zip:\n  ${zipForbidden.join('\n  ')}`);
}

// Confirm required artifacts present — match against individual filename columns
// to avoid false positives from substring matches in the raw unzip -l output.
const required = ['content.js', 'service-worker.js', 'popup.js', 'popup.html', 'manifest.json'];
for (const req of required) {
  const found = zipList.split('\n').some((line) => {
    const trimmed = line.trim();
    return trimmed === req || trimmed.endsWith(`   ${req}`);
  });
  if (!found) fail(`Required artifact missing from zip: ${req}`);
}

log('Zip verification passed.');
log(`\nStore-ready package: ${ZIP_PATH}`);
log('Upload at: https://chrome.google.com/webstore/devconsole');

// Cleanup staging
rmSync(STAGING, { recursive: true, force: true });
