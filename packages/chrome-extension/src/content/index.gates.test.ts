import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { parseHTML } from 'linkedom';

const g = globalThis as Record<string, any>;
const saved: Record<string, unknown> = {};
before(() => {
  const { window } = parseHTML('<!doctype html><html><body><div id="t">hi</div></body></html>', );
  for (const k of ['window','document','Node','HTMLElement','Element','Document','CSS','chrome','location','getComputedStyle','requestAnimationFrame','cancelAnimationFrame','ResizeObserver','MutationObserver','navigator','indexedDB']) saved[k] = g[k];
  g.window = window; g.document = window.document; g.Node = window.Node; g.HTMLElement = window.HTMLElement; g.Element = window.Element; g.Document = window.Document;
  (window as any).location = { hostname: 'localhost', href: 'http://localhost:3000/', origin: 'http://localhost:3000', pathname: '/', search: '', hash: '' };
  (window as any).innerWidth = 1280; (window as any).innerHeight = 800;
  (window as any).addEventListener = (window as any).addEventListener ?? (() => {});
  g.getComputedStyle = () => new Proxy({}, { get: (_t, k) => (k === 'getPropertyValue' ? () => '' : k === 'display' ? 'block' : '') });
  (window as any).getComputedStyle = g.getComputedStyle;
  const rect = { x: 0, y: 0, width: 100, height: 20, top: 0, left: 0, right: 100, bottom: 20 };
  (window.Element.prototype as any).getBoundingClientRect ??= () => rect;
  (window.Element.prototype as any).getClientRects ??= () => [rect];
  (window as any).matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
  g.indexedDB = { open() { const r: any = {}; setTimeout(() => r.onerror?.({ target: r }), 0); return r; } };
  g.CSS = { supports: () => true, escape: (s: string) => s };
  g.requestAnimationFrame = (f: () => void) => setTimeout(f, 0);
  g.cancelAnimationFrame = clearTimeout;
  g.ResizeObserver = class { observe() {} disconnect() {} unobserve() {} };
  g.MutationObserver = g.MutationObserver ?? class { observe() {} disconnect() {} takeRecords() { return []; } };
  g.chrome = {
    runtime: { onMessage: { addListener() {} }, sendMessage: () => Promise.resolve(), connect: () => { throw new Error('x'); } },
    storage: { session: { get: async () => ({}), set: async () => {} }, local: { get: async () => ({}), set: async () => {} }, onChanged: { addListener() {}, removeListener() {} } },
  };
});
after(() => { for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete g[k]; else g[k] = v; } });

function trustedFlag<T extends object>(ev: T, value: boolean): T {
  Object.defineProperty(ev, 'isTrusted', { value });
  return ev;
}
function click(trusted: boolean) {
  const ev: any = new g.window.Event('click', { bubbles: true, cancelable: true });
  Object.defineProperties(ev, { clientX: { value: 5 }, clientY: { value: 5 }, altKey: { value: false } });
  return trustedFlag(ev, trusted);
}
function key(k: string, trusted: boolean, mods: { meta?: boolean } = {}) {
  const ev: any = new g.window.Event('keydown', { bubbles: true, cancelable: true });
  Object.defineProperties(ev, {
    key: { value: k }, metaKey: { value: !!mods.meta }, ctrlKey: { value: false },
    shiftKey: { value: false }, altKey: { value: false },
    composedPath: { value: () => [g.document.body] },
  });
  return trustedFlag(ev, trusted);
}

describe('editor document listeners ignore synthetic events (KL-4)', () => {
  let target: any;
  before(async () => {
    target = g.document.getElementById('t');
    // elementFromPoint is what the hover click resolves the page element with.
    g.document.elementFromPoint = () => g.document.getElementById('t') ?? g.document.body;
    const m = await import('./index');
    await m.activate();
  });
  after(async () => { (await import('./index')).deactivate(); });

  it('a synthetic click does not select an element', () => {
    const ev = click(false);
    g.document.dispatchEvent(ev);
    assert.equal(ev.defaultPrevented, false, 'a synthetic click must not be captured as a selection');
  });

  it('a trusted click selects an element (positive control)', () => {
    const ev = click(true);
    try { g.document.dispatchEvent(ev); } catch (err) { console.log('selection threw', String(err)); }
    assert.equal(ev.defaultPrevented, true, 'a trusted click is captured as a selection');
  });

  it('a synthetic Delete does not delete the selected element', () => {
    g.document.dispatchEvent(key('Delete', false));
    assert.ok(g.document.getElementById('t'), 'element must still be in the page');
  });

  it('a synthetic Cmd+P does nothing', () => {
    const ev = key('p', false, { meta: true });
    g.document.dispatchEvent(ev);
    assert.equal(ev.defaultPrevented, false);
  });

  it('a trusted Cmd+P is handled (positive control)', () => {
    const ev = key('p', true, { meta: true });
    g.document.dispatchEvent(ev);
    assert.equal(ev.defaultPrevented, true);
  });

  it('a synthetic Cmd+Z does nothing', () => {
    const ev = key('z', false, { meta: true });
    g.document.dispatchEvent(ev);
    assert.equal(ev.defaultPrevented, false);
  });

  it('a trusted Cmd+Z is handled (positive control)', () => {
    const ev = key('z', true, { meta: true });
    g.document.dispatchEvent(ev);
    assert.equal(ev.defaultPrevented, true);
  });

  it('a trusted Delete deletes the selected element (positive control)', () => {
    g.document.dispatchEvent(key('Delete', true));
    assert.equal(g.document.getElementById('t'), null);
    void target;
  });
});
