/**
 * Security tests for MCP bridge rejection paths.
 *
 * Coverage:
 * - isAllowedOrigin: WebSocket origin allowlist (accept extension + localhost; reject foreign, missing, look-alike)
 * - confineToProject: path traversal + absolute-outside-project rejection
 * - resolveAssetDir: traversal segment rejection falls back to safe default
 * - resolveAssetDir: dot-directory rejection (HACK-011)
 * - assetExt / matchesMagic / svgIsSafe: asset type allowlist (HACK-011)
 * - isPlausibleSourcePath: page-controlled source hints (HACK-012)
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

function assetExt(bridge: Bridge, mime: string, filename?: string): string | null {
  return (bridge as unknown as { assetExt(m: string, f?: string): string | null })
    .assetExt(mime, filename);
}

function matchesMagic(ext: string, buf: Buffer): boolean {
  return (Bridge as unknown as { matchesMagic(e: string, b: Buffer): boolean })
    .matchesMagic(ext, buf);
}

function svgIsSafe(buf: Buffer): boolean {
  return (Bridge as unknown as { svgIsSafe(b: Buffer): boolean }).svgIsSafe(buf);
}

function plausibleSource(p: unknown): boolean {
  return (Bridge as unknown as { isPlausibleSourcePath(p: unknown): boolean })
    .isPlausibleSourcePath(p);
}

const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);

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

// ---------------------------------------------------------------------------
// HACK-011 — asset writes are confined to image/video types in asset dirs
//
// The chain these close: anything that can reach the bridge could pick both
// the directory and the extension of a file written into the project. A
// dot-directory plus an arbitrary extension meant `.github/workflows/x.yml`
// (runs on push, with repo secrets) or `.claude/agents/x.md` (read as agent
// instructions later). confineToProject kept the write inside the repo, which
// is not the same as keeping it harmless.
// ---------------------------------------------------------------------------

describe('resolveAssetDir — dot-directory rejection (HACK-011)', () => {
  for (const src of [
    '/.github/workflows/x.png',
    'http://localhost:3000/.github/workflows/x.png',
    '/.claude/agents/x.png',
    '/.cursor/rules/x.png',
    '/assets/.hidden/x.png',
  ]) {
    it(`falls back instead of selecting a dot-directory: ${src}`, async () => {
      const result = await resolveAsset(bridge, src);
      assert.match(result, /^public\/images/);
      assert.ok(
        !result.split(/[\\/]/).some((seg) => seg.startsWith('.')),
        `no segment may start with a dot: ${result}`,
      );
    });
  }

  it('still resolves an ordinary asset directory', async () => {
    const result = await resolveAsset(bridge, '/images/hero.png');
    assert.ok(result.endsWith('images'), `expected an images dir, got: ${result}`);
  });
});

describe('assetExt — extension allowlist (HACK-011)', () => {
  it('ignores a non-asset extension on the picked filename', () => {
    // The whole point: the caller does not get to name the extension.
    assert.equal(assetExt(bridge, 'image/png', 'payload.yml'), '.png');
    assert.equal(assetExt(bridge, 'image/png', 'payload.html'), '.png');
    assert.equal(assetExt(bridge, 'image/png', 'payload.php'), '.png');
  });

  it('honours an allowlisted extension on the picked filename', () => {
    assert.equal(assetExt(bridge, 'image/png', 'logo.webp'), '.webp');
  });

  it('returns null for a non-asset MIME type', () => {
    assert.equal(assetExt(bridge, 'text/html'), null);
    assert.equal(assetExt(bridge, 'application/x-yaml'), null);
    assert.equal(assetExt(bridge, 'text/html', 'x.yml'), null);
  });

  it('falls back to the MIME extension when no filename is given', () => {
    assert.equal(assetExt(bridge, 'image/jpeg'), '.jpg');
  });
});

describe('matchesMagic — declared type must match the bytes (HACK-011)', () => {
  it('accepts a real PNG under .png', () => {
    assert.equal(matchesMagic('.png', PNG), true);
  });

  it('rejects non-image bytes under an image extension', () => {
    assert.equal(matchesMagic('.png', Buffer.from('name: pwn\non: push\n')), false);
    assert.equal(matchesMagic('.jpg', Buffer.from('<html></html>')), false);
  });

  it('rejects an unknown extension outright', () => {
    assert.equal(matchesMagic('.yml', PNG), false);
  });
});

describe('svgIsSafe — SVG is screened, not trusted (HACK-011)', () => {
  it('accepts a plain SVG', () => {
    assert.equal(svgIsSafe(Buffer.from('<svg><rect width="1" height="1"/></svg>')), true);
  });

  for (const bad of [
    '<svg><script>alert(1)</script></svg>',
    '<svg onload="alert(1)"></svg>',
    '<svg><a href="javascript:alert(1)">x</a></svg>',
    '<svg><foreignObject><body xmlns="http://www.w3.org/1999/xhtml"/></foreignObject></svg>',
  ]) {
    it(`rejects scripted SVG: ${bad.slice(0, 40)}`, () => {
      assert.equal(svgIsSafe(Buffer.from(bad)), false);
    });
  }
});

// ---------------------------------------------------------------------------
// HACK-012 — sourceFile is a page-controlled hint, not a trusted path
//
// It is copied straight out of a data-source-file attribute, which untrusted
// page content (a seeded DB, a prod dump, user-generated content on the dev
// server) can set. The agent is told it is "the exact place to edit".
// ---------------------------------------------------------------------------

describe('isPlausibleSourcePath (HACK-012)', () => {
  it('accepts ordinary project-relative source paths', () => {
    for (const p of ['src/App.tsx', 'components/Hero.jsx', 'pages/index.vue', 'app/x.svelte']) {
      assert.equal(plausibleSource(p), true, p);
    }
  });

  it('rejects traversal, absolute and dot-directory paths', () => {
    for (const p of [
      '../../.github/workflows/release.yml',
      '/etc/passwd',
      'C:\\Windows\\system32\\x.ts',
      '.github/workflows/release.yml',
      '.claude/agents/x.tsx',
    ]) {
      assert.equal(plausibleSource(p), false, p);
    }
  });

  it('rejects non-source extensions and junk', () => {
    for (const p of ['notes.yml', 'README.md', 'noextension', '', 'a'.repeat(2000)]) {
      assert.equal(plausibleSource(p), false, String(p));
    }
  });

  it('rejects non-strings', () => {
    for (const p of [undefined, null, 42, {}, []]) {
      assert.equal(plausibleSource(p), false, String(p));
    }
  });
});
