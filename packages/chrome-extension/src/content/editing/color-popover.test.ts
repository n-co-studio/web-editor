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
  it('survives a retargeted pointerdown from inside a shadow root', async () => {
    const { attachColorPopover } = await import('./color-input');

    // Reproduce the real topology: the control lives in a shadow root, so a
    // document-level listener sees events retargeted to the shadow HOST
    // rather than the node that was actually clicked. linkedom does not
    // retarget, so the retargeted event is dispatched explicitly here — that
    // retargeting is the whole bug, and a test that skips it passes against
    // broken code.
    const hostEl = document.createElement('div');
    document.body.appendChild(hostEl);
    const shadow = (hostEl as unknown as { attachShadow(i: { mode: string }): ShadowRoot })
      .attachShadow({ mode: 'open' });

    const swatch = document.createElement('div');
    shadow.appendChild(swatch);

    let committed: string | null = null;
    const handle = attachColorPopover(swatch as unknown as HTMLElement, {
      label: 'color',
      initial: '#000000',
      tokens: [{ name: 'brand', value: '#06b6d4' }],
      onInput: () => {},
      onCommit: (v) => { committed = v; },
    });

    const W = window as never as { Event: typeof Event };
    swatch.dispatchEvent(new W.Event('click', { bubbles: true }));
    assert.equal(handle.popover.isConnected, true, 'popover should be open');

    // The killer: a pointerdown whose target is the HOST, as the document
    // sees it, while the real click is inside the popover. The old guard read
    // e.target, decided the click was outside, and removed the popover before
    // the click could land.
    const pd = new W.Event('pointerdown', { bubbles: true });
    Object.defineProperty(pd, 'target', { value: hostEl, configurable: true });
    Object.defineProperty(pd, 'composedPath', {
      value: () => [handle.popover, shadow, hostEl, document.body],
      configurable: true,
    });
    document.dispatchEvent(pd);

    assert.equal(
      handle.popover.isConnected, true,
      'a pointerdown originating inside the popover must not close it, even though the document sees it retargeted to the host',
    );

    // And the chip is still there to be clicked.
    const chip = handle.popover.querySelector('[aria-label*="brand"]') as HTMLElement | null;
    assert.ok(chip, 'token chip should still be in the popover');
    chip!.dispatchEvent(new W.Event('click', { bubbles: true }));
    assert.equal(committed, '#06b6d4', 'picking a token must commit its value');
  });

  it('still closes on a genuine outside pointerdown', async () => {
    const { attachColorPopover } = await import('./color-input');
    const swatch = document.createElement('div');
    document.body.appendChild(swatch);
    const handle = attachColorPopover(swatch as unknown as HTMLElement, {
      label: 'color', initial: '#000000', onInput: () => {}, onCommit: () => {},
    });
    const W = window as never as { Event: typeof Event };
    swatch.dispatchEvent(new W.Event('click', { bubbles: true }));
    assert.equal(handle.popover.isConnected, true);

    const outside = document.createElement('div');
    document.body.appendChild(outside);
    const pd = new W.Event('pointerdown', { bubbles: true });
    Object.defineProperty(pd, 'target', { value: outside, configurable: true });
    Object.defineProperty(pd, 'composedPath', { value: () => [outside, document.body], configurable: true });
    document.dispatchEvent(pd);

    assert.equal(handle.popover.isConnected, false, 'outside click must still dismiss');
  });
});
