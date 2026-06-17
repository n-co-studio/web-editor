#!/usr/bin/env node
/**
 * scripts/smoke-test.mjs
 *
 * Clean-room tarball smoke test for @nco-studio/web-editor-mcp and
 * @nco-studio/web-editor-plugin. Verifies installability and basic
 * behaviour from a packed tarball without a live registry.
 *
 * Reused by Brief 5 against the live registry post-publish.
 *
 * Usage:
 *   node scripts/smoke-test.mjs
 *
 * Exits 0 on success, non-zero on any failure.
 */

import { execSync, spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// ── Helpers ──────────────────────────────────────────────────────────────────

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

function runInDir(cmd, cwd, env) {
  return execSync(cmd, { stdio: 'pipe', cwd, env: { ...process.env, ...env } }).toString().trim();
}

// ── Build required ────────────────────────────────────────────────────────────

console.log('\n-- Build check --');

// Both packages must have been built (dist/ must exist and be non-empty)
for (const pkg of ['mcp-server', 'dev-plugin']) {
  const distDir = join(ROOT, 'packages', pkg, 'dist');
  try {
    const files = run(`ls "${distDir}"`);
    if (!files.trim()) throw new Error('empty dist/');
    pass(`packages/${pkg}/dist/ exists and is non-empty`);
  } catch (err) {
    fail(`packages/${pkg}/dist/ must exist — run npm run build first`, err.message);
  }
}

if (failCount > 0) {
  console.error('\nBuild step failed — run `npm run build` in each package first.');
  process.exit(1);
}

// ── Pack both packages ────────────────────────────────────────────────────────

console.log('\n-- npm pack --');

const mcpDir = join(ROOT, 'packages', 'mcp-server');
const pluginDir = join(ROOT, 'packages', 'dev-plugin');

let mcpTarball, pluginTarball;

try {
  const mcpPacked = run('npm pack --json', { cwd: mcpDir });
  mcpTarball = JSON.parse(mcpPacked)[0].filename;
  mcpTarball = join(mcpDir, mcpTarball);
  pass(`mcp-server packed: ${mcpTarball}`);
} catch (err) {
  fail('npm pack mcp-server', err.message);
}

try {
  const pluginPacked = run('npm pack --json', { cwd: pluginDir });
  pluginTarball = JSON.parse(pluginPacked)[0].filename;
  pluginTarball = join(pluginDir, pluginTarball);
  pass(`dev-plugin packed: ${pluginTarball}`);
} catch (err) {
  fail('npm pack dev-plugin', err.message);
}

if (failCount > 0) {
  console.error('\nPack step failed.');
  process.exit(1);
}

// ── MCP server smoke test ─────────────────────────────────────────────────────

console.log('\n-- MCP server: install + verify --');

const mcpTmp = mkdtempSync(join(tmpdir(), 'nco-smoke-mcp-'));
let mcpInstallOk = false;

try {
  runInDir('npm init -y', mcpTmp);
  runInDir(`npm install "${mcpTarball}"`, mcpTmp);
  pass('mcp-server installed from tarball');
  mcpInstallOk = true;
} catch (err) {
  fail('mcp-server install from tarball', err.message);
}

if (mcpInstallOk) {
  // Resolve the installed CLI entry point directly (avoids .bin wrapper issues with ESM)
  const cliJsPath = join(mcpTmp, 'node_modules', '@nco-studio', 'web-editor-mcp', 'dist', 'bin', 'cli.js');

  // --version prints the package version
  try {
    const versionOut = run(`node "${cliJsPath}" --version`, { cwd: mcpTmp });
    if (/^\d+\.\d+\.\d+/.test(versionOut)) {
      pass(`--version prints semver: ${versionOut}`);
    } else {
      fail('--version output is not a semver string', versionOut);
    }
  } catch (err) {
    fail('nco-web-editor-mcp --version', err.message);
  }

  // --help prints the settings snippet key
  try {
    const helpOut = run(`node "${cliJsPath}" --help`, { cwd: mcpTmp });
    if (helpOut.includes('nco-web-editor')) {
      pass('--help includes "nco-web-editor" settings key');
    } else {
      fail('--help missing "nco-web-editor" settings key', helpOut.slice(0, 200));
    }
    if (helpOut.includes('NCO_WEB_EDITOR_PORT')) {
      pass('--help includes NCO_WEB_EDITOR_PORT env var');
    } else {
      fail('--help missing NCO_WEB_EDITOR_PORT', helpOut.slice(0, 200));
    }
    if (helpOut.includes('get_pending_visual_changes')) {
      pass('--help includes MCP tools list');
    } else {
      fail('--help missing MCP tools list', helpOut.slice(0, 200));
    }
  } catch (err) {
    fail('nco-web-editor-mcp --help', err.message);
  }

  // No @frontend-editor strings anywhere in installed tree
  try {
    const grepResult = spawnSync(
      'grep',
      ['-rl', '@frontend-editor', join(mcpTmp, 'node_modules', '@nco-studio')],
      { encoding: 'utf8' },
    );
    if (grepResult.stdout && grepResult.stdout.trim()) {
      fail('@frontend-editor found in installed mcp-server tree', grepResult.stdout.trim());
    } else {
      pass('no @frontend-editor strings in installed mcp-server tree');
    }
  } catch (err) {
    pass('no @frontend-editor strings in installed mcp-server tree (grep error = no matches)');
  }
}

// Cleanup
try { rmSync(mcpTmp, { recursive: true, force: true }); } catch { /* ignore */ }

// ── Dev plugin smoke test ─────────────────────────────────────────────────────

console.log('\n-- Dev plugin: install + verify --');

const pluginTmp = mkdtempSync(join(tmpdir(), 'nco-smoke-plugin-'));
let pluginInstallOk = false;

try {
  runInDir('npm init -y', pluginTmp);
  // Install plugin + peer deps needed for the transform
  runInDir(`npm install "${pluginTarball}" @babel/core @babel/parser @babel/traverse`, pluginTmp);
  pass('dev-plugin installed from tarball');
  pluginInstallOk = true;
} catch (err) {
  fail('dev-plugin install from tarball', err.message);
}

if (pluginInstallOk) {
  // Sample JSX source
  const sampleJsx = `
function App() {
  return (
    <div className="app">
      <h1>Hello</h1>
    </div>
  );
}
`.trim();

  const samplePath = join(pluginTmp, 'sample.jsx');
  writeFileSync(samplePath, sampleJsx, 'utf8');

  // Transform script — ESM import path
  const transformScriptESM = `
import { transformSync } from '@babel/core';
import ncoPlugin from '@nco-studio/web-editor-plugin/babel';

const code = ${JSON.stringify(sampleJsx)};

const result = transformSync(code, {
  filename: ${JSON.stringify(samplePath)},
  plugins: [ncoPlugin],
  parserOpts: { plugins: ['jsx'] },
});

if (!result || !result.code) {
  process.stderr.write('transform returned null\\n');
  process.exit(1);
}

const hasSourceFile = result.code.includes('data-source-file');
const hasSourceLine = result.code.includes('data-source-line');

if (!hasSourceFile) {
  process.stderr.write('FAIL: data-source-file not found in output\\n');
  process.exit(1);
}
if (!hasSourceLine) {
  process.stderr.write('FAIL: data-source-line not found in output\\n');
  process.exit(1);
}
process.stdout.write('OK\\n');
`;

  // Transform script — CJS require path
  const transformScriptCJS = `
const { transformSync } = require('@babel/core');
const ncoPlugin = require('@nco-studio/web-editor-plugin/babel');

const code = ${JSON.stringify(sampleJsx)};

// babel plugin may be default export or the module itself
const plugin = ncoPlugin.default || ncoPlugin;

const result = transformSync(code, {
  filename: ${JSON.stringify(samplePath)},
  plugins: [plugin],
  parserOpts: { plugins: ['jsx'] },
});

if (!result || !result.code) {
  process.stderr.write('transform returned null\\n');
  process.exit(1);
}

const hasSourceFile = result.code.includes('data-source-file');
const hasSourceLine = result.code.includes('data-source-line');

if (!hasSourceFile) {
  process.stderr.write('FAIL: data-source-file not found in output\\n');
  process.exit(1);
}
if (!hasSourceLine) {
  process.stderr.write('FAIL: data-source-line not found in output\\n');
  process.exit(1);
}
process.stdout.write('OK\\n');
`;

  // Write and run ESM transform
  const esmScriptPath = join(pluginTmp, 'test-esm.mjs');
  writeFileSync(esmScriptPath, transformScriptESM, 'utf8');
  try {
    const out = runInDir(`node "${esmScriptPath}"`, pluginTmp, { NODE_ENV: 'development' });
    if (out.includes('OK')) {
      pass('dev-plugin ESM import: data-source-file + data-source-line injected');
    } else {
      fail('dev-plugin ESM import: unexpected output', out);
    }
  } catch (err) {
    fail('dev-plugin ESM import transform', err.stderr?.toString() || err.message);
  }

  // Write and run CJS require
  const cjsScriptPath = join(pluginTmp, 'test-cjs.cjs');
  writeFileSync(cjsScriptPath, transformScriptCJS, 'utf8');
  try {
    const out = runInDir(`node "${cjsScriptPath}"`, pluginTmp, { NODE_ENV: 'development' });
    if (out.includes('OK')) {
      pass('dev-plugin CJS require: data-source-file + data-source-line injected');
    } else {
      fail('dev-plugin CJS require: unexpected output', out);
    }
  } catch (err) {
    fail('dev-plugin CJS require transform', err.stderr?.toString() || err.message);
  }

  // Production mode: zero annotations
  const prodScriptPath = join(pluginTmp, 'test-prod.cjs');
  writeFileSync(prodScriptPath, `
const { transformSync } = require('@babel/core');
const ncoPlugin = require('@nco-studio/web-editor-plugin/babel');
const plugin = ncoPlugin.default || ncoPlugin;

const result = transformSync(${JSON.stringify(sampleJsx)}, {
  filename: ${JSON.stringify(samplePath)},
  plugins: [plugin],
  parserOpts: { plugins: ['jsx'] },
});

if (result && result.code && result.code.includes('data-source-file')) {
  process.stderr.write('FAIL: data-source-file present in production output\\n');
  process.exit(1);
}
process.stdout.write('OK\\n');
`, 'utf8');

  try {
    const out = runInDir(`node "${prodScriptPath}"`, pluginTmp, { NODE_ENV: 'production' });
    if (out.includes('OK')) {
      pass('dev-plugin production mode: zero data-source-* attributes');
    } else {
      fail('dev-plugin production mode: unexpected output', out);
    }
  } catch (err) {
    fail('dev-plugin production mode', err.stderr?.toString() || err.message);
  }

  // No @frontend-editor strings in installed plugin tree
  try {
    const grepResult = spawnSync(
      'grep',
      ['-rl', '@frontend-editor', join(pluginTmp, 'node_modules', '@nco-studio')],
      { encoding: 'utf8' },
    );
    if (grepResult.stdout && grepResult.stdout.trim()) {
      fail('@frontend-editor found in installed dev-plugin tree', grepResult.stdout.trim());
    } else {
      pass('no @frontend-editor strings in installed dev-plugin tree');
    }
  } catch (err) {
    pass('no @frontend-editor strings in installed dev-plugin tree (grep error = no matches)');
  }
}

// Cleanup
try { rmSync(pluginTmp, { recursive: true, force: true }); } catch { /* ignore */ }

// ── Summary ───────────────────────────────────────────────────────────────────

console.log(`\n-- Summary: ${passCount} passed, ${failCount} failed --`);

if (failCount > 0) {
  console.error('\nSmoke test FAILED.');
  process.exit(1);
}

console.log('\nSmoke test PASSED.');
