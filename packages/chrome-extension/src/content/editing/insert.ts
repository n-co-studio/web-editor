/**
 * Insert editing — click between siblings in a flex/grid container to
 * insert a new element.
 *
 * 3-state FSM: SCANNING → CONFIGURING → COMMITTED (→ SCANNING)
 *
 * SCANNING: persistent clickable drop zones with plus-circle at each child gap.
 * CONFIGURING: Shadow DOM phantom at gap, confirm button.
 * COMMITTED: createElement + insertBefore, fire commit callback, return to SCANNING.
 */

import { createElement } from '../../shared/ui-utils';
import { INSERT_INDICATOR, OVERLAY } from '../../shared/constants';
import { detectContainerLayout, computeGapZones, type ContainerLayout, type GapZone } from './gap-math';
import type { InsertState } from '../../shared/types';
import { InsertPanel } from './insert-panel';
import type { InsertPanelConfig } from './insert-panel';
import { isProjectComponentEntry, type CompoundChild } from './insert-catalog';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** Callback shape for insert commit. */
export type InsertCommitCallback = (
  element: HTMLElement,
  container: HTMLElement,
  insertIndex: number,
  config: InsertPanelConfig | null,
) => void;

/** A drop zone with attached visual elements. */
interface InsertZone extends Omit<GapZone, 'center'> {
  /** Mutable center position (updated on scroll/resize). */
  center: number;
  /** The clickable drop zone element in Shadow DOM. */
  zoneEl: HTMLDivElement | null;
}

// ---------------------------------------------------------------------------
// Block-reason guard
// ---------------------------------------------------------------------------

/**
 * Returns a human-readable reason why insert is blocked for this element,
 * or null if the element is a valid flex/grid container for insertion.
 */
export function getInsertBlockReason(element: Element): string | null {
  const style = getComputedStyle(element);
  const display = style.display;

  const isFlex = display.includes('flex');
  const isGrid = display.includes('grid');

  if (!isFlex && !isGrid) {
    return 'Element is not a flex or grid container';
  }

  return null;
}

// ---------------------------------------------------------------------------
// InsertEditor
// ---------------------------------------------------------------------------

export class InsertEditor {
  // --- State ---
  private state: InsertState | null = null;
  private container: HTMLElement | null = null;
  private onCommitCb: InsertCommitCallback | null = null;
  private closeCb: (() => void) | null = null;
  private layout: ContainerLayout = { direction: 'row', isReversed: false };

  // --- Geometry ---
  private insertZones: InsertZone[] = [];
  private selectedInsertIndex = -1;

  // --- DOM elements in shadow ---
  private zoneElements: HTMLDivElement[] = [];
  private phantomEl: HTMLDivElement | null = null;
  private phantomLabel: HTMLSpanElement | null = null;
  private panel: InsertPanel | null = null;
  private modeBadge: HTMLDivElement | null = null;

  constructor(private readonly shadow: ShadowRoot) {}

  onClose(cb: () => void): void {
    this.closeCb = cb;
  }

  isActive(): boolean {
    return this.state !== null;
  }

  getState(): InsertState | null {
    return this.state;
  }

  /** No-op — InsertEditor has no positioned mini panel. */
  reposition(_anchorPos: { x: number; y: number }): void {}

  /** Get the current insert panel configuration (tag, styles, children). */
  getInsertConfig(): InsertPanelConfig | null {
    return this.panel?.getConfig() ?? null;
  }

  // -----------------------------------------------------------------------
  // Enter SCANNING state
  // -----------------------------------------------------------------------

  /**
   * Enter insert mode on the given container.
   * Renders drop zones at every child gap.
   */
  enter(container: HTMLElement, onCommit: InsertCommitCallback): void {
    this.cleanup();

    if (getInsertBlockReason(container) !== null) return;

    this.container = container;
    this.onCommitCb = onCommit;
    this.layout = detectContainerLayout(container);

    this.enterScanning();
  }

  // -----------------------------------------------------------------------
  // Cancel / cleanup
  // -----------------------------------------------------------------------

  /**
   * Cancel current state:
   * - CONFIGURING → return to SCANNING
   * - SCANNING → full cleanup (exit insert mode)
   */
  cancel(): void {
    if (this.state === 'configuring') {
      this.clearConfiguring();
      this.enterScanning();
    } else if (this.state === 'scanning') {
      this.cleanup();
      this.closeCb?.();
    }
  }

  /** Full cleanup — remove all DOM, reset state. */
  cleanup(): void {
    this.clearScanning();
    this.clearConfiguring();
    this.modeBadge?.remove();
    this.modeBadge = null;

    this.container = null;
    this.onCommitCb = null;
    this.state = null;
    this.selectedInsertIndex = -1;
  }

  /** Refresh overlay positions on scroll. */
  refreshOverlay(): void {
    if (!this.container || !this.state) return;

    if (this.state === 'scanning') {
      this.refreshZonePositions();
    } else if (this.state === 'configuring') {
      this.refreshPhantomPosition();
    }

    this.refreshBadgePosition();
  }

  // -----------------------------------------------------------------------
  // SCANNING state
  // -----------------------------------------------------------------------

  private enterScanning(): void {
    this.state = 'scanning';
    this.selectedInsertIndex = -1;

    const children = this.getContainerChildren();
    const zones = computeGapZones(this.container!, children, this.layout);

    this.insertZones = zones.map((gz) => ({ ...gz, zoneEl: null }));
    this.renderDropZones();
    this.renderModeBadge();
  }

  private clearScanning(): void {
    for (const el of this.zoneElements) el.remove();
    this.zoneElements = [];
    this.insertZones = [];
  }

  private renderDropZones(): void {
    if (!this.container) return;

    const containerRect = this.container.getBoundingClientRect();
    const isRow = this.layout.direction === 'row';

    for (const zone of this.insertZones) {
      const zoneEl = createElement('div', { title: 'Insert element here' }, {
        position: 'fixed',
        zIndex: '59',
        pointerEvents: 'auto',
        cursor: 'pointer',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      });

      // Size the clickable zone
      if (isRow) {
        const zoneWidth = Math.max(INSERT_INDICATOR.plusSize + 8, 28);
        zoneEl.style.left = `${zone.center - zoneWidth / 2}px`;
        zoneEl.style.top = `${containerRect.top}px`;
        zoneEl.style.width = `${zoneWidth}px`;
        zoneEl.style.height = `${containerRect.height}px`;
      } else {
        const zoneHeight = Math.max(INSERT_INDICATOR.plusSize + 8, 28);
        zoneEl.style.left = `${containerRect.left}px`;
        zoneEl.style.top = `${zone.center - zoneHeight / 2}px`;
        zoneEl.style.width = `${containerRect.width}px`;
        zoneEl.style.height = `${zoneHeight}px`;
      }

      // Indicator line
      const line = createElement('div', {}, {
        position: 'absolute',
        background: INSERT_INDICATOR.color,
        opacity: '0.4',
        borderRadius: '1px',
        transition: 'opacity 100ms, background 100ms',
      });

      if (isRow) {
        line.style.left = '50%';
        line.style.transform = 'translateX(-50%)';
        line.style.top = '0';
        line.style.width = `${INSERT_INDICATOR.thickness}px`;
        line.style.height = '100%';
      } else {
        line.style.top = '50%';
        line.style.transform = 'translateY(-50%)';
        line.style.left = '0';
        line.style.width = '100%';
        line.style.height = `${INSERT_INDICATOR.thickness}px`;
      }
      zoneEl.appendChild(line);

      // Plus circle icon
      const plus = createElement('div', {}, {
        width: `${INSERT_INDICATOR.plusSize}px`,
        height: `${INSERT_INDICATOR.plusSize}px`,
        borderRadius: '50%',
        background: OVERLAY.bg,
        border: `2px solid ${INSERT_INDICATOR.color}`,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: '1',
        transition: 'transform 100ms, border-color 100ms, background 100ms',
        flexShrink: '0',
      });
      plus.innerHTML = `<svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="${INSERT_INDICATOR.color}" stroke-width="2" stroke-linecap="round">
        <line x1="6" y1="2" x2="6" y2="10"/>
        <line x1="2" y1="6" x2="10" y2="6"/>
      </svg>`;
      zoneEl.appendChild(plus);

      // Hover effects
      zoneEl.addEventListener('mouseenter', () => {
        line.style.opacity = '1';
        line.style.background = INSERT_INDICATOR.activeColor;
        if (isRow) {
          line.style.width = `${INSERT_INDICATOR.activeThickness}px`;
        } else {
          line.style.height = `${INSERT_INDICATOR.activeThickness}px`;
        }
        plus.style.borderColor = INSERT_INDICATOR.activeColor;
        plus.style.transform = 'scale(1.15)';
      });

      zoneEl.addEventListener('mouseleave', () => {
        line.style.opacity = '0.4';
        line.style.background = INSERT_INDICATOR.color;
        if (isRow) {
          line.style.width = `${INSERT_INDICATOR.thickness}px`;
        } else {
          line.style.height = `${INSERT_INDICATOR.thickness}px`;
        }
        plus.style.borderColor = INSERT_INDICATOR.color;
        plus.style.transform = 'scale(1)';
      });

      // Click → transition to CONFIGURING
      const insertIdx = zone.insertIndex;
      zoneEl.addEventListener('click', (e) => {
        e.stopPropagation();
        this.enterConfiguring(insertIdx);
      });

      zone.zoneEl = zoneEl;
      this.shadow.appendChild(zoneEl);
      this.zoneElements.push(zoneEl);
    }
  }

  private refreshZonePositions(): void {
    if (!this.container) return;

    const children = this.getContainerChildren();
    const freshZones = computeGapZones(this.container, children, this.layout);
    const containerRect = this.container.getBoundingClientRect();
    const isRow = this.layout.direction === 'row';

    for (let i = 0; i < this.insertZones.length && i < freshZones.length; i++) {
      const zone = this.insertZones[i];
      const fresh = freshZones[i];
      zone.center = fresh.center;

      if (!zone.zoneEl) continue;

      if (isRow) {
        const zoneWidth = Math.max(INSERT_INDICATOR.plusSize + 8, 28);
        zone.zoneEl.style.left = `${zone.center - zoneWidth / 2}px`;
        zone.zoneEl.style.top = `${containerRect.top}px`;
        zone.zoneEl.style.height = `${containerRect.height}px`;
      } else {
        const zoneHeight = Math.max(INSERT_INDICATOR.plusSize + 8, 28);
        zone.zoneEl.style.top = `${zone.center - zoneHeight / 2}px`;
        zone.zoneEl.style.left = `${containerRect.left}px`;
        zone.zoneEl.style.width = `${containerRect.width}px`;
      }
    }
  }

  // -----------------------------------------------------------------------
  // CONFIGURING state
  // -----------------------------------------------------------------------

  private enterConfiguring(insertIndex: number): void {
    this.clearScanning();
    this.state = 'configuring';
    this.selectedInsertIndex = insertIndex;

    this.renderPhantom(insertIndex);
    this.renderInsertPanel();
  }

  private clearConfiguring(): void {
    this.phantomEl?.remove();
    this.phantomEl = null;
    this.phantomLabel = null;
    this.panel?.cleanup();
    this.panel = null;
  }

  private renderPhantom(insertIndex: number): void {
    if (!this.container) return;

    const children = this.getContainerChildren();
    const isRow = this.layout.direction === 'row';
    const containerRect = this.container.getBoundingClientRect();

    // Compute phantom size from average sibling dimensions or defaults
    let phantomWidth = 100;
    let phantomHeight = 40;

    if (children.length > 0) {
      const rects = children.map((c) => c.getBoundingClientRect());
      phantomWidth = Math.round(rects.reduce((s, r) => s + r.width, 0) / rects.length);
      phantomHeight = Math.round(rects.reduce((s, r) => s + r.height, 0) / rects.length);
    }

    // Compute phantom position at the gap
    let left: number;
    let top: number;

    if (isRow) {
      // Vertical gap in a row layout
      if (insertIndex === 0) {
        left = containerRect.left;
      } else if (insertIndex >= children.length) {
        const lastRect = children[children.length - 1].getBoundingClientRect();
        left = lastRect.right;
      } else {
        const prevRect = children[insertIndex - 1].getBoundingClientRect();
        const nextRect = children[insertIndex].getBoundingClientRect();
        left = (prevRect.right + nextRect.left) / 2 - phantomWidth / 2;
      }
      top = containerRect.top + (containerRect.height - phantomHeight) / 2;
    } else {
      // Horizontal gap in a column layout
      if (insertIndex === 0) {
        top = containerRect.top;
      } else if (insertIndex >= children.length) {
        const lastRect = children[children.length - 1].getBoundingClientRect();
        top = lastRect.bottom;
      } else {
        const prevRect = children[insertIndex - 1].getBoundingClientRect();
        const nextRect = children[insertIndex].getBoundingClientRect();
        top = (prevRect.bottom + nextRect.top) / 2 - phantomHeight / 2;
      }
      left = containerRect.left + (containerRect.width - phantomWidth) / 2;
    }

    this.phantomEl = createElement('div', {}, {
      position: 'fixed',
      left: `${left}px`,
      top: `${top}px`,
      width: `${phantomWidth}px`,
      height: `${phantomHeight}px`,
      border: `2px dashed ${INSERT_INDICATOR.phantomBorder}`,
      background: INSERT_INDICATOR.phantomBg,
      borderRadius: OVERLAY.radiusSm,
      pointerEvents: 'none',
      zIndex: '58',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
    });

    // Inner label
    const label = createElement('span', {}, {
      fontFamily: OVERLAY.monoFamily,
      fontSize: '10px',
      // White on a grey pill (4.83:1) so the tag reads on any page; it was grey
      // text straight on the page (4.12:1 on near-black).
      color: '#fff',
      background: INSERT_INDICATOR.phantomBorder,
      padding: '1px 4px',
      borderRadius: '3px',
      pointerEvents: 'none',
    });
    label.textContent = '<div>';
    this.phantomLabel = label;
    this.phantomEl.appendChild(label);

    this.shadow.appendChild(this.phantomEl);
  }

  private renderInsertPanel(): void {
    if (!this.phantomEl) return;

    this.panel = new InsertPanel(this.shadow);

    this.panel.onChange((entry) => {
      if (this.phantomLabel) {
        this.phantomLabel.textContent = isProjectComponentEntry(entry)
          ? `<${entry.componentName} />`
          : `<${entry.tag}>`;
      }
    });

    this.panel.onConfirm(() => {
      this.commitInsert();
    });

    this.panel.onCancel(() => {
      this.cancel();
    });

    const phantomRect = this.phantomEl.getBoundingClientRect();
    const panelEl = this.panel.render(phantomRect);
    this.shadow.appendChild(panelEl);
  }

  private refreshPhantomPosition(): void {
    // Re-render phantom, then reposition panel to track it
    if (this.selectedInsertIndex >= 0) {
      const idx = this.selectedInsertIndex;
      this.removePhantom();
      this.renderPhantom(idx);
      this.syncPanelToPhantom();
    }
  }

  /** Remove phantom DOM without touching panel state. */
  private removePhantom(): void {
    this.phantomEl?.remove();
    this.phantomEl = null;
    this.phantomLabel = null;
  }

  /** Update phantom label and reposition panel to track phantom. */
  private syncPanelToPhantom(): void {
    if (this.phantomLabel && this.panel) {
      const config = this.panel.getConfig();
      this.phantomLabel.textContent = config.componentInsert
        ? `<${config.componentInsert.componentName} />`
        : `<${config.tagName}>`;
    }
    if (this.panel && this.phantomEl) {
      this.panel.reposition(this.phantomEl.getBoundingClientRect());
    }
  }

  // -----------------------------------------------------------------------
  // COMMITTED state
  // -----------------------------------------------------------------------

  private commitInsert(): void {
    if (!this.container || this.selectedInsertIndex < 0) return;

    const insertIndex = this.selectedInsertIndex;
    const container = this.container;

    // 1. Read config from panel BEFORE clearConfiguring nulls it
    const config = this.panel?.getConfig() ?? null;

    // 2. Build the new element (not yet in DOM)
    const tagName = config?.tagName ?? 'div';
    const newElement = document.createElement(tagName);

    if (config?.attributes) {
      for (const attr of config.attributes) {
        newElement.setAttribute(attr.name, attr.value);
      }
    }

    if (config?.initialStyles) {
      for (const style of config.initialStyles) {
        newElement.style.setProperty(style.property, style.toValue);
      }
    }

    if (config?.compoundChildren) {
      for (const child of config.compoundChildren) {
        newElement.appendChild(createCompoundChild(child));
      }
    }

    // Project component inserts: tag the phantom element so the pending
    // changes panel and any inspector can identify it before Claude Code
    // applies the source-level rewrite.
    if (config?.componentInsert) {
      newElement.setAttribute(
        'data-nco-web-editor-pending-component',
        config.componentInsert.componentName,
      );
    }

    // 3. Fire commit callback BEFORE DOM insertion so buildInsertChange
    //    reads the pre-insert child list for correct sibling anchors.
    //    The callback receives the element (not yet in DOM) and config.
    this.onCommitCb?.(newElement, container, insertIndex, config);

    // 4. Insert element into page DOM
    const refNode = container.children[insertIndex] || null;
    container.insertBefore(newElement, refNode);

    // 5. Clean up configuring UI
    this.clearConfiguring();

    // Return to scanning with updated child list
    this.layout = detectContainerLayout(container);
    this.enterScanning();
  }

  // -----------------------------------------------------------------------
  // Mode badge
  // -----------------------------------------------------------------------

  private renderModeBadge(): void {
    if (this.modeBadge) {
      this.modeBadge.remove();
      this.modeBadge = null;
    }

    if (!this.container) return;

    const containerRect = this.container.getBoundingClientRect();

    this.modeBadge = createElement('div', {}, {
      position: 'fixed',
      left: `${containerRect.left}px`,
      top: `${containerRect.top - 24}px`,
      zIndex: '61',
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
      padding: '2px 8px',
      background: OVERLAY.bg,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      fontFamily: OVERLAY.fontFamily,
      fontSize: '10px',
      fontWeight: '600',
      color: OVERLAY.text,
      pointerEvents: 'none',
      whiteSpace: 'nowrap',
    });

    const dot = createElement('div', {}, {
      width: '6px',
      height: '6px',
      borderRadius: '50%',
      background: INSERT_INDICATOR.color,
      flexShrink: '0',
    });
    this.modeBadge.appendChild(dot);
    this.modeBadge.appendChild(document.createTextNode('INSERT'));
    this.shadow.appendChild(this.modeBadge);
  }

  private refreshBadgePosition(): void {
    if (!this.modeBadge || !this.container) return;
    const containerRect = this.container.getBoundingClientRect();
    this.modeBadge.style.left = `${containerRect.left}px`;
    this.modeBadge.style.top = `${containerRect.top - 24}px`;
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  private getContainerChildren(): HTMLElement[] {
    if (!this.container) return [];
    return Array.from(this.container.children)
      .filter((c): c is HTMLElement => c instanceof HTMLElement);
  }
}

// ---------------------------------------------------------------------------
// Compound child creation helper
// ---------------------------------------------------------------------------

function createCompoundChild(descriptor: CompoundChild): HTMLElement {
  const el = document.createElement(descriptor.tagName);
  if (descriptor.textContent) {
    el.textContent = descriptor.textContent;
  }
  if (descriptor.styles) {
    for (const style of descriptor.styles) {
      el.style.setProperty(style.property, style.value);
    }
  }
  if (descriptor.children) {
    for (const child of descriptor.children) {
      el.appendChild(createCompoundChild(child));
    }
  }
  return el;
}
