// ---------------------------------------------------------------------------
// CSS specificity calculator
// ---------------------------------------------------------------------------

/**
 * Compute the specificity of a CSS selector as an (a, b, c) tuple.
 * - a: ID selectors (#foo)
 * - b: class selectors, attribute selectors, pseudo-classes
 * - c: type selectors, pseudo-elements
 *
 * Modern CSS handling:
 * - :where(...) → zero specificity (stripped entirely)
 * - :is(...), :not(...), :has(...) → specificity of highest argument
 * - ::before, ::after, etc. → c += 1
 * - Selector lists (.a, .b) → returns max specificity across list
 *
 * Known limitation: deeply nested :is(:not(:has(...))) may be approximate.
 */
export function computeSpecificity(selector: string): [number, number, number] {
  // Handle selector lists — comma-separated, return max
  const parts = splitSelectorList(selector);
  if (parts.length > 1) {
    let maxSpec: [number, number, number] = [0, 0, 0];
    for (const part of parts) {
      const spec = computeSingleSpecificity(part.trim());
      if (compareSpecificity(spec, maxSpec) > 0) {
        maxSpec = spec;
      }
    }
    return maxSpec;
  }

  return computeSingleSpecificity(selector.trim());
}

/**
 * Compare two specificity tuples.
 * Returns > 0 if a > b, < 0 if a < b, 0 if equal.
 */
export function compareSpecificity(
  a: [number, number, number],
  b: [number, number, number],
): number {
  if (a[0] !== b[0]) return a[0] - b[0];
  if (a[1] !== b[1]) return a[1] - b[1];
  return a[2] - b[2];
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function computeSingleSpecificity(selector: string): [number, number, number] {
  let s = selector;

  // 1. Strip :where(...) — contributes zero specificity
  s = stripFunctionalPseudo(s, ':where');

  // 2. Process :is(), :not(), :has() — specificity = max of arguments
  let extraA = 0;
  let extraB = 0;
  let extraC = 0;

  for (const pseudo of [':is', ':not', ':has']) {
    const extracted = extractFunctionalPseudo(s, pseudo);
    s = extracted.remaining;
    for (const argSpec of extracted.argSpecificities) {
      extraA = Math.max(extraA, argSpec[0]);
      extraB = Math.max(extraB, argSpec[1]);
      extraC = Math.max(extraC, argSpec[2]);
    }
  }

  // 3. Count specificity components in the remaining selector
  let a = 0; // IDs
  let b = 0; // classes, attributes, pseudo-classes
  let c = 0; // types, pseudo-elements

  // Remove strings/brackets content that might contain false matches
  // Process attribute selectors [attr] — count and remove
  const attrRegex = /\[[^\]]*\]/g;
  const attrMatches = s.match(attrRegex);
  if (attrMatches) {
    b += attrMatches.length;
    s = s.replace(attrRegex, '');
  }

  // Pseudo-elements (::before, ::after, ::placeholder, ::first-line, etc.)
  const pseudoElementRegex = /::([\w-]+)/g;
  const pseudoElements = s.match(pseudoElementRegex);
  if (pseudoElements) {
    c += pseudoElements.length;
    s = s.replace(pseudoElementRegex, '');
  }

  // Pseudo-classes (:hover, :focus, :nth-child(), etc.) — but NOT ::
  // Also handle functional pseudo-classes like :nth-child(2n+1)
  const pseudoClassRegex = /:([\w-]+)(?:\([^)]*\))?/g;
  const pseudoClasses = s.match(pseudoClassRegex);
  if (pseudoClasses) {
    b += pseudoClasses.length;
    s = s.replace(pseudoClassRegex, '');
  }

  // ID selectors
  const idRegex = /#[\w-]+/g;
  const ids = s.match(idRegex);
  if (ids) {
    a += ids.length;
    s = s.replace(idRegex, '');
  }

  // Class selectors
  const classRegex = /\.[\w-]+/g;
  const classes = s.match(classRegex);
  if (classes) {
    b += classes.length;
    s = s.replace(classRegex, '');
  }

  // Type selectors (bare tag names) — exclude combinators and universal selector
  const remaining = s.replace(/[>+~*\s]+/g, ' ').trim();
  if (remaining) {
    const types = remaining.split(/\s+/).filter((t) => t && /^[a-zA-Z][\w-]*$/.test(t));
    c += types.length;
  }

  return [a + extraA, b + extraB, c + extraC];
}

/**
 * Split a selector list by commas, respecting parenthetical nesting.
 * e.g., ":is(.a, .b), .c" → [":is(.a, .b)", ".c"]
 */
function splitSelectorList(selector: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let current = '';

  for (const ch of selector) {
    if (ch === '(') {
      depth++;
      current += ch;
    } else if (ch === ')') {
      depth--;
      current += ch;
    } else if (ch === ',' && depth === 0) {
      parts.push(current);
      current = '';
    } else {
      current += ch;
    }
  }
  if (current) parts.push(current);
  return parts;
}

/**
 * Strip a functional pseudo-class entirely (e.g., :where(...)).
 * Handles nested parentheses.
 */
function stripFunctionalPseudo(selector: string, pseudo: string): string {
  let result = selector;
  let idx = result.indexOf(pseudo + '(');

  while (idx !== -1) {
    const start = idx;
    const parenStart = idx + pseudo.length;
    const end = findMatchingParen(result, parenStart);
    if (end === -1) break;
    result = result.slice(0, start) + result.slice(end + 1);
    idx = result.indexOf(pseudo + '(');
  }

  return result;
}

/**
 * Extract functional pseudo-class arguments and compute their specificities.
 * Returns the remaining selector with the pseudo removed, plus computed arg specificities.
 */
function extractFunctionalPseudo(
  selector: string,
  pseudo: string,
): { remaining: string; argSpecificities: Array<[number, number, number]> } {
  const argSpecificities: Array<[number, number, number]> = [];
  let remaining = selector;
  let idx = remaining.indexOf(pseudo + '(');

  while (idx !== -1) {
    const parenStart = idx + pseudo.length;
    const end = findMatchingParen(remaining, parenStart);
    if (end === -1) break;

    const argsStr = remaining.slice(parenStart + 1, end);
    // Split args by comma (respecting nesting) and compute specificity of each
    const args = splitSelectorList(argsStr);
    for (const arg of args) {
      const trimmed = arg.trim();
      if (trimmed) {
        argSpecificities.push(computeSpecificity(trimmed));
      }
    }

    remaining = remaining.slice(0, idx) + remaining.slice(end + 1);
    idx = remaining.indexOf(pseudo + '(');
  }

  return { remaining, argSpecificities };
}

/** Find the closing parenthesis matching the opening one at `start`. */
function findMatchingParen(s: string, start: number): number {
  if (s[start] !== '(') return -1;
  let depth = 1;
  for (let i = start + 1; i < s.length; i++) {
    if (s[i] === '(') depth++;
    else if (s[i] === ')') {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}
