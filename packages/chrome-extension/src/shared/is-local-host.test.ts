import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

import { isLocalDevHost, isLocalDevUrl } from './is-local-host';

// ---------------------------------------------------------------------------
// These two predicates are what makes the store listing's "runs only on
// localhost" claim true, so the reject cases matter as much as the accepts.
// ---------------------------------------------------------------------------

describe('isLocalDevHost', () => {
  it('accepts loopback hostnames', () => {
    for (const host of ['localhost', 'LOCALHOST', 'localhost.', '127.0.0.1', '::1', '[::1]', '0:0:0:0:0:0:0:1']) {
      assert.equal(isLocalDevHost(host), true, `expected ${host} to be local`);
    }
  });

  it('accepts *.localhost subdomains (RFC 6761 reserves the TLD)', () => {
    for (const host of ['app.localhost', 'my-site.localhost', 'a.b.localhost']) {
      assert.equal(isLocalDevHost(host), true, `expected ${host} to be local`);
    }
  });

  it('rejects public hosts, including look-alikes', () => {
    for (const host of [
      'example.com',
      'localhost.evil.com',
      'notlocalhost',
      'localhostx',
      'my-localhost.com',
      '127.0.0.1.evil.com',
      '10.0.0.5',
      '192.168.1.10',
    ]) {
      assert.equal(isLocalDevHost(host), false, `expected ${host} to be rejected`);
    }
  });

  it('rejects empty and missing input', () => {
    for (const host of ['', '   ', null, undefined]) {
      assert.equal(isLocalDevHost(host), false);
    }
  });
});

describe('isLocalDevUrl', () => {
  it('accepts http and https loopback URLs on any port or path', () => {
    for (const url of [
      'http://localhost:5173/',
      'http://127.0.0.1:3000/app?x=1',
      'https://localhost/secure',
      'http://app.localhost:8080/',
      'http://[::1]:5173/',
    ]) {
      assert.equal(isLocalDevUrl(url), true, `expected ${url} to be local`);
    }
  });

  it('rejects public URLs and non-web schemes', () => {
    for (const url of [
      'https://example.com/',
      'http://localhost.evil.com/',
      'chrome://extensions',
      'file:///Users/someone/index.html',
      'chrome-extension://abcdefghijklmnop/popup.html',
      'about:blank',
      'not a url',
      '',
      null,
      undefined,
    ]) {
      assert.equal(isLocalDevUrl(url), false, `expected ${url} to be rejected`);
    }
  });
});
