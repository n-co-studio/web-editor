/**
 * KL-4 — bridge peer authentication.
 *
 * Every test here opens a REAL `ws` client against a REAL Bridge listening on a
 * loopback test port and forges the Origin header. The assertion is the
 * security outcome (was the upgrade refused or not), never an implementation
 * detail, so removing a guard makes the matching test fail.
 *
 * Out of scope by design: a local process can forge Origin, and a process that
 * binds 127.0.0.1 first is not authenticated. See the comment at
 * Bridge.tryPort.
 */

import { describe, it, before, after, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import WebSocket from 'ws';
import { Bridge, PUBLISHED_EXTENSION_ID, EXTENSION_IDS_ENV } from './bridge.js';

const PINNED = `chrome-extension://${PUBLISHED_EXTENSION_ID}`;

let tmpDir: string;
let bridge: Bridge;
let port: number;
let stderr: string[];
let realConsoleError: typeof console.error;

/** Try to open a socket with the given Origin; resolve to what the server did. */
function attempt(origin: string | undefined): Promise<'accepted' | 'refused'> {
  return new Promise((resolve) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}`, origin === undefined ? {} : { origin });
    ws.on('open', () => {
      ws.close();
      resolve('accepted');
    });
    ws.on('unexpected-response', () => {
      ws.terminate();
      resolve('refused');
    });
    ws.on('error', () => resolve('refused'));
  });
}

before(async () => {
  tmpDir = await mkdtemp(join(tmpdir(), 'nco-peer-auth-'));
});

after(async () => {
  await rm(tmpDir, { recursive: true, force: true });
});

beforeEach(async () => {
  stderr = [];
  realConsoleError = console.error;
  console.error = (...args: unknown[]) => {
    stderr.push(args.map(String).join(' '));
  };
  delete process.env[EXTENSION_IDS_ENV];
  process.env.NCO_WEB_EDITOR_PORT = String(47000 + Math.floor(Math.random() * 900));
});

afterEach(async () => {
  console.error = realConsoleError;
  delete process.env[EXTENSION_IDS_ENV];
  delete process.env.NCO_WEB_EDITOR_PORT;
  await bridge?.stop();
});

async function startBridge(): Promise<void> {
  const dir = await mkdtemp(join(tmpDir, 'proj-'));
  bridge = new Bridge(dir);
  port = await bridge.start();
}

describe('server refuses forged page and foreign origins (KL-4)', () => {
  it('refuses a script on http://localhost:3000', async () => {
    await startBridge();
    assert.equal(await attempt('http://localhost:3000'), 'refused');
  });

  it('refuses a script on http://127.0.0.1:5173', async () => {
    await startBridge();
    assert.equal(await attempt('http://127.0.0.1:5173'), 'refused');
  });

  it('refuses a script on http://[::1]:8080', async () => {
    await startBridge();
    assert.equal(await attempt('http://[::1]:8080'), 'refused');
  });

  it('refuses a script on https://localhost', async () => {
    await startBridge();
    assert.equal(await attempt('https://localhost'), 'refused');
  });

  it('refuses a different chrome-extension ID', async () => {
    await startBridge();
    assert.equal(await attempt('chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'), 'refused');
  });

  it('refuses moz-extension, even with the pinned ID', async () => {
    await startBridge();
    assert.equal(await attempt(`moz-extension://${PUBLISHED_EXTENSION_ID}`), 'refused');
  });

  it('refuses a connection with no Origin header', async () => {
    await startBridge();
    assert.equal(await attempt(undefined), 'refused');
  });

  it('refuses an Origin that only starts with the pinned origin', async () => {
    await startBridge();
    assert.equal(await attempt(`${PINNED}.evil.example`), 'refused');
  });
});

describe('server accepts the pinned extension (KL-4)', () => {
  it('accepts chrome-extension://<pinned id>', async () => {
    await startBridge();
    assert.equal(await attempt(PINNED), 'accepted');
  });
});

describe('NCO_WEB_EDITOR_EXTENSION_IDS (KL-4 dev escape hatch)', () => {
  const GOOD = 'abcdefghijklmnopabcdefghijklmnop';

  it('accepts a well-formed extra ID', async () => {
    process.env[EXTENSION_IDS_ENV] = GOOD;
    await startBridge();
    assert.equal(await attempt(`chrome-extension://${GOOD}`), 'accepted');
  });

  it('accepts several comma-separated IDs, tolerating spaces', async () => {
    process.env[EXTENSION_IDS_ENV] = ` ${GOOD} , ${'a'.repeat(32)}`;
    await startBridge();
    assert.equal(await attempt(`chrome-extension://${GOOD}`), 'accepted');
    assert.equal(await attempt(`chrome-extension://${'a'.repeat(32)}`), 'accepted');
  });

  it('does not accept an ID that is not in the variable', async () => {
    await startBridge();
    assert.equal(await attempt(`chrome-extension://${GOOD}`), 'refused');
  });

  it('ignores an entry that is too short', async () => {
    process.env[EXTENSION_IDS_ENV] = 'abcdef';
    await startBridge();
    assert.equal(await attempt('chrome-extension://abcdef'), 'refused');
  });

  it('ignores an entry with characters outside a-p', async () => {
    const bad = 'q'.repeat(32);
    process.env[EXTENSION_IDS_ENV] = bad;
    await startBridge();
    assert.equal(await attempt(`chrome-extension://${bad}`), 'refused');
  });

  it('ignores an uppercase entry and a 33-character entry', async () => {
    const upper = 'A'.repeat(32);
    const long = 'a'.repeat(33);
    process.env[EXTENSION_IDS_ENV] = `${upper},${long}`;
    await startBridge();
    assert.equal(await attempt(`chrome-extension://${upper}`), 'refused');
    assert.equal(await attempt(`chrome-extension://${long}`), 'refused');
  });

  it('a malformed entry does not stop a well-formed one in the same list working', async () => {
    process.env[EXTENSION_IDS_ENV] = `nonsense,${GOOD}`;
    await startBridge();
    assert.equal(await attempt(`chrome-extension://${GOOD}`), 'accepted');
  });

  it('warns on stderr about a malformed entry', async () => {
    process.env[EXTENSION_IDS_ENV] = 'not-a-valid-extension-id-warn-test';
    await startBridge();
    await attempt(PINNED);
    assert.ok(
      stderr.some((l) => l.includes('Ignoring malformed entry') && l.includes('not-a-valid-extension-id-warn-test')),
      `expected a malformed-entry warning, got: ${JSON.stringify(stderr)}`,
    );
  });

  it('logs accepted extra IDs once at startup', async () => {
    process.env[EXTENSION_IDS_ENV] = GOOD;
    await startBridge();
    await attempt(`chrome-extension://${GOOD}`);
    await attempt(`chrome-extension://${GOOD}`);
    const logged = stderr.filter((l) => l.includes('Also accepting extension ID') && l.includes(GOOD));
    assert.equal(logged.length, 1, `expected exactly one startup log, got: ${JSON.stringify(stderr)}`);
  });

  it('logs nothing about extra IDs when the variable is unset', async () => {
    await startBridge();
    assert.ok(!stderr.some((l) => l.includes('Also accepting extension ID')));
  });
});

describe('outdated-extension notice (version skew)', () => {
  it('tells the developer, once per origin, that a pre-0.3.1 extension must be updated', async () => {
    await startBridge();
    await attempt('http://localhost:3000');
    await attempt('http://localhost:3000');
    await attempt('http://localhost:3000');
    const notices = stderr.filter((l) => l.includes('outdated extension') && l.includes('http://localhost:3000'));
    assert.equal(notices.length, 1, `expected one notice, got: ${JSON.stringify(stderr)}`);
  });

  it('logs a separate notice for a different page origin', async () => {
    await startBridge();
    await attempt('http://localhost:3000');
    await attempt('http://127.0.0.1:5173');
    const notices = stderr.filter((l) => l.includes('outdated extension'));
    assert.equal(notices.length, 2);
  });

  it('does not blame an outdated extension for a foreign origin', async () => {
    await startBridge();
    await attempt('https://evil.example');
    await attempt('chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
    assert.ok(!stderr.some((l) => l.includes('outdated extension')));
  });
});
