import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

// Stub chrome.storage.session before importing the store (persist() writes to it).
(globalThis as any).chrome = {
  storage: {
    session: {
      set: () => Promise.resolve(),
      get: () => Promise.resolve({}),
    },
  },
};

import { NotesStore } from './notes-store';
import type { NoteElementRef } from '@nco-studio/shared';

function imgRef(selector: string, assetPath: string): NoteElementRef {
  const label = assetPath.split('/').pop()!.split('.')[0];
  return { selector, tagName: 'img', sourceFile: 'src/G.tsx', sourceLine: 1, assetPath, label };
}

describe('NotesStore.toBatchNote ordering format (issue #29)', () => {
  it('renders N → /images/<file> per referenced element (the motivating numbering case)', () => {
    const store = new NotesStore();
    store.add('reorder these to 1,2,3', [
      imgRef('#a', '/images/a.jpg'),
      imgRef('#b', '/images/b.jpg'),
      imgRef('#c', '/images/c.jpg'),
    ]);
    const out = store.toBatchNote()!;
    assert.match(out, /^1\. reorder these to 1,2,3$/m);
    assert.match(out, /^ {3}1 → \/images\/a\.jpg$/m);
    assert.match(out, /^ {3}2 → \/images\/b\.jpg$/m);
    assert.match(out, /^ {3}3 → \/images\/c\.jpg$/m);
  });

  it('numbers non-asset refs too, falling back to source/selector', () => {
    const store = new NotesStore();
    const plain: NoteElementRef = {
      selector: '.btn',
      tagName: 'button',
      textContent: 'Save',
      sourceFile: 'src/F.tsx',
      sourceLine: 4,
    };
    store.add('rename', [plain]);
    const out = store.toBatchNote()!;
    assert.match(out, /^ {3}1 → <button> "Save" \(src\/F\.tsx:4\)$/m);
  });

  it('returns undefined when there are no notes', () => {
    assert.equal(new NotesStore().toBatchNote(), undefined);
  });
});

describe('NotesStore.toStructuredNotes (KL-6)', () => {
  it('returns undefined when there are no notes', () => {
    assert.equal(new NotesStore().toStructuredNotes(), undefined);
  });

  it('keeps the designer text apart from the element references', () => {
    const store = new NotesStore();
    store.add('reorder these', [imgRef('#a', '/images/a.jpg')]);
    const [note] = store.toStructuredNotes()!;
    assert.equal(note.text, 'reorder these');
    assert.deepEqual(note.elements, [
      { tagName: 'img', selector: '#a', sourceFile: 'src/G.tsx', sourceLine: 1, assetPath: '/images/a.jpg' },
    ]);
    assert.ok(!note.text.includes('/images/a.jpg'), 'element data must not be blended into the text');
  });

  it('omits an empty sourceFile (and its line) rather than sending a blank', () => {
    const store = new NotesStore();
    store.add('x', [{ selector: '.a', tagName: 'div', sourceFile: '', sourceLine: 0 }]);
    const ref = store.toStructuredNotes()![0].elements[0];
    assert.equal('sourceFile' in ref, false);
    assert.equal('sourceLine' in ref, false);
  });

  it('still produces the legacy batchNote alongside', () => {
    const store = new NotesStore();
    store.add('reorder these', [imgRef('#a', '/images/a.jpg')]);
    assert.match(store.toBatchNote()!, /^1\. reorder these$/m);
  });
});

describe('NotesStore.removeEntries (KL-6)', () => {
  it('removes exactly the given entries and keeps later ones', () => {
    const store = new NotesStore();
    store.add('a');
    store.add('b');
    const sent = store.getAll();
    store.add('c');
    store.removeEntries(sent);
    assert.deepEqual(store.getAll().map((n) => n.text), ['c']);
  });
});
