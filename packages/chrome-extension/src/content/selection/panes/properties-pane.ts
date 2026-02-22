import { createElement, createText } from '../../../shared/ui-utils';
import { OVERLAY } from '../../../shared/constants';
import type { PanelSizeTier } from '../../../shared/constants';
import { createStyleSnapshot } from '../../../shared/dom-utils';
import type { ComputedStyleSnapshot } from '../../../shared/dom-utils';
import type { TokenStore } from '../../tokens/store';
import type { PendingQueue } from '../../batching/queue';
import { CssGroupsSection } from './css-groups-section';
import { BoxModelSection } from './box-model-section';
import { LayoutSection } from './layout-section';

const STORAGE_KEY_TAB = 'frontend-editor-devtools-tab';

type PropertyChangeCb = (property: string, fromValue: string, toValue: string, token?: string) => void;
type MultiPropertyChangeCb = (changes: Array<{ element: Element; property: string; fromValue: string; toValue: string; token?: string }>) => void;

/**
 * Properties pane — middle column orchestrator.
 * Contains tab bar (Edit active, Rules disabled placeholder), filter input,
 * and delegates to BoxModelSection, LayoutSection, and CssGroupsSection for Edit tab content.
 */
export class PropertiesPane {
  private container: HTMLDivElement | null = null;
  private tabBar: HTMLDivElement | null = null;
  private filterInput: HTMLInputElement | null = null;
  private contentArea: HTMLDivElement | null = null;
  private activeTab: 'edit' | 'rules' = 'edit';
  private editScrollTop = 0;
  private tier: PanelSizeTier = 'full';
  private cssGroups: CssGroupsSection;
  private boxModelSection: BoxModelSection;
  private layoutSection: LayoutSection;
  private currentElement: Element | null = null;
  private currentElements: Element[] | null = null;

  constructor(
    private readonly tokenStore: TokenStore,
    private readonly pendingQueue: PendingQueue,
  ) {
    this.cssGroups = new CssGroupsSection(tokenStore, pendingQueue);
    this.boxModelSection = new BoxModelSection();
    this.layoutSection = new LayoutSection(tokenStore);
  }

  mount(container: HTMLDivElement): void {
    this.container = container;

    // Tab bar
    this.tabBar = this.buildTabBar();
    container.appendChild(this.tabBar);

    // Filter input (between tab bar and content area)
    this.filterInput = this.buildFilterInput();
    container.appendChild(this.filterInput);

    // Scrollable content area
    this.contentArea = createElement('div', {}, {
      flex: '1',
      overflowY: 'auto',
      fontFamily: OVERLAY.monoFamily,
      fontSize: '11px',
    });
    container.appendChild(this.contentArea);

    this.restoreTab();
  }

  dispose(): void {
    if (this.activeTab === 'edit' && this.contentArea) {
      this.editScrollTop = this.contentArea.scrollTop;
    }
    this.container = null;
    this.tabBar = null;
    this.filterInput = null;
    this.contentArea = null;
  }

  setTier(tier: PanelSizeTier): void {
    this.tier = tier;
    this.refreshProperties();
  }

  updateElement(el: Element, snapshot: ComputedStyleSnapshot): void {
    this.currentElement = el;
    this.currentElements = null;

    // Clear filter on element change
    if (this.filterInput) this.filterInput.value = '';

    if (this.activeTab === 'edit' && this.contentArea) {
      this.renderEditContent(el, snapshot);
    }
  }

  updateMultiElements(elements: Element[]): void {
    this.currentElements = elements;
    this.currentElement = elements[0] ?? null;

    if (this.filterInput) this.filterInput.value = '';

    if (this.activeTab === 'edit' && this.contentArea) {
      this.contentArea.innerHTML = '';
      this.contentArea.appendChild(this.cssGroups.buildMulti(elements));
    }
  }

  clearElement(): void {
    this.currentElement = null;
    this.currentElements = null;
    if (this.filterInput) this.filterInput.value = '';
    if (this.contentArea) {
      this.contentArea.innerHTML = '';
      const empty = createText('div', 'No element selected', 'mono');
      empty.style.color = OVERLAY.textMuted;
      empty.style.padding = '8px';
      this.contentArea.appendChild(empty);
    }
  }

  refreshProperties(): void {
    if (!this.contentArea) return;
    if (this.currentElements && this.currentElements.length > 1) {
      this.contentArea.innerHTML = '';
      this.contentArea.appendChild(this.cssGroups.buildMulti(this.currentElements));
    } else if (this.currentElement) {
      const snapshot = createStyleSnapshot(this.currentElement);
      this.renderEditContent(this.currentElement, snapshot);
    }
  }

  onPropertyChange(cb: PropertyChangeCb): void {
    this.cssGroups.onPropertyChange(cb);
    this.boxModelSection.onPropertyChange(cb);
    this.layoutSection.onPropertyChange(cb);
  }

  onMultiPropertyChange(cb: MultiPropertyChangeCb): void {
    this.cssGroups.onMultiPropertyChange(cb);
  }

  // ---------------------------------------------------------------------------
  // Edit content rendering (orchestrates sections)
  // ---------------------------------------------------------------------------

  private renderEditContent(el: Element, snapshot: ComputedStyleSnapshot): void {
    if (!this.contentArea) return;
    this.contentArea.innerHTML = '';

    // 1. Box model section (tier-dependent)
    const boxModelEl = this.boxModelSection.build(snapshot, el, this.tier);
    const excludeGroups: string[] = [];
    if (boxModelEl) {
      this.contentArea.appendChild(boxModelEl);
      excludeGroups.push('Dimensions', 'Spacing');
    }

    // 2. Layout section (conditional on flex/grid context)
    const layoutEl = this.layoutSection.build(el, snapshot);
    if (layoutEl) {
      this.contentArea.appendChild(layoutEl);
    }

    // 3. CSS property groups (with Dimensions/Spacing excluded when box model visible)
    this.contentArea.appendChild(this.cssGroups.buildSingle(el, snapshot, excludeGroups));
  }

  // ---------------------------------------------------------------------------
  // Filter input
  // ---------------------------------------------------------------------------

  private buildFilterInput(): HTMLInputElement {
    const input = createElement('input', {
      type: 'text',
      placeholder: 'Filter...',
    }, {
      width: '100%',
      height: '24px',
      padding: '0 8px',
      border: 'none',
      borderBottom: `1px solid ${OVERLAY.border}`,
      background: 'rgba(255, 255, 255, 0.04)',
      color: OVERLAY.text,
      fontFamily: OVERLAY.monoFamily,
      fontSize: '11px',
      outline: 'none',
      flexShrink: '0',
      boxSizing: 'border-box',
      pointerEvents: 'auto',
    }) as HTMLInputElement;

    input.addEventListener('input', () => this.applyFilter(input.value));
    return input;
  }

  private applyFilter(query: string): void {
    if (!this.contentArea) return;
    const q = query.toLowerCase().trim();

    // Collect all group labels and property rows
    const groupLabels = this.contentArea.querySelectorAll('[data-group-label]');
    const propRows = this.contentArea.querySelectorAll('[data-prop-row]');

    if (!q) {
      // Show everything
      groupLabels.forEach((h) => ((h as HTMLElement).style.display = ''));
      propRows.forEach((r) => ((r as HTMLElement).style.display = ''));
      return;
    }

    // First pass: mark matching rows
    const matchingGroups = new Set<string>();
    propRows.forEach((row) => {
      const el = row as HTMLElement;
      const name = el.getAttribute('data-prop-name') ?? '';
      const value = el.getAttribute('data-prop-value') ?? '';
      const matches = name.toLowerCase().includes(q) || value.toLowerCase().includes(q);
      el.style.display = matches ? '' : 'none';

      if (matches) {
        // Find the closest preceding group label
        const parent = el.parentElement;
        const grandparent = parent?.parentElement;
        if (grandparent) {
          const prevLabel = grandparent.querySelector(`[data-group-label]`);
          if (prevLabel) {
            matchingGroups.add(prevLabel.getAttribute('data-group-label') ?? '');
          }
        }
      }
    });

    // Second pass: show/hide group labels
    groupLabels.forEach((label) => {
      const el = label as HTMLElement;
      const groupName = el.getAttribute('data-group-label') ?? '';

      // Check if the following sibling grid has any visible rows
      const nextEl = el.nextElementSibling;
      if (nextEl) {
        const visibleRows = nextEl.querySelectorAll('[data-prop-row]:not([style*="display: none"])');
        el.style.display = visibleRows.length > 0 ? '' : 'none';
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Tab bar
  // ---------------------------------------------------------------------------

  private buildTabBar(): HTMLDivElement {
    const bar = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      height: '24px',
      borderBottom: `1px solid ${OVERLAY.border}`,
      flexShrink: '0',
      gap: '0',
      paddingLeft: '4px',
    });

    const editTab = createElement('button', {}, {
      background: 'transparent',
      border: 'none',
      borderBottom: `2px solid ${OVERLAY.primary}`,
      padding: '0 8px',
      height: '100%',
      fontSize: '11px',
      fontFamily: OVERLAY.fontFamily,
      color: OVERLAY.text,
      cursor: 'pointer',
      fontWeight: '500',
    });
    editTab.textContent = 'Edit';
    editTab.addEventListener('click', () => this.switchTab('edit'));
    bar.appendChild(editTab);

    const rulesTab = createElement('button', {}, {
      background: 'transparent',
      border: 'none',
      borderBottom: '2px solid transparent',
      padding: '0 8px',
      height: '100%',
      fontSize: '11px',
      fontFamily: OVERLAY.fontFamily,
      color: OVERLAY.textMuted,
      cursor: 'not-allowed',
      opacity: '0.5',
      fontWeight: '400',
    });
    rulesTab.textContent = 'Rules';
    bar.appendChild(rulesTab);

    return bar;
  }

  private switchTab(tab: 'edit' | 'rules'): void {
    if (tab === this.activeTab) return;
    if (tab === 'rules') return;

    if (this.activeTab === 'edit' && this.contentArea) {
      this.editScrollTop = this.contentArea.scrollTop;
    }

    this.activeTab = tab;
    this.saveTab(tab);

    if (tab === 'edit') {
      if (this.filterInput) this.filterInput.value = '';
      this.refreshProperties();
      if (this.contentArea) {
        this.contentArea.scrollTop = this.editScrollTop;
      }
    }
  }

  private async restoreTab(): Promise<void> {
    try {
      const result = await chrome.storage.session.get(STORAGE_KEY_TAB);
      const saved = result[STORAGE_KEY_TAB] as string | undefined;
      if (saved === 'edit' || saved === 'rules') {
        if (saved === 'edit') {
          this.activeTab = saved;
        }
      }
    } catch {
      // Non-fatal
    }
  }

  private async saveTab(tab: string): Promise<void> {
    try {
      await chrome.storage.session.set({ [STORAGE_KEY_TAB]: tab });
    } catch {
      // Non-fatal
    }
  }
}
