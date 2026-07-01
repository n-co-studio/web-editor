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
