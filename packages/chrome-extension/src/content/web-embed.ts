/**
 * Web-embed entry point.
 *
 * Bundled as an IIFE and served from the portfolio site's public/ folder.
 * Loaded lazily on a "Try it now" button click. Exposes a minimal global
 * API on window so the site can mount/unmount the editor without knowing
 * anything about the internals.
 *
 * IMPORTANT: `./demo-bootstrap` must be imported BEFORE `./index` so the
 * chrome.* shim is installed before index.ts's top-level
 * `chrome.runtime.onMessage.addListener` call runs. ES module evaluation
 * is depth-first in import order, so this ordering is load-bearing.
 */
import './demo-bootstrap';
import { activate, deactivate } from './index';

type NcoWebEditorGlobal = {
  readonly version: string;
  mount: () => Promise<void>;
  unmount: () => void;
};

const api: NcoWebEditorGlobal = {
  version: '0.1.0-embed',
  mount: () => activate(),
  unmount: () => deactivate(),
};

(globalThis as any).__ncoWebEditor = api;

// Signal readiness so the site-side loader can resolve its promise.
try {
  window.dispatchEvent(new CustomEvent('nco-web-editor:ready'));
} catch { /* non-fatal */ }
