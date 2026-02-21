import type { DragHandleManager } from './handles';
import type { SelectionManager } from '../selection/select';

/**
 * Keyboard editing handler for the overlay.
 * Listens for Tab, Arrow, Enter/Space, and Escape within the shadow root.
 *
 * - Tab: cycle through editable properties
 * - Arrow keys: nudge value by 1px (or step through token stops)
 * - Shift+Arrow: nudge by 4px (or next token category step)
 * - Enter/Space: commit current edit
 * - Escape: handled by global handler in content/index.ts (3-level ladder)
 */
export class KeyboardHandler {
  private activeProperty: string | null = null;
  private destroyed = false;

  constructor(
    private readonly shadow: ShadowRoot,
    private readonly handles: DragHandleManager,
    private readonly _panel: unknown,
    private readonly selection: SelectionManager,
  ) {
    // ShadowRoot's typed addEventListener only supports 'slotchange'.
    // Cast to EventTarget for generic keydown listening.
    (shadow as EventTarget).addEventListener('keydown', this.handleKeyDown as EventListener);
  }

  destroy(): void {
    this.destroyed = true;
    (this.shadow as EventTarget).removeEventListener('keydown', this.handleKeyDown as EventListener);
  }

  // -----------------------------------------------------------------------
  // Key handling
  // -----------------------------------------------------------------------

  private handleKeyDown = (e: KeyboardEvent): void => {
    if (this.destroyed) return;

    switch (e.key) {
      case 'Tab':
        e.preventDefault();
        this.cycleProperty(e.shiftKey);
        break;

      case 'ArrowUp':
      case 'ArrowDown':
      case 'ArrowLeft':
      case 'ArrowRight': {
        if (!this.activeProperty) return;
        e.preventDefault();

        const step = e.shiftKey ? 4 : 1;
        const direction =
          e.key === 'ArrowUp' || e.key === 'ArrowLeft' ? -1 : 1;

        this.handles.nudge(this.activeProperty, step * direction);
        break;
      }

      case 'Enter':
      case ' ':
        if (this.handles.isEditing()) {
          e.preventDefault();
          // Commit is handled by pointer-up in handles; Enter just signals done
        }
        break;
    }
  };

  // -----------------------------------------------------------------------
  // Property cycling
  // -----------------------------------------------------------------------

  private static readonly CYCLE_ORDER = [
    'padding-top',
    'padding-right',
    'padding-bottom',
    'padding-left',
    'margin-top',
    'margin-right',
    'margin-bottom',
    'margin-left',
    'width',
    'height',
    'font-size',
    'font-weight',
    'line-height',
    'color',
    'background-color',
    'border-radius',
  ] as const;

  private cycleProperty(reverse: boolean): void {
    const props = KeyboardHandler.CYCLE_ORDER;

    if (!this.activeProperty) {
      this.activeProperty = reverse ? props[props.length - 1] : props[0];
    } else {
      const idx = props.indexOf(
        this.activeProperty as (typeof props)[number],
      );
      if (idx === -1) {
        this.activeProperty = props[0];
      } else if (reverse) {
        this.activeProperty = props[(idx - 1 + props.length) % props.length];
      } else {
        this.activeProperty = props[(idx + 1) % props.length];
      }
    }
  }
}
