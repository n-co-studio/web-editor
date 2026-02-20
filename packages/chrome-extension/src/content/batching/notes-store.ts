import type { NoteElementRef, NoteEntry } from '@frontend-editor/shared';

const NOTES_STORAGE_KEY = 'frontend-editor-session-notes';

type NotesChangeCallback = () => void;

/**
 * Session-scoped notes store. Persists notes to chrome.storage.session
 * so they survive panel re-renders and toolbar toggles.
 * Notes can reference DOM elements for communicating design intent to Claude.
 */
export class NotesStore {
  private notes: NoteEntry[] = [];
  private changeCallbacks: NotesChangeCallback[] = [];

  /** Get all notes (read-only copy). */
  getAll(): readonly NoteEntry[] {
    return [...this.notes];
  }

  get count(): number {
    return this.notes.length;
  }

  /** Add a note. Trims whitespace, ignores empty strings. */
  add(text: string, elements?: NoteElementRef[]): void {
    const trimmed = text.trim();
    if (!trimmed) return;
    this.notes.push({ text: trimmed, elements: elements ?? [] });
    this.persist();
    this.notify();
  }

  /** Add an element reference to an existing note. Deduplicates by selector. */
  addElementToNote(noteIndex: number, ref: NoteElementRef): void {
    if (noteIndex < 0 || noteIndex >= this.notes.length) return;
    const note = this.notes[noteIndex];
    // Deduplicate by selector
    if (note.elements.some((e) => e.selector === ref.selector)) return;
    this.notes[noteIndex] = {
      ...note,
      elements: [...note.elements, ref],
    };
    this.persist();
    this.notify();
  }

  /** Remove an element reference from a note. */
  removeElementFromNote(noteIndex: number, elementIndex: number): void {
    if (noteIndex < 0 || noteIndex >= this.notes.length) return;
    const note = this.notes[noteIndex];
    if (elementIndex < 0 || elementIndex >= note.elements.length) return;
    const elements = [...note.elements];
    elements.splice(elementIndex, 1);
    this.notes[noteIndex] = { ...note, elements };
    this.persist();
    this.notify();
  }

  /** Remove note at index. */
  remove(index: number): void {
    if (index < 0 || index >= this.notes.length) return;
    this.notes.splice(index, 1);
    this.persist();
    this.notify();
  }

  /** Clear all notes (called after successful batch send). */
  clear(): void {
    this.notes = [];
    this.persist();
    this.notify();
  }

  /** Join notes into a single string for the batchNote field. */
  toBatchNote(): string | undefined {
    if (this.notes.length === 0) return undefined;
    return this.notes.map((note, i) => {
      let line = `${i + 1}. ${note.text}`;
      if (note.elements.length > 0) {
        const refs = note.elements.map((ref) => `   \u2192 ${formatElementRef(ref)}`);
        line += '\n' + refs.join('\n');
      }
      return line;
    }).join('\n');
  }

  /** Register change callback. */
  onChange(cb: NotesChangeCallback): void {
    this.changeCallbacks.push(cb);
  }

  /** Restore from chrome.storage.session (handles legacy string[] format). */
  async restore(): Promise<void> {
    try {
      const result = await chrome.storage.session.get(NOTES_STORAGE_KEY);
      const stored = result[NOTES_STORAGE_KEY];
      if (Array.isArray(stored)) {
        this.notes = stored.map((item: unknown) => {
          if (typeof item === 'string') {
            // Legacy string format → migrate
            return { text: item, elements: [] };
          }
          const entry = item as { text?: string; elements?: unknown[] };
          const rawElements = Array.isArray(entry.elements) ? entry.elements : [];
          const validElements = rawElements.filter((el): el is NoteElementRef =>
            typeof el === 'object' && el !== null &&
            typeof (el as Record<string, unknown>).selector === 'string' &&
            typeof (el as Record<string, unknown>).tagName === 'string',
          );
          return {
            text: typeof entry.text === 'string' ? entry.text : '',
            elements: validElements,
          };
        });
      }
    } catch {
      // Non-fatal
    }
  }

  private persist(): void {
    chrome.storage.session.set({ [NOTES_STORAGE_KEY]: this.notes }).catch(() => {});
  }

  private notify(): void {
    for (const cb of this.changeCallbacks) cb();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function formatElementRef(ref: NoteElementRef): string {
  const label = ref.textContent
    ? `<${ref.tagName}> "${ref.textContent.slice(0, 30)}"`
    : `<${ref.tagName}> ${ref.selector.slice(0, 40)}`;
  const source = ref.sourceFile
    ? `(${ref.sourceFile}:${ref.sourceLine})`
    : `[${ref.selector}]`;
  return `${label} ${source}`;
}
