import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

import { isInjectableUrl } from './page-support';

// ---------------------------------------------------------------------------
// This predicate decides where the toolbar icon will do anything at all, so the
// accept cases matter as much as the rejects: refusing a page the editor could
// have run on silently removes the feature on that page.
// ---------------------------------------------------------------------------

describe('isInjectableUrl', () => {
  it('accepts ordinary public pages — the capability this restores', () => {
    for (const url of [
      'https://example.com/',
      'http://example.com/some/path?q=1#frag',
      'https://news.ycombinator.com/item?id=1',
      'https://staging.internal.example.co.uk/dashboard',
      'https://example.com:8443/app',
    ]) {
      assert.equal(isInjectableUrl(url), true, `expected ${url} to be injectable`);
    }
  });

  it('accepts local dev servers, which keep working exactly as before', () => {
    for (const url of [
      'http://localhost:5173/',
      'http://127.0.0.1:3000/app',
      'https://localhost/secure',
      'http://app.localhost:8080/',
      'http://[::1]:5173/',
    ]) {
      assert.equal(isInjectableUrl(url), true, `expected ${url} to be injectable`);
    }
  });

  it('rejects browser-internal schemes Chrome refuses to script', () => {
    for (const url of [
      'chrome://extensions',
      'chrome://settings/clearBrowserData',
      'chrome-extension://abcdefghijklmnop/popup.html',
      'chrome-untrusted://print',
      'devtools://devtools/bundled/inspector.html',
      'about:blank',
      'about:srcdoc',
      'view-source:https://example.com/',
      'edge://settings',
    ]) {
      assert.equal(isInjectableUrl(url), false, `expected ${url} to be rejected`);
    }
  });

  it('rejects non-page schemes', () => {
    for (const url of [
      'file:///Users/someone/index.html',
      'data:text/html,<h1>hi</h1>',
      'blob:https://example.com/550e8400',
      'ftp://example.com/file.txt',
      'ws://localhost:7890',
      'mailto:someone@example.com',
    ]) {
      assert.equal(isInjectableUrl(url), false, `expected ${url} to be rejected`);
    }
  });

  it('rejects the extension galleries, which the browser protects', () => {
    for (const url of [
      'https://chromewebstore.google.com/',
      'https://chromewebstore.google.com/detail/something/abcdef',
      'https://chrome.google.com/webstore/category/extensions',
      'https://microsoftedge.microsoft.com/addons/detail/abc',
    ]) {
      assert.equal(isInjectableUrl(url), false, `expected ${url} to be rejected`);
    }
  });

  it('rejects empty, missing and unparseable input', () => {
    for (const url of ['', '   ', 'not a url', '://missing-scheme', null, undefined]) {
      assert.equal(isInjectableUrl(url), false, `expected ${JSON.stringify(url)} to be rejected`);
    }
  });

  it('does not reject a public host merely for resembling a blocked one', () => {
    for (const url of [
      'https://chromewebstore.google.com.evil.test/',
      'https://notchrome.google.com/',
      'https://mychrome.google.com.example.org/webstore',
    ]) {
      assert.equal(isInjectableUrl(url), true, `expected ${url} to be injectable`);
    }
  });
});
