/**
 * Theme preference types and resolution logic.
 *
 * This module is intentionally free of chrome.* and window.* so it is
 * unit-testable under the existing node:test runner.
 */

export type ThemePreference = 'light' | 'dark' | 'system';
export type ResolvedTheme = 'light' | 'dark';

/** chrome.storage.local key for the persisted theme preference. */
export const THEME_STORAGE_KEY = 'nco:theme';

/** Default to system — existing users see no visual change until they choose otherwise. */
export const DEFAULT_THEME_PREFERENCE: ThemePreference = 'system';

/**
 * Type guard for ThemePreference.
 * Rejects null, undefined, and any value not in the union so storage reads
 * fall back to the default rather than throwing.
 */
export function isThemePreference(v: unknown): v is ThemePreference {
  return v === 'light' || v === 'dark' || v === 'system';
}

/**
 * Resolve a stored preference to a concrete 'light' | 'dark' value.
 * The system fallback is decided here and nowhere else.
 */
export function resolveTheme(pref: ThemePreference, systemPrefersDark: boolean): ResolvedTheme {
  if (pref === 'light') return 'light';
  if (pref === 'dark') return 'dark';
  return systemPrefersDark ? 'dark' : 'light';
}
