import type { ElementInfo, PropertyChange } from '@nco-studio/shared';
import { createElement } from '../../shared/ui-utils';
import { getComputedProperty, buildElementInfo } from '../../shared/dom-utils';
import { extractUnit } from './token-select';
import {
  OVERLAY,
  SELECTION,
  HANDLE_VISUAL_SIZE,
  HANDLE_HIT_AREA,
  SNAP_EASE_MS,
  HANDLE_COLORS,
  GUIDE_SNAP_THRESHOLD,
} from '../../shared/constants';
import { snapToGuides } from './guide-snap';
import { createZoneOverlays } from './zone-overlays';
import type { EditMode } from '../../shared/types';
import type { SnappingEngine } from '../tokens/snapping';
import type { PreviewManager } from './preview';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface HandleConfig {
  /** CSS property this handle controls. */
  readonly property: string;
  /** Drag axis. */
  readonly axis: 'x' | 'y' | 'xy';
  /** Position on the element's bounding rect. */
  readonly position: 'top' | 'right' | 'bottom' | 'left' | 'top-left' | 'top-right' | 'bottom-left' | 'bottom-right';
  /** Cursor style during drag. */
  readonly cursor: string;
  /** Handle pill color. */
  readonly color: string;
  /** Position offset from edge: negative = inset, positive = outset, 0 = on edge. */
  readonly positionOffset: number;
  /** Cross-axis offset to separate overlapping handles (e.g., padding vs margin on same edge). */
  readonly crossOffset?: number;
  /** Dynamic position offset — overrides positionOffset when present. Used for spacing handles where offset depends on current computed style. */
  readonly dynamicOffset?: (element: Element) => number;
  /** Whether this is a corner handle (border-radius). */
  readonly isCorner?: boolean;
  /** Text label rendered inside the handle pill (e.g., "Padding"). */
  readonly label?: string;
  /** Map drag delta (in px) to a CSS value string. */
  computeValue(startValue: number, delta: number): string;
  /** Parse the current computed value to a number. */
  parseValue(computed: string): number;
}

type EditCommitCallback = (elementInfo: ElementInfo, changes: PropertyChange[]) => void;

const MODE_LABELS: Partial<Record<EditMode, string>> = {
  spacing: 'SPACING',
  dimensions: 'DIMENSIONS',
  'border-radius': 'BORDER RADIUS',
};

const MODE_BADGE_COLORS: Partial<Record<EditMode, string>> = {
  spacing: HANDLE_COLORS.padding, // amber — primary spacing color
  dimensions: HANDLE_COLORS.dimensions,
  'border-radius': HANDLE_COLORS.borderRadius,
};

// ---------------------------------------------------------------------------
// DragHandleManager
// ---------------------------------------------------------------------------

/**
 * Renders drag handles around a selected element and manages
 * pointer-based drag interactions for CSS property editing.
 */
export class DragHandleManager {
  private handleEntries: Array<{ el: HTMLDivElement; pill: HTMLDivElement; config: HandleConfig }> = [];
  private rulers: HTMLDivElement[] = [];
  private zoneOverlays: HTMLDivElement[] = [];
  private modeBadge: HTMLDivElement | null = null;
  private currentElement: Element | null = null;
  private currentMode: EditMode | null = null;
  private _editing = false;
  private commitCb: EditCommitCallback | null = null;
  private dragUpdateCb: (() => void) | null = null;
  private disabledCb: ((reason: string) => void) | null = null;

  constructor(
    private readonly shadow: ShadowRoot,
    private readonly snapping: SnappingEngine,
    private readonly preview: PreviewManager,
    private readonly guideGetter?: () => { x: number[]; y: number[] },
  ) {}

  onEditCommit(cb: EditCommitCallback): void {
    this.commitCb = cb;
  }

  onDragUpdate(cb: () => void): void {
    this.dragUpdateCb = cb;
  }

  onDisabled(cb: (reason: string) => void): void {
    this.disabledCb = cb;
  }

  isEditing(): boolean {
    return this._editing;
  }

  /** Show handles for the given edit mode around the element. */
  showHandles(element: Element, mode: EditMode): void {
    this.hideHandles();
    this.currentElement = element;
    this.currentMode = mode;

    // Check if dimensions mode is valid for this element's layout context
    if (mode === 'dimensions') {
      const reason = getDimensionBlockReason(element);
      if (reason) {
        this.disabledCb?.(reason);
        return;
      }
    }

    const rect = element.getBoundingClientRect();
    const configs = getHandleConfigs(mode, rect);

    // Always render zone overlays (behind handles)
    this.renderSpacingZones(element, rect);

    // Mode badge above element
    this.renderModeBadge(mode, rect);

    for (const config of configs) {
      const { handle, pill } = this.createHandle(config, element, rect);
      this.shadow.appendChild(handle);
      this.handleEntries.push({ el: handle, pill, config });
    }
  }

  /** Remove all handles, rulers, zones, and badge. */
  hideHandles(): void {
    for (const { el } of this.handleEntries) el.remove();
    for (const r of this.rulers) r.remove();
    for (const z of this.zoneOverlays) z.remove();
    this.modeBadge?.remove();
    this.handleEntries = [];
    this.rulers = [];
    this.zoneOverlays = [];
    this.modeBadge = null;
    this.currentElement = null;
    this.currentMode = null;
    this._editing = false;
  }

  /** Reposition all handles, zones, and badge to match the element's current bounding rect. */
  refreshHandles(): void {
    if (!this.currentElement || (this.handleEntries.length === 0 && this.zoneOverlays.length === 0)) return;
    const rect = this.currentElement.getBoundingClientRect();
    for (const { el, config } of this.handleEntries) {
      const offset = config.dynamicOffset
        ? config.dynamicOffset(this.currentElement!)
        : config.positionOffset;
      const { x, y } = getHandlePosition(config.position, rect, offset, config.crossOffset);
      const hitW = config.label ? 48 : HANDLE_HIT_AREA;
      el.style.left = `${x - hitW / 2}px`;
      el.style.top = `${y - HANDLE_HIT_AREA / 2}px`;
    }
    // Reposition zone overlays
    if (this.zoneOverlays.length > 0) {
      this.repositionSpacingZones(this.currentElement, rect);
    }
    // Reposition badge
    if (this.modeBadge) {
      this.modeBadge.style.left = `${rect.left}px`;
      this.modeBadge.style.top = `${rect.top - 24}px`;
    }
  }

  /** Cancel an active drag edit (revert preview, hide rulers). */
  cancelEdit(): void {
    this.preview.revert();
    for (const r of this.rulers) r.remove();
    this.rulers = [];
    this._editing = false;
    // Restore handle opacity
    for (const { el } of this.handleEntries) {
      el.style.opacity = '1';
    }
  }

  /**
   * Programmatic nudge — used by keyboard handler.
   * Applies a delta to the specified property.
   */
  nudge(property: string, delta: number): void {
    if (!this.currentElement) return;

    const computed = getComputedProperty(this.currentElement, property);
    const currentVal = parseFloat(computed);
    if (isNaN(currentVal)) return;

    const newVal = currentVal + delta;
    const unit = extractUnit(computed) ?? 'px';
    const snap = this.snapping.snap(property, newVal);

    const newStr = `${snap.snappedValue}${unit}`;
    this.preview.begin(this.currentElement as HTMLElement);
    this.preview.apply(property, newStr);

    // Auto-commit nudge
    const originals = this.preview.commit();
    this.emitChange(property, originals.get(property) ?? computed, newStr, unit);
  }

  // -----------------------------------------------------------------------
  // Handle creation
  // -----------------------------------------------------------------------

  private createHandle(
    config: HandleConfig,
    element: Element,
    rect: DOMRect,
  ): { handle: HTMLDivElement; pill: HTMLDivElement } {
    const offset = config.dynamicOffset
      ? config.dynamicOffset(element)
      : config.positionOffset;
    const { x, y } = getHandlePosition(config.position, rect, offset, config.crossOffset);

    // Labeled handles need a wider hit area
    const hitW = config.label ? 48 : HANDLE_HIT_AREA;
    const hitH = HANDLE_HIT_AREA;

    // Visual indicator
    const handle = createElement('div', {}, {
      position: 'fixed',
      left: `${x - hitW / 2}px`,
      top: `${y - hitH / 2}px`,
      width: `${hitW}px`,
      height: `${hitH}px`,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      cursor: config.cursor,
      pointerEvents: 'auto',
      zIndex: '60',
      transition: 'opacity 0.1s',
    });

    // Inner visual: labeled circle for spacing, plain pill for dimensions, corner shape for border-radius
    const pill = config.isCorner
      ? this.createCornerPill(config)
      : config.label
        ? this.createLabeledPill(config)
        : this.createEdgePill(config);

    handle.appendChild(pill);

    // Drag interaction
    this.setupDrag(handle, pill, config, element);

    return { handle, pill };
  }

  private createEdgePill(config: HandleConfig): HTMLDivElement {
    return createElement('div', {}, {
      width: config.axis === 'y' ? `${HANDLE_VISUAL_SIZE * 2}px` : `${HANDLE_VISUAL_SIZE}px`,
      height: config.axis === 'x' ? `${HANDLE_VISUAL_SIZE * 2}px` : `${HANDLE_VISUAL_SIZE}px`,
      background: config.color,
      borderRadius: '9999px',
      transition: 'background 0.1s',
    });
  }

  private createLabeledPill(config: HandleConfig): HTMLDivElement {
    const pill = createElement('div', {}, {
      height: '14px',
      padding: '0 4px',
      background: config.color,
      borderRadius: '7px',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      transition: 'background 0.1s',
      whiteSpace: 'nowrap',
    });

    const label = createElement('span', {}, {
      color: '#000',
      fontSize: '8px',
      fontWeight: '700',
      fontFamily: OVERLAY.monoFamily,
      lineHeight: '1',
      pointerEvents: 'none',
      userSelect: 'none',
      letterSpacing: '0.3px',
    });
    label.textContent = config.label!;
    pill.appendChild(label);

    return pill;
  }

  private createCornerPill(config: HandleConfig): HTMLDivElement {
    // Small square with one rounded corner matching the corner being edited
    const size = 8;
    const radiusMap: Record<string, string> = {
      'top-left': '3px 9999px 3px 3px',
      'top-right': '9999px 3px 3px 3px',
      'bottom-right': '3px 3px 3px 9999px',
      'bottom-left': '3px 3px 9999px 3px',
    };

    return createElement('div', {}, {
      width: `${size}px`,
      height: `${size}px`,
      background: config.color,
      borderRadius: radiusMap[config.position] ?? '3px',
      transition: 'background 0.1s',
    });
  }

  private setupDrag(
    handle: HTMLDivElement,
    pill: HTMLDivElement,
    config: HandleConfig,
    element: Element,
  ): void {
    let startPos = 0;
    let startValue = 0;
    const rulerAxis: 'x' | 'y' = config.axis === 'xy' ? 'x' : config.axis;
    let ruler: HTMLDivElement | null = null;

    const onPointerDown = (e: PointerEvent) => {
      e.preventDefault();
      handle.setPointerCapture(e.pointerId);
      this._editing = true;

      startPos = config.axis === 'x' ? e.clientX : e.clientY;
      const computed = getComputedProperty(element, config.property);
      startValue = config.parseValue(computed);

      // Begin live preview
      this.preview.begin(element as HTMLElement);

      // Show token ruler
      const rect = element.getBoundingClientRect();
      ruler = this.snapping.renderRuler(
        this.shadow,
        rulerAxis,
        rect,
        config.property,
        startValue,
      );
      this.rulers.push(ruler);

      pill.style.background = config.color;

      // R4: Dim inactive handles during drag
      for (const entry of this.handleEntries) {
        entry.el.style.opacity = entry.el === handle ? '1' : '0.4';
      }

      // Hide mode badge during drag
      if (this.modeBadge) {
        this.modeBadge.style.opacity = '0';
        this.modeBadge.style.pointerEvents = 'none';
      }
    };

    const onPointerMove = (e: PointerEvent) => {
      if (!handle.hasPointerCapture(e.pointerId)) return;

      const currentPos = config.axis === 'x' ? e.clientX : e.clientY;
      const delta = currentPos - startPos;
      const newValue = config.computeValue(startValue, delta);

      // Apply live preview
      this.preview.apply(config.property, newValue);
      this.dragUpdateCb?.();

      // Update ruler position indicator if visible
      if (ruler) {
        const numVal = parseFloat(newValue);
        if (!isNaN(numVal)) {
          // Re-render ruler with updated position
          ruler.remove();
          const idx = this.rulers.indexOf(ruler);
          const rect = element.getBoundingClientRect();
          ruler = this.snapping.renderRuler(
            this.shadow,
            rulerAxis,
            rect,
            config.property,
            numVal,
          );
          if (idx >= 0) this.rulers[idx] = ruler;
          else this.rulers.push(ruler);
        }
      }
    };

    const onPointerUp = (e: PointerEvent) => {
      if (!handle.hasPointerCapture(e.pointerId)) return;
      handle.releasePointerCapture(e.pointerId);

      // Snap on release
      const currentPos = config.axis === 'x' ? e.clientX : e.clientY;
      const delta = currentPos - startPos;
      const rawValue = config.computeValue(startValue, delta);
      const numVal = parseFloat(rawValue);
      const unit = extractUnit(rawValue) ?? 'px';

      let finalValue = rawValue;
      if (!isNaN(numVal)) {
        // Check guide snap first — guides take priority over token snap.
        // Guide positions are in viewport coordinates, so we convert the
        // element's relevant edge position to viewport coords, snap that,
        // then derive the CSS value that places the edge at the guide.
        const guideAxis = config.axis === 'xy' ? 'x' : config.axis;
        const guidePositions = this.guideGetter?.();
        const axisGuides = guideAxis === 'x' ? guidePositions?.x : guidePositions?.y;

        let guideSnappedValue: number | null = null;
        if (axisGuides?.length) {
          const rect = element.getBoundingClientRect();
          const edgePos = getEdgePosition(config.position, rect, guideAxis);
          if (edgePos !== null) {
            const guideSnap = snapToGuides(edgePos, axisGuides, GUIDE_SNAP_THRESHOLD);
            if (guideSnap) {
              // Convert viewport guide position back to CSS value
              const delta = guideSnap.snapped - edgePos;
              guideSnappedValue = numVal + delta;
            }
          }
        }

        let snappedValue: number;
        let hasToken = false;

        if (guideSnappedValue !== null) {
          snappedValue = guideSnappedValue;
        } else {
          const snap = this.snapping.snap(config.property, numVal);
          snappedValue = snap.snappedValue;
          hasToken = !!snap.token;
        }

        finalValue = `${snappedValue}${unit}`;

        // Animate snap if value changed
        if (snappedValue !== numVal) {
          const el = element as HTMLElement;
          el.style.transition = `${config.property} ${SNAP_EASE_MS}ms ease`;
          el.style.setProperty(config.property, finalValue);
          setTimeout(() => {
            el.style.transition = '';
          }, SNAP_EASE_MS);
        } else {
          this.preview.apply(config.property, finalValue);
        }

        // Update handle color for snap feedback
        pill.style.background = (hasToken || guideSnappedValue !== null) ? HANDLE_COLORS.snapped : config.color;
      }

      // Commit
      const originals = this.preview.commit();
      const fromValue = originals.get(config.property) ??
        getComputedProperty(element, config.property);

      this.emitChange(config.property, fromValue, finalValue, unit);

      // Cleanup ruler
      if (ruler) {
        ruler.remove();
        const idx = this.rulers.indexOf(ruler);
        if (idx >= 0) this.rulers.splice(idx, 1);
      }

      this._editing = false;
      pill.style.background = config.color;

      // Restore all handle opacity
      for (const entry of this.handleEntries) {
        entry.el.style.opacity = '1';
      }

      // Restore mode badge
      if (this.modeBadge) {
        this.modeBadge.style.opacity = '1';
        this.modeBadge.style.pointerEvents = 'auto';
      }
    };

    handle.addEventListener('pointerdown', onPointerDown);
    handle.addEventListener('pointermove', onPointerMove);
    handle.addEventListener('pointerup', onPointerUp);
  }

  // -----------------------------------------------------------------------
  // Spacing zone overlays (R1)
  // -----------------------------------------------------------------------

  private renderSpacingZones(element: Element, _rect: DOMRect, animate = true): void {
    this.zoneOverlays = createZoneOverlays(element, this.shadow, { animate });
  }

  private repositionSpacingZones(element: Element, _rect: DOMRect): void {
    for (const z of this.zoneOverlays) z.remove();
    this.zoneOverlays = [];
    this.renderSpacingZones(element, _rect, false);
  }

  // -----------------------------------------------------------------------
  // Mode badge (R3)
  // -----------------------------------------------------------------------

  private renderModeBadge(mode: EditMode, rect: DOMRect): void {
    const label = MODE_LABELS[mode];
    if (!label) return;

    const badgeColor = MODE_BADGE_COLORS[mode] ?? SELECTION.ring;

    const badge = createElement('div', {}, {
      position: 'fixed',
      left: `${rect.left}px`,
      top: `${rect.top - 24}px`,
      background: OVERLAY.bg,
      color: OVERLAY.text,
      fontFamily: OVERLAY.monoFamily,
      fontSize: '11px',
      fontWeight: '500',
      lineHeight: '1',
      padding: '3px 6px',
      borderRadius: OVERLAY.radiusSm,
      display: 'flex',
      alignItems: 'center',
      gap: '5px',
      pointerEvents: 'none',
      zIndex: '61',
      whiteSpace: 'nowrap',
      transition: 'opacity 0.1s',
    });

    // Colored dot
    const dot = createElement('div', {}, {
      width: '6px',
      height: '6px',
      borderRadius: '50%',
      background: badgeColor,
      flexShrink: '0',
    });
    badge.appendChild(dot);

    // Label text
    const text = document.createTextNode(label);
    badge.appendChild(text);

    this.shadow.appendChild(badge);
    this.modeBadge = badge;
  }

  // -----------------------------------------------------------------------
  // Change emission
  // -----------------------------------------------------------------------

  private emitChange(
    property: string,
    fromValue: string,
    toValue: string,
    unit?: string,
  ): void {
    if (!this.currentElement || !this.commitCb) return;
    if (fromValue === toValue) return;

    const info = buildElementInfo(this.currentElement);
    const changes: PropertyChange[] = [
      {
        property,
        fromValue,
        toValue,
        unit: unit || undefined,
      },
    ];

    this.commitCb(info, changes);
  }
}

// ---------------------------------------------------------------------------
// Handle configuration factories
// ---------------------------------------------------------------------------

function getHandleConfigs(mode: EditMode, _rect: DOMRect): HandleConfig[] {
  switch (mode) {
    case 'spacing':
      return spacingHandles();
    case 'dimensions':
      return dimensionHandles();
    case 'border-radius':
      return borderRadiusHandles();
    default:
      return [];
  }
}

function spacingHandles(): HandleConfig[] {
  // Cross-axis offset separates padding and margin handles on the same edge
  const CROSS = 24;

  const makePadding = (
    side: 'top' | 'right' | 'bottom' | 'left',
    axis: 'x' | 'y',
    cursor: string,
  ): HandleConfig => ({
    property: `padding-${side}`,
    axis,
    position: side,
    cursor,
    color: HANDLE_COLORS.padding,
    positionOffset: 0,
    crossOffset: -CROSS,
    label: 'Padding',
    // Position at inner edge of padding zone (content edge)
    dynamicOffset: (el: Element) => {
      const v = parseFloat(getComputedStyle(el).getPropertyValue(`padding-${side}`)) || 0;
      return -v; // Negative = inset toward content edge
    },
    parseValue: (v) => parseFloat(v) || 0,
    computeValue: (start, delta) => {
      // Padding grows when dragging INTO the box (toward center)
      const sign = side === 'right' || side === 'bottom' ? -1 : 1;
      return `${Math.max(0, start + delta * sign)}px`;
    },
  });

  const makeMargin = (
    side: 'top' | 'right' | 'bottom' | 'left',
    axis: 'x' | 'y',
    cursor: string,
  ): HandleConfig => ({
    property: `margin-${side}`,
    axis,
    position: side,
    cursor,
    color: HANDLE_COLORS.margin,
    positionOffset: 0,
    crossOffset: CROSS,
    label: 'Margin',
    // Position at outer edge of margin zone
    dynamicOffset: (el: Element) => {
      const v = parseFloat(getComputedStyle(el).getPropertyValue(`margin-${side}`)) || 0;
      return v; // Positive = outset toward margin edge
    },
    parseValue: (v) => parseFloat(v) || 0,
    computeValue: (start, delta) => {
      const sign = side === 'right' || side === 'bottom' ? 1 : -1;
      return `${start + delta * sign}px`;
    },
  });

  return [
    makePadding('top', 'y', 'ns-resize'),
    makePadding('right', 'x', 'ew-resize'),
    makePadding('bottom', 'y', 'ns-resize'),
    makePadding('left', 'x', 'ew-resize'),
    makeMargin('top', 'y', 'ns-resize'),
    makeMargin('right', 'x', 'ew-resize'),
    makeMargin('bottom', 'y', 'ns-resize'),
    makeMargin('left', 'x', 'ew-resize'),
  ];
}

function dimensionHandles(): HandleConfig[] {
  return [
    {
      property: 'width',
      axis: 'x',
      position: 'right',
      cursor: 'ew-resize',
      color: HANDLE_COLORS.dimensions,
      positionOffset: 0,
      parseValue: (v) => parseFloat(v) || 0,
      computeValue: (start, delta) => `${Math.max(0, start + delta)}px`,
    },
    {
      property: 'height',
      axis: 'y',
      position: 'bottom',
      cursor: 'ns-resize',
      color: HANDLE_COLORS.dimensions,
      positionOffset: 0,
      parseValue: (v) => parseFloat(v) || 0,
      computeValue: (start, delta) => `${Math.max(0, start + delta)}px`,
    },
    {
      property: 'width',
      axis: 'x',
      position: 'left',
      cursor: 'ew-resize',
      color: HANDLE_COLORS.dimensions,
      positionOffset: 0,
      parseValue: (v) => parseFloat(v) || 0,
      computeValue: (start, delta) => `${Math.max(0, start - delta)}px`,
    },
    {
      property: 'height',
      axis: 'y',
      position: 'top',
      cursor: 'ns-resize',
      color: HANDLE_COLORS.dimensions,
      positionOffset: 0,
      parseValue: (v) => parseFloat(v) || 0,
      computeValue: (start, delta) => `${Math.max(0, start - delta)}px`,
    },
  ];
}

function borderRadiusHandles(): HandleConfig[] {
  const corners: Array<{
    prop: string;
    pos: HandleConfig['position'];
  }> = [
    { prop: 'border-top-left-radius', pos: 'top-left' },
    { prop: 'border-top-right-radius', pos: 'top-right' },
    { prop: 'border-bottom-right-radius', pos: 'bottom-right' },
    { prop: 'border-bottom-left-radius', pos: 'bottom-left' },
  ];

  return corners.map(({ prop, pos }) => ({
    property: prop,
    axis: 'xy' as const,
    position: pos,
    cursor: 'nwse-resize',
    color: HANDLE_COLORS.borderRadius,
    positionOffset: 0,
    isCorner: true,
    parseValue: (v: string) => parseFloat(v) || 0,
    computeValue: (start: number, delta: number) =>
      `${Math.max(0, start + delta)}px`,
  }));
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Compute handle pixel position with optional offset from the edge.
 * Negative offset = inset (toward center), positive = outset (away from center).
 * crossOffset shifts perpendicular to the edge (x for top/bottom, y for left/right).
 */
function getHandlePosition(
  position: HandleConfig['position'],
  rect: DOMRect,
  offset: number = 0,
  crossOffset: number = 0,
): { x: number; y: number } {
  switch (position) {
    case 'top':
      return { x: rect.left + rect.width / 2 + crossOffset, y: rect.top - offset };
    case 'right':
      return { x: rect.right + offset, y: rect.top + rect.height / 2 + crossOffset };
    case 'bottom':
      return { x: rect.left + rect.width / 2 + crossOffset, y: rect.bottom + offset };
    case 'left':
      return { x: rect.left - offset, y: rect.top + rect.height / 2 + crossOffset };
    case 'top-left':
      return { x: rect.left, y: rect.top };
    case 'top-right':
      return { x: rect.right, y: rect.top };
    case 'bottom-right':
      return { x: rect.right, y: rect.bottom };
    case 'bottom-left':
      return { x: rect.left, y: rect.bottom };
  }
}

/**
 * Check if an element's dimensions can't be freely resized.
 * Returns a reason string if blocked, null if resizing is OK.
 */
export function getDimensionBlockReason(element: Element): string | null {
  const parent = element.parentElement;
  if (parent) {
    const parentDisplay = getComputedStyle(parent).display;
    if (parentDisplay.includes('grid')) {
      return 'Element is in a grid layout — size is controlled by the grid';
    }
    if (parentDisplay.includes('flex')) {
      const style = getComputedStyle(element);
      // flex children with flex-basis/flex-grow set are layout-controlled
      const flexGrow = style.flexGrow;
      const flexBasis = style.flexBasis;
      if (flexGrow !== '0' || (flexBasis !== 'auto' && flexBasis !== '0px')) {
        return 'Element size is controlled by flexbox';
      }
    }
  }

  const style = getComputedStyle(element);
  const display = style.display;
  if (display === 'inline') {
    return 'Inline elements cannot be resized — change display first';
  }

  // Check for calculated/intrinsic sizing
  const width = style.width;
  const height = style.height;
  if (width.includes('calc') || height.includes('calc')) {
    return 'Element uses calc() — resize in code instead';
  }

  return null;
}

/**
 * Get the viewport coordinate of the element's edge for the given handle position.
 * Returns null for corner handles (xy axis) where guide snap doesn't apply.
 */
function getEdgePosition(
  position: HandleConfig['position'],
  rect: DOMRect,
  axis: 'x' | 'y',
): number | null {
  if (axis === 'x') {
    if (position === 'right') return rect.right;
    if (position === 'left') return rect.left;
  }
  if (axis === 'y') {
    if (position === 'bottom') return rect.bottom;
    if (position === 'top') return rect.top;
  }
  return null;
}
