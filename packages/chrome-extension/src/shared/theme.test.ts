import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { isThemePreference, resolveTheme, DEFAULT_THEME_PREFERENCE } from './theme';

describe('resolveTheme', () => {
  it('returns "dark" for explicit dark regardless of system flag', () => {
    assert.equal(resolveTheme('dark', false), 'dark');
    assert.equal(resolveTheme('dark', true), 'dark');
  });

  it('returns "light" for explicit light regardless of system flag', () => {
    assert.equal(resolveTheme('light', false), 'light');
    assert.equal(resolveTheme('light', true), 'light');
  });

  it('follows the system flag when preference is "system"', () => {
    assert.equal(resolveTheme('system', true), 'dark');
    assert.equal(resolveTheme('system', false), 'light');
  });

  it('mutation check — invert system branch would break these assertions', () => {
    // If the system branch were inverted (dark → light, light → dark), these would fail.
    assert.notEqual(resolveTheme('system', true), 'light');
    assert.notEqual(resolveTheme('system', false), 'dark');
  });
});

describe('isThemePreference', () => {
  it('accepts valid preferences', () => {
    assert.equal(isThemePreference('light'), true);
    assert.equal(isThemePreference('dark'), true);
    assert.equal(isThemePreference('system'), true);
  });

  it('rejects null', () => {
    assert.equal(isThemePreference(null), false);
  });

  it('rejects undefined', () => {
    assert.equal(isThemePreference(undefined), false);
  });

  it('rejects empty string', () => {
    assert.equal(isThemePreference(''), false);
  });

  it('rejects capitalized variants', () => {
    assert.equal(isThemePreference('Light'), false);
    assert.equal(isThemePreference('Dark'), false);
    assert.equal(isThemePreference('System'), false);
  });

  it('rejects "auto" (not a valid preference)', () => {
    assert.equal(isThemePreference('auto'), false);
  });

  it('rejects objects', () => {
    assert.equal(isThemePreference({}), false);
    assert.equal(isThemePreference({ value: 'light' }), false);
  });

  it('rejects numbers', () => {
    assert.equal(isThemePreference(0), false);
    assert.equal(isThemePreference(1), false);
  });
});

describe('DEFAULT_THEME_PREFERENCE', () => {
  it('is "system"', () => {
    assert.equal(DEFAULT_THEME_PREFERENCE, 'system');
  });
});
