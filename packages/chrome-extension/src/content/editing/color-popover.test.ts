import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { parseHTML } from 'linkedom';

// ---------------------------------------------------------------------------
// Regression test for a bug this file exists because of.
//
// `attachColorPopover` used to resolve the popover's host once, at construction
// time:
//
//     const root = swatch.getRootNode();
//     if (root instanceof ShadowRoot) root.appendChild(popover);
//
// Panels build their entire subtree and append it to the shadow root LAST, so
// at construction the swatch is detached and `getRootNode()` returns that
// detached subtree rather than the ShadowRoot. The condition was false, there
// was no else, and the popover was never inserted into any document. Opening it
// set `display: flex` on an orphan — nothing appeared, nothing threw, and every
// colour control in the product was silently dead.
//
// The ordering is the whole point, so the test reproduces it exactly: build the
// control while detached, attach afterwards, then open.
// ---------------------------------------------------------------------------

let restore: Array<() => void> = [];

before(async () => {
  const { window } = parseHTML('<!doctype html><html><body></body></html>');
  const g = globalThis as Record<string, unknown>;
  for (const key of ['window', 'document', 'Document', 'ShadowRoot', 'Node', 'MutationObserver', 'CSS']) {
    const had = key in g;
    const prev = g[key];
    restore.push(() => { if (had) g[key] = prev; else delete g[key]; });
  }
  g.window = window;
  g.document = window.document;
  g.Document = window.Document;
  g.Node = window.Node;
  if (!('ShadowRoot' in g) && 'ShadowRoot' in window) g.ShadowRoot = (window as never as Record<string, unknown>).ShadowRoot;
  g.CSS = { supports: () => true };
});

after(() => { for (const fn of restore) fn(); restore = []; });

describe('attachColorPopover — attachment timing', () => {
  it('inserts the popover into the document when opened, even though the swatch was detached when it was built', async () => {
    const { attachColorPopover } = await import('./color-input');

    // 1. Build the control while DETACHED. This is the order every panel uses.
    const row = document.createElement('div');
    const swatch = document.createElement('div');
    row.appendChild(swatch);
    assert.equal(swatch.isConnected, false, 'precondition: swatch starts detached');

    const handle = attachColorPopover(swatch as unknown as HTMLElement, {
      label: 'color',
      initial: '#ff0000',
      onInput: () => {},
      onCommit: () => {},
    });

    // The popover must not be in the document before it is opened.
    assert.equal(
      handle.popover.isConnected, false,
      'popover should not be in the document before opening',
    );

    // 2. NOW attach the panel, as a real panel does.
    document.body.appendChild(row);
    assert.equal(swatch.isConnected, true);

    // 3. Open it the way a user does.
    swatch.dispatchEvent(new (window as never as { Event: typeof Event }).Event('click', { bubbles: true }));

    // The actual regression: this was false, because the host had been
    // resolved while detached and the append silently never happened.
    assert.equal(
      handle.popover.isConnected, true,
      'popover must be in the document after the swatch is clicked',
    );
    assert.notEqual(
      handle.popover.style.display, 'none',
      'popover must be visible after opening',
    );
  });

  it('removes the popover from the document on close, leaving nothing orphaned', async () => {
    const { attachColorPopover } = await import('./color-input');

    const row = document.createElement('div');
    const swatch = document.createElement('div');
    row.appendChild(swatch);
    document.body.appendChild(row);

    const handle = attachColorPopover(swatch as unknown as HTMLElement, {
      label: 'color',
      initial: '#00ff00',
      onInput: () => {},
      onCommit: () => {},
    });

    swatch.dispatchEvent(new (window as never as { Event: typeof Event }).Event('click', { bubbles: true }));
    assert.equal(handle.popover.isConnected, true, 'open should attach');

    handle.close();
    // The popover lives outside the panel that owns it, so panel teardown
    // cannot collect it — close has to.
    assert.equal(handle.popover.isConnected, false, 'close should detach');
  });
});
