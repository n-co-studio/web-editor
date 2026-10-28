/**
 * KL-4: dispatch and add-note must be real user gestures. Page script can
 * dispatch synthetic events (isTrusted === false) but cannot forge trusted ones.
 *
 * Also pins that the overlay's shadow root is closed, so page script cannot
 * reach into the panel at all.
 */
import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { parseHTML } from 'linkedom';

let restore: Array<() => void> = [];

before(() => {
  const { window } = parseHTML('<!doctype html><html><body></body></html>');
  const g = globalThis as Record<string, unknown>;
  for (const key of ['window', 'document', 'Document', 'Node', 'HTMLElement', 'ShadowRoot', 'MutationObserver', 'CSS', 'chrome', 'ResizeObserver']) {
    const had = key in g;
    const prev = g[key];
    restore.push(() => { if (had) g[key] = prev; else delete g[key]; });
  }
  g.window = window;
  g.document = window.document;
  g.Document = window.Document;
  g.Node = window.Node;
  g.HTMLElement = window.HTMLElement;
  g.CSS = { supports: () => true };
  g.chrome = {
    storage: { session: { get: () => Promise.resolve({}), set: () => Promise.resolve() } },
  };
});
after(() => { for (const fn of restore) fn(); restore = []; });

/** An event the page could not have forged: a real user gesture. */
function trusted<T extends object>(ev: T): T {
  Object.defineProperty(ev, 'isTrusted', { value: true });
  return ev;
}
function synthetic<T extends object>(ev: T): T {
  Object.defineProperty(ev, 'isTrusted', { value: false });
  return ev;
}

describe('Apply Changes dispatch requires a trusted event (KL-4)', () => {
  async function setup() {
    const { ReviewPanel } = await import('./batching/review-panel');
    const { NotesStore } = await import('./batching/notes-store');
    const sent: unknown[][] = [];
    const wsClient = {
      hasEverConnected: true,
      sendDiffBatch: (...args: unknown[]) => { sent.push(args); return true; },
      sendStatusRequest: () => true,
      retryNow: () => {},
    };
    const diff = { id: 'd1' };
    const queue = {
      onChange: () => {},
      getAllActive: () => [diff],
      stampBatchId: () => [diff],
    };
    const notes = new NotesStore();
    notes.add('make it bigger');
    const panel = new ReviewPanel(
      {} as ShadowRoot, queue as never, wsClient as never, {} as never, notes,
    );
    return { panel, sent, notes };
  }

  it('does not send when triggerSend gets a synthetic event (a page-dispatched Cmd+S)', async () => {
    const { panel, sent, notes } = await setup();
    await panel.triggerSend(synthetic(new window.Event('keydown')) as unknown as Event);
    assert.equal(sent.length, 0, 'a synthetic event must not dispatch a batch');
    assert.equal(notes.count, 1, 'and must not consume the notes');
  });

  it('does send for a trusted event (positive control)', async () => {
    const { panel, sent } = await setup();
    await panel.triggerSend(trusted(new window.Event('keydown')) as unknown as Event);
    assert.equal(sent.length, 1);
    // structured notes ride along with the legacy batchNote
    const [, legacy, , structured] = sent[0] as [unknown, string, string, Array<{ text: string }>];
    assert.match(legacy, /make it bigger/);
    assert.equal(structured[0].text, 'make it bigger');
  });
});

describe('notes lifecycle across an async send (KL-6)', () => {
  type Deferred = { resolve: (ok: boolean) => void };
  async function setup(results: Array<boolean | 'deferred'>, diffCount: number) {
    const { ReviewPanel } = await import('./batching/review-panel');
    const { NotesStore } = await import('./batching/notes-store');
    const calls: Array<{ notes: unknown }> = [];
    const deferred: Deferred[] = [];
    let i = 0;
    const wsClient = {
      hasEverConnected: true,
      sendDiffBatch: (_d: unknown, _n: unknown, _b: unknown, notes: unknown) => {
        calls.push({ notes });
        const r = results[i++];
        if (r === 'deferred') return new Promise<boolean>((resolve) => deferred.push({ resolve }));
        return Promise.resolve(r);
      },
      sendStatusRequest: () => true,
      retryNow: () => {},
    };
    const diffs = Array.from({ length: diffCount }, (_, k) => ({ id: `d${k}` }));
    const queue = { onChange: () => {}, getAllActive: () => diffs, stampBatchId: () => diffs };
    const notes = new NotesStore();
    notes.add('first note');
    const panel = new ReviewPanel({} as ShadowRoot, queue as never, wsClient as never, {} as never, notes);
    return { panel, notes, calls, deferred };
  }
  const send = (panel: { triggerSend(e: Event): Promise<void> }) =>
    panel.triggerSend(trusted(new window.Event('keydown')) as unknown as Event);

  it('removes the notes as soon as segment 0 succeeds, even if segment 1 fails, and does not resend them', async () => {
    // 150 diffs = two segments (MAX_DIFFS_PER_BATCH is 100): true then false.
    const { panel, notes, calls } = await setup([true, false, true, true], 150);
    await send(panel);
    assert.equal(notes.count, 0, 'notes went out with segment 0 and must be removed');
    assert.ok(calls[0].notes, 'segment 0 carried the notes');
    await new Promise((r) => setTimeout(r, 5100)); // let the sending flag reset
    await send(panel); // retry
    for (const c of calls.slice(2)) assert.equal(c.notes, undefined, 'the retry must not resend the notes');
  });

  it('keeps a note added while the send is in flight', async () => {
    const { panel, notes, deferred } = await setup(['deferred'], 3);
    const pending = send(panel);
    notes.add('added mid-send');
    deferred[0].resolve(true);
    await pending;
    assert.equal(notes.count, 1);
    assert.equal(notes.getAll()[0].text, 'added mid-send');
  });

  it('leaves the notes intact when segment 0 fails', async () => {
    const { panel, notes } = await setup([false], 150);
    await send(panel);
    assert.equal(notes.count, 1);
  });
});

describe('a failed send keeps the designer\'s notes (KL-6)', () => {
  async function setup(result: boolean) {
    const { ReviewPanel } = await import('./batching/review-panel');
    const { NotesStore } = await import('./batching/notes-store');
    const wsClient = {
      hasEverConnected: true,
      sendDiffBatch: () => Promise.resolve(result),
      sendStatusRequest: () => true,
      retryNow: () => {},
    };
    const diff = { id: 'd1' };
    const queue = { onChange: () => {}, getAllActive: () => [diff], stampBatchId: () => [diff] };
    const notes = new NotesStore();
    notes.add('keep me');
    const panel = new ReviewPanel({} as ShadowRoot, queue as never, wsClient as never, {} as never, notes);
    return { panel, notes };
  }

  it('does not clear notes when the worker reports the send failed', async () => {
    const { panel, notes } = await setup(false);
    await panel.triggerSend(trusted(new window.Event('keydown')) as unknown as Event);
    assert.equal(notes.count, 1, 'notes must survive a failed send');
  });

  it('clears notes only when the worker reports success (positive control)', async () => {
    const { panel, notes } = await setup(true);
    await panel.triggerSend(trusted(new window.Event('keydown')) as unknown as Event);
    assert.equal(notes.count, 0);
  });
});

describe('add-note requires a trusted event (KL-4)', () => {
  async function render() {
    const { NotesEditor } = await import('./editing/notes');
    const { NotesStore } = await import('./batching/notes-store');
    const store = new NotesStore();
    const shadow = document.createElement('div') as unknown as ShadowRoot;
    const editor = new NotesEditor(store, shadow);
    const container = editor.render({ x: 0, y: 0 });
    const input = container.querySelector('input') as HTMLInputElement;
    input.value = 'a new note';
    return { store, container, input };
  }

  function keydownEnter() {
    const ev = new window.Event('keydown') as unknown as KeyboardEvent;
    Object.defineProperty(ev, 'key', { value: 'Enter' });
    return ev;
  }

  it('ignores a synthetic Enter keydown', async () => {
    const { store, input } = await render();
    input.dispatchEvent(synthetic(keydownEnter()));
    assert.equal(store.count, 0, 'a synthetic Enter must not add a note');
  });

  it('ignores a synthetic click on the add (+) button', async () => {
    const { store, container } = await render();
    const buttons = Array.from(container.querySelectorAll('button')) as HTMLButtonElement[];
    const addBtn = buttons.find((b) => b.textContent === '+')!;
    assert.ok(addBtn, 'add button present');
    addBtn.dispatchEvent(synthetic(new window.Event('click')));
    assert.equal(store.count, 0, 'a synthetic click must not add a note');
  });

  it('adds the note for a trusted Enter keydown (positive control)', async () => {
    const { store, input } = await render();
    input.dispatchEvent(trusted(keydownEnter()));
    assert.equal(store.count, 1);
  });

  it('adds the note for a trusted click on the add (+) button (positive control)', async () => {
    const { store, container } = await render();
    const addBtn = (Array.from(container.querySelectorAll('button')) as HTMLButtonElement[]).find((b) => b.textContent === '+')!;
    addBtn.dispatchEvent(trusted(new window.Event('click')));
    assert.equal(store.count, 1);
  });
});

describe('"+ Ref" and "+ Selected" require a trusted click (KL-4)', () => {
  async function render() {
    const { NotesEditor } = await import('./editing/notes');
    const { NotesStore } = await import('./batching/notes-store');
    const store = new NotesStore();
    store.add('a note');
    const editor = new NotesEditor(store, document.createElement('div') as unknown as ShadowRoot);
    const picked: number[] = [];
    const selected: number[] = [];
    editor.onStartPick((i) => picked.push(i));
    editor.onAddSelected((i) => selected.push(i));
    editor.setHasSelection(() => true);
    const container = editor.render({ x: 0, y: 0 });
    const btn = (label: string) =>
      (Array.from(container.querySelectorAll('button')) as HTMLButtonElement[]).find((b) => b.textContent === label)!;
    return { picked, selected, btn };
  }

  it('ignores a synthetic click on "+ Ref"', async () => {
    const { picked, btn } = await render();
    assert.ok(btn('+ Ref'));
    btn('+ Ref').dispatchEvent(synthetic(new window.Event('click')));
    assert.equal(picked.length, 0);
  });

  it('starts pick mode for a trusted click on "+ Ref" (positive control)', async () => {
    const { picked, btn } = await render();
    btn('+ Ref').dispatchEvent(trusted(new window.Event('click')));
    assert.deepEqual(picked, [0]);
  });

  it('ignores a synthetic click on "+ Selected"', async () => {
    const { selected, btn } = await render();
    assert.ok(btn('+ Selected'));
    btn('+ Selected').dispatchEvent(synthetic(new window.Event('click')));
    assert.equal(selected.length, 0);
  });

  it('adds the selection for a trusted click on "+ Selected" (positive control)', async () => {
    const { selected, btn } = await render();
    btn('+ Selected').dispatchEvent(trusted(new window.Event('click')));
    assert.deepEqual(selected, [0]);
  });
});

describe('note pick-mode click requires a trusted event (KL-4)', () => {
  async function make() {
    const { createNotePickHandler } = await import('./editing/note-pick');
    const added: Element[] = [];
    const el = document.createElement('div') as unknown as Element;
    const handler = createNotePickHandler({
      getPanelRect: () => null,
      elementAt: () => el,
      addElement: (e) => added.push(e),
    });
    return { handler, added };
  }
  const click = () => new window.Event('click') as unknown as MouseEvent;

  it('ignores a synthetic click (page script cannot attach elements)', async () => {
    const { handler, added } = await make();
    handler(synthetic(click()));
    assert.equal(added.length, 0);
  });

  it('attaches the element for a trusted click (positive control)', async () => {
    const { handler, added } = await make();
    handler(trusted(click()));
    assert.equal(added.length, 1);
  });
});

describe('text editing blur and paste require a trusted event (KL-4)', () => {
  async function start() {
    const g = globalThis as Record<string, any>;
    const w = window as any;
    g.document.createRange = () => ({ selectNodeContents() {} });
    w.getSelection = g.getSelection = () => ({ removeAllRanges() {}, addRange() {}, rangeCount: 0 });
    g.document.execCommand = () => true;
    const { TextEditor } = await import('./editing/text');
    const el = document.createElement('p') as unknown as HTMLElement;
    el.textContent = 'hello';
    (el as any).focus ??= () => {};
    document.body.appendChild(el);
    const editor = new TextEditor();
    editor.editElement(el, () => {});
    return { editor, el };
  }
  const evt = (type: string) => new window.Event(type, { cancelable: true }) as unknown as Event;

  it('ignores a synthetic blur (page script cannot commit the edit)', async () => {
    const { editor, el } = await start();
    el.dispatchEvent(synthetic(evt('blur')));
    assert.equal(editor.isActive(), true);
  });

  it('commits on a trusted blur (positive control)', async () => {
    const { editor, el } = await start();
    try { el.dispatchEvent(trusted(evt('blur'))); } catch { /* linkedom limits inside finishEditing */ }
    assert.equal(editor.isActive(), false);
  });

  it('ignores a synthetic paste', async () => {
    const { el } = await start();
    const ev = synthetic(evt('paste'));
    el.dispatchEvent(ev);
    assert.equal((ev as Event).defaultPrevented, false);
  });

  it('handles a trusted paste (positive control)', async () => {
    const { el } = await start();
    const ev = trusted(evt('paste'));
    el.dispatchEvent(ev);
    assert.equal((ev as Event).defaultPrevented, true);
  });
});

describe('overlay shadow root is closed (KL-4)', () => {
  it('exposes no shadowRoot to page script, while the extension keeps its own reference', async () => {
    const { mountShadowHost } = await import('./shadow-host');
    const { host, shadow } = mountShadowHost();
    assert.equal(host.shadowRoot, null, 'host.shadowRoot must be null for a closed root');
    assert.ok(shadow, 'the mounting code still receives the root');
  });

  it('sets the host position, z-index and pointer-events with !important so page CSS cannot override them', async () => {
    const { mountShadowHost } = await import('./shadow-host');
    // linkedom ignores setProperty priority, so record what the code asked for.
    const calls: Array<[string, string, string | undefined]> = [];
    const proto = Object.getPrototypeOf((document.createElement('div') as HTMLElement).style) as Record<string, any>;
    const orig = proto.setProperty;
    proto.setProperty = function (this: unknown, n: string, v: string, p?: string) {
      calls.push([n, v, p]);
      return orig.call(this, n, v, p);
    };
    try {
      mountShadowHost();
    } finally {
      proto.setProperty = orig;
    }
    for (const prop of ['position', 'z-index', 'pointer-events', 'top', 'left', 'right', 'bottom']) {
      const c = calls.find(([n]) => n === prop);
      assert.ok(c, `${prop} must be set via setProperty`);
      assert.equal(c![2], 'important', `${prop} must carry !important`);
    }
    assert.equal(calls.find(([n]) => n === 'pointer-events')![1], 'none');
  });

  it('keeps pointer-events important after the editor toggles it', async () => {
    const { setHostPointerEvents } = await import('./shadow-host');
    const calls: Array<[string, string, string | undefined]> = [];
    const fake = { style: { setProperty: (n: string, v: string, p?: string) => { calls.push([n, v, p]); } } };
    setHostPointerEvents(fake as never, 'none');
    setHostPointerEvents(fake as never, '');
    assert.equal(calls.length, 2);
    for (const c of calls) assert.deepEqual(c, ['pointer-events', 'none', 'important']);
  });
});
