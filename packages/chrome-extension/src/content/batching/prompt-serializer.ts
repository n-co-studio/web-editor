import type {
  VisualDiff,
  NoteEntry,
  NoteElementRef,
  SiblingAnchor,
  CompoundChildDescriptor,
  RuleSource,
  CrossBreakpointRuleSource,
} from '@nco-studio/shared';

/**
 * Serialize active diffs and notes into a clipboard-ready prompt.
 * Produces human-readable Markdown grouped by source file,
 * with raw JSON appended in an HTML comment for machine consumption.
 */
export function serializeToPrompt(
  diffs: readonly VisualDiff[],
  notes?: readonly NoteEntry[],
): string {
  const sections: string[] = [];

  sections.push("# Visual Changes from Visual Web Editor for AI Agents\n");

  if (hasResponsiveContext(diffs)) {
    sections.push(
      '> Scope edits to the active breakpoint where applicable. Active breakpoint is shown on each element heading; per-property [@ ...] annotations indicate a rule defined at a different breakpoint.\n',
    );
  }

  // Group diffs by source file (empty sourceFile → "unresolved" bucket)
  const byFile = new Map<string, VisualDiff[]>();
  for (const diff of diffs) {
    const key = diff.element.sourceFile || '';
    const group = byFile.get(key);
    if (group) group.push(diff);
    else byFile.set(key, [diff]);
  }

  // Render verified-source groups first, unresolved last
  const sorted = [...byFile.entries()].sort((a, b) => {
    if (!a[0] && b[0]) return 1;
    if (a[0] && !b[0]) return -1;
    return a[0].localeCompare(b[0]);
  });

  // Collect structural changes separately
  const reorders: Array<{ diff: VisualDiff }> = [];
  const inserts: Array<{ diff: VisualDiff }> = [];
  const removes: Array<{ diff: VisualDiff }> = [];
  const groups: Array<{ diff: VisualDiff }> = [];
  const textEdits: Array<{ diff: VisualDiff }> = [];

  for (const [file, fileDiffs] of sorted) {
    const heading = file
      ? `## ${file}`
      : '## (unresolved source \u2014 CSS selector only)';
    sections.push(heading + '\n');

    for (const diff of fileDiffs) {
      // Element heading with selector, optional line number, and optional breakpoint annotation
      const lineInfo = diff.element.sourceLine
        ? ` (line ${diff.element.sourceLine})`
        : '';
      const breakpointInfo = formatBreakpointHeading(diff.context);
      const assetInfo = formatAssetSuffix(diff.element);
      sections.push(`### \`${diff.element.selector}\`${lineInfo}${breakpointInfo}${assetInfo}\n`);

      // Property changes
      const activeBreakpointLabel = formatActiveBreakpointLabel(diff.context);
      for (const c of diff.changes) {
        const tokenInfo = formatTokenInfo(c.fromToken, c.toToken);
        const sourceContext = formatSourceContext(
          c.source,
          diff.context.breakpointValue,
          c.allBreakpointSources,
          activeBreakpointLabel,
        );
        sections.push(
          `- \`${c.property}\`: ${c.fromValue} \u2192 ${c.toValue}${tokenInfo}${sourceContext}`,
        );
      }

      // Collect reorder changes for a separate section
      if (diff.reorderChanges) {
        for (const _rc of diff.reorderChanges) {
          reorders.push({ diff });
        }
      }

      // Collect insert changes for a separate section
      if (diff.insertChanges) {
        for (const _ic of diff.insertChanges) {
          inserts.push({ diff });
        }
      }

      // Collect remove changes for a separate section
      if (diff.removeChanges) {
        for (const _rmc of diff.removeChanges) {
          removes.push({ diff });
        }
      }

      // Collect group changes for a separate section
      if (diff.groupChanges) {
        for (const _gc of diff.groupChanges) {
          groups.push({ diff });
        }
      }

      // Collect text changes for a separate section
      if (diff.textChanges) {
        for (const _tc of diff.textChanges) {
          textEdits.push({ diff });
        }
      }

      sections.push('');
    }
  }

  // Reorder changes section
  if (reorders.length > 0) {
    sections.push('## Reorder Changes\n');
    // Deduplicate: render directly from diffs that have reorderChanges
    const seen = new Set<string>();
    for (const { diff } of reorders) {
      if (seen.has(diff.id)) continue;
      seen.add(diff.id);
      for (const rc of diff.reorderChanges!) {
        sections.push(
          `- Move child from position ${rc.fromIndex + 1} to position ${rc.toIndex + 1} in \`${rc.containerSelector}\` (${rc.containerDirection})`,
        );
        // Enumerate the sibling order with resolved asset paths so a gallery
        // reorder is actionable from the payload alone (issue #29).
        if (rc.siblingAnchors && rc.siblingAnchors.length > 0) {
          const order = rc.siblingAnchors.map(
            (a, i) => `${i + 1} → ${anchorLabel(a)}`,
          );
          sections.push(`  Order: ${order.join(', ')}`);
        }
      }
    }
    sections.push('');
  }

  // Insert changes section
  if (inserts.length > 0) {
    sections.push('## Insert Changes\n');
    const seen = new Set<string>();
    for (const { diff } of inserts) {
      if (seen.has(diff.id)) continue;
      seen.add(diff.id);
      for (const ic of diff.insertChanges!) {
        const bracketInfo = [];
        if (ic.prevSibling) bracketInfo.push(`after ${ic.prevSibling.sourceFile}:${ic.prevSibling.sourceLine}${formatAssetSuffix(ic.prevSibling)}`);
        if (ic.nextSibling) bracketInfo.push(`before ${ic.nextSibling.sourceFile}:${ic.nextSibling.sourceLine}${formatAssetSuffix(ic.nextSibling)}`);
        const bracket = bracketInfo.length > 0 ? ` (${bracketInfo.join(', ')})` : '';
        sections.push(
          `- Insert \`<${ic.tagName}>\` at position ${ic.insertIndex + 1} in \`${ic.containerSelector}\`${bracket}`,
        );
        if (ic.compoundChildren && ic.compoundChildren.length > 0) {
          sections.push(`  Children: ${describeCompoundChildren(ic.compoundChildren)}`);
        }
        if (ic.initialStyles.length > 0) {
          const styleDesc = ic.initialStyles.map(s => `${s.property}: ${s.toValue}`).join(', ');
          sections.push(`  Initial styles: ${styleDesc}`);
        }
        // Clone/paste/duplicate inserts carry the full subtree markup — emit it
        // verbatim so the source rewrite reproduces the exact element, not an
        // empty `<tag>`.
        if (ic.outerHTML) {
          sections.push('  Full HTML (reproduce exactly):');
          sections.push('  ```html');
          sections.push(ic.outerHTML);
          sections.push('  ```');
        }
      }
    }
    sections.push('');
  }

  // Remove changes section
  if (removes.length > 0) {
    sections.push('## Remove Changes\n');
    const seen = new Set<string>();
    for (const { diff } of removes) {
      if (seen.has(diff.id)) continue;
      seen.add(diff.id);
      for (const rmc of diff.removeChanges!) {
        const lineInfo = diff.element.sourceLine
          ? ` (line ${diff.element.sourceLine})`
          : '';
        const fileInfo = diff.element.sourceFile
          ? ` in ${diff.element.sourceFile}${lineInfo}`
          : '';
        sections.push(
          `- Remove \`<${rmc.tagName}>\` (\`${diff.element.selector}\`) from \`${rmc.containerSelector}\` at position ${rmc.removedIndex + 1}${fileInfo}`,
        );
      }
    }
    sections.push('');
  }

  // Group changes section
  if (groups.length > 0) {
    sections.push('## Group Changes\n');
    const seen = new Set<string>();
    for (const { diff } of groups) {
      if (seen.has(diff.id)) continue;
      seen.add(diff.id);
      for (const gc of diff.groupChanges!) {
        const bracketInfo = [];
        if (gc.prevSibling) bracketInfo.push(`after ${gc.prevSibling.sourceFile}:${gc.prevSibling.sourceLine}`);
        if (gc.nextSibling) bracketInfo.push(`before ${gc.nextSibling.sourceFile}:${gc.nextSibling.sourceLine}`);
        const bracket = bracketInfo.length > 0 ? ` (${bracketInfo.join(', ')})` : '';
        sections.push(
          `- Wrap ${gc.wrappedSelectors.length} elements in \`<${gc.wrapperTagName}>\` at position ${gc.insertIndex + 1} in \`${gc.containerSelector}\`${bracket}`,
        );
        if (gc.wrapperInitialStyles.length > 0) {
          const styleDesc = gc.wrapperInitialStyles.map(s => `${s.property}: ${s.toValue}`).join(', ');
          sections.push(`  Wrapper styles: ${styleDesc}`);
        }
        sections.push(`  Wrapped: ${gc.wrappedSelectors.map(s => `\`${s}\``).join(', ')}`);
      }
    }
    sections.push('');
  }

  // Text changes section
  if (textEdits.length > 0) {
    sections.push('## Text Changes\n');
    const seen = new Set<string>();
    for (const { diff } of textEdits) {
      if (seen.has(diff.id)) continue;
      seen.add(diff.id);
      for (const tc of diff.textChanges!) {
        const lineInfo = diff.element.sourceLine
          ? ` (line ${diff.element.sourceLine})`
          : '';
        const fromPreview = tc.fromText.length > 60 ? tc.fromText.slice(0, 57) + '...' : tc.fromText;
        const toPreview = tc.toText.length > 60 ? tc.toText.slice(0, 57) + '...' : tc.toText;
        sections.push(
          `- \`${diff.element.selector}\`${lineInfo}: "${fromPreview}" \u2192 "${toPreview}"`,
        );
        // feature-012: when markup is present, emit an un-truncated fenced HTML block
        // following the InsertChange.outerHTML "reproduce exactly" pattern.
        if (tc.toHtml !== undefined) {
          sections.push('  Markup (reproduce exactly):');
          if (tc.fromHtml !== undefined) {
            sections.push('  Before:');
            sections.push('  ```html');
            sections.push(tc.fromHtml);
            sections.push('  ```');
          }
          sections.push('  After:');
          sections.push('  ```html');
          sections.push(tc.toHtml);
          sections.push('  ```');
        }
      }
    }
    sections.push('');
  }

  // Operator notes
  const activeNotes = notes?.filter((n) => n.text.trim()) ?? [];
  if (activeNotes.length > 0) {
    sections.push('## Operator Notes\n');
    for (let i = 0; i < activeNotes.length; i++) {
      const note = activeNotes[i];
      sections.push(`${i + 1}. ${note.text}`);
      // Number each referenced element and prefer its resolved asset path, so a
      // numbering note over a gallery renders `N → /images/<file>` (issue #29).
      for (let e = 0; e < note.elements.length; e++) {
        sections.push(`   ${e + 1} → ${formatNoteRefTarget(note.elements[e])}`);
      }
    }
    sections.push('');
  }

  // Raw JSON in HTML comment for machine parsing
  const raw = JSON.stringify({ diffs, notes: activeNotes });
  sections.push(`<!-- nco-web-editor-raw: ${raw} -->`);

  return sections.join('\n');
}

/**
 * Trailing ` (asset: /images/<file>)` suffix for any element reference carrying
 * a resolved `assetPath` (issue #29). Returns "" for non-asset references.
 */
function formatAssetSuffix(ref: { assetPath?: string }): string {
  return ref.assetPath ? ` (asset: ${ref.assetPath})` : '';
}

/** Compact label for a reordered sibling — asset path when present, else selector. */
function anchorLabel(a: SiblingAnchor): string {
  return a.assetPath ?? a.label ?? a.selector;
}

/** Actionable target for a note element reference — asset path when present. */
function formatNoteRefTarget(ref: NoteElementRef): string {
  if (ref.assetPath) return ref.assetPath;
  if (ref.textContent) return `<${ref.tagName}> "${ref.textContent.slice(0, 30)}"`;
  return `<${ref.tagName}> ${ref.selector}`;
}

/** Describe compound children for prompt output. */
function describeCompoundChildren(
  children: readonly CompoundChildDescriptor[],
): string {
  return children.map(c => {
    let desc = `<${c.tagName}>`;
    if (c.styles && c.styles.length > 0) {
      const styleDesc = c.styles.map(s => `${s.property}: ${s.value}`).join('; ');
      desc += ` {${styleDesc}}`;
    }
    if (c.textContent) desc += ` "${c.textContent}"`;
    if (c.children && c.children.length > 0) {
      desc += ` [${describeCompoundChildren(c.children)}]`;
    }
    return desc;
  }).join(', ');
}

/** Format token info parenthetical, e.g. " (space-4 → space-5)" */
function formatTokenInfo(
  fromToken?: string,
  toToken?: string,
): string {
  if (fromToken && toToken) return ` (${fromToken} \u2192 ${toToken})`;
  if (toToken) return ` (\u2192 ${toToken})`;
  if (fromToken) return ` (${fromToken} \u2192)`;
  return '';
}

/**
 * Format the element-heading breakpoint annotation from PageContext.
 * Returns "" when neither breakpoint nor breakpointValue is present.
 * Handles all four combinations of the two optional fields symmetrically.
 */
function formatBreakpointHeading(
  context: VisualDiff['context'],
): string {
  const { breakpoint, breakpointValue } = context;
  if (breakpoint && breakpointValue) return ` \u2014 @ ${breakpoint} (${breakpointValue})`;
  if (breakpointValue) return ` \u2014 @ ${breakpointValue}`;
  if (breakpoint) return ` \u2014 @ ${breakpoint}`;
  return '';
}

/**
 * Format the per-property source-rule annotation when its media query diverges
 * from the active breakpoint. Extension point reused by downstream consumers.
 *
 * @param source                Cascade-winning rule for the property (RuleSource.mediaQuery
 *                              is expected to be raw CSSOM conditionText, e.g.
 *                              "(min-width: 768px)" — not a design-token name).
 * @param activeBreakpointValue PageContext.breakpointValue (the design-system-resolved
 *                              value, e.g. "768px") — NOT PageContext.breakpoint (the
 *                              token name). The token name is shown separately on the
 *                              element heading and is not used for divergence comparison.
 *
 * Comparison is heuristic: whitespace stripped and lowercased. Token-resolved
 * values (e.g. "768px") will not normalise to conditionText (e.g.
 * "(min-width: 768px)"); divergent annotations are emitted in that case.
 */
export function formatSourceContext(
  source: RuleSource | undefined,
  activeBreakpointValue: string | undefined,
  allBreakpointSources?: readonly CrossBreakpointRuleSource[],
  activeBreakpointLabel?: string,
): string {
  const inline = formatInlineSourceAnnotation(source, activeBreakpointValue);
  const subBullet = formatCrossBreakpointSubBullet(allBreakpointSources, activeBreakpointLabel);
  return inline + subBullet;
}

function formatInlineSourceAnnotation(
  source: RuleSource | undefined,
  activeBreakpointValue: string | undefined,
): string {
  if (!source || !source.mediaQuery) return '';
  const normSource = normaliseMediaQuery(source.mediaQuery);
  const normActive = activeBreakpointValue
    ? normaliseMediaQuery(activeBreakpointValue)
    : '';
  if (normActive && normSource === normActive) return '';
  return ` [@ ${source.mediaQuery}]`;
}

function formatCrossBreakpointSubBullet(
  allBreakpointSources: readonly CrossBreakpointRuleSource[] | undefined,
  activeBreakpointLabel: string | undefined,
): string {
  if (!allBreakpointSources || allBreakpointSources.length === 0) return '';
  // Dedup mediaQuery strings — multiple selectors under the same @media block
  // should appear once. Preserves first-seen order for readability.
  const seen = new Set<string>();
  const queries: string[] = [];
  for (const s of allBreakpointSources) {
    if (!s.mediaQuery || seen.has(s.mediaQuery)) continue;
    seen.add(s.mediaQuery);
    queries.push(s.mediaQuery);
  }
  if (queries.length === 0) return '';
  const label = activeBreakpointLabel ?? 'the active viewport';
  return `\n  - Also defined at: ${queries.join(', ')}. Do not modify these; the active edit applies only to ${label}.`;
}

/**
 * Human-readable label for the active breakpoint to embed in the cross-
 * breakpoint sub-bullet. Mirrors the heading annotation precedence:
 * token name (when present) > breakpoint value > generic fallback.
 */
function formatActiveBreakpointLabel(context: VisualDiff['context']): string {
  if (context.breakpoint && context.breakpointValue) {
    return `${context.breakpoint} (${context.breakpointValue})`;
  }
  if (context.breakpoint) return context.breakpoint;
  if (context.breakpointValue) return context.breakpointValue;
  return 'the active viewport';
}

function normaliseMediaQuery(value: string): string {
  return value.replace(/\s+/g, '').toLowerCase();
}

/**
 * True when any diff carries breakpoint metadata on its context or a
 * source.mediaQuery on any property change, or any allBreakpointSources
 * are present.
 */
function hasResponsiveContext(diffs: readonly VisualDiff[]): boolean {
  for (const d of diffs) {
    if (d.context.breakpoint || d.context.breakpointValue) return true;
    for (const c of d.changes) {
      if (c.source?.mediaQuery) return true;
      if (c.allBreakpointSources && c.allBreakpointSources.length > 0) return true;
    }
  }
  return false;
}
