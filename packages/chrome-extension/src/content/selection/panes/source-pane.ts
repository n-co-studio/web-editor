import type { ElementInfo } from '@frontend-editor/shared';
import { createElement, createText } from '../../../shared/ui-utils';
import { OVERLAY, SELECTOR_TRUNCATE_LENGTH } from '../../../shared/constants';

/**
 * Source pane — bottom of the left column.
 * Shows source file + line and the CSS selector for the selected element.
 */
export class SourcePane {
  private container: HTMLDivElement | null = null;

  mount(container: HTMLDivElement): void {
    this.container = container;
  }

  dispose(): void {
    this.container = null;
  }

  updateElement(info: ElementInfo): void {
    if (!this.container) return;
    this.renderSourceContent(info);
  }

  clearElement(): void {
    if (this.container) {
      this.container.innerHTML = '';
    }
  }

  private renderSourceContent(info: ElementInfo): void {
    if (!this.container) return;
    this.container.innerHTML = '';
    if (info.sourceFile) {
      const fileLine = createText('div', `${info.sourceFile}:${info.sourceLine}`, 'mono');
      fileLine.style.color = OVERLAY.textMuted;
      this.container.appendChild(fileLine);
    } else {
      const warning = createElement('div', {}, {
        background: 'rgba(245, 158, 11, 0.15)',
        border: `1px solid ${OVERLAY.warning}`,
        borderRadius: OVERLAY.radiusSm,
        padding: '4px 8px',
        fontSize: OVERLAY.bodySize,
        color: OVERLAY.warning,
        fontFamily: OVERLAY.fontFamily,
      });
      warning.textContent = 'Source mapping unavailable \u2014 install the dev-plugin for precise file targeting.';
      this.container.appendChild(warning);
    }
    const selectorText = info.selector.length > SELECTOR_TRUNCATE_LENGTH
      ? info.selector.slice(0, SELECTOR_TRUNCATE_LENGTH) + '\u2026'
      : info.selector;
    const selector = createText('div', selectorText, 'mono');
    selector.style.color = OVERLAY.textMuted;
    selector.style.marginTop = '4px';
    selector.title = info.selector;
    this.container.appendChild(selector);
  }
}
