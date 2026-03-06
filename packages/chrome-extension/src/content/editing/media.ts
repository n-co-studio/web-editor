import type { PropertyChange, AttributeChange } from '@frontend-editor/shared';
import { createElement, createText, createButton } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY, TOOLBAR_WIDTH } from '../../shared/constants';
import type { PreviewManager } from './preview';

// File System Access API types (not in standard TS lib)
declare global {
  interface Window {
    showOpenFilePicker?: (options?: OpenFilePickerOptions) => Promise<FileSystemFileHandle[]>;
  }
  interface OpenFilePickerOptions {
    types?: Array<{ description: string; accept: Record<string, string[]> }>;
    multiple?: boolean;
    startIn?: FileSystemDirectoryHandle | string;
  }
}

type ChangeCallback = (changes: PropertyChange[]) => void;
type AttributeCallback = (changes: AttributeChange[]) => void;

const PANEL_WIDTH = 240;

const OBJECT_FIT_OPTIONS = ['fill', 'contain', 'cover', 'none', 'scale-down'] as const;
const OBJECT_POSITION_OPTIONS = ['center', 'top', 'bottom', 'left', 'right', 'top left', 'top right', 'bottom left', 'bottom right'] as const;
const ASPECT_RATIO_PRESETS = ['auto', '16 / 9', '4 / 3', '3 / 2', '1 / 1'] as const;

/**
 * Media editing panel — controls for image/video source, object-fit,
 * object-position, and aspect-ratio.
 * Renders as a positioned floating panel anchored to the toolbar.
 */
export class MediaEditor {
  private container: HTMLDivElement | null = null;
  private closeCb: (() => void) | null = null;

  constructor(
    private readonly preview: PreviewManager,
  ) {}

  onClose(cb: () => void): void {
    this.closeCb = cb;
  }

  render(
    element: Element,
    anchorPos: { x: number; y: number },
    onCommit: ChangeCallback,
    onAttributeCommit: AttributeCallback,
  ): HTMLDivElement {
    this.cleanup();

    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - (PANEL_WIDTH + 8),
    );
    const panelTop = Math.max(8, anchorPos.y);

    const container = createElement('div', { role: 'dialog', 'aria-label': 'Media editor' }, {
      position: 'fixed',
      left: `${panelLeft}px`,
      top: `${panelTop}px`,
      width: `${PANEL_WIDTH}px`,
      background: OVERLAY.bg,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusMd,
      boxShadow: OVERLAY.shadowLg,
      pointerEvents: 'auto',
      zIndex: '102',
      fontFamily: OVERLAY.fontFamily,
      overflow: 'hidden',
    });

    // Header
    const header = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      padding: '6px 10px',
      borderBottom: `1px solid ${OVERLAY.border}`,
    });
    const title = createText('span', 'Media', 'heading');
    title.style.fontSize = '12px';
    header.appendChild(title);

    const closeBtn = createButton('\u00d7', 'ghost', () => {
      this.cleanup();
      this.closeCb?.();
    });
    closeBtn.style.padding = '2px 6px';
    closeBtn.style.fontSize = '14px';
    header.appendChild(closeBtn);
    container.appendChild(header);

    // Body
    const body = createElement('div', {}, {
      padding: '8px 10px',
      display: 'flex',
      flexDirection: 'column',
      gap: '10px',
      maxHeight: '400px',
      overflowY: 'auto',
    });

    const isMediaElement = this.isMediaElement(element);

    // Source URL (only for img, video, source elements)
    if (isMediaElement) {
      const srcValue = (element as HTMLImageElement).src || '';
      body.appendChild(this.buildTextInput(
        'Source URL',
        srcValue,
        (value) => {
          const oldSrc = (element as HTMLImageElement).src || '';
          (element as HTMLImageElement).src = value;
          onAttributeCommit([{
            type: 'attribute',
            attribute: 'src',
            fromValue: oldSrc,
            toValue: value,
          }]);
        },
        { filePicker: true },
      ));

      // Alt text (only for img)
      if (element.tagName === 'IMG') {
        const altValue = (element as HTMLImageElement).alt || '';
        body.appendChild(this.buildTextInput(
          'Alt text',
          altValue,
          (value) => {
            const oldAlt = (element as HTMLImageElement).alt || '';
            (element as HTMLImageElement).alt = value;
            onAttributeCommit([{
              type: 'attribute',
              attribute: 'alt',
              fromValue: oldAlt,
              toValue: value,
            }]);
          },
        ));
      }
    }

    // Background image URL (for non-media elements)
    if (!isMediaElement) {
      const bgImage = getComputedProperty(element, 'background-image');
      const bgUrl = this.extractUrl(bgImage);
      body.appendChild(this.buildTextInput(
        'Background URL',
        bgUrl,
        (value) => {
          const cssValue = value ? `url(${value})` : 'none';
          this.preview.begin(element as HTMLElement);
          this.preview.apply('background-image', cssValue);
          this.preview.commit();
          onCommit([{
            property: 'background-image',
            fromValue: bgImage,
            toValue: cssValue,
          }]);
        },
        { filePicker: true },
      ));

      // Background size
      body.appendChild(this.buildSelect(
        'background-size',
        element,
        ['auto', 'cover', 'contain', '100% 100%'],
        onCommit,
      ));

      // Background position
      body.appendChild(this.buildSelect(
        'background-position',
        element,
        ['center', 'top', 'bottom', 'left', 'right', 'top left', 'top right', 'bottom left', 'bottom right'],
        onCommit,
      ));

      // Background repeat
      body.appendChild(this.buildSelect(
        'background-repeat',
        element,
        ['repeat', 'no-repeat', 'repeat-x', 'repeat-y', 'space', 'round'],
        onCommit,
      ));
    }

    // Object-fit (for replaced elements: img, video, canvas, etc.)
    if (isMediaElement) {
      body.appendChild(this.buildSelect(
        'object-fit',
        element,
        [...OBJECT_FIT_OPTIONS],
        onCommit,
      ));

      // Object-position
      body.appendChild(this.buildSelect(
        'object-position',
        element,
        [...OBJECT_POSITION_OPTIONS],
        onCommit,
      ));
    }

    // Aspect-ratio (works on any element)
    body.appendChild(this.buildSelect(
      'aspect-ratio',
      element,
      [...ASPECT_RATIO_PRESETS],
      onCommit,
    ));

    container.appendChild(body);
    this.container = container;
    return container;
  }

  reposition(anchorPos: { x: number; y: number }): void {
    if (!this.container) return;
    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - (PANEL_WIDTH + 8),
    );
    const panelTop = Math.max(8, anchorPos.y);
    this.container.style.left = `${panelLeft}px`;
    this.container.style.top = `${panelTop}px`;
  }

  cleanup(): void {
    this.container?.remove();
    this.container = null;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  private isMediaElement(el: Element): boolean {
    const tag = el.tagName;
    return tag === 'IMG' || tag === 'VIDEO' || tag === 'CANVAS' || tag === 'SVG' || tag === 'PICTURE';
  }

  private extractUrl(bgImage: string): string {
    const match = bgImage.match(/url\(["']?([^"')]+)["']?\)/);
    return match?.[1] ?? '';
  }

  private buildTextInput(
    label: string,
    value: string,
    onChange: (value: string) => void,
    options?: { filePicker?: boolean },
  ): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '4px',
    });

    const labelEl = createText('div', label, 'mono');
    labelEl.style.color = OVERLAY.textMuted;
    labelEl.style.fontSize = '10px';
    row.appendChild(labelEl);

    const inputRow = createElement('div', {}, {
      display: 'flex',
      gap: '4px',
      alignItems: 'center',
    });

    const input = createElement('input', { type: 'text', value, placeholder: label }, {
      flex: '1',
      minWidth: '0',
      padding: '4px 6px',
      background: 'rgba(255, 255, 255, 0.08)',
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      color: OVERLAY.text,
      fontSize: OVERLAY.monoSize,
      fontFamily: OVERLAY.monoFamily,
      outline: 'none',
      boxSizing: 'border-box',
    }) as HTMLInputElement;

    input.addEventListener('focus', () => {
      input.style.borderColor = OVERLAY.primary;
    });
    input.addEventListener('blur', () => {
      input.style.borderColor = OVERLAY.border;
    });
    input.addEventListener('keydown', (e) => {
      e.stopPropagation();
      if (e.key === 'Enter') {
        onChange(input.value);
        input.blur();
      }
    });
    input.addEventListener('change', () => {
      onChange(input.value);
    });

    inputRow.appendChild(input);

    if (options?.filePicker) {
      const browseBtn = createElement('button', {}, {
        padding: '4px 8px',
        fontSize: '10px',
        flexShrink: '0',
        whiteSpace: 'nowrap',
        border: `1px solid ${OVERLAY.border}`,
        borderRadius: OVERLAY.radiusSm,
        background: 'rgba(255, 255, 255, 0.08)',
        color: OVERLAY.textMuted,
        cursor: 'pointer',
        fontFamily: OVERLAY.fontFamily,
      }) as HTMLButtonElement;
      browseBtn.textContent = 'Browse';
      browseBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        e.preventDefault();
        this.openFilePicker((dataUrl) => {
          input.value = dataUrl;
          onChange(dataUrl);
        });
      });
      browseBtn.addEventListener('mousedown', (e) => e.stopPropagation());
      browseBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
      inputRow.appendChild(browseBtn);
    }

    row.appendChild(inputRow);
    return row;
  }

  /** Last file handle — browser uses its parent directory as startIn for the next pick. */
  private static lastFileHandle: FileSystemFileHandle | null = null;

  private async openFilePicker(onSelect: (dataUrl: string) => void): Promise<void> {
    // Try File System Access API first (remembers directory per project)
    if ('showOpenFilePicker' in window) {
      try {
        const opts: OpenFilePickerOptions = {
          types: [
            {
              description: 'Images',
              accept: { 'image/*': ['.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.avif', '.ico'] },
            },
            {
              description: 'Videos',
              accept: { 'video/*': ['.mp4', '.webm', '.ogg', '.mov'] },
            },
          ],
          multiple: false,
        };
        // Start in the same folder as the last picked file
        if (MediaEditor.lastFileHandle) {
          (opts as any).startIn = MediaEditor.lastFileHandle;
        }
        const [handle] = await window.showOpenFilePicker!(opts);
        MediaEditor.lastFileHandle = handle;
        // Persist handle to IndexedDB so it survives page reloads
        MediaEditor.persistHandle(handle);
        const file = await handle.getFile();
        this.readFileAsDataUrl(file, onSelect);
        return;
      } catch {
        // User cancelled or API not available — fall through
        return;
      }
    }

    // Fallback: detached file input
    const fileInput = document.createElement('input');
    fileInput.type = 'file';
    fileInput.accept = 'image/*,video/*';

    fileInput.addEventListener('change', () => {
      const file = fileInput.files?.[0];
      if (!file) return;
      this.readFileAsDataUrl(file, onSelect);
    });

    fileInput.click();
  }

  /** Persist the last file handle to IndexedDB (keyed by origin). */
  private static persistHandle(handle: FileSystemFileHandle): void {
    const dbReq = indexedDB.open('frontend-editor-media', 1);
    dbReq.onupgradeneeded = () => {
      const db = dbReq.result;
      if (!db.objectStoreNames.contains('handles')) {
        db.createObjectStore('handles');
      }
    };
    dbReq.onsuccess = () => {
      const db = dbReq.result;
      const tx = db.transaction('handles', 'readwrite');
      tx.objectStore('handles').put(handle, 'lastFileHandle');
    };
  }

  /** Restore the last file handle from IndexedDB on first use. */
  static restoreHandle(): void {
    const dbReq = indexedDB.open('frontend-editor-media', 1);
    dbReq.onupgradeneeded = () => {
      const db = dbReq.result;
      if (!db.objectStoreNames.contains('handles')) {
        db.createObjectStore('handles');
      }
    };
    dbReq.onsuccess = () => {
      const db = dbReq.result;
      const tx = db.transaction('handles', 'readonly');
      const getReq = tx.objectStore('handles').get('lastFileHandle');
      getReq.onsuccess = () => {
        if (getReq.result) {
          MediaEditor.lastFileHandle = getReq.result as FileSystemFileHandle;
        }
      };
    };
  }

  private readFileAsDataUrl(file: File, onSelect: (dataUrl: string) => void): void {
    const reader = new FileReader();
    reader.onload = () => {
      onSelect(reader.result as string);
    };
    reader.readAsDataURL(file);
  }

  private buildSelect(
    property: string,
    element: Element,
    options: string[],
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const currentValue = getComputedProperty(element, property);

    const row = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '4px',
    });

    const label = createText('div', property, 'mono');
    label.style.color = OVERLAY.textMuted;
    label.style.fontSize = '10px';
    row.appendChild(label);

    const select = createElement('select', {}, {
      width: '100%',
      padding: '4px 6px',
      background: 'rgba(255, 255, 255, 0.08)',
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      color: OVERLAY.text,
      fontSize: OVERLAY.monoSize,
      fontFamily: OVERLAY.monoFamily,
      outline: 'none',
      cursor: 'pointer',
      boxSizing: 'border-box',
    }) as HTMLSelectElement;

    for (const opt of options) {
      const option = createElement('option', { value: opt }, {
        background: '#1a1a2e',
        color: OVERLAY.text,
      }) as HTMLOptionElement;
      option.textContent = opt;
      if (this.normalizeValue(currentValue) === this.normalizeValue(opt)) {
        option.selected = true;
      }
      select.appendChild(option);
    }

    select.addEventListener('change', () => {
      const newValue = select.value;
      this.preview.begin(element as HTMLElement);
      this.preview.apply(property, newValue);
      this.preview.commit();
      onCommit([{
        property,
        fromValue: currentValue,
        toValue: newValue,
      }]);
    });

    row.appendChild(select);
    return row;
  }

  private normalizeValue(val: string): string {
    return val.replace(/\s+/g, ' ').trim().toLowerCase();
  }
}
