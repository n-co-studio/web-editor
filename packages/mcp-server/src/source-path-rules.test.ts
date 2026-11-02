/**
 * `isPlausibleSourcePath` — config-shaped names and dependency directories (KL-7).
 *
 * The earlier rule was a list of tool names, so any tool not on the list
 * (`sentry.client.config.ts`, `lint-staged.config.js`) passed as a plausible
 * "element source". It now matches the `<name>.config|setup|conf|rc.<js|ts>`
 * shape and refuses any `node_modules` segment.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { Bridge } from './bridge.js';

function plausible(p: unknown): boolean {
  return (Bridge as unknown as { isPlausibleSourcePath(p: unknown): boolean }).isPlausibleSourcePath(p);
}

describe('isPlausibleSourcePath — config shapes and node_modules (KL-7)', () => {
  const rejected = [
    'sentry.client.config.ts',
    'commitlint.config.js',
    'lint-staged.config.js',
    'drizzle.config.ts',
    'jest.setup.js',
    'scripts/setup.js',
    'node_modules/x/index.js',
    'packages/a/Node_Modules/x.tsx',
  ];
  const accepted = [
    'src/components/Hero.tsx',
    'app/page.tsx',
    'pages/setup.tsx',
    'app/config.tsx',
    'app.config.tsx',
    'src/lib/drizzle.tsx',
    'src/routes/+page.svelte',
  ];

  for (const p of rejected) {
    it(`rejects ${p}`, () => {
      assert.equal(plausible(p), false);
    });
  }

  for (const p of accepted) {
    it(`accepts ${p}`, () => {
      assert.equal(plausible(p), true);
    });
  }
});
