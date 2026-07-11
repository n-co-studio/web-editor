import { createElement, createText } from '../../../shared/ui-utils';
import { OVERLAY } from '../../../shared/constants';
import type { PanelSizeTier } from '../../../shared/constants';
import { createStyleSnapshot } from '../../../shared/dom-utils';
import type { ComputedStyleSnapshot } from '../../../shared/dom-utils';
import type { TokenStore } from '../../tokens/store';
import type { PendingQueue } from '../../batching/queue';
import { MatchedRulesCache } from '../../inspection/matched-rules-cache';
import { ToggleManager } from '../../inspection/toggle-manager';
import { StateSimulator } from '../../inspection/state-simulator';
import { VariableResolver } from '../../inspection/variable-resolver';
import { CssGroupsSection } from './css-groups-section';
import { BoxModelSection } from './box-model-section';
import { LayoutSection } from './layout-section';
import { RulesSection } from './rules-section';
import { AccessibilitySection } from './accessibility-section';

const STORAGE_KEY_TAB = 'nco-web-editor-devtools-tab';

// Stable ids wiring the Edit/Rules tabs to their shared tabpanel (ARIA).
const EDIT_TAB_ID = 'nco-props-tab-edit';
const RULES_TAB_ID = 'nco-props-tab-rules';
const TABPANEL_ID = 'nco-props-tabpanel';

type PropertyChangeCb = (property: string, fromValue: string, toValue: string, token?: string) => void;
type MultiPropertyChangeCb = (changes: Array<{ element: Element; property: string; fromValue: string; toValue: string; token?: string }>) => void;

/**
 * Properties pane — middle column orchestrator.
 * Contains tab bar (Edit / Rules), filter input,
 * and delegates to sub-sections for tab content.
 * Owns ToggleManager and MatchedRulesCache (lazily initialized on first Rules tab activation).
 */
export class PropertiesPane {
  private container: HTMLDivElement | null = null;
  private tabBar: HTMLDivElement | null = null;
  private editTabEl: HTMLElement | null = null;
  private rulesTabEl: HTMLElement | null = null;
  private filterInput: HTMLInputElement | null = null;
  private contentArea: HTMLDivElement | null = null;
  private activeTab: 'edit' | 'rules' = 'edit';
  private editScrollTop = 0;
  private rulesScrollTop = 0;
  private tier: PanelSizeTier = 'full';
  private cssGroups: CssGroupsSection;
  private boxModelSection: BoxModelSection;
  private layoutSection: LayoutSection;
  private accessibilitySection: AccessibilitySection;
  private currentElement: Element | null = null;
  private currentElements: Element[] | null = null;

  // Eager: state simulator for :hov toggles (available on Edit tab)
  private stateSimulator: StateSimulator;

  // Lazy-initialized on first Rules tab activation
  private toggleManager: ToggleManager | null = null;
  private rulesCache: MatchedRulesCache | null = null;
  private variableResolver: VariableResolver | null = null;
  private rulesSection: RulesSection | null = null;
  private rulesInitialized = false;

  constructor(
    private readonly tokenStore: TokenStore,
    private readonly pendingQueue: PendingQueue,
    private readonly shadowHost: Element | null = null,
  ) {
    this.cssGroups = new CssGroupsSection(tokenStore, pendingQueue);
    this.boxModelSection = new BoxModelSection();
    this.layoutSection = new LayoutSection(tokenStore);
    this.accessibilitySection = new AccessibilitySection();

    // Shadow root for click-outside dismiss in tooltips
    const shadowRoot = this.shadowHost?.shadowRoot;
    if (shadowRoot) this.cssGroups.setDismissRoot(shadowRoot);

    // StateSimulator is eager (no heavy setup until first activation)
    this.stateSimulator = new StateSimulator(
      () => this.getExcludeSheets(),
      this.shadowHost ?? undefined,
    );
    this.cssGroups.setStateSimulator(this.stateSimulator);
    this.cssGroups.onStateToggleRefresh(() => this.refreshProperties());
  }

  mount(container: HTMLDivElement): void {
    this.container = container;

    // Tab bar
    this.tabBar = this.buildTabBar();
    container.appendChild(this.tabBar);

    // Filter input (between tab bar and content area)
    this.filterInput = this.buildFilterInput();
    container.appendChild(this.filterInput);

    // Scrollable content area — the tabpanel for whichever tab is active.
    this.contentArea = createElement('div', {
      role: 'tabpanel',
      id: TABPANEL_ID,
      'aria-labelledby': this.activeTab === 'edit' ? EDIT_TAB_ID : RULES_TAB_ID,
    }, {
      flex: '1',
      overflowY: 'auto',
      fontFamily: OVERLAY.monoFamily,
      fontSize: '11px',
    });
    container.appendChild(this.contentArea);

    this.restoreTab();
  }

  dispose(): void {
    if (this.contentArea) {
      if (this.activeTab === 'edit') {
        this.editScrollTop = this.contentArea.scrollTop;
      } else {
        this.rulesScrollTop = this.contentArea.scrollTop;
      }
    }
    this.stateSimulator.dispose();
    this.rulesSection?.dispose();
    this.toggleManager?.dispose();
    this.rulesCache?.dispose();
    this.rulesSection = null;
    this.toggleManager = null;
    this.rulesCache = null;
    this.variableResolver = null;
    this.cssGroups.setVariableResolver(null);
    this.rulesInitialized = false;
    this.container = null;
    this.tabBar = null;
    this.editTabEl = null;
    this.rulesTabEl = null;
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

    // Update cache element watcher if initialized
    this.rulesCache?.startWatching(el);

    if (this.activeTab === 'edit' && this.contentArea) {
      this.renderEditContent(el, snapshot);
      // Eager idle indexing: pre-compute matched rules for Edit tab annotations
      if (this.rulesCache) {
        const cache = this.rulesCache;
        const excludeSheets = this.getExcludeSheets();
        requestIdleCallback(() => {
          cache.get(el, excludeSheets, this.shadowHost ?? undefined);
        });
      }
    } else if (this.activeTab === 'rules') {
      this.rulesSection?.updateElement(el);
    }
  }

  updateMultiElements(elements: Element[]): void {
    this.currentElements = elements;
    this.currentElement = elements[0] ?? null;

    if (this.filterInput) this.filterInput.value = '';

    // Multi-select always shows Edit tab (Rules tab is single-element only)
    if (this.activeTab === 'rules') {
      this.switchTab('edit');
    }

    if (this.activeTab === 'edit' && this.contentArea) {
      this.contentArea.innerHTML = '';
      this.contentArea.appendChild(this.cssGroups.buildMulti(elements));
    }
  }

  clearElement(): void {
    this.currentElement = null;
    this.currentElements = null;
    if (this.filterInput) this.filterInput.value = '';
    this.stateSimulator.deactivateAll();
    this.toggleManager?.clearAll();
    this.rulesCache?.stopWatching();
    this.rulesSection?.clear();
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
    if (this.activeTab === 'rules') {
      if (this.currentElement) {
        this.rulesSection?.updateElement(this.currentElement);
      }
      return;
    }
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

    // 4. Accessibility insights (collapsible, at bottom)
    this.accessibilitySection.setScrollTarget(this.contentArea);
    const a11yEl = this.accessibilitySection.build(el, snapshot);
    if (a11yEl) {
      this.contentArea.appendChild(a11yEl);
    }
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

    input.addEventListener('input', () => {
      if (this.activeTab === 'rules') {
        this.rulesSection?.setFilter(input.value);
      } else {
        this.applyFilter(input.value);
      }
    });
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
    const bar = createElement('div', { role: 'tablist', 'aria-label': 'Properties view' }, {
      display: 'flex',
      alignItems: 'center',
      height: '24px',
      borderBottom: `1px solid ${OVERLAY.border}`,
      flexShrink: '0',
      gap: '0',
      paddingLeft: '4px',
    });

    const editActive = this.activeTab === 'edit';
    const editTab = createElement('button', {
      role: 'tab',
      id: EDIT_TAB_ID,
      'aria-selected': String(editActive),
      'aria-controls': TABPANEL_ID,
      tabindex: editActive ? '0' : '-1',
    }, {
      background: 'transparent',
      border: 'none',
      borderBottom: `2px solid ${editActive ? OVERLAY.primary : 'transparent'}`,
      padding: '0 8px',
      height: '100%',
      fontSize: '11px',
      fontFamily: OVERLAY.fontFamily,
      color: editActive ? OVERLAY.text : OVERLAY.textMuted,
      cursor: 'pointer',
      fontWeight: editActive ? '500' : '400',
    });
    editTab.textContent = 'Edit';
    editTab.addEventListener('click', () => this.switchTab('edit'));
    editTab.addEventListener('keydown', (e) => this.onTabKeydown(e));
    this.editTabEl = editTab;
    bar.appendChild(editTab);

    const rulesTab = createElement('button', {
      role: 'tab',
      id: RULES_TAB_ID,
      'aria-selected': String(!editActive),
      'aria-controls': TABPANEL_ID,
      tabindex: editActive ? '-1' : '0',
    }, {
      background: 'transparent',
      border: 'none',
      borderBottom: `2px solid ${!editActive ? OVERLAY.primary : 'transparent'}`,
      padding: '0 8px',
      height: '100%',
      fontSize: '11px',
      fontFamily: OVERLAY.fontFamily,
      color: !editActive ? OVERLAY.text : OVERLAY.textMuted,
      cursor: 'pointer',
      fontWeight: !editActive ? '500' : '400',
    });
    rulesTab.textContent = 'Rules';
    rulesTab.addEventListener('click', () => this.switchTab('rules'));
    rulesTab.addEventListener('keydown', (e) => this.onTabKeydown(e));
    this.rulesTabEl = rulesTab;
    bar.appendChild(rulesTab);

    return bar;
  }

  /** Roving-tabindex arrow navigation for the Edit/Rules tablist (ARIA tabs pattern). */
  private onTabKeydown(e: KeyboardEvent): void {
    let target: 'edit' | 'rules' | null = null;
    if (e.key === 'ArrowRight' || e.key === 'End') target = 'rules';
    else if (e.key === 'ArrowLeft' || e.key === 'Home') target = 'edit';
    else return;
    e.preventDefault();
    this.switchTab(target);
    (target === 'edit' ? this.editTabEl : this.rulesTabEl)?.focus();
  }

  private switchTab(tab: 'edit' | 'rules'): void {
    if (tab === this.activeTab) return;

    // Save current scroll position
    if (this.contentArea) {
      if (this.activeTab === 'edit') {
        this.editScrollTop = this.contentArea.scrollTop;
      } else {
        this.rulesScrollTop = this.contentArea.scrollTop;
      }
    }

    this.activeTab = tab;
    this.saveTab(tab);
    this.updateTabStyles();

    if (this.filterInput) this.filterInput.value = '';

    if (tab === 'edit') {
      this.refreshProperties();
      if (this.contentArea) {
        this.contentArea.scrollTop = this.editScrollTop;
      }
    } else {
      this.ensureRulesInitialized();
      this.renderRulesContent();
      if (this.contentArea) {
        this.contentArea.scrollTop = this.rulesScrollTop;
      }
    }
  }

  private updateTabStyles(): void {
    const editActive = this.activeTab === 'edit';
    if (this.editTabEl) {
      this.editTabEl.style.borderBottom = editActive
        ? `2px solid ${OVERLAY.primary}` : '2px solid transparent';
      this.editTabEl.style.color = editActive ? OVERLAY.text : OVERLAY.textMuted;
      this.editTabEl.style.fontWeight = editActive ? '500' : '400';
      this.editTabEl.setAttribute('aria-selected', String(editActive));
      this.editTabEl.setAttribute('tabindex', editActive ? '0' : '-1');
    }
    if (this.rulesTabEl) {
      this.rulesTabEl.style.borderBottom = !editActive
        ? `2px solid ${OVERLAY.primary}` : '2px solid transparent';
      this.rulesTabEl.style.color = !editActive ? OVERLAY.text : OVERLAY.textMuted;
      this.rulesTabEl.style.fontWeight = !editActive ? '500' : '400';
      this.rulesTabEl.setAttribute('aria-selected', String(!editActive));
      this.rulesTabEl.setAttribute('tabindex', !editActive ? '0' : '-1');
    }
    this.contentArea?.setAttribute('aria-labelledby', editActive ? EDIT_TAB_ID : RULES_TAB_ID);
  }

  // ---------------------------------------------------------------------------
  // Rules tab infrastructure (lazy initialization)
  // ---------------------------------------------------------------------------

  private ensureRulesInitialized(): void {
    if (this.rulesInitialized) return;
    this.rulesInitialized = true;

    this.toggleManager = new ToggleManager();
    this.toggleManager.init();

    this.rulesCache = new MatchedRulesCache();
    this.rulesSection = new RulesSection(this.rulesCache, this.toggleManager);
    this.rulesSection.configure(
      this.getExcludeSheets(),
      this.shadowHost ?? undefined,
    );

    // Pass toggle manager and cache to CssGroupsSection for annotation coordination
    this.cssGroups.setInspectionDeps(this.toggleManager, this.rulesCache);

    // Variable resolver for var() badge tooltips
    this.variableResolver = new VariableResolver(
      this.rulesCache,
      this.tokenStore,
      () => this.getExcludeSheets(),
      this.shadowHost ?? undefined,
    );
    this.cssGroups.setVariableResolver(this.variableResolver);

    // Scroll-to-rule: switch to Rules tab and highlight the matching rule
    this.cssGroups.onScrollToRule((selectorText) => {
      this.switchTab('rules');
      // Defer to allow Rules tab to render
      requestAnimationFrame(() => {
        if (!this.contentArea) return;
        const ruleEl = this.contentArea.querySelector(`[data-rule-selector="${CSS.escape(selectorText)}"]`) as HTMLElement | null;
        if (ruleEl) {
          ruleEl.scrollIntoView({ block: 'center', behavior: 'smooth' });
          ruleEl.style.background = 'rgba(6, 182, 212, 0.15)';
          setTimeout(() => { ruleEl.style.background = ''; }, 1200);
        }
      });
    });

    // Invalidate cache when toggles change so Edit tab annotations stay accurate
    this.rulesSection.onToggleChange((el, _property, _toggled) => {
      this.rulesCache?.invalidate(el);
    });
  }

  private getExcludeSheets(): Set<CSSStyleSheet> {
    const sheets = new Set<CSSStyleSheet>();
    const toggleSheet = this.toggleManager?.getSheet();
    if (toggleSheet) sheets.add(toggleSheet);
    return sheets;
  }

  /** Expose cache for external eager indexing. */
  getMatchedRulesCache(): MatchedRulesCache | null {
    return this.rulesCache;
  }

  /** Expose state simulator for DomTreePane orange dot indicator. */
  getStateSimulator(): StateSimulator {
    return this.stateSimulator;
  }

  private renderRulesContent(): void {
    if (!this.contentArea) return;
    this.contentArea.innerHTML = '';

    if (!this.rulesSection) return;

    // Mount rules section into content area
    this.rulesSection.mount(this.contentArea);

    if (this.currentElement) {
      this.rulesSection.updateElement(this.currentElement);
    } else {
      this.rulesSection.clear();
    }
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  private async restoreTab(): Promise<void> {
    try {
      const result = await chrome.storage.session.get(STORAGE_KEY_TAB);
      const saved = result[STORAGE_KEY_TAB] as string | undefined;
      if (saved === 'edit' || saved === 'rules') {
        this.activeTab = saved;
        this.updateTabStyles();
        if (saved === 'rules') {
          this.ensureRulesInitialized();
          this.renderRulesContent();
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
