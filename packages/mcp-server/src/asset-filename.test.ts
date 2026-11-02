/**
 * A picked file's name arrives over the wire, so its type is the sender's claim (KL-7).
 *
 * `assetFilename` used to call `.split` on whatever it was given. A non-string
 * threw, and `resolveAttributeAsset` caught the throw and returned the change
 * with its original `data:` URL — skipping the size cap, the MIME allowlist and
 * the magic-byte check, and handing the agent up to ~5 MB of base64.
 */

import { describe, it, before, after, afterEach, mock } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Bridge } from './bridge.js';

type Result = { toValue: string; assetTruncated?: boolean };

let tmpDir: string;
let bridge: Bridge;

before(async () => {
  tmpDir = await mkdtemp(join(tmpdir(), 'nco-asset-filename-'));
  bridge = new Bridge(tmpDir);
});

after(async () => {
  await rm(tmpDir, { recursive: true, force: true });
});

afterEach(() => {
  mock.restoreAll();
});

/** A valid PNG header plus a distinguishing tail, so each case hashes differently. */
function png(tag: number): string {
  const head = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  return Buffer.from([...head, tag, tag, tag, tag]).toString('base64');
}

function resolveAttribute(ac: Record<string, unknown>): Promise<Result> {
  return (bridge as unknown as { resolveAttributeAsset(a: unknown): Promise<Result> }).resolveAttributeAsset(ac);
}

describe('assetFilename — the picked name is untrusted input (KL-7)', () => {
  const change = (tag: number, filename: unknown): Record<string, unknown> => ({
    attribute: 'src',
    fromValue: '/images/a.png',
    toValue: `data:image/png;base64,${png(tag)}`,
    pendingUpload: { filename },
  });

  it('saves a PNG under an uploaded- name when the filename is a number', async () => {
    const result = await resolveAttribute(change(1, 42));
    assert.equal(/uploaded-[0-9a-f]{12}\.png$/.test(result.toValue), true, result.toValue);
    assert.equal(result.toValue.startsWith('data:'), false);
    assert.equal(result.assetTruncated, undefined);
  });

  it('does the same for null, an object, an array, an empty string and an over-long string', async () => {
    let tag = 10;
    for (const filename of [null, {}, ['x.png'], '', 'a'.repeat(256) + '.png']) {
      const result = await resolveAttribute(change(tag++, filename));
      assert.equal(/uploaded-[0-9a-f]{12}\.png$/.test(result.toValue), true, `${JSON.stringify(filename)}: ${result.toValue}`);
    }
  });

  it('still seeds the name from a real picked filename', async () => {
    const result = await resolveAttribute(change(30, 'photo.png'));
    assert.equal(/\/photo-[0-9a-f]{12}\.png$/.test(result.toValue), true, result.toValue);
  });

  it('truncates, and never returns the original data: URL, when saving throws', async () => {
    mock.method(console, 'error', () => {});
    mock.method(bridge as unknown as { saveDataUrl: () => Promise<string | null> }, 'saveDataUrl', async () => {
      throw new Error('forced failure');
    });
    const original = change(40, 'photo.png');
    const result = await resolveAttribute(original);
    mock.restoreAll();
    assert.equal(result.toValue, '');
    assert.equal(result.assetTruncated, true);
  });
});
