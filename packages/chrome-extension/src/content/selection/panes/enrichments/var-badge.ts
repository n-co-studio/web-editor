import { createElement, createText } from '../../../../shared/ui-utils';
import { OVERLAY } from '../../../../shared/constants';
import type { ResolutionResult, ResolutionStep } from '../../../inspection/variable-resolver';

const VAR_RE = /var\(/;

interface TooltipElement extends HTMLDivElement {
  __abortController?: AbortController;
}

/** Clean up the click-outside listener for a tooltip created by createVarTooltip(). */
export function cleanupVarTooltip(tooltip: HTMLDivElement): void {
  (tooltip as TooltipElement).__abortController?.abort();
}

/**
 * Create a "var" badge for property values that contain var() references.
 * Returns null if the value does not contain a var() function.
 * Click-activated (not hover).
 */
export function createVarBadge(
  authoredValue: string,
  onClick: () => void,
): HTMLSpanElement | null {
  if (!VAR_RE.test(authoredValue)) return null;

  const badge = createElement('span', {
    title: 'CSS variable — click to resolve',
  }, {
    fontSize: '10px',
    fontFamily: OVERLAY.monoFamily,
    color: 'rgb(168, 85, 247)',
    background: 'rgba(168, 85, 247, 0.12)',
    borderRadius: '3px',
    padding: '0 4px',
    lineHeight: '14px',
    flexShrink: '0',
    cursor: 'pointer',
    pointerEvents: 'auto',
    whiteSpace: 'nowrap',
  }) as HTMLSpanElement;
  badge.textContent = 'var';

  badge.addEventListener('click', (e) => {
    e.stopPropagation();
    onClick();
  });

  return badge;
}

type RuleClickCb = (selectorText: string) => void;
type DismissCb = () => void;

/**
 * Create a tooltip showing the CSS variable resolution chain.
 * Rendered as an absolutely-positioned div below the badge.
 */
export function createVarTooltip(
  result: ResolutionResult,
  onRuleClick: RuleClickCb,
  onDismiss: DismissCb,
  dismissRoot?: EventTarget,
): HTMLDivElement {
  const tooltip = createElement('div', {}, {
    position: 'absolute',
    zIndex: '200',
    background: OVERLAY.bg,
    border: `1px solid ${OVERLAY.border}`,
    borderRadius: OVERLAY.radiusMd,
    padding: '8px',
    boxShadow: '0 4px 12px rgba(0, 0, 0, 0.3)',
    maxWidth: '320px',
    minWidth: '180px',
    fontFamily: OVERLAY.monoFamily,
    fontSize: '11px',
    pointerEvents: 'auto',
  });

  // Circular reference warning
  if (result.circular) {
    const warn = createText('div', 'Circular reference detected', 'mono');
    warn.style.color = OVERLAY.destructive;
    warn.style.fontSize = '10px';
    warn.style.marginBottom = '6px';
    tooltip.appendChild(warn);
  }

  // Resolution chain steps
  for (let i = 0; i < result.chain.length; i++) {
    const step = result.chain[i];
    const stepEl = buildStepRow(step, i, onRuleClick);
    tooltip.appendChild(stepEl);

    if (i < result.chain.length - 1) {
      const arrow = createText('div', '\u2193', 'mono');
      arrow.style.color = OVERLAY.textMuted;
      arrow.style.textAlign = 'center';
      arrow.style.fontSize = '10px';
      arrow.style.padding = '1px 0';
      tooltip.appendChild(arrow);
    }
  }

  // Truncation indicator
  if (result.truncated) {
    const more = createText('div', `\u2026 (${result.totalDepth} levels)`, 'mono');
    more.style.color = OVERLAY.textMuted;
    more.style.fontSize = '10px';
    more.style.textAlign = 'center';
    more.style.padding = '2px 0';
    tooltip.appendChild(more);
  }

  // Final resolved value
  const finalRow = createElement('div', {}, {
    borderTop: `1px solid ${OVERLAY.border}`,
    marginTop: '6px',
    paddingTop: '6px',
    display: 'flex',
    alignItems: 'baseline',
    gap: '4px',
  });
  const finalLabel = createText('span', 'Resolved:', 'mono');
  finalLabel.style.color = OVERLAY.textMuted;
  finalLabel.style.fontSize = '10px';
  finalLabel.style.flexShrink = '0';
  finalRow.appendChild(finalLabel);

  const finalVal = createText('span', result.finalValue, 'mono');
  finalVal.style.color = OVERLAY.text;
  finalVal.style.fontSize = '11px';
  finalVal.style.wordBreak = 'break-all';
  finalRow.appendChild(finalVal);
  tooltip.appendChild(finalRow);

  // Click-outside dismiss (deferred to avoid immediate trigger)
  // Use dismissRoot (shadow root) when available — events inside shadow DOM
  // are re-targeted at the shadow host before reaching document.
  // AbortController ensures cleanup on programmatic dismiss via cleanupVarTooltip().
  const root = dismissRoot ?? document;
  const ac = new AbortController();
  (tooltip as TooltipElement).__abortController = ac;
  requestAnimationFrame(() => {
    const handler = (e: Event) => {
      if (!tooltip.contains(e.target as Node)) {
        ac.abort();
        onDismiss();
      }
    };
    root.addEventListener('click', handler, { capture: true, signal: ac.signal });
  });

  return tooltip;
}

function buildStepRow(
  step: ResolutionStep,
  _index: number,
  onRuleClick: RuleClickCb,
): HTMLDivElement {
  const row = createElement('div', {}, {
    display: 'flex',
    flexDirection: 'column',
    gap: '1px',
    padding: '2px 4px',
    borderRadius: '3px',
    background: 'rgba(255, 255, 255, 0.03)',
  });

  // Variable name
  const nameRow = createElement('div', {}, {
    display: 'flex',
    alignItems: 'baseline',
    gap: '4px',
  });
  const nameEl = createText('span', step.variableName, 'mono');
  nameEl.style.color = 'rgb(168, 85, 247)';
  nameEl.style.fontSize = '11px';
  nameRow.appendChild(nameEl);

  // Token badge if applicable
  if (step.tokenName) {
    const tokenBadge = createElement('span', {}, {
      fontSize: '9px',
      fontFamily: OVERLAY.monoFamily,
      color: OVERLAY.primary,
      background: 'rgba(6, 182, 212, 0.12)',
      borderRadius: '3px',
      padding: '0 3px',
      lineHeight: '13px',
      whiteSpace: 'nowrap',
    });
    tokenBadge.textContent = step.tokenName;
    nameRow.appendChild(tokenBadge);
  }

  row.appendChild(nameRow);

  // Value
  const valueEl = createText('div', step.value, 'mono');
  valueEl.style.color = OVERLAY.text;
  valueEl.style.fontSize = '10px';
  valueEl.style.wordBreak = 'break-all';
  row.appendChild(valueEl);

  // Source link (clickable if not computed/inline)
  const sourceEl = createText('div', '', 'mono');
  sourceEl.style.fontSize = '9px';
  sourceEl.style.color = OVERLAY.textMuted;

  if (step.isComputed) {
    sourceEl.textContent = '(computed fallback)';
  } else if (step.source === 'inline') {
    sourceEl.textContent = 'inline style';
  } else {
    sourceEl.textContent = step.source;
    sourceEl.style.cursor = 'pointer';
    sourceEl.style.textDecoration = 'underline';
    sourceEl.style.textDecorationColor = 'rgba(255, 255, 255, 0.2)';
    sourceEl.addEventListener('click', (e) => {
      e.stopPropagation();
      onRuleClick(step.source);
    });
    sourceEl.addEventListener('mouseenter', () => {
      sourceEl.style.color = OVERLAY.primary;
    });
    sourceEl.addEventListener('mouseleave', () => {
      sourceEl.style.color = OVERLAY.textMuted;
    });
  }

  row.appendChild(sourceEl);
  return row;
}
