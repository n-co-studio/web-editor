/**
 * Side-effect-only module that installs the chrome.* shim for web-embed mode.
 *
 * Imported by web-embed.ts BEFORE ./index to ensure the shim is in place by
 * the time index.ts evaluates its top-level `chrome.runtime.onMessage`
 * listener registration.
 *
 * ES modules evaluate dependencies depth-first in import order, so any
 * module that imports this one will see `window.chrome` already populated
 * before their own top-level code runs.
 */
import { installChromeShim } from './web-env';

installChromeShim();
