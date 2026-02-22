import { createElement, createText } from '../../../shared/ui-utils';
import { OVERLAY } from '../../../shared/constants';
import { createStyleSnapshot, snapshotGet, getComputedProperty } from '../../../shared/dom-utils';
import type { ComputedStyleSnapshot } from '../../../shared/dom-utils';
import type { TokenStore } from '../../tokens/store';
import { InlineEditor } from './inline-editor';

type PropertyChangeCb = (property: string, fromValue: string, toValue: string, token?: string) => void;

interface LayoutContext {
  isFlexContainer: boolean;
  isGridContainer: boolean;
  isFlexChild: boolean;
  isGridChild: boolean;
}

const FLEX_CONTAINER_PROPS = ['flex-direction', 'justify-content', 'align-items', 'flex-wrap', 'gap'];
const GRID_CONTAINER_PROPS = ['grid-template-columns', 'grid-template-rows', 'gap', 'grid-auto-flow'];
const FLEX_CHILD_PROPS = ['align-self', 'flex-grow', 'flex-shrink', 'flex-basis', 'order'];
const GRID_CHILD_PROPS = ['grid-column', 'grid-row', 'align-self', 'order'];

/**
 * Conditional layout property group that appears in the Edit tab
 * only when the selected element is a flex/grid container or child.
 */
export class LayoutSection {
  private inlineEditor: InlineEditor;
  private propChangeCb: PropertyChangeCb | null = null;

  constructor(tokenStore: TokenStore) {
    this.inlineEditor = new InlineEditor(tokenStore);
  }

  onPropertyChange(cb: PropertyChangeCb): void {
    this.propChangeCb = cb;
  }

  /**
   * Detect the layout context for the element.
   * Returns null if no flex/grid context applies.
   */
  detect(element: Element, snapshot: ComputedStyleSnapshot): LayoutContext | null {
    const display = snapshot.display;
    const isFlexContainer = display === 'flex' || display === 'inline-flex';
    const isGridContainer = display === 'grid' || display === 'inline-grid';

    let isFlexChild = false;
    let isGridChild = false;
    if (element.parentElement) {
      const parentSnapshot = createStyleSnapshot(element.parentElement);
      const parentDisplay = parentSnapshot.display;
      isFlexChild = parentDisplay === 'flex' || parentDisplay === 'inline-flex';
      isGridChild = parentDisplay === 'grid' || parentDisplay === 'inline-grid';
    }

    if (!isFlexContainer && !isGridContainer && !isFlexChild && !isGridChild) {
      return null;
    }

    return { isFlexContainer, isGridContainer, isFlexChild, isGridChild };
  }

  /**
   * Build the layout section. Returns null if no flex/grid context.
   */
  build(element: Element, snapshot: ComputedStyleSnapshot): HTMLDivElement | null {
    const ctx = this.detect(element, snapshot);
    if (!ctx) return null;

    const section = createElement('div', {}, {
      padding: '8px 10px',
      borderBottom: `1px solid ${OVERLAY.border}`,
    });

    const title = createText('div', 'Layout', 'heading');
    title.style.fontSize = OVERLAY.monoSize;
    title.style.color = OVERLAY.textMuted;
    title.style.textTransform = 'uppercase';
    title.style.letterSpacing = '0.5px';
    title.style.marginBottom = '4px';
    section.appendChild(title);

    if (ctx.isFlexContainer) {
      section.appendChild(this.buildSubGroup('Flex Container', FLEX_CONTAINER_PROPS, element, snapshot));
    }
    if (ctx.isGridContainer) {
      section.appendChild(this.buildSubGroup('Grid Container', GRID_CONTAINER_PROPS, element, snapshot));
    }
    if (ctx.isFlexChild) {
      section.appendChild(this.buildSubGroup('Flex Child', FLEX_CHILD_PROPS, element, snapshot));
    }
    if (ctx.isGridChild) {
      section.appendChild(this.buildSubGroup('Grid Child', GRID_CHILD_PROPS, element, snapshot));
    }

    return section;
  }

  // ---------------------------------------------------------------------------
  // Sub-group rendering
  // ---------------------------------------------------------------------------

  private buildSubGroup(
    label: string,
    props: string[],
    element: Element,
    snapshot: ComputedStyleSnapshot,
  ): HTMLDivElement {
    const group = createElement('div', {}, {
      marginBottom: '6px',
    });

    const subLabel = createText('div', label, 'mono');
    subLabel.style.fontSize = '10px';
    subLabel.style.color = OVERLAY.textMuted;
    subLabel.style.marginBottom = '2px';
    subLabel.style.opacity = '0.7';
    group.appendChild(subLabel);

    const propsGrid = createElement('div', {}, {
      display: 'grid',
      gridTemplateColumns: 'repeat(auto-fill, minmax(160px, 1fr))',
      gap: '0 12px',
    });

    for (const prop of props) {
      const value = snapshotGet(snapshot, prop);
      propsGrid.appendChild(this.buildPropertyRow(prop, value, element));
    }

    group.appendChild(propsGrid);
    return group;
  }

  private buildPropertyRow(name: string, value: string, element: Element): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'center',
      padding: '2px 0',
      gap: '8px',
    });
    row.setAttribute('data-prop-row', '');
    row.setAttribute('data-prop-name', name);
    row.setAttribute('data-prop-value', value);

    const nameEl = createText('span', name, 'mono');
    nameEl.style.color = OVERLAY.textMuted;
    nameEl.style.flexShrink = '0';
    row.appendChild(nameEl);

    const valueContainer = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
      overflow: 'hidden',
      cursor: 'pointer',
      pointerEvents: 'auto',
    });

    const valueEl = createText('span', value, 'mono');
    valueEl.style.textOverflow = 'ellipsis';
    valueEl.style.overflow = 'hidden';
    valueEl.style.whiteSpace = 'nowrap';
    valueContainer.appendChild(valueEl);

    // Token badge
    const token = this.inlineEditor.resolveToken(name, value);
    if (token) {
      const badgeEl = createElement('span', {}, {
        background: 'rgba(6, 182, 212, 0.2)',
        color: OVERLAY.primary,
        padding: '1px 4px',
        borderRadius: '2px',
        fontSize: '10px',
        fontFamily: OVERLAY.monoFamily,
        whiteSpace: 'nowrap',
        flexShrink: '0',
      });
      badgeEl.textContent = token.name;
      valueContainer.appendChild(badgeEl);
    }

    valueContainer.addEventListener('click', () => {
      this.inlineEditor.openSingle(
        row as HTMLDivElement,
        valueContainer as HTMLDivElement,
        name,
        value,
        (property, fromValue, toValue, tokenName) => {
          this.propChangeCb?.(property, fromValue, toValue, tokenName);
        },
        element,
      );
    });

    valueContainer.addEventListener('mouseenter', () => {
      valueEl.style.textDecoration = 'underline';
      valueEl.style.textDecorationStyle = 'dotted';
    });
    valueContainer.addEventListener('mouseleave', () => {
      valueEl.style.textDecoration = '';
    });

    row.appendChild(valueContainer);
    return row;
  }
}
