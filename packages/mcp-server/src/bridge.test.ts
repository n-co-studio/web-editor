/**
 * Security tests for MCP bridge rejection paths.
 *
 * Coverage:
 * - isAllowedOrigin: WebSocket origin allowlist (accept extension + localhost; reject foreign, missing, look-alike)
 * - confineToProject: path traversal + absolute-outside-project rejection
 * - resolveAssetDir: traversal segment rejection falls back to safe default
 *
 * All three tested functions are private; accessed via unknown cast (same
 * pattern as batch-identity.test.ts which casts processDiffBatch). No logic
 * changes were required to reach them.
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Bridge } from './bridge.js';

// ---------------------------------------------------------------------------
// Type-cast helpers for private API access
// ---------------------------------------------------------------------------

function allowedOrigin(origin: string | undefined): boolean {
  return (Bridge as unknown as { isAllowedOrigin(o: string | undefined): boolean })
    .isAllowedOrigin(origin);
}

function confine(bridge: Bridge, p: string): string {
  return (bridge as unknown as { confineToProject(p: string): string })
    .confineToProject(p);
}

function resolveAsset(bridge: Bridge, src: string): Promise<string> {
  return (bridge as unknown as { resolveAssetDir(src: string): Promise<string> })
    .resolveAssetDir(src);
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

let tmpDir: string;
let bridge: Bridge;

before(async () => {
  tmpDir = await mkdtemp(join(tmpdir(), 'nco-bridge-sec-test-'));
  bridge = new Bridge(tmpDir);
});

after(async () => {
  await rm(tmpDir, { recursive: true, force: true });
});

// ---------------------------------------------------------------------------
// isAllowedOrigin
// ---------------------------------------------------------------------------

describe('isAllowedOrigin — accept cases', () => {
  it('accepts chrome-extension:// origin', () => {
    assert.equal(allowedOrigin('chrome-extension://abcdefghijklmnop/'), true);
  });

  it('accepts moz-extension:// origin', () => {
    assert.equal(allowedOrigin('moz-extension://abcdefghijklmnop/'), true);
  });

  it('accepts http://localhost with port', () => {
    assert.equal(allowedOrigin('http://localhost:3000'), true);
  });

  it('accepts http://127.0.0.1 with port', () => {
    assert.equal(allowedOrigin('http://127.0.0.1:5173'), true);
  });

  it('accepts http://[::1] (IPv6 loopback)', () => {
    assert.equal(allowedOrigin('http://[::1]:8080'), true);
  });
});

describe('isAllowedOrigin — reject cases', () => {
  it('rejects undefined origin', () => {
    assert.equal(allowedOrigin(undefined), false);
  });

  it('rejects empty string origin', () => {
    assert.equal(allowedOrigin(''), false);
  });

  it('rejects foreign https origin', () => {
    assert.equal(allowedOrigin('https://evil.com'), false);
  });

  it('rejects look-alike host: localhost.evil.com', () => {
    assert.equal(allowedOrigin('http://localhost.evil.com'), false);
  });

  it('rejects look-alike host: 127.0.0.1.attacker.net', () => {
    assert.equal(allowedOrigin('http://127.0.0.1.attacker.net'), false);
  });

  it('rejects non-loopback private address', () => {
    assert.equal(allowedOrigin('http://192.168.1.1:3000'), false);
  });
});

// ---------------------------------------------------------------------------
// confineToProject
// ---------------------------------------------------------------------------

describe('confineToProject — accept cases', () => {
  it('accepts a relative path inside the project', () => {
    const result = confine(bridge, 'src/app.tsx');
    assert.ok(result.includes('src'), `expected result to include 'src', got: ${result}`);
    assert.ok(result.startsWith(tmpDir), `expected result to start with tmpDir, got: ${result}`);
  });

  it('accepts a nested relative path', () => {
    const result = confine(bridge, 'public/images/hero.jpg');
    assert.ok(result.startsWith(tmpDir));
  });

  it('accepts the project root itself', () => {
    const result = confine(bridge, '.');
    assert.equal(result, tmpDir);
  });
});

describe('confineToProject — reject cases', () => {
  it('throws for single-step ../ traversal', () => {
    assert.throws(
      () => confine(bridge, '../escape'),
      /escapes project directory/i,
    );
  });

  it('throws for deep ../ traversal', () => {
    assert.throws(
      () => confine(bridge, '../../etc/passwd'),
      /escapes project directory/i,
    );
  });

  it('throws for absolute path outside the project', () => {
    assert.throws(
      () => confine(bridge, '/etc/passwd'),
      /escapes project directory/i,
    );
  });

  it('throws for absolute path that happens to be /tmp but outside tmpDir', () => {
    assert.throws(
      () => confine(bridge, '/tmp'),
      /escapes project directory/i,
    );
  });
});

// ---------------------------------------------------------------------------
// resolveAssetDir — traversal rejection
// ---------------------------------------------------------------------------

describe('resolveAssetDir — traversal rejection', () => {
  // Note: the URL constructor + base normalizes away ../ segments before the
  // `..` segment check runs (defense-in-depth; confineToProject is the primary
  // guard). The meaningful guarantee of resolveAssetDir is: the returned path
  // is always relative and never contains ".." segments itself.

  it('does not return a path containing .. for a URL with traversal segments', async () => {
    // new URL('http://localhost:3000/../../../etc/passwd').pathname → '/etc/passwd'
    // URL normalization strips the traversal; dirPart = 'etc' (no '..' left).
    // Result is a safe relative path — the important invariant is no '..' leaks out.
    const result = await resolveAsset(bridge, 'http://localhost:3000/../../../etc/passwd');
    assert.ok(!result.includes('..'), `result must not contain ..: ${result}`);
    assert.ok(!result.startsWith('/'), `result must be relative, got: ${result}`);
  });

  it('does not return a path containing .. for a path with embedded traversal', async () => {
    // new URL('/../escape/secret.jpg', 'http://localhost').pathname → '/escape/secret.jpg'
    const result = await resolveAsset(bridge, '/../escape/secret.jpg');
    assert.ok(!result.includes('..'), `result must not contain ..: ${result}`);
    assert.ok(!result.startsWith('/'), `result must be relative, got: ${result}`);
  });

  it('returns fallback (public/images) for empty fromValue', async () => {
    const result = await resolveAsset(bridge, '');
    assert.match(result, /^public\/images/);
  });

  it('returns a non-traversal relative path for a normal src URL', async () => {
    // No dirs exist in tmpDir, so it returns the first candidate: public/images
    const result = await resolveAsset(bridge, 'http://localhost:3000/images/hero.jpg');
    assert.ok(!result.includes('..'), `result must not contain ..: ${result}`);
    assert.ok(!result.startsWith('/'), `result must be relative, got: ${result}`);
  });

  it('returns fallback when URL path has only a root (no dir component)', async () => {
    const result = await resolveAsset(bridge, 'http://localhost:3000/hero.jpg');
    // dirname of '/hero.jpg' is '/', dirPart becomes '' → fallback
    assert.match(result, /^public\/images/);
  });
});
