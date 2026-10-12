import type { PropertyChange } from '@nco-studio/shared';
import { createElement, createText, createButton, makeDraggable } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY, TOOLBAR_WIDTH, HANDLE_COLORS } from '../../shared/constants';
import type { TokenStore } from '../tokens/store';
import type { PreviewManager } from './preview';
import { buildTokenSelect, extractUnit } from './token-select';

type ChangeCallback = (changes: PropertyChange[]) => void;

/** Short corner labels, in the order BORDER_RADIUS_PROPERTIES declares them. */
const CORNER_LABELS: Record<string, string> = {
  'border-top-left-radius': 'TL',
  'border-top-right-radius': 'TR',
  'border-bottom-right-radius': 'BR',
  'border-bottom-left-radius': 'BL',
};

/** Border radius corner properties. */
export const BORDER_RADIUS_PROPERTIES = [
  'border-top-left-radius',
  'border-top-right-radius',
  'border-bottom-right-radius',
  'border-bottom-left-radius',
] as const;

/** Read current border radius values for an element. */
export function readBorderRadiusValues(
  element: Element,
): Record<string, string> {
  const values: Record<string, string> = {};
  for (const prop of BORDER_RADIUS_PROPERTIES) {
    values[prop] = getComputedProperty(element, prop);
  }
  return values;
}

/**
 * Build PropertyChange objects from before/after border radius values.
 * Only includes properties that actually changed.
 */
export function buildBorderRadiusChanges(
  before: Record<string, string>,
  after: Record<string, string>,
): PropertyChange[] {
  const changes: PropertyChange[] = [];

  for (const prop of BORDER_RADIUS_PROPERTIES) {
    const fromValue = before[prop] ?? '0px';
    const toValue = after[prop] ?? '0px';
    if (fromValue !== toValue) {
      changes.push({
        property: prop,
        fromValue,
        toValue,
        unit: extractUnit(toValue),
      });
    }
  }

  return changes;
}

// ---------------------------------------------------------------------------
// Panel
// ---------------------------------------------------------------------------

/**
 * Floating panel for the four corner radii.
 *
 * Radius was the only edit mode whose toolbar button opened nothing: the mode
 * fell through to the default branch in `activateToolForElement`, which shows
 * the corner drag handles but appends no panel. Dragging worked; there was no
 * way to type a value, read the current one, or snap to a token.
 *
 * Laid out like `SpacingEditor` deliberately — same header, same draggable
 * chrome, same 2×2 grid of labelled cells — because a corner set and a side
 * set are the same shape of problem and the two panels sit next to each other
 * in the toolbar.
 *
 * The grid uses `minmax(0, 1fr)` rather than `1fr`. A bare `1fr` is
 * `minmax(auto, 1fr)`, whose minimum is the content's min-content width, which
 * is what pushed the Spacing panel's second column past its own edge.
 */
export class BorderRadiusEditor {
  private container: HTMLDivElement | null = null;
  private closeCb: (() => void) | null = null;
  private userDragged = false;
  /** Per-corner inputs, so "All corners" can write through to them. */
  private cornerInputs = new Map<string, HTMLInputElement>();

  constructor(
    private readonly tokenStore: TokenStore,
    private readonly preview: PreviewManager,
  ) {}

  onClose(cb: () => void): void {
    this.closeCb = cb;
  }

  render(
    element: Element,
    anchorPos: { x: number; y: number },
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    this.cleanup();

    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - 228,
    );
    const panelTop = Math.max(8, anchorPos.y);

    const container = createElement('div', { role: 'dialog', 'aria-label': 'Border radius editor' }, {
      position: 'fixed',
      left: `${panelLeft}px`,
      top: `${panelTop}px`,
      width: '220px',
      background: OVERLAY.bg,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusMd,
      boxShadow: OVERLAY.shadowLg,
      pointerEvents: 'auto',
      zIndex: '102',
      fontFamily: OVERLAY.fontFamily,
      overflow: 'hidden',
    });

    const header = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      padding: '6px 10px',
      borderBottom: `1px solid ${OVERLAY.border}`,
    });
    const title = createText('span', 'Radius', 'heading');
    title.style.fontSize = '12px';
    header.appendChild(title);

    const closeBtn = createButton('×', 'ghost', () => {
      this.cleanup();
      this.closeCb?.();
    });
    closeBtn.style.padding = '2px 6px';
    closeBtn.style.fontSize = '14px';
    header.appendChild(closeBtn);
    container.appendChild(header);

    makeDraggable(header, container, undefined, () => { this.userDragged = true; });

    const body = createElement('div', {}, {
      padding: '8px 10px',
      display: 'flex',
      flexDirection: 'column',
      gap: '8px',
    });

    const before = readBorderRadiusValues(element);

    // Group heading, matching the Spacing panel's dot + caps convention.
    const heading = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '5px',
    });
    const dot = createElement('span', {}, {
      width: '6px',
      height: '6px',
      borderRadius: '3px',
      background: HANDLE_COLORS.borderRadius,
      flexShrink: '0',
    });
    heading.appendChild(dot);
    const headingText = createText('span', 'CORNERS', 'mono');
    headingText.style.fontSize = '9px';
    headingText.style.letterSpacing = '0.5px';
    headingText.style.color = OVERLAY.textMuted;
    heading.appendChild(headingText);
    body.appendChild(heading);

    // "All corners" writes the same value to all four. This is the common case
    // for radius — far more so than for spacing, where sides usually differ —
    // so it leads rather than hiding behind a link toggle.
    body.appendChild(this.buildAllCornersRow(element, before, onCommit));

    const grid = createElement('div', {}, {
      display: 'grid',
      gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)',
      gap: '3px',
    });
    for (const prop of BORDER_RADIUS_PROPERTIES) {
      grid.appendChild(this.buildCornerCell(prop, element, onCommit));
    }
    body.appendChild(grid);

    container.appendChild(body);
    this.container = container;
    return container;
  }

  reposition(anchorPos: { x: number; y: number }): void {
    if (!this.container) return;
    if (this.userDragged) return;
    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - 228,
    );
    const panelTop = Math.max(8, anchorPos.y);
    this.container.style.left = `${panelLeft}px`;
    this.container.style.top = `${panelTop}px`;
  }

  cleanup(): void {
    this.container?.remove();
    this.container = null;
    this.userDragged = false;
    this.cornerInputs.clear();
  }

  // -----------------------------------------------------------------------
  // Controls
  // -----------------------------------------------------------------------

  /**
   * One input that drives all four corners.
   *
   * Commits through `buildBorderRadiusChanges`, so corners already at the
   * target value produce no change entry — the agent is not asked to rewrite
   * a property that did not move.
   */
  private buildAllCornersRow(
    element: Element,
    before: Record<string, string>,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
    });

    const label = createText('span', 'All', 'mono');
    label.style.color = OVERLAY.textMuted;
    label.style.fontSize = '10px';
    label.style.width = '22px';
    label.style.flexShrink = '0';
    label.style.whiteSpace = 'nowrap';
    row.appendChild(label);

    // Uniform only when every corner already agrees; otherwise left blank so
    // typing is an explicit choice rather than an accidental flatten.
    const values = BORDER_RADIUS_PROPERTIES.map((p) => before[p] ?? '0px');
    const uniform = values.every((v) => v === values[0]) ? values[0] : '';

    const input = createElement('input', {
      type: 'text',
      value: uniform,
      placeholder: uniform === '' ? 'mixed' : '',
      'aria-label': 'All corners radius',
    }, {
      background: 'rgba(255, 255, 255, 0.1)',
      color: OVERLAY.text,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '2px 4px',
      fontSize: '10px',
      fontFamily: OVERLAY.monoFamily,
      pointerEvents: 'auto',
      flex: '1',
      minWidth: '0',
    }) as HTMLInputElement;

    const applyAll = (commit: boolean): void => {
      const next = input.value.trim();
      if (next === '') return;
      const after: Record<string, string> = {};
      this.preview.begin(element as HTMLElement);
      for (const prop of BORDER_RADIUS_PROPERTIES) {
        this.preview.apply(prop, next);
        after[prop] = next;
      }
      if (!commit) return;
      this.preview.commit();
      for (const prop of BORDER_RADIUS_PROPERTIES) {
        const field = this.cornerInputs.get(prop);
        if (field) field.value = next;
      }
      // `before` is the render-time snapshot, so a corner already at the
      // target contributes nothing and the agent is never asked to rewrite a
      // property that did not move. Applying twice diffs from the original
      // each time, which is what a reader of the change list expects.
      const changes = buildBorderRadiusChanges(before, after);
      if (changes.length > 0) onCommit(changes);
    };

    input.addEventListener('input', () => applyAll(false));
    input.addEventListener('change', () => applyAll(true));
    input.addEventListener('keydown', (e) => {
      if ((e as KeyboardEvent).key === 'Enter') applyAll(true);
    });

    row.appendChild(input);
    return row;
  }

  private buildCornerCell(
    property: string,
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const cell = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
    });

    const cornerLabel = createText('span', CORNER_LABELS[property] ?? '', 'mono');
    cornerLabel.style.color = OVERLAY.textMuted;
    cornerLabel.style.fontSize = '10px';
    cornerLabel.style.fontWeight = '600';
    cornerLabel.style.width = '16px';
    cornerLabel.style.flexShrink = '0';
    cornerLabel.style.whiteSpace = 'nowrap';
    cell.appendChild(cornerLabel);

    const tokens = this.tokenStore.getForProperty(property);
    const currentValue = getComputedProperty(element, property);

    if (tokens.length > 0) {
      cell.appendChild(
        buildTokenSelect(property, tokens, currentValue, element, this.preview, onCommit),
      );
      return cell;
    }

    const input = createElement('input', {
      type: 'text',
      value: currentValue,
      'aria-label': `${CORNER_LABELS[property] ?? property} radius`,
    }, {
      background: 'rgba(255, 255, 255, 0.1)',
      color: OVERLAY.text,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '2px 3px',
      fontSize: '10px',
      fontFamily: OVERLAY.monoFamily,
      pointerEvents: 'auto',
      flex: '1',
      minWidth: '0',
    }) as HTMLInputElement;

    this.cornerInputs.set(property, input);

    const apply = (commit: boolean): void => {
      const next = input.value.trim();
      if (next === '') return;
      this.preview.begin(element as HTMLElement);
      this.preview.apply(property, next);
      if (!commit) return;
      this.preview.commit();
      if (next === currentValue) return;
      onCommit([
        { property, fromValue: currentValue, toValue: next, unit: extractUnit(next) },
      ]);
    };

    input.addEventListener('input', () => apply(false));
    input.addEventListener('change', () => apply(true));
    input.addEventListener('keydown', (e) => {
      if ((e as KeyboardEvent).key === 'Enter') apply(true);
    });

    cell.appendChild(input);
    return cell;
  }
}
