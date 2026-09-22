/**
 * Unit tests for the onInstalled handler.
 * Runs via node:test (see scripts/run-tests.mjs).
 * Stubs the global `chrome` object — no browser required.
 */
import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';

// ---------------------------------------------------------------------------
// Chrome stub
// ---------------------------------------------------------------------------

let tabsCreateCalls: Array<{ url: string }> = [];

const chromeMock = {
  runtime: {
    OnInstalledReason: {
      INSTALL: 'install',
      UPDATE: 'update',
      CHROME_UPDATE: 'chrome_update',
      SHARED_MODULE_UPDATE: 'shared_module_update',
    } as const,
  },
  tabs: {
    create(opts: { url: string }): Promise<void> {
      tabsCreateCalls.push(opts);
      return Promise.resolve();
    },
  },
};

// ---------------------------------------------------------------------------
// Stub-before-import ordering
// ---------------------------------------------------------------------------
// This file is run via run-tests.mjs which bundles each *.test.ts with
// esbuild (bundle: true, format: esm). esbuild inlines imported modules in
// declaration order rather than hoisting static imports ahead of all
// statements (the standard ESM behaviour). As a result, the chrome stub
// assigned below is in scope when `handle-installed.ts` is first evaluated.
//
// If this test is ever run *without* the esbuild bundler (e.g. directly via
// `node --test` with a native ESM loader), static imports will be hoisted and
// the stub will not be set during module evaluation. The test would still
// pass in that scenario because `handle-installed.ts` accesses `chrome` only
// inside the function body — but future changes to that module that add
// module-level chrome access would fail silently. Document this constraint
// here so it is visible.
(globalThis as unknown as Record<string, unknown>).chrome = chromeMock;

import { handleInstalled } from './handle-installed.js';
import { GUIDE_URL } from '../shared/constants.js';

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('handleInstalled', () => {
  beforeEach(() => {
    tabsCreateCalls = [];
  });

  it('opens GUIDE_URL exactly once for reason=install', () => {
    handleInstalled({ reason: 'install' } as chrome.runtime.InstalledDetails);
    assert.equal(tabsCreateCalls.length, 1);
    assert.equal(tabsCreateCalls[0].url, GUIDE_URL);
  });

  it('does not open a tab for reason=update', () => {
    handleInstalled({ reason: 'update' } as chrome.runtime.InstalledDetails);
    assert.equal(tabsCreateCalls.length, 0);
  });

  it('does not open a tab for reason=chrome_update', () => {
    handleInstalled({ reason: 'chrome_update' } as chrome.runtime.InstalledDetails);
    assert.equal(tabsCreateCalls.length, 0);
  });

  it('does not open a tab for reason=shared_module_update', () => {
    handleInstalled({ reason: 'shared_module_update' } as chrome.runtime.InstalledDetails);
    assert.equal(tabsCreateCalls.length, 0);
  });
});
