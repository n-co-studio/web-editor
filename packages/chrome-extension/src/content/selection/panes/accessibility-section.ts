// ---------------------------------------------------------------------------
// Accessibility insights section — ARIA role, name, warnings, contrast
// ---------------------------------------------------------------------------

import { createElement, createText } from '../../../shared/ui-utils';
import { OVERLAY, tint } from '../../../shared/constants';
import type { ComputedStyleSnapshot } from '../../../shared/dom-utils';
import { computeContrast } from './enrichments/contrast-badge';

// ---------------------------------------------------------------------------
// Tag → implicit ARIA role mapping (~35 entries from WAI-ARIA)
// ---------------------------------------------------------------------------

const IMPLICIT_ROLES: Record<string, string | ((el: Element) => string | null)> = {
  a: (el) => el.hasAttribute('href') ? 'link' : null,
  article: 'article',
  aside: 'complementary',
  button: 'button',
  details: 'group',
  dialog: 'dialog',
  fieldset: 'group',
  figure: 'figure',
  footer: 'contentinfo',
  form: 'form',
  h1: 'heading',
  h2: 'heading',
  h3: 'heading',
  h4: 'heading',
  h5: 'heading',
  h6: 'heading',
  header: 'banner',
  hr: 'separator',
  img: (el) => el.getAttribute('alt') === '' ? 'presentation' : 'img',
  input: (el) => {
    const type = (el.getAttribute('type') ?? 'text').toLowerCase();
    const typeRoles: Record<string, string> = {
      button: 'button',
      checkbox: 'checkbox',
      email: 'textbox',
      image: 'button',
      number: 'spinbutton',
      password: 'textbox',
      radio: 'radio',
      range: 'slider',
      reset: 'button',
      search: 'searchbox',
      submit: 'button',
      tel: 'textbox',
      text: 'textbox',
      url: 'textbox',
    };
    return typeRoles[type] ?? 'textbox';
  },
  li: 'listitem',
  main: 'main',
  menu: 'list',
  nav: 'navigation',
  ol: 'list',
  option: 'option',
  output: 'status',
  progress: 'progressbar',
  section: 'region',
  select: 'combobox',
  summary: 'button',
  table: 'table',
  tbody: 'rowgroup',
  td: 'cell',
  textarea: 'textbox',
  tfoot: 'rowgroup',
  th: 'columnheader',
  thead: 'rowgroup',
  tr: 'row',
  ul: 'list',
};

const INTERACTIVE_TAGS = new Set(['button', 'a', 'input', 'select', 'textarea']);

interface AccessibilityCheck {
  label: string;
  value: string;
  severity: 'pass' | 'warning' | 'info';
  scrollTarget?: string; // data-prop-name to scroll to
}

/**
 * Accessibility insights section — renders at the bottom of the Edit tab.
 * Collapsible, collapsed by default.
 * Checks: computed role, accessible name, missing ARIA, contrast reference.
 */
export class AccessibilitySection {
  private expanded = false;
  private scrollTarget: HTMLElement | null = null;

  setScrollTarget(target: HTMLElement): void {
    this.scrollTarget = target;
  }

  build(element: Element, snapshot: ComputedStyleSnapshot): HTMLDivElement | null {
    const checks = this.runChecks(element, snapshot);
    if (checks.length === 0) return null;

    const wrapper = createElement('div', {}, {
      borderTop: `1px solid ${OVERLAY.border}`,
      marginTop: '8px',
    });

    // Header
    const header = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '6px',
      padding: '6px 10px',
      cursor: 'pointer',
      pointerEvents: 'auto',
    });

    const chevron = createText('span', '\u25B6', 'mono');
    chevron.style.fontSize = '7px';
    chevron.style.display = 'inline-block';
    chevron.style.transition = 'transform 0.12s ease';
    chevron.style.color = OVERLAY.textMuted;
    if (this.expanded) chevron.style.transform = 'rotate(90deg)';
    header.appendChild(chevron);

    const label = createText('span', 'Accessibility', 'heading');
    label.style.fontSize = '11px';
    label.style.flex = '1';
    header.appendChild(label);

    // Summary pills
    const warnings = checks.filter(c => c.severity === 'warning').length;
    const passes = checks.filter(c => c.severity === 'pass').length;

    if (warnings > 0) {
      header.appendChild(this.buildPill(`${warnings}`, 'warning'));
    }
    if (passes > 0) {
      header.appendChild(this.buildPill(`${passes}`, 'pass'));
    }

    wrapper.appendChild(header);

    // Content
    const content = createElement('div', {}, {
      display: this.expanded ? 'block' : 'none',
      padding: '0 10px 8px',
    });

    for (const check of checks) {
      content.appendChild(this.buildCheckRow(check));
    }

    wrapper.appendChild(content);

    header.addEventListener('click', (e) => {
      e.stopPropagation();
      this.expanded = !this.expanded;
      chevron.style.transform = this.expanded ? 'rotate(90deg)' : '';
      content.style.display = this.expanded ? 'block' : 'none';
    });

    return wrapper;
  }

  // ---------------------------------------------------------------------------
  // Check runners
  // ---------------------------------------------------------------------------

  private runChecks(element: Element, snapshot: ComputedStyleSnapshot): AccessibilityCheck[] {
    const checks: AccessibilityCheck[] = [];

    // 1. Computed ARIA role
    const roleCheck = this.checkRole(element);
    if (roleCheck) checks.push(roleCheck);

    // 2. Accessible name
    const nameCheck = this.checkAccessibleName(element);
    if (nameCheck) checks.push(nameCheck);

    // 3. Missing ARIA warnings
    const warnings = this.checkMissingAria(element);
    checks.push(...warnings);

    // 4. Contrast reference
    const contrastCheck = this.checkContrast(element, snapshot);
    if (contrastCheck) checks.push(contrastCheck);

    return checks;
  }

  private checkRole(element: Element): AccessibilityCheck {
    const explicit = element.getAttribute('role');
    if (explicit) {
      return { label: 'Role', value: `${explicit} (explicit)`, severity: 'pass' };
    }

    const tag = element.tagName.toLowerCase();
    const mapping = IMPLICIT_ROLES[tag];
    if (mapping) {
      const role = typeof mapping === 'function' ? mapping(element) : mapping;
      if (role) {
        return { label: 'Role', value: `${role} (implicit)`, severity: 'info' };
      }
    }

    return { label: 'Role', value: '(none)', severity: 'info' };
  }

  private checkAccessibleName(element: Element): AccessibilityCheck {
    const name = this.computeAccessibleName(element);
    if (name) {
      const truncated = name.length > 60 ? name.slice(0, 60) + '\u2026' : name;
      return { label: 'Name', value: truncated, severity: 'pass' };
    }
    return { label: 'Name', value: '(none)', severity: 'info' };
  }

  private computeAccessibleName(element: Element): string | null {
    // aria-label
    const ariaLabel = element.getAttribute('aria-label');
    if (ariaLabel?.trim()) return ariaLabel.trim();

    // aria-labelledby
    const labelledBy = element.getAttribute('aria-labelledby');
    if (labelledBy) {
      const ids = labelledBy.split(/\s+/);
      const parts: string[] = [];
      for (const id of ids) {
        const ref = document.getElementById(id);
        if (ref?.textContent?.trim()) parts.push(ref.textContent.trim());
      }
      if (parts.length > 0) return parts.join(' ');
    }

    // alt (img, area)
    const tag = element.tagName.toLowerCase();
    if (tag === 'img' || tag === 'area') {
      const alt = element.getAttribute('alt');
      if (alt?.trim()) return alt.trim();
    }

    // title
    const title = element.getAttribute('title');
    if (title?.trim()) return title.trim();

    // input value / placeholder
    if (tag === 'input') {
      const inputEl = element as HTMLInputElement;
      // Check for associated label
      if (inputEl.id) {
        const label = document.querySelector(`label[for="${CSS.escape(inputEl.id)}"]`);
        if (label?.textContent?.trim()) return label.textContent.trim();
      }
      if (inputEl.value?.trim()) return inputEl.value.trim();
      if (inputEl.placeholder?.trim()) return inputEl.placeholder.trim();
    }

    if (tag === 'textarea') {
      const textareaEl = element as HTMLTextAreaElement;
      if (textareaEl.id) {
        const label = document.querySelector(`label[for="${CSS.escape(textareaEl.id)}"]`);
        if (label?.textContent?.trim()) return label.textContent.trim();
      }
      if (textareaEl.placeholder?.trim()) return textareaEl.placeholder.trim();
    }

    // placeholder for select
    if (tag === 'select') {
      const selectEl = element as HTMLSelectElement;
      if (selectEl.id) {
        const label = document.querySelector(`label[for="${CSS.escape(selectEl.id)}"]`);
        if (label?.textContent?.trim()) return label.textContent.trim();
      }
    }

    // textContent (first 80 chars)
    const text = element.textContent?.trim();
    if (text) return text.slice(0, 80);

    return null;
  }

  private checkMissingAria(element: Element): AccessibilityCheck[] {
    const warnings: AccessibilityCheck[] = [];
    const tag = element.tagName.toLowerCase();
    const hasName = this.computeAccessibleName(element) !== null;

    // img without alt
    if (tag === 'img' && !element.hasAttribute('alt')) {
      warnings.push({
        label: 'Warning',
        value: 'Image missing alt attribute',
        severity: 'warning',
      });
    }

    // role="img" without accessible name
    if (element.getAttribute('role') === 'img' && !hasName) {
      warnings.push({
        label: 'Warning',
        value: 'role="img" without accessible name',
        severity: 'warning',
      });
    }

    // Form inputs without accessible name or associated label (specific check)
    const isFormInput = tag === 'input' || tag === 'textarea' || tag === 'select';
    if (isFormInput && !hasName) {
      const inputEl = element as HTMLInputElement;
      const hasLabel = inputEl.id
        ? document.querySelector(`label[for="${CSS.escape(inputEl.id)}"]`) !== null
        : false;
      if (!hasLabel) {
        warnings.push({
          label: 'Warning',
          value: `<${tag}> without label or accessible name`,
          severity: 'warning',
        });
      }
    }

    // Other interactive elements without accessible name (button, a — excludes form inputs handled above)
    if (INTERACTIVE_TAGS.has(tag) && !isFormInput && !hasName) {
      warnings.push({
        label: 'Warning',
        value: `Interactive <${tag}> without accessible name`,
        severity: 'warning',
      });
    }

    // Focusable without role and name (tabindex >= 0)
    const tabindex = element.getAttribute('tabindex');
    if (tabindex !== null && parseInt(tabindex, 10) >= 0) {
      if (!element.getAttribute('role') && !hasName && !INTERACTIVE_TAGS.has(tag)) {
        warnings.push({
          label: 'Warning',
          value: 'Focusable element without role or name',
          severity: 'warning',
        });
      }
    }

    return warnings;
  }

  private checkContrast(element: Element, snapshot: ComputedStyleSnapshot): AccessibilityCheck | null {
    const result = computeContrast('color', snapshot, element);
    if (!result) return null;

    if (!result.computable) {
      return {
        label: 'Contrast',
        value: 'Cannot determine (gradient/image background)',
        severity: 'info',
      };
    }

    return {
      label: 'Contrast',
      value: `${result.label} — see color property above`,
      severity: result.passes ? 'pass' : 'warning',
      scrollTarget: 'color',
    };
  }

  // ---------------------------------------------------------------------------
  // UI builders
  // ---------------------------------------------------------------------------

  private buildPill(text: string, type: 'pass' | 'warning'): HTMLSpanElement {
    const colors = {
      pass: { bg: tint(OVERLAY.success, 12), text: OVERLAY.success },
      warning: { bg: tint(OVERLAY.destructive, 12), text: OVERLAY.destructive },
    };
    const c = colors[type];
    const pill = createElement('span', {}, {
      fontSize: '10px',
      fontFamily: OVERLAY.monoFamily,
      color: c.text,
      background: c.bg,
      borderRadius: '8px',
      padding: '0 6px',
      lineHeight: '16px',
      flexShrink: '0',
    }) as HTMLSpanElement;
    pill.textContent = text;
    return pill;
  }

  private buildCheckRow(check: AccessibilityCheck): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      alignItems: 'baseline',
      gap: '6px',
      padding: '3px 0',
      fontSize: '11px',
      fontFamily: OVERLAY.monoFamily,
    });

    // Severity dot
    const dotColor = {
      pass: OVERLAY.success,
      warning: OVERLAY.destructive,
      info: OVERLAY.textMuted,
    }[check.severity];

    const dot = createElement('span', {}, {
      width: '6px',
      height: '6px',
      borderRadius: '50%',
      background: dotColor,
      flexShrink: '0',
      display: 'inline-block',
      marginTop: '4px',
    });
    row.appendChild(dot);

    const labelEl = createText('span', check.label, 'mono');
    labelEl.style.color = OVERLAY.textMuted;
    labelEl.style.flexShrink = '0';
    labelEl.style.fontSize = '11px';
    row.appendChild(labelEl);

    const valueEl = createText('span', check.value, 'mono');
    valueEl.style.color = OVERLAY.text;
    valueEl.style.fontSize = '11px';
    valueEl.style.wordBreak = 'break-word';

    // Scroll-to-property link for contrast reference
    if (check.scrollTarget) {
      valueEl.style.cursor = 'pointer';
      valueEl.style.textDecoration = 'underline';
      valueEl.style.textDecorationColor = OVERLAY.border;
      valueEl.addEventListener('click', (e) => {
        e.stopPropagation();
        if (!this.scrollTarget) return;
        const propRow = this.scrollTarget.querySelector(
          `[data-prop-name="${check.scrollTarget}"]`,
        ) as HTMLElement | null;
        if (propRow) {
          propRow.scrollIntoView({ block: 'center', behavior: 'smooth' });
          propRow.style.background = tint(OVERLAY.primary, 12);
          setTimeout(() => { propRow.style.background = ''; }, 1200);
        }
      });
    }

    row.appendChild(valueEl);
    return row;
  }
}
