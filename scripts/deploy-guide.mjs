#!/usr/bin/env node
/**
 * deploy-guide.mjs — Build the guide page and sync it into the nco.studio site repo.
 *
 * The guide lives at examples/demo-app (it doubles as the local practice target).
 * Its production build is what nco.studio serves at /web-editor/.
 *
 * Expected layout:
 *   /Users/Mark/Developer/
 *     nco-studio-site/                   ← static site repo (auto-deploys on push)
 *       web-editor/
 *         <everything the guide build emits>  ← replaced by this script
 *         privacy/                            ← never touched
 *     _tools/_extensions/web-editor/     ← this repo
 *
 * Usage:
 *   npm run deploy:site
 *   NCO_SITE_DIR=/path/to/site npm run deploy:site
 *
 * This script never runs git in the site repo — committing and pushing (which
 * triggers the deploy) stays an operator decision.
 */
import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, rmSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '..');
const APP_DIR = resolve(REPO_ROOT, 'examples/demo-app');
const DIST_DIR = resolve(APP_DIR, 'dist');

const SITE_DIR_OVERRIDE = (process.env.NCO_SITE_DIR ?? '').trim();
const SITE_DIR = resolve(SITE_DIR_OVERRIDE || '/Users/Mark/Developer/nco-studio-site');
const DEST_DIR = resolve(SITE_DIR, 'web-editor');

/**
 * Entries this script owns inside <site>/web-editor/ are whatever the build
 * emits, so a new file in examples/demo-app/public/ ships without editing this
 * script. Everything else in the destination is left alone — PROTECTED names
 * are never written or pruned even if a build somehow emits them.
 */
const PROTECTED = ['privacy'];

function log(msg) {
  console.log(`[deploy-guide] ${msg}`);
}

function fail(msg) {
  console.error(`[deploy-guide] ERROR: ${msg}`);
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Step 1: Site repo must exist (this script writes into it, never creates it)
// ---------------------------------------------------------------------------

if (!existsSync(SITE_DIR)) {
  fail(
    `site repo not found at: ${SITE_DIR}\n` +
      '       clone it first, or set NCO_SITE_DIR to its path',
  );
}

// ---------------------------------------------------------------------------
// Step 2: Build the guide for the /web-editor/ base path
// ---------------------------------------------------------------------------

log('Building guide (npm run build:site -w examples/demo-app)...');
execFileSync('npm', ['run', 'build:site', '-w', 'examples/demo-app'], {
  cwd: REPO_ROOT,
  stdio: 'inherit',
});

if (!existsSync(join(DIST_DIR, 'index.html'))) {
  fail(`build produced no index.html at ${DIST_DIR}`);
}

// ---------------------------------------------------------------------------
// Step 3: Replace the managed files, leaving everything else (privacy/) alone
// ---------------------------------------------------------------------------

mkdirSync(DEST_DIR, { recursive: true });

for (const name of readdirSync(DIST_DIR)) {
  if (PROTECTED.includes(name)) {
    log(`skipped ${name} (protected — this script never writes it)`);
    continue;
  }

  const dest = join(DEST_DIR, name);

  // Prune first so stale hashed bundles from an earlier build do not pile up.
  rmSync(dest, { recursive: true, force: true });
  cpSync(join(DIST_DIR, name), dest, { recursive: true });
  log(`wrote ${relative(SITE_DIR, dest)}`);
}

// ---------------------------------------------------------------------------
// Step 4: Report what the site repo now holds
// ---------------------------------------------------------------------------

const listing = readdirSync(DEST_DIR)
  .map((name) => (statSync(join(DEST_DIR, name)).isDirectory() ? `${name}/` : name))
  .sort();

log(`web-editor/ now contains: ${listing.join(' ')}`);
log('');
log(`Deployed to ${SITE_DIR}. Review, commit and push there to publish:`);
log(`  cd ${SITE_DIR} && git status`);
