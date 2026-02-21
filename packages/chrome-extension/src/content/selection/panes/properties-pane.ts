import { createElement, createText } from '../../../shared/ui-utils';
import { OVERLAY } from '../../../shared/constants';
import { createStyleSnapshot } from '../../../shared/dom-utils';
import type { ComputedStyleSnapshot } from '../../../shared/dom-utils';
import type { TokenStore } from '../../tokens/store';
import { CssGroupsSection } from './css-groups-section';

const STORAGE_KEY_TAB = 'frontend-editor-devtools-tab';

type PropertyChangeCb = (property: string, fromValue: string, toValue: string, token?: string) => void;
type MultiPropertyChangeCb = (changes: Array<{ element: Element; property: string; fromValue: string; toValue: string; token?: string }>) => void;

/**
 * Properties pane — middle column orchestrator.
 * Contains tab bar (Edit active, Rules disabled placeholder) and
 * delegates to CssGroupsSection for Edit tab content.
 */
export class PropertiesPane {
  private container: HTMLDivElement | null = null;
  private tabBar: HTMLDivElement | null = null;
  private contentArea: HTMLDivElement | null = null;
  private activeTab: 'edit' | 'rules' = 'edit';
  private editScrollTop = 0;
  private cssGroups: CssGroupsSection;
  private currentElement: Element | null = null;
  private currentElements: Element[] | null = null;

  constructor(private readonly tokenStore: TokenStore) {
    this.cssGroups = new CssGroupsSection(tokenStore);
  }

  mount(container: HTMLDivElement): void {
    this.container = container;

    // Tab bar
    this.tabBar = this.buildTabBar();
    container.appendChild(this.tabBar);

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
    // Save scroll position for Edit tab
    if (this.activeTab === 'edit' && this.contentArea) {
      this.editScrollTop = this.contentArea.scrollTop;
    }
    this.container = null;
    this.tabBar = null;
    this.contentArea = null;
  }

  updateElement(el: Element, snapshot: ComputedStyleSnapshot): void {
    this.currentElement = el;
    this.currentElements = null;
    if (this.activeTab === 'edit' && this.contentArea) {
      this.contentArea.innerHTML = '';
      this.contentArea.appendChild(this.cssGroups.buildSingle(el, snapshot));
    }
  }

  updateMultiElements(elements: Element[]): void {
    this.currentElements = elements;
    this.currentElement = elements[0] ?? null;
    if (this.activeTab === 'edit' && this.contentArea) {
      this.contentArea.innerHTML = '';
      this.contentArea.appendChild(this.cssGroups.buildMulti(elements));
    }
  }

  clearElement(): void {
    this.currentElement = null;
    this.currentElements = null;
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
      this.contentArea.innerHTML = '';
      this.contentArea.appendChild(this.cssGroups.buildSingle(this.currentElement, snapshot));
    }
  }

  onPropertyChange(cb: PropertyChangeCb): void {
    this.cssGroups.onPropertyChange(cb);
  }

  onMultiPropertyChange(cb: MultiPropertyChangeCb): void {
    this.cssGroups.onMultiPropertyChange(cb);
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

    // Edit tab (active)
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

    // Rules tab (disabled placeholder)
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
    // Rules tab is disabled — no click handler
    bar.appendChild(rulesTab);

    return bar;
  }

  private switchTab(tab: 'edit' | 'rules'): void {
    if (tab === this.activeTab) return;
    if (tab === 'rules') return; // disabled

    // Save scroll from current tab
    if (this.activeTab === 'edit' && this.contentArea) {
      this.editScrollTop = this.contentArea.scrollTop;
    }

    this.activeTab = tab;
    this.saveTab(tab);

    // Re-render content
    if (tab === 'edit') {
      this.refreshProperties();
      // Restore scroll
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
        // Only restore if it's a valid tab (and not disabled)
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
