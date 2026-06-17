#!/usr/bin/env node
/**
 * scripts/publish-dry-run.mjs
 *
 * Runs `npm publish --dry-run` for both public packages and asserts that
 * the tarball contents match expected criteria:
 *   - dist/ files present
 *   - LICENSE present
 *   - README.md present
 *   - No src/ files
 *   - No @frontend-editor strings
 *   - bin entry present (mcp-server only)
 *   - No non-dist .ts files
 *
 * Does NOT publish — safe to run at any time.
 *
 * Usage:
 *   node scripts/publish-dry-run.mjs
 *
 * Exits 0 on success, non-zero on any failure.
 */

import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const ROOT = resolve(__dirname, '..');

let failCount = 0;
let passCount = 0;

function pass(label) {
  console.log(`  PASS  ${label}`);
  passCount++;
}

function fail(label, detail) {
  console.error(`  FAIL  ${label}`);
  if (detail) console.error(`        ${detail}`);
  failCount++;
}

function run(cmd, opts = {}) {
  return execSync(cmd, { stdio: 'pipe', ...opts }).toString().trim();
}

// ── Run dry-run for a package and parse the file list ─────────────────────

function dryRunFiles(pkgDir) {
  // npm publish --dry-run emits the file list to stderr as "npm notice" lines.
  // Merge stderr into stdout to capture them. The --dry-run flag prevents any
  // actual publish.
  // --ignore-scripts skips prepublishOnly to avoid triggering a rebuild here.
  // The verify step (smoke-test + build) already guarantees the dist is fresh.
  const out = run('npm publish --dry-run --ignore-scripts 2>&1 || true', { cwd: pkgDir });

  // File list format (npm v7+):
  //   npm notice 1.1kB LICENSE
  //   npm notice 70.9kB dist/bin/cli.js
  // Lines with file sizes appear between "Tarball Contents" and "Tarball Details".
  const lines = out.split('\n');
  const files = [];
  let inContents = false;
  for (const line of lines) {
    if (line.includes('Tarball Contents')) { inContents = true; continue; }
    if (line.includes('Tarball Details')) { inContents = false; continue; }
    if (!inContents) continue;
    // Match: "npm notice 1.1kB LICENSE" or "npm notice 70.9kB dist/bin/cli.js"
    const m = line.match(/npm notice\s+[\d.]+[a-zA-Z]+\s+(.+)$/);
    if (m) {
      files.push(m[1].trim());
    }
  }
  return { files, raw: out };
}

// ── Assertions ─────────────────────────────────────────────────────────────

function assertDryRun(pkgName, pkgDir, { expectBin = false } = {}) {
  console.log(`\n-- ${pkgName} dry-run --`);

  let files;
  let raw;
  try {
    ({ files, raw } = dryRunFiles(pkgDir));
  } catch (err) {
    fail(`${pkgName}: npm publish --dry-run failed`, err.message.slice(0, 300));
    return;
  }

  if (files.length === 0) {
    // Fall back: parse from non-JSON output
    fail(`${pkgName}: no files detected in dry-run output (check npm version)`, raw.slice(0, 300));
    return;
  }

  // dist/ present
  const hasDist = files.some(f => f.startsWith('dist/'));
  if (hasDist) {
    pass(`${pkgName}: dist/ files present`);
  } else {
    fail(`${pkgName}: no dist/ files in tarball`, `files: ${files.slice(0, 10).join(', ')}`);
  }

  // LICENSE present
  if (files.some(f => f === 'LICENSE')) {
    pass(`${pkgName}: LICENSE present`);
  } else {
    fail(`${pkgName}: LICENSE missing from tarball`);
  }

  // README.md present
  if (files.some(f => f === 'README.md')) {
    pass(`${pkgName}: README.md present`);
  } else {
    fail(`${pkgName}: README.md missing from tarball`);
  }

  // No src/ files
  const srcFiles = files.filter(f => f.startsWith('src/'));
  if (srcFiles.length === 0) {
    pass(`${pkgName}: no src/ files in tarball`);
  } else {
    fail(`${pkgName}: src/ files found in tarball`, srcFiles.join(', '));
  }

  // No .ts files (except .d.ts declaration files which live in dist/)
  const rawTsFiles = files.filter(f => f.endsWith('.ts') && !f.endsWith('.d.ts'));
  if (rawTsFiles.length === 0) {
    pass(`${pkgName}: no raw .ts source files in tarball`);
  } else {
    fail(`${pkgName}: raw .ts files found in tarball`, rawTsFiles.join(', '));
  }

  // No @frontend-editor strings in the package.json that would be published
  try {
    const pkgJson = run(`cat "${pkgDir}/package.json"`);
    if (pkgJson.includes('@frontend-editor')) {
      fail(`${pkgName}: @frontend-editor found in package.json`);
    } else {
      pass(`${pkgName}: no @frontend-editor in package.json`);
    }
  } catch {
    fail(`${pkgName}: could not read package.json`);
  }

  // bin entry present (mcp-server only)
  if (expectBin) {
    const hasBin = files.some(f => f.startsWith('dist/bin/'));
    if (hasBin) {
      pass(`${pkgName}: dist/bin/ present (CLI entry)`);
    } else {
      fail(`${pkgName}: dist/bin/ missing (CLI entry expected)`, `files: ${files.filter(f => f.startsWith('dist')).join(', ')}`);
    }
  }
}

// ── Main ──────────────────────────────────────────────────────────────────

const mcpDir = resolve(ROOT, 'packages', 'mcp-server');
const pluginDir = resolve(ROOT, 'packages', 'dev-plugin');

console.log('\n== Publish dry-run verification ==');
console.log('Running npm publish --dry-run for both public packages.');
console.log('No packages will be published.\n');

// Check that dist/ exists (build required before dry-run is meaningful)
for (const [name, dir] of [['mcp-server', mcpDir], ['dev-plugin', pluginDir]]) {
  try {
    run(`ls "${dir}/dist"`);
  } catch {
    console.error(`\nERROR: ${name}/dist/ not found — run npm run build first.`);
    process.exit(1);
  }
}

assertDryRun('@nco-studio/web-editor-mcp', mcpDir, { expectBin: true });
assertDryRun('@nco-studio/web-editor-plugin', pluginDir, { expectBin: false });

// ── Summary ───────────────────────────────────────────────────────────────

console.log(`\n-- Summary: ${passCount} passed, ${failCount} failed --`);

if (failCount > 0) {
  console.error('\nDry-run verification FAILED. Fix the issues above before publishing.');
  process.exit(1);
}

console.log('\nDry-run verification PASSED. Safe to publish (modulo auth).');
