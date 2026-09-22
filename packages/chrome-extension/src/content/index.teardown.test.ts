/**
 * Regression lock: activate() / deactivate() teardown parity (SE-1)
 *
 * Every module-level subsystem field that is assigned to a `new SomeClass(...)`
 * instance inside activate() MUST also be set to `null` inside deactivate().
 *
 * The field lists are derived at test runtime by parsing the index.ts source
 * text — they are NOT hand-copied. If someone adds a subsystem to activate()
 * and forgets to null it in deactivate(), this test fails.
 *
 * Mutation check: delete one `fieldName = null;` line from deactivate(), and
 * this test fails. Restore it, and the test passes again.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

// ---------------------------------------------------------------------------
// Source parsing helpers
// ---------------------------------------------------------------------------

/**
 * Extract the body of a named function from TypeScript source text using
 * line-by-line brace counting. Works for top-level (possibly exported, possibly
 * async) function declarations. The function body includes the outer `{` / `}`.
 */
function extractFunctionBody(src: string, funcName: string): string {
  const lines = src.split('\n');

  // Find the line that begins the function declaration
  const startPattern = new RegExp(
    `^\\s*(export\\s+)?(async\\s+)?function\\s+${funcName}\\s*\\(`,
  );
  const startLine = lines.findIndex(l => startPattern.test(l));
  if (startLine === -1) {
    throw new Error(`Function '${funcName}' not found in source`);
  }

  // Walk forward counting braces (simple — assumes well-formed TS with balanced
  // braces inside string literals; this holds for index.ts)
  let depth = 0;
  let openedOnce = false;
  for (let i = startLine; i < lines.length; i++) {
    for (const ch of lines[i]) {
      if (ch === '{') { depth++; openedOnce = true; }
      else if (ch === '}') {
        depth--;
        if (openedOnce && depth === 0) {
          return lines.slice(startLine, i + 1).join('\n');
        }
      }
    }
  }
  throw new Error(`Unbalanced braces for function '${funcName}'`);
}

/**
 * Extract all identifiers matching `<name> = new ` from the given source
 * snippet. Returns a Set of field names. Excludes property-access patterns
 * (e.g. `this.field = new …`) because module-level fields are bare names.
 */
function extractNewAssignments(body: string): Set<string> {
  const re = /(?:^|[^.\w])([a-zA-Z_$][a-zA-Z0-9_$]*)\s*=\s*new\s+/gm;
  const names = new Set<string>();
  let m: RegExpExecArray | null;
  while ((m = re.exec(body)) !== null) {
    names.add(m[1]);
  }
  return names;
}

/**
 * Extract all identifiers matching `<name> = null` (as a standalone statement)
 * from the given source snippet.
 */
function extractNullAssignments(body: string): Set<string> {
  const re = /(?:^|[^.\w])([a-zA-Z_$][a-zA-Z0-9_$]*)\s*=\s*null\b/gm;
  const names = new Set<string>();
  let m: RegExpExecArray | null;
  while ((m = re.exec(body)) !== null) {
    names.add(m[1]);
  }
  return names;
}

// ---------------------------------------------------------------------------
// Load source (resolved from the package root — CWD when `npm test` runs)
// ---------------------------------------------------------------------------

const indexPath = resolve(process.cwd(), 'src/content/index.ts');
const indexSrc = readFileSync(indexPath, 'utf-8');

const activateBody = extractFunctionBody(indexSrc, 'activate');
const deactivateBody = extractFunctionBody(indexSrc, 'deactivate');

const activatedFields = extractNewAssignments(activateBody);
const nulledFields = extractNullAssignments(deactivateBody);

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

describe('index.ts — activate/deactivate teardown parity (regression lock SE-1)', () => {
  it('every field assigned via "= new …" in activate() is also set to null in deactivate()', () => {
    // Sanity: confirm we actually found fields (guards against regex failure)
    assert.ok(
      activatedFields.size >= 10,
      `Expected ≥10 subsystem fields from activate(), found ${activatedFields.size}. Parser may have failed.`,
    );
    assert.ok(
      nulledFields.size >= 10,
      `Expected ≥10 null assignments in deactivate(), found ${nulledFields.size}. Parser may have failed.`,
    );

    // The parity check: nothing activated may be missing from the teardown
    const missing = [...activatedFields].filter(name => !nulledFields.has(name));

    assert.deepEqual(
      missing,
      [],
      `Teardown parity failure: field(s) assigned in activate() but not nulled in deactivate(): ${missing.join(', ')}. ` +
      `Add "  ${missing.map(n => `${n} = null;`).join('\n  ')}" to deactivate().`,
    );
  });

  it('records the parsed field sets for diagnostics (informational)', () => {
    // This test always passes; it surfaces the field counts in the test output.
    const activatedList = [...activatedFields].sort().join(', ');
    const nulledList = [...nulledFields].sort().join(', ');
    assert.ok(true, `activated(${activatedFields.size}): ${activatedList}`);
    assert.ok(true, `nulled(${nulledFields.size}): ${nulledList}`);
  });
});
