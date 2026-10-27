/**
 * Regression tests for isScriptUrl — the scheme check sanitizeFragment uses to
 * strip scripted URLs from href/src/action attributes.
 *
 * These exist because the original check was `/^\s*javascript:/i`, which is
 * bypassable. Browsers strip tabs, newlines and C0 control characters from
 * inside a scheme before resolving it, so `java&#9;script:alert(1)` and
 * `\u0001javascript:alert(1)` both execute while failing that regex.
 *
 * Only the URL predicate is covered here. The other two fixes in the same
 * change — removing SVG `animate`/`set` (which can rewrite an href after it
 * has been inspected) and recursing into nested `<template>.content` (which
 * querySelectorAll does not descend into) — are structural and need a real DOM
 * to exercise; this suite uses hand-rolled doubles by convention, and a mock
 * faithful enough to prove those would be the thing under test.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { isScriptUrl } from './dom-utils.js';

describe('isScriptUrl — plain cases', () => {
  it('flags an unobfuscated javascript: URL', () => {
    assert.equal(isScriptUrl('javascript:alert(1)'), true);
    assert.equal(isScriptUrl('JavaScript:alert(1)'), true);
    assert.equal(isScriptUrl('  javascript:alert(1)'), true);
  });

  it('leaves ordinary URLs alone', () => {
    for (const url of [
      'https://example.com/a.png',
      '/images/hero.png',
      './relative.html',
      '#anchor',
      'mailto:someone@example.com',
      'data:image/png;base64,iVBORw0KGgo=',
    ]) {
      assert.equal(isScriptUrl(url), false, url);
    }
  });
});

describe('isScriptUrl — bypasses the old /^\\s*javascript:/ test missed', () => {
  it('flags a tab or newline inside the scheme', () => {
    // What `java&#9;script:` parses to once the entity is decoded.
    assert.equal(isScriptUrl('java\tscript:alert(1)'), true);
    assert.equal(isScriptUrl('java\nscript:alert(1)'), true);
    assert.equal(isScriptUrl('java\r\nscript:alert(1)'), true);
  });

  it('flags leading C0 control characters', () => {
    assert.equal(isScriptUrl('\u0001javascript:alert(1)'), true);
    assert.equal(isScriptUrl('\u0000javascript:alert(1)'), true);
    assert.equal(isScriptUrl('\u000bjavascript:alert(1)'), true);
  });

  it('flags mixed whitespace, control characters and casing together', () => {
    assert.equal(isScriptUrl('\u0002 jAvA\tScRiPt\n:alert(1)'), true);
  });

  it('flags a non-breaking space and BOM, which \\s does not cover', () => {
    assert.equal(isScriptUrl('﻿javascript:alert(1)'), true);
    assert.equal(isScriptUrl('java script:alert(1)'), true);
  });

  it('flags data:text/html, which navigates to an attacker-controlled document', () => {
    assert.equal(isScriptUrl('data:text/html,<script>alert(1)</script>'), true);
    assert.equal(isScriptUrl('DATA:TEXT/HTML;base64,PHNjcmlwdD4='), true);
  });
});
