import type { PropertyChange } from '@nco-studio/shared';
import { createElement, createText, createButton, makeDraggable } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { extractUnit } from './token-select';
import { OVERLAY, TOOLBAR_WIDTH } from '../../shared/constants';
import type { PreviewManager } from './preview';
import { MoveEditor, getMoveBlockReason } from './move';

type ChangeCallback = (changes: PropertyChange[]) => void;

/** CSS position values we expose. */
const POSITION_VALUES = ['static', 'relative', 'absolute', 'fixed', 'sticky'] as const;

/** Inset properties shown when position is absolute or fixed. */
const INSET_PROPERTIES = ['top', 'right', 'bottom', 'left'] as const;

const INSET_LABELS: Record<string, string> = {
  top: 'T',
  right: 'R',
  bottom: 'B',
  left: 'L',
};

/** 4-way arrow SVG icon reused from the old toolbar Move button. */
const MOVE_ICON = `<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
  <path d="M8 2v12M2 8h12"/>
  <polyline points="5,4 8,2 11,4"/>
  <polyline points="5,12 8,14 11,12"/>
  <polyline points="4,5 2,8 4,11"/>
  <polyline points="12,5 14,8 12,11"/>
</svg>`;

/**
 * Position editing controls rendered as a floating mini-panel.
 * Shows a position-type selector, a Move toggle button, and
 * when the position is absolute or fixed, editable inset fields.
 *
 * Composes MoveEditor internally — the Move toggle activates/deactivates
 * the drag-to-reposition overlay without requiring a separate toolbar tool.
 */
export class PositionEditor {
  private container: HTMLDivElement | null = null;
  private closeCb: (() => void) | null = null;
  private userDragged = false;
  private insetSection: HTMLDivElement | null = null;
  private currentElement: Element | null = null;
  private currentOnCommit: ChangeCallback | null = null;
  private moveToggleBtn: HTMLButtonElement | null = null;
  private moveActive = false;

  private readonly moveEditor: MoveEditor;

  constructor(
    private readonly shadow: ShadowRoot,
    private readonly preview: PreviewManager,
  ) {
    this.moveEditor = new MoveEditor(shadow, preview);
  }

  onClose(cb: () => void): void {
    this.closeCb = cb;
  }

  render(
    element: Element,
    anchorPos: { x: number; y: number },
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    this.cleanup();
    this.currentElement = element;
    this.currentOnCommit = onCommit;

    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - 228,
    );
    const panelTop = Math.max(8, anchorPos.y);

    const container = createElement('div', { role: 'dialog', 'aria-label': 'Position editor' }, {
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

    // Header
    const header = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      padding: '6px 10px',
      borderBottom: `1px solid ${OVERLAY.border}`,
    });
    const title = createText('span', 'Position', 'heading');
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

    makeDraggable(header, container, undefined, () => { this.userDragged = true; });

    // Body
    const body = createElement('div', {}, {
      padding: '8px 10px',
      display: 'flex',
      flexDirection: 'column',
      gap: '8px',
    });

    // Position type selector
    body.appendChild(this.buildPositionSelector(element, onCommit));

    // Move toggle row (between position selector and inset section)
    body.appendChild(this.buildMoveToggle(element, onCommit));

    // Inset section (conditionally visible)
    this.insetSection = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '6px',
    });
    this.buildInsetControls(element, onCommit);
    body.appendChild(this.insetSection);

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
    this.moveEditor.cleanup();
    this.moveActive = false;
    this.moveToggleBtn = null;
    this.container?.remove();
    this.container = null;
    this.insetSection = null;
    this.currentElement = null;
    this.currentOnCommit = null;
    this.userDragged = false;
  }

  // -----------------------------------------------------------------------
  // Move delegation methods (for index.ts integration)
  // -----------------------------------------------------------------------

  /** Whether the Move toggle is currently active. */
  isMoveActive(): boolean {
    return this.moveActive;
  }

  /** Whether a drag is in progress within the MoveEditor. */
  isMoveDragging(): boolean {
    return this.moveEditor.isDragging();
  }

  /** Cancel an active drag but keep Move toggle active (re-renders overlay). */
  cancelMoveDrag(): void {
    if (!this.currentElement || !this.currentOnCommit) return;
    this.moveEditor.cleanup();
    this.moveEditor.render(this.currentElement, this.makeMoveCommit());
  }

  /** Turn off Move toggle, clean up overlay, restore inset section. */
  deactivateMove(): void {
    this.moveEditor.cleanup();
    this.moveActive = false;
    this.applyMoveToggleStyle();
    // Restore inset section
    if (this.insetSection && this.currentElement && this.currentOnCommit) {
      this.insetSection.style.display = 'flex';
      this.buildInsetControls(this.currentElement, this.currentOnCommit);
    }
  }

  /** Refresh the cursor overlay position (e.g., after scroll). */
  refreshMoveOverlay(): void {
    this.moveEditor.refreshOverlay();
  }

  // -----------------------------------------------------------------------
  // Move toggle button
  // -----------------------------------------------------------------------

  private buildMoveToggle(
    element: Element,
    _onCommit: ChangeCallback,
  ): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '6px',
    });

    const btn = createElement('button', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '6px',
      width: '100%',
      padding: '5px 8px',
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      background: 'transparent',
      color: OVERLAY.textMuted,
      cursor: 'pointer',
      fontFamily: OVERLAY.fontFamily,
      fontSize: '11px',
      transition: 'background 0.1s, color 0.1s',
      pointerEvents: 'auto',
    }) as HTMLButtonElement;

    const iconSpan = createElement('span', {}, {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      width: '14px',
      height: '14px',
      flexShrink: '0',
    });
    iconSpan.innerHTML = MOVE_ICON;
    btn.appendChild(iconSpan);

    const label = createElement('span', {}, {});
    label.textContent = 'Move';
    btn.appendChild(label);

    this.moveToggleBtn = btn;

    // Check if move is blocked
    const blockReason = getMoveBlockReason(element);
    if (blockReason) {
      btn.style.opacity = '0.3';
      btn.style.cursor = 'not-allowed';
      btn.title = `Move \u2014 ${blockReason}`;
    } else {
      btn.title = 'Drag to reposition element';
    }

    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      if (!this.currentElement || !this.currentOnCommit) return;

      // Re-check block reason (position may have changed)
      const reason = getMoveBlockReason(this.currentElement);
      if (reason) return;

      if (this.moveActive) {
        // Toggle OFF
        this.deactivateMove();
      } else {
        // Toggle ON
        this.moveActive = true;
        this.applyMoveToggleStyle();
        // Hide inset section
        if (this.insetSection) {
          this.insetSection.style.display = 'none';
        }
        this.moveEditor.render(this.currentElement, this.makeMoveCommit());
      }
    });

    btn.addEventListener('mouseenter', () => {
      if (btn.style.opacity !== '0.3' && !this.moveActive) {
        btn.style.background = 'rgba(255, 255, 255, 0.08)';
      }
    });
    btn.addEventListener('mouseleave', () => {
      this.applyMoveToggleStyle();
    });

    row.appendChild(btn);
    return row;
  }

  private applyMoveToggleStyle(): void {
    if (!this.moveToggleBtn) return;
    if (!this.currentElement) return;

    const blockReason = getMoveBlockReason(this.currentElement);
    if (blockReason) {
      this.moveToggleBtn.style.opacity = '0.3';
      this.moveToggleBtn.style.cursor = 'not-allowed';
      this.moveToggleBtn.style.background = 'transparent';
      this.moveToggleBtn.style.color = OVERLAY.textMuted;
      this.moveToggleBtn.title = `Move \u2014 ${blockReason}`;
    } else if (this.moveActive) {
      this.moveToggleBtn.style.opacity = '1';
      this.moveToggleBtn.style.cursor = 'pointer';
      this.moveToggleBtn.style.background = 'rgba(6, 182, 212, 0.12)';
      this.moveToggleBtn.style.color = OVERLAY.primary;
      this.moveToggleBtn.title = 'Drag to reposition element';
    } else {
      this.moveToggleBtn.style.opacity = '1';
      this.moveToggleBtn.style.cursor = 'pointer';
      this.moveToggleBtn.style.background = 'transparent';
      this.moveToggleBtn.style.color = OVERLAY.textMuted;
      this.moveToggleBtn.title = 'Drag to reposition element';
    }
  }

  /** Build the onCommit callback for the composed MoveEditor. */
  private makeMoveCommit(): ChangeCallback {
    return (changes) => {
      this.currentOnCommit?.(changes);
    };
  }

  // -----------------------------------------------------------------------
  // Position type selector
  // -----------------------------------------------------------------------

  private buildPositionSelector(
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '4px',
    });

    const labelRow = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
    });

    const label = createText('span', 'position', 'mono');
    label.style.color = OVERLAY.textMuted;
    label.style.fontSize = '10px';
    labelRow.appendChild(label);
    row.appendChild(labelRow);

    const currentValue = getComputedProperty(element, 'position');

    const btnRow = createElement('div', {}, {
      display: 'flex',
      gap: '2px',
    });

    for (const pos of POSITION_VALUES) {
      const isActive = pos === currentValue;
      const btn = createButton(pos, isActive ? 'primary' : 'ghost', () => {
        if (pos === currentValue) return;
        const fromValue = getComputedProperty(element, 'position');
        this.preview.begin(element as HTMLElement);
        this.preview.apply('position', pos);
        this.preview.commit();
        onCommit([{
          property: 'position',
          fromValue,
          toValue: pos,
        }]);

        // Refresh inset section visibility
        this.refreshInsetVisibility(pos);

        // Refresh move toggle enabled state
        this.refreshMoveToggleState();

        // Re-style all buttons in this row
        for (const child of Array.from(btnRow.children) as HTMLButtonElement[]) {
          const val = child.dataset.posValue;
          if (val === pos) {
            child.style.background = 'rgba(6, 182, 212, 0.12)';
            child.style.color = OVERLAY.primary;
          } else {
            child.style.background = 'transparent';
            child.style.color = OVERLAY.textMuted;
          }
        }
      });
      btn.dataset.posValue = pos;
      btn.style.flex = '1';
      btn.style.padding = '3px 0';
      btn.style.fontSize = '9px';
      btn.style.fontFamily = OVERLAY.monoFamily;
      btn.style.textTransform = 'uppercase';
      btn.style.letterSpacing = '0.3px';
      btnRow.appendChild(btn);
    }

    row.appendChild(btnRow);
    return row;
  }

  // -----------------------------------------------------------------------
  // Inset controls (top, right, bottom, left)
  // -----------------------------------------------------------------------

  private buildInsetControls(
    element: Element,
    onCommit: ChangeCallback,
  ): void {
    if (!this.insetSection) return;
    this.insetSection.innerHTML = '';

    const currentPosition = getComputedProperty(element, 'position');
    const showInsets = currentPosition === 'absolute' || currentPosition === 'fixed';

    // Don't show insets while move is active
    if (!showInsets || this.moveActive) {
      this.insetSection.style.display = 'none';
      return;
    }

    this.insetSection.style.display = 'flex';

    // Section header
    const headerRow = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '5px',
      marginTop: '2px',
    });
    const headerLabel = createText('span', 'Inset', 'heading');
    headerLabel.style.fontSize = '11px';
    headerLabel.style.color = OVERLAY.textMuted;
    headerLabel.style.textTransform = 'uppercase';
    headerLabel.style.letterSpacing = '0.5px';
    headerRow.appendChild(headerLabel);
    this.insetSection.appendChild(headerRow);

    // 2x2 grid: T R / B L
    const grid = createElement('div', {}, {
      display: 'grid',
      gridTemplateColumns: '1fr 1fr',
      gap: '3px',
    });

    for (const prop of INSET_PROPERTIES) {
      grid.appendChild(this.buildInsetCell(prop, element, onCommit));
    }

    this.insetSection.appendChild(grid);
  }

  private buildInsetCell(
    property: string,
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const cell = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
    });

    const sideLabel = createText('span', INSET_LABELS[property] ?? '', 'mono');
    sideLabel.style.color = OVERLAY.textMuted;
    sideLabel.style.fontSize = '10px';
    sideLabel.style.fontWeight = '600';
    sideLabel.style.width = '10px';
    sideLabel.style.flexShrink = '0';
    cell.appendChild(sideLabel);

    const currentValue = getComputedProperty(element, property);

    const input = createElement('input', {
      type: 'text',
      value: currentValue === 'auto' ? 'auto' : currentValue,
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

    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        const fromValue = getComputedProperty(element, property);
        const toValue = input.value.trim();
        if (toValue && toValue !== fromValue) {
          this.preview.begin(element as HTMLElement);
          this.preview.apply(property, toValue);
          this.preview.commit();
          onCommit([{
            property,
            fromValue,
            toValue,
            unit: extractUnit(toValue),
          }]);
        }
      }
    });

    cell.appendChild(input);
    return cell;
  }

  // -----------------------------------------------------------------------
  // Refresh helpers
  // -----------------------------------------------------------------------

  private refreshInsetVisibility(_newPosition: string): void {
    if (!this.insetSection || !this.currentElement || !this.currentOnCommit) return;
    this.buildInsetControls(this.currentElement, this.currentOnCommit);
  }

  /** Re-evaluate the Move toggle's enabled/disabled state after position type change. */
  private refreshMoveToggleState(): void {
    if (!this.moveToggleBtn || !this.currentElement) return;

    const blockReason = getMoveBlockReason(this.currentElement);

    if (!blockReason && this.moveToggleBtn.style.opacity === '0.3') {
      // Position changed from blocked → movable: auto-enable is just making it clickable
      // (don't auto-activate the toggle — just enable the button)
    }

    if (blockReason && this.moveActive) {
      // Position changed to blocked while move was active — deactivate
      this.deactivateMove();
    }

    this.applyMoveToggleStyle();
  }
}
