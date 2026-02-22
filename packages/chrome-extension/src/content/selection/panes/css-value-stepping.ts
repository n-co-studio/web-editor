/**
 * Pure utility functions for CSS value stepping (Arrow Up/Down in inline editor).
 * Parses numeric CSS values, applies step deltas, and recomposes with original units.
 */

export interface ParsedCssValue {
  number: number;
  unit: string;
}

/**
 * Parse a CSS value string into numeric part and unit suffix.
 * Returns null for non-numeric values (auto, bold, inherit, rgb(...), calc(...), etc.).
 */
export function parseCssValue(value: string): ParsedCssValue | null {
  const trimmed = value.trim();
  if (!trimmed) return null;
  const match = trimmed.match(/^(-?\d+\.?\d*)\s*([a-z%]*)$/i);
  if (!match) return null;
  const num = parseFloat(match[1]);
  if (isNaN(num)) return null;
  return { number: num, unit: match[2] || '' };
}

/** Count decimal places in a number. */
function getDecimalPlaces(n: number): number {
  const str = String(n);
  const dotIndex = str.indexOf('.');
  return dotIndex === -1 ? 0 : str.length - dotIndex - 1;
}

/** Round to N decimal places, avoiding floating-point drift. */
function roundTo(n: number, places: number): number {
  if (places === 0) return Math.round(n);
  const factor = Math.pow(10, places);
  return Math.round(n * factor) / factor;
}

/**
 * Step a CSS value string by a given delta.
 * Returns the original value unchanged if non-numeric.
 *
 * Handles decimal precision to avoid floating-point drift:
 *   stepCssValue("1.5rem", 0.1)  -> "1.6rem"
 *   stepCssValue("10px", -0.1)   -> "9.9px"
 *   stepCssValue("auto", 1)      -> "auto"
 */
export function stepCssValue(currentValue: string, delta: number): string {
  const parsed = parseCssValue(currentValue);
  if (!parsed) return currentValue;

  const raw = parsed.number + delta;
  const precision = Math.max(getDecimalPlaces(parsed.number), getDecimalPlaces(delta));
  const stepped = roundTo(raw, precision);

  return `${stepped}${parsed.unit}`;
}

/**
 * Determine the step delta from a KeyboardEvent.
 * Returns 0 if the key is not ArrowUp/ArrowDown.
 *
 * Modifier mapping:
 *   (none)       -> ±1
 *   Shift        -> ±10
 *   Alt/Option   -> ±0.1
 *   Cmd/Ctrl     -> ±100
 */
export function getStepDelta(e: KeyboardEvent): number {
  if (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') return 0;

  const direction = e.key === 'ArrowUp' ? 1 : -1;

  if (e.metaKey || e.ctrlKey) return 100 * direction;
  if (e.shiftKey) return 10 * direction;
  if (e.altKey) return 0.1 * direction;

  return 1 * direction;
}
