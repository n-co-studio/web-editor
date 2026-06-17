/**
 * InsertPanel — floating element picker panel for the insert tool.
 *
 * Renders a fixed-position panel anchored to the phantom element,
 * presenting a searchable catalog of HTML elements with sizing controls.
 * All styling is inline (no CSS stylesheets — Shadow DOM isolation).
 */

import { createElement, createButton } from "../../shared/ui-utils";
import {
  OVERLAY,
  INSERT_INDICATOR,
  INSERT_PANEL_WIDTH,
  INSERT_PANEL_MAX_HEIGHT,
} from "../../shared/constants";
import type {
  PropertyChange,
  ComponentInsertDescriptor,
} from "@nco-studio/shared";
import {
  INSERT_CATEGORIES,
  CATEGORY_LABELS,
  filterCatalog,
  getDefaultEntry,
  isProjectComponentEntry,
  type InsertCatalogEntry,
  type ProjectComponentEntry,
  type SizingPreset,
  type CompoundChild,
} from "./insert-catalog";

// ---------------------------------------------------------------------------
// Exported types
// ---------------------------------------------------------------------------

export interface InsertPanelConfig {
  readonly tagName: string;
  readonly label: string;
  readonly initialStyles: readonly PropertyChange[];
  readonly compoundChildren?: readonly CompoundChild[];
  readonly attributes?: readonly { name: string; value: string }[];
  readonly componentInsert?: ComponentInsertDescriptor;
}

type ActiveTab = 'html' | 'components';

// ---------------------------------------------------------------------------
// InsertPanel
// ---------------------------------------------------------------------------

/**
 * Per-instance project component registry — shared across all InsertPanel
 * instances because component data is pushed once per WebSocket connection
 * but the panel is constructed each time the operator enters CONFIGURING.
 */
let projectComponentEntries: readonly ProjectComponentEntry[] = [];
const componentRegistryListeners = new Set<() => void>();

export function setPanelProjectComponents(
  entries: readonly ProjectComponentEntry[],
): void {
  projectComponentEntries = entries;
  for (const listener of componentRegistryListeners) listener();
}

export function getPanelProjectComponents(): readonly ProjectComponentEntry[] {
  return projectComponentEntries;
}

export class InsertPanel {
  // --- DOM refs ---
  private container: HTMLDivElement | null = null;
  private catalogListEl: HTMLDivElement | null = null;
  private confirmBtn: HTMLButtonElement | null = null;
  private widthControls: HTMLDivElement | null = null;
  private heightControls: HTMLDivElement | null = null;
  private sizingSectionEl: HTMLDivElement | null = null;
  private searchInputEl: HTMLInputElement | null = null;
  private htmlTabBtn: HTMLButtonElement | null = null;
  private componentsTabBtn: HTMLButtonElement | null = null;

  // --- State ---
  private selectedEntry: InsertCatalogEntry = getDefaultEntry();
  private widthPreset: SizingPreset = getDefaultEntry().defaultWidthPreset;
  private heightPreset: SizingPreset = getDefaultEntry().defaultHeightPreset;
  private widthUnit: "px" | "%" = "px";
  private heightUnit: "px" | "%" = "px";
  private fixedWidth: number = getDefaultEntry().defaultFixedWidth ?? 100;
  private fixedHeight: number = getDefaultEntry().defaultFixedHeight ?? 40;
  private searchQuery: string = "";
  private activeTab: ActiveTab = 'html';
  private readonly onRegistryChange = () => this.handleRegistryChange();

  // --- Callbacks ---
  private changeCb: ((entry: InsertCatalogEntry) => void) | null = null;
  private confirmCb: (() => void) | null = null;
  private cancelCb: (() => void) | null = null;

  constructor(private readonly shadow: ShadowRoot) {
    // Registry listener is registered in render() (after cleanup()) so a
    // re-render on the same instance does not leave the panel deaf to
    // setPanelProjectComponents calls.
  }

  /**
   * Mutate the shared project-component registry. Static helper preserved on
   * the class for callers that hold the panel reference; routes to the
   * module-level setter so multiple panel instances stay in sync.
   */
  setProjectComponents(entries: readonly ProjectComponentEntry[]): void {
    setPanelProjectComponents(entries);
  }

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  onChange(cb: (entry: InsertCatalogEntry) => void): void {
    this.changeCb = cb;
  }

  onConfirm(cb: () => void): void {
    this.confirmCb = cb;
  }

  onCancel(cb: () => void): void {
    this.cancelCb = cb;
  }

  isOpen(): boolean {
    return this.container !== null;
  }

  /** Render the panel, anchored to phantomRect. Returns the container element. */
  render(phantomRect: DOMRect): HTMLDivElement {
    this.cleanup();
    componentRegistryListeners.add(this.onRegistryChange);

    const pos = computeInsertPanelPosition(
      phantomRect,
      INSERT_PANEL_WIDTH,
      INSERT_PANEL_MAX_HEIGHT,
    );

    const container = createElement(
      "div",
      { role: "dialog", "aria-label": "Insert element picker" },
      {
        position: "fixed",
        left: `${pos.x}px`,
        top: `${pos.y}px`,
        width: `${INSERT_PANEL_WIDTH}px`,
        maxHeight: `${INSERT_PANEL_MAX_HEIGHT}px`,
        background: OVERLAY.bg,
        border: `1px solid ${OVERLAY.border}`,
        borderRadius: OVERLAY.radiusMd,
        fontFamily: OVERLAY.fontFamily,
        fontSize: OVERLAY.bodySize,
        color: OVERLAY.text,
        pointerEvents: "auto",
        zIndex: "102",
        display: "flex",
        flexDirection: "column",
        overflow: "hidden",
        boxShadow: "0 8px 32px rgba(0, 0, 0, 0.4)",
      },
    );

    // Stop propagation on click — prevent host page from receiving events
    container.addEventListener("click", (e) => e.stopPropagation());
    container.addEventListener("mousedown", (e) => e.stopPropagation());
    container.addEventListener("pointerdown", (e) => e.stopPropagation());

    // 1. Tab bar (HTML / Components)
    container.appendChild(this.buildTabBar());

    // 2. Search input
    container.appendChild(this.buildSearchArea());

    // 3. Catalog list (scrollable)
    this.catalogListEl = createElement(
      "div",
      {},
      {
        flex: "1",
        overflowY: "auto",
        padding: "0 8px 8px",
      },
    );
    this.renderCatalogList();
    container.appendChild(this.catalogListEl);

    // 4. Sizing section (hidden when a project component is selected)
    this.sizingSectionEl = this.buildSizingSection();
    container.appendChild(this.sizingSectionEl);
    this.applySizingVisibility();

    // 5. Action row
    container.appendChild(this.buildActionRow());

    this.container = container;
    return container;
  }

  /** Reposition to track phantom on scroll. */
  reposition(phantomRect: DOMRect): void {
    if (!this.container) return;
    const pos = computeInsertPanelPosition(
      phantomRect,
      INSERT_PANEL_WIDTH,
      INSERT_PANEL_MAX_HEIGHT,
    );
    this.container.style.left = `${pos.x}px`;
    this.container.style.top = `${pos.y}px`;
  }

  /** Get current configuration for commit. */
  getConfig(): InsertPanelConfig {
    if (isProjectComponentEntry(this.selectedEntry)) {
      // Project component insert: no sizing styles, no attributes, no compound
      // children — the JSX usage emits the component's own defaults.
      // tagName: 'div' is the phantom-DOM placeholder; the diff carries the
      // real component identity in componentInsert.
      const entry = this.selectedEntry;
      return {
        tagName: 'div',
        label: entry.label,
        initialStyles: [],
        componentInsert: {
          componentName: entry.componentName,
          importPath: entry.importPath,
          props: [],
        },
      };
    }

    const styles: PropertyChange[] = [];

    if (this.widthPreset === "stretch") {
      styles.push({ property: "width", fromValue: "", toValue: "100%" });
    } else if (this.widthPreset === "fixed") {
      styles.push({
        property: "width",
        fromValue: "",
        toValue: `${this.fixedWidth}${this.widthUnit}`,
      });
    }

    if (this.heightPreset === "stretch") {
      styles.push({ property: "height", fromValue: "", toValue: "100%" });
    } else if (this.heightPreset === "fixed") {
      styles.push({
        property: "height",
        fromValue: "",
        toValue: `${this.fixedHeight}${this.heightUnit}`,
      });
    }

    // Add default styles from catalog entry
    for (const ds of this.selectedEntry.defaultStyles ?? []) {
      styles.push({ property: ds.property, fromValue: "", toValue: ds.value });
    }

    return {
      tagName: this.selectedEntry.tag,
      label: this.selectedEntry.label,
      initialStyles: styles,
      compoundChildren: this.selectedEntry.compoundChildren,
      attributes: this.selectedEntry.attributes,
    };
  }

  /** Clean up DOM. */
  cleanup(): void {
    componentRegistryListeners.delete(this.onRegistryChange);
    this.container?.remove();
    this.container = null;
    this.catalogListEl = null;
    this.confirmBtn = null;
    this.widthControls = null;
    this.heightControls = null;
    this.sizingSectionEl = null;
    this.searchInputEl = null;
    this.htmlTabBtn = null;
    this.componentsTabBtn = null;
  }

  // -------------------------------------------------------------------------
  // Tab bar
  // -------------------------------------------------------------------------

  private buildTabBar(): HTMLDivElement {
    const bar = createElement(
      "div",
      { role: "tablist", "aria-label": "Insert panel category" },
      {
        flexShrink: "0",
        display: "flex",
        borderBottom: `1px solid ${OVERLAY.border}`,
      },
    );

    this.htmlTabBtn = this.buildTab("html", "HTML", true);
    this.componentsTabBtn = this.buildTab(
      "components",
      "Components",
      projectComponentEntries.length > 0,
    );

    bar.appendChild(this.htmlTabBtn);
    bar.appendChild(this.componentsTabBtn);
    return bar;
  }

  private buildTab(tab: ActiveTab, label: string, enabled: boolean): HTMLButtonElement {
    const isActive = this.activeTab === tab;
    const btn = createElement(
      "button",
      { role: "tab", "aria-selected": String(isActive) },
      {
        flex: "1",
        padding: "8px 10px",
        fontSize: "11px",
        fontFamily: OVERLAY.fontFamily,
        fontWeight: isActive ? "600" : "500",
        border: "none",
        background: isActive ? "rgba(255, 255, 255, 0.06)" : "transparent",
        borderBottom: `2px solid ${isActive ? INSERT_INDICATOR.color : "transparent"}`,
        color: enabled ? (isActive ? OVERLAY.text : OVERLAY.textMuted) : "rgba(255,255,255,0.25)",
        cursor: enabled ? "pointer" : "not-allowed",
        pointerEvents: "auto",
        textAlign: "center",
        transition: "background 0.1s, color 0.1s, border-bottom-color 0.1s",
      },
    ) as HTMLButtonElement;
    btn.textContent = label;

    if (enabled) {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        this.switchTab(tab);
      });
    }

    return btn;
  }

  private switchTab(tab: ActiveTab): void {
    if (this.activeTab === tab) return;
    this.activeTab = tab;
    // Reset search so a Components-tab query doesn't bleed into HTML and vice versa
    this.searchQuery = "";
    if (this.searchInputEl) {
      this.searchInputEl.value = "";
      this.searchInputEl.placeholder = this.searchPlaceholder();
    }
    this.refreshTabStyles();
    this.renderCatalogList();
  }

  private refreshTabStyles(): void {
    const apply = (btn: HTMLButtonElement | null, tab: ActiveTab, enabled: boolean) => {
      if (!btn) return;
      const isActive = this.activeTab === tab;
      btn.setAttribute("aria-selected", String(isActive));
      btn.style.fontWeight = isActive ? "600" : "500";
      btn.style.background = isActive ? "rgba(255, 255, 255, 0.06)" : "transparent";
      btn.style.borderBottom = `2px solid ${isActive ? INSERT_INDICATOR.color : "transparent"}`;
      btn.style.color = enabled
        ? (isActive ? OVERLAY.text : OVERLAY.textMuted)
        : "rgba(255,255,255,0.25)";
      btn.style.cursor = enabled ? "pointer" : "not-allowed";
    };
    apply(this.htmlTabBtn, "html", true);
    apply(this.componentsTabBtn, "components", projectComponentEntries.length > 0);
  }

  private handleRegistryChange(): void {
    // If our enabling premise vanished, fall back to the HTML tab
    if (this.activeTab === "components" && projectComponentEntries.length === 0) {
      this.activeTab = "html";
    }
    this.refreshTabStyles();
    if (this.activeTab === "components") this.renderCatalogList();
  }

  private searchPlaceholder(): string {
    return this.activeTab === "components"
      ? "Search components..."
      : "Search elements...";
  }

  // -------------------------------------------------------------------------
  // Section builders
  // -------------------------------------------------------------------------

  private buildSearchArea(): HTMLDivElement {
    const wrapper = createElement(
      "div",
      {},
      {
        flexShrink: "0",
        padding: "8px",
      },
    );

    const input = createElement(
      "input",
      {
        type: "text",
        placeholder: this.searchPlaceholder(),
      },
      {
        width: "100%",
        padding: "6px 8px",
        background: "rgba(255, 255, 255, 0.08)",
        border: `1px solid ${OVERLAY.border}`,
        borderRadius: OVERLAY.radiusSm,
        color: OVERLAY.text,
        fontFamily: OVERLAY.fontFamily,
        fontSize: "11px",
        outline: "none",
        boxSizing: "border-box",
      },
    ) as HTMLInputElement;

    input.value = this.searchQuery;

    input.addEventListener("input", () => {
      this.searchQuery = input.value;
      this.renderCatalogList();
    });

    wrapper.appendChild(input);
    this.searchInputEl = input;
    return wrapper;
  }

  private buildSizingSection(): HTMLDivElement {
    const section = createElement(
      "div",
      {},
      {
        flexShrink: "0",
        borderTop: `1px solid ${OVERLAY.border}`,
        padding: "8px",
      },
    );

    const sizeLabel = createElement(
      "div",
      {},
      {
        fontSize: "10px",
        color: OVERLAY.textMuted,
        fontWeight: "500",
      },
    );
    sizeLabel.textContent = "Size";
    section.appendChild(sizeLabel);

    // Width row
    this.widthControls = createElement(
      "div",
      {},
      {
        display: "flex",
        alignItems: "center",
        gap: "4px",
        marginTop: "4px",
      },
    );
    this.renderWidthRow();
    section.appendChild(this.widthControls);

    // Height row
    this.heightControls = createElement(
      "div",
      {},
      {
        display: "flex",
        alignItems: "center",
        gap: "4px",
        marginTop: "4px",
      },
    );
    this.renderHeightRow();
    section.appendChild(this.heightControls);

    return section;
  }

  private buildActionRow(): HTMLDivElement {
    const row = createElement(
      "div",
      {},
      {
        flexShrink: "0",
        borderTop: `1px solid ${OVERLAY.border}`,
        padding: "8px",
        display: "flex",
        gap: "4px",
      },
    );

    const confirmBtn = createButton(
      this.confirmButtonLabel(),
      "primary",
      () => {
        this.confirmCb?.();
      },
    );
    confirmBtn.style.fontSize = "11px";
    confirmBtn.style.padding = "4px 12px";
    confirmBtn.style.flex = "1";
    confirmBtn.style.background = INSERT_INDICATOR.color;
    confirmBtn.style.borderColor = INSERT_INDICATOR.color;
    this.confirmBtn = confirmBtn;
    row.appendChild(confirmBtn);

    const cancelBtn = createButton("Cancel", "ghost", () => {
      this.cancelCb?.();
    });
    cancelBtn.style.fontSize = "11px";
    cancelBtn.style.padding = "4px 8px";
    row.appendChild(cancelBtn);

    return row;
  }

  // -------------------------------------------------------------------------
  // Catalog list rendering
  // -------------------------------------------------------------------------

  private renderCatalogList(): void {
    if (!this.catalogListEl) return;
    this.catalogListEl.innerHTML = "";

    if (this.activeTab === "components") {
      this.renderComponentsList();
      return;
    }

    const filtered = filterCatalog(this.searchQuery);

    for (const category of INSERT_CATEGORIES) {
      if (category === "components") continue; // rendered in its own tab
      const entries = filtered.filter((e) => e.category === category);
      if (entries.length === 0) continue;

      // Category header
      const header = createElement(
        "div",
        {},
        {
          fontSize: "9px",
          textTransform: "uppercase",
          letterSpacing: "0.5px",
          color: OVERLAY.textMuted,
          padding: "8px 0 4px",
          fontWeight: "600",
        },
      );
      header.textContent = CATEGORY_LABELS[category];
      this.catalogListEl.appendChild(header);

      // Entry grid
      const grid = createElement(
        "div",
        {},
        {
          display: "grid",
          gridTemplateColumns: "1fr 1fr",
          gap: "2px",
        },
      );

      for (const entry of entries) {
        grid.appendChild(this.buildEntryButton(entry));
      }

      this.catalogListEl.appendChild(grid);
    }
  }

  private renderComponentsList(): void {
    if (!this.catalogListEl) return;

    const q = this.searchQuery.trim().toLowerCase();
    const entries = q
      ? projectComponentEntries.filter(
          (e) =>
            e.componentName.toLowerCase().includes(q) ||
            e.importPath.toLowerCase().includes(q),
        )
      : projectComponentEntries;

    if (entries.length === 0) {
      const empty = createElement(
        "div",
        {},
        {
          padding: "16px 8px",
          fontSize: "11px",
          color: OVERLAY.textMuted,
          textAlign: "center",
          fontFamily: OVERLAY.fontFamily,
        },
      );
      empty.textContent =
        projectComponentEntries.length === 0
          ? "No project components discovered."
          : "No components match your search.";
      this.catalogListEl.appendChild(empty);
      return;
    }

    const list = createElement(
      "div",
      {},
      {
        display: "flex",
        flexDirection: "column",
        gap: "2px",
        paddingTop: "4px",
      },
    );

    for (const entry of entries) {
      list.appendChild(this.buildComponentEntryRow(entry));
    }
    this.catalogListEl.appendChild(list);
  }

  private buildComponentEntryRow(
    entry: ProjectComponentEntry,
  ): HTMLButtonElement {
    const isSelected = this.isEntrySelected(entry);

    const row = createElement(
      "button",
      {},
      {
        display: "flex",
        alignItems: "center",
        gap: "8px",
        padding: "6px 8px",
        border: `1px solid ${isSelected ? INSERT_INDICATOR.color : "transparent"}`,
        borderRadius: OVERLAY.radiusSm,
        background: isSelected ? "rgba(16, 185, 129, 0.12)" : "transparent",
        color: OVERLAY.text,
        cursor: "pointer",
        fontFamily: OVERLAY.fontFamily,
        textAlign: "left",
        width: "100%",
        boxSizing: "border-box",
        pointerEvents: "auto",
        transition: "background 0.1s, border-color 0.1s",
      },
    ) as HTMLButtonElement;

    const iconSpan = createElement(
      "span",
      {},
      {
        display: "flex",
        width: "16px",
        height: "16px",
        flexShrink: "0",
        color: OVERLAY.textMuted,
      },
    );
    iconSpan.innerHTML = entry.icon;
    row.appendChild(iconSpan);

    const textCol = createElement(
      "span",
      {},
      {
        display: "flex",
        flexDirection: "column",
        minWidth: "0",
        flex: "1",
      },
    );

    const nameSpan = createElement(
      "span",
      {},
      {
        fontSize: "11px",
        fontWeight: "600",
        overflow: "hidden",
        textOverflow: "ellipsis",
        whiteSpace: "nowrap",
      },
    );
    nameSpan.textContent = entry.componentName;
    textCol.appendChild(nameSpan);

    const pathSpan = createElement(
      "span",
      {},
      {
        fontFamily: OVERLAY.monoFamily,
        fontSize: "10px",
        color: OVERLAY.textMuted,
        overflow: "hidden",
        textOverflow: "ellipsis",
        whiteSpace: "nowrap",
        direction: "rtl",
        textAlign: "left",
      },
    );
    pathSpan.textContent = entry.importPath;
    textCol.appendChild(pathSpan);

    row.appendChild(textCol);

    row.addEventListener("mouseenter", () => {
      if (!this.isEntrySelected(entry)) {
        row.style.background = "rgba(255, 255, 255, 0.08)";
      }
    });
    row.addEventListener("mouseleave", () => {
      if (!this.isEntrySelected(entry)) {
        row.style.background = "transparent";
      }
    });
    row.addEventListener("click", (e) => {
      e.stopPropagation();
      this.selectEntry(entry);
    });

    return row;
  }

  private applySizingVisibility(): void {
    if (!this.sizingSectionEl) return;
    this.sizingSectionEl.style.display = isProjectComponentEntry(this.selectedEntry)
      ? "none"
      : "block";
  }

  private buildEntryButton(entry: InsertCatalogEntry): HTMLButtonElement {
    const isSelected = this.isEntrySelected(entry);

    const btn = createElement(
      "button",
      {},
      {
        display: "flex",
        alignItems: "center",
        gap: "6px",
        padding: "4px 6px",
        border: `1px solid ${isSelected ? INSERT_INDICATOR.color : "transparent"}`,
        borderRadius: OVERLAY.radiusSm,
        background: isSelected ? "rgba(16, 185, 129, 0.12)" : "transparent",
        color: OVERLAY.text,
        cursor: "pointer",
        fontSize: "11px",
        fontFamily: OVERLAY.fontFamily,
        textAlign: "left",
        width: "100%",
        boxSizing: "border-box",
        pointerEvents: "auto",
        transition: "background 0.1s, border-color 0.1s",
      },
    ) as HTMLButtonElement;

    // Icon span
    const iconSpan = createElement(
      "span",
      {},
      {
        display: "flex",
        width: "16px",
        height: "16px",
        flexShrink: "0",
        color: OVERLAY.textMuted,
      },
    );
    iconSpan.innerHTML = entry.icon;
    btn.appendChild(iconSpan);

    // Label span
    const labelSpan = createElement(
      "span",
      {},
      {
        overflow: "hidden",
        textOverflow: "ellipsis",
        whiteSpace: "nowrap",
      },
    );
    labelSpan.textContent = entry.label;
    btn.appendChild(labelSpan);

    // Hover effects (only when not selected)
    btn.addEventListener("mouseenter", () => {
      if (!this.isEntrySelected(entry)) {
        btn.style.background = "rgba(255, 255, 255, 0.08)";
      }
    });

    btn.addEventListener("mouseleave", () => {
      if (!this.isEntrySelected(entry)) {
        btn.style.background = "transparent";
      }
    });

    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      this.selectEntry(entry);
    });

    return btn;
  }

  private isEntrySelected(entry: InsertCatalogEntry): boolean {
    if (isProjectComponentEntry(entry) && isProjectComponentEntry(this.selectedEntry)) {
      return (
        entry.componentName === this.selectedEntry.componentName &&
        entry.importPath === this.selectedEntry.importPath
      );
    }
    if (isProjectComponentEntry(entry) || isProjectComponentEntry(this.selectedEntry)) {
      return false;
    }
    return (
      entry.tag === this.selectedEntry.tag &&
      entry.label === this.selectedEntry.label
    );
  }

  private selectEntry(entry: InsertCatalogEntry): void {
    this.selectedEntry = entry;
    this.widthPreset = entry.defaultWidthPreset;
    this.heightPreset = entry.defaultHeightPreset;
    this.fixedWidth = entry.defaultFixedWidth ?? 100;
    this.fixedHeight = entry.defaultFixedHeight ?? 40;

    // Re-render catalog to update selected state
    this.renderCatalogList();

    // Re-render sizing controls
    if (this.widthControls) {
      this.widthControls.innerHTML = "";
      this.renderWidthRow();
    }
    if (this.heightControls) {
      this.heightControls.innerHTML = "";
      this.renderHeightRow();
    }
    this.applySizingVisibility();

    // Update confirm button label
    if (this.confirmBtn) {
      this.confirmBtn.textContent = this.confirmButtonLabel();
    }

    this.changeCb?.(entry);
  }

  private confirmButtonLabel(): string {
    if (isProjectComponentEntry(this.selectedEntry)) {
      return `Insert ${this.selectedEntry.componentName}`;
    }
    return `Insert <${this.selectedEntry.tag}>`;
  }

  // -------------------------------------------------------------------------
  // Sizing rows
  // -------------------------------------------------------------------------

  private renderWidthRow(): void {
    if (!this.widthControls) return;

    const dimLabel = createElement(
      "span",
      {},
      {
        fontFamily: OVERLAY.monoFamily,
        fontSize: "10px",
        color: OVERLAY.textMuted,
        width: "14px",
        flexShrink: "0",
      },
    );
    dimLabel.textContent = "W";
    this.widthControls.appendChild(dimLabel);

    const presets: SizingPreset[] = ["auto", "stretch", "fixed"];
    const presetLabels: Record<SizingPreset, string> = {
      auto: "Auto",
      stretch: "Stretch",
      fixed: "Fixed",
    };

    for (const preset of presets) {
      const isActive = this.widthPreset === preset;
      const btn = createElement(
        "button",
        {},
        {
          padding: "2px 6px",
          fontSize: "10px",
          border: `1px solid ${isActive ? INSERT_INDICATOR.color : OVERLAY.border}`,
          borderRadius: "3px",
          background: isActive ? "rgba(16, 185, 129, 0.15)" : "transparent",
          color: isActive ? INSERT_INDICATOR.color : OVERLAY.textMuted,
          cursor: "pointer",
          pointerEvents: "auto",
          fontFamily: OVERLAY.fontFamily,
        },
      ) as HTMLButtonElement;
      btn.textContent = presetLabels[preset];

      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        this.widthPreset = preset;
        if (this.widthControls) {
          this.widthControls.innerHTML = "";
          this.renderWidthRow();
        }
      });

      this.widthControls.appendChild(btn);
    }

    // Fixed controls: number input + unit toggle
    if (this.widthPreset === "fixed") {
      const numInput = createElement(
        "input",
        { type: "number" },
        {
          width: "48px",
          padding: "2px 4px",
          fontSize: "10px",
          fontFamily: OVERLAY.monoFamily,
          background: "rgba(255, 255, 255, 0.08)",
          border: `1px solid ${OVERLAY.border}`,
          borderRadius: "3px",
          color: OVERLAY.text,
          textAlign: "right",
          boxSizing: "border-box",
        },
      ) as HTMLInputElement;
      numInput.value = String(this.fixedWidth);

      numInput.addEventListener("input", () => {
        const parsed = parseInt(numInput.value, 10);
        if (!isNaN(parsed)) {
          this.fixedWidth = Math.max(1, Math.min(9999, parsed));
        }
      });

      this.widthControls.appendChild(numInput);

      const unitBtn = this.buildUnitToggleButton("width");
      this.widthControls.appendChild(unitBtn);
    }
  }

  private renderHeightRow(): void {
    if (!this.heightControls) return;

    const dimLabel = createElement(
      "span",
      {},
      {
        fontFamily: OVERLAY.monoFamily,
        fontSize: "10px",
        color: OVERLAY.textMuted,
        width: "14px",
        flexShrink: "0",
      },
    );
    dimLabel.textContent = "H";
    this.heightControls.appendChild(dimLabel);

    const presets: SizingPreset[] = ["auto", "stretch", "fixed"];
    const presetLabels: Record<SizingPreset, string> = {
      auto: "Auto",
      stretch: "Stretch",
      fixed: "Fixed",
    };

    for (const preset of presets) {
      const isActive = this.heightPreset === preset;
      const btn = createElement(
        "button",
        {},
        {
          padding: "2px 6px",
          fontSize: "10px",
          border: `1px solid ${isActive ? INSERT_INDICATOR.color : OVERLAY.border}`,
          borderRadius: "3px",
          background: isActive ? "rgba(16, 185, 129, 0.15)" : "transparent",
          color: isActive ? INSERT_INDICATOR.color : OVERLAY.textMuted,
          cursor: "pointer",
          pointerEvents: "auto",
          fontFamily: OVERLAY.fontFamily,
        },
      ) as HTMLButtonElement;
      btn.textContent = presetLabels[preset];

      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        this.heightPreset = preset;
        if (this.heightControls) {
          this.heightControls.innerHTML = "";
          this.renderHeightRow();
        }
      });

      this.heightControls.appendChild(btn);
    }

    // Fixed controls: number input + unit toggle
    if (this.heightPreset === "fixed") {
      const numInput = createElement(
        "input",
        { type: "number" },
        {
          width: "48px",
          padding: "2px 4px",
          fontSize: "10px",
          fontFamily: OVERLAY.monoFamily,
          background: "rgba(255, 255, 255, 0.08)",
          border: `1px solid ${OVERLAY.border}`,
          borderRadius: "3px",
          color: OVERLAY.text,
          textAlign: "right",
          boxSizing: "border-box",
        },
      ) as HTMLInputElement;
      numInput.value = String(this.fixedHeight);

      numInput.addEventListener("input", () => {
        const parsed = parseInt(numInput.value, 10);
        if (!isNaN(parsed)) {
          this.fixedHeight = Math.max(1, Math.min(9999, parsed));
        }
      });

      this.heightControls.appendChild(numInput);

      const unitBtn = this.buildUnitToggleButton("height");
      this.heightControls.appendChild(unitBtn);
    }
  }

  private buildUnitToggleButton(axis: "width" | "height"): HTMLButtonElement {
    const getUnit = () => (axis === "width" ? this.widthUnit : this.heightUnit);
    const setUnit = (u: "px" | "%") => {
      if (axis === "width") {
        this.widthUnit = u;
      } else {
        this.heightUnit = u;
      }
    };

    const btn = createElement(
      "button",
      {},
      {
        padding: "2px 6px",
        fontSize: "10px",
        border: `1px solid ${OVERLAY.border}`,
        borderRadius: "3px",
        background: "transparent",
        color: OVERLAY.textMuted,
        cursor: "pointer",
        pointerEvents: "auto",
        fontFamily: OVERLAY.monoFamily,
      },
    ) as HTMLButtonElement;
    btn.textContent = getUnit();

    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const next = getUnit() === "px" ? "%" : "px";
      setUnit(next);
      btn.textContent = next;
    });

    return btn;
  }
}

// ---------------------------------------------------------------------------
// Positioning helpers
// ---------------------------------------------------------------------------

function computeInsertPanelPosition(
  phantomRect: DOMRect,
  panelWidth: number,
  panelHeight: number,
): { x: number; y: number } {
  const GAP = 8;
  const EDGE = 8;
  const vw = window.innerWidth;
  const vh = window.innerHeight;

  // Preference 1: RIGHT of phantom
  const rightX = phantomRect.right + GAP;
  if (rightX + panelWidth + EDGE <= vw) {
    return { x: rightX, y: clampY(phantomRect.top, panelHeight, vh, EDGE) };
  }

  // Preference 2: LEFT of phantom
  const leftX = phantomRect.left - panelWidth - GAP;
  if (leftX >= EDGE) {
    return { x: leftX, y: clampY(phantomRect.top, panelHeight, vh, EDGE) };
  }

  // Preference 3: BELOW phantom
  const belowY = phantomRect.bottom + GAP;
  if (belowY + panelHeight + EDGE <= vh) {
    return { x: clampX(phantomRect.left, panelWidth, vw, EDGE), y: belowY };
  }

  // Preference 4: ABOVE phantom
  const aboveY = phantomRect.top - panelHeight - GAP;
  if (aboveY >= EDGE) {
    return { x: clampX(phantomRect.left, panelWidth, vw, EDGE), y: aboveY };
  }

  // Fallback: clamp to viewport
  return {
    x: clampX(phantomRect.left, panelWidth, vw, EDGE),
    y: clampY(phantomRect.top, panelHeight, vh, EDGE),
  };
}

function clampX(x: number, width: number, vw: number, edge: number): number {
  return Math.max(edge, Math.min(x, vw - width - edge));
}

function clampY(y: number, height: number, vh: number, edge: number): number {
  return Math.max(edge, Math.min(y, vh - height - edge));
}
