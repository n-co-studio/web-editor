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
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
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

  it('prefixes a Windows device name that would sit before the first dot (KL-7)', async () => {
    // Each picked name is `<stem>.png`; the stem is what the guard looks at.
    const name = (filename: string): string =>
      (bridge as unknown as { assetFilename(h: string, e: string, f?: unknown): string }).assetFilename(
        'abcdef0123456789',
        '.png',
        filename,
      );
    const changed = ['con.x', 'CON.x', 'Com1.a.b', 'lpt9.x', 'nul.tar.gz', '-con.x', '.con.x'];
    for (const stem of changed) {
      const bare = stem.replace(/^[-.]+/, '');
      assert.equal(name(`${stem}.png`), `_${bare}-abcdef012345.png`, stem);
    }
    const unchanged = ['console.x', 'com10.x', 'conx.y', 'x.con', 'communications'];
    for (const stem of unchanged) {
      assert.equal(name(`${stem}.png`), `${stem}-abcdef012345.png`, stem);
    }
    // No dot in the stem: the hash follows the word, so `con-<hash>.png` is not a device name.
    assert.equal(name('con.png'), 'con-abcdef012345.png');
    assert.equal(name('con'), 'con-abcdef012345.png');
  });

  it('saves a picked con.x.png under a safe name end to end', async () => {
    const result = await resolveAttribute(change(50, 'con.x.png'));
    assert.equal(/\/_con\.x-[0-9a-f]{12}\.png$/.test(result.toValue), true, result.toValue);
  });

  it('keeps the final name within 255 bytes', () => {
    const name = (bridge as unknown as { assetFilename(h: string, e: string, f?: unknown): string }).assetFilename(
      'abcdef0123456789',
      '.png',
      `${'a'.repeat(251)}.png`, // 255 characters: allowed in, so the stem must give way to the hash and extension
    );
    assert.equal(Buffer.byteLength(name), 255);
    assert.equal(name.endsWith('-abcdef012345.png'), true);
    assert.equal(name.startsWith('aaaa'), true);
  });

  it('drops an embedded data: URL when persisting it throws (fail closed, KL-7)', async () => {
    // A regular file where the asset directory's parent should be: mkdir fails with ENOTDIR.
    const root = await mkdtemp(join(tmpdir(), 'nco-asset-embedded-'));
    try {
      await writeFile(join(root, 'public'), 'not a directory');
      const b = new Bridge(root) as unknown as { replaceDataUrlsInString(s: string): Promise<string> };
      const logged = mock.method(console, 'error', () => {});
      const url = `data:image/png;base64,${png(60)}`;
      const out = await b.replaceDataUrlsInString(`<img src="${url}"><img src="${url}" alt="again">`);
      assert.equal(out.includes('data:'), false, out);
      assert.equal(out, '<img src=""><img src="" alt="again">');
      const text = logged.mock.calls.map((c) => c.arguments.join(' ')).join('\n');
      assert.equal(/Failed to save embedded data URL/.test(text), true, text);
      assert.equal(text.includes(png(60)), false);
    } finally {
      mock.restoreAll();
      await rm(root, { recursive: true, force: true });
    }
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
