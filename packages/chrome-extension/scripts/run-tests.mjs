#!/usr/bin/env node
/**
 * Lightweight test runner for the chrome-extension package.
 * Bundles each `*.test.ts` colocated with source via esbuild, then runs
 * the bundle through Node's built-in test runner (`node:test`).
 *
 * Zero new dev-deps: esbuild is already used for the production build.
 */
import { build } from 'esbuild';
import { readdir, mkdtemp, rm } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, relative, join } from 'node:path';
import { tmpdir } from 'node:os';

const __dirname = dirname(fileURLToPath(import.meta.url));
const pkgRoot = resolve(__dirname, '..');

async function collectTestFiles() {
  const matches = [];
  async function walk(dir) {
    const entries = await readdir(dir, { withFileTypes: true });
    for (const e of entries) {
      const full = join(dir, e.name);
      if (e.isDirectory()) {
        await walk(full);
      } else if (e.isFile() && e.name.endsWith('.test.ts')) {
        matches.push(relative(pkgRoot, full));
      }
    }
  }
  await walk(resolve(pkgRoot, 'src'));
  return matches.sort();
}

async function main() {
  const tests = await collectTestFiles();
  if (tests.length === 0) {
    console.log('No *.test.ts files found.');
    return;
  }

  const outDir = await mkdtemp(join(tmpdir(), 'fe-tests-'));

  try {
    const entries = tests.map((t) => ({
      in: resolve(pkgRoot, t),
      out: t.replace(/\.ts$/, '').replace(/^src\//, ''),
    }));

    await build({
      entryPoints: entries,
      outdir: outDir,
      bundle: true,
      format: 'esm',
      platform: 'node',
      target: 'node20',
      sourcemap: 'inline',
      external: ['node:*'],
      logLevel: 'warning',
    });

    const bundled = entries.map((e) => resolve(outDir, `${e.out}.js`));
    const args = ['--test', ...bundled];
    console.log(`Running ${bundled.length} test bundle(s) via node ${args[0]}...`);
    for (const b of bundled) {
      console.log(`  - ${relative(pkgRoot, b.replace(outDir, 'tmp'))}`);
    }
    const result = spawnSync('node', args, { stdio: 'inherit' });
    process.exit(result.status ?? 1);
  } finally {
    await rm(outDir, { recursive: true, force: true });
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
