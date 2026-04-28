import type { VisualDiff, NoteEntry, CompoundChildDescriptor } from '@frontend-editor/shared';

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

  sections.push('# Visual Changes from Frontend Editor\n');

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
      // Element heading with selector and optional line number
      const lineInfo = diff.element.sourceLine
        ? ` (line ${diff.element.sourceLine})`
        : '';
      sections.push(`### \`${diff.element.selector}\`${lineInfo}\n`);

      // Property changes
      for (const c of diff.changes) {
        const tokenInfo = formatTokenInfo(c.fromToken, c.toToken);
        sections.push(
          `- \`${c.property}\`: ${c.fromValue} \u2192 ${c.toValue}${tokenInfo}`,
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
        if (ic.prevSibling) bracketInfo.push(`after ${ic.prevSibling.sourceFile}:${ic.prevSibling.sourceLine}`);
        if (ic.nextSibling) bracketInfo.push(`before ${ic.nextSibling.sourceFile}:${ic.nextSibling.sourceLine}`);
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
      }
    }
    sections.push('');
  }

  // Operator notes
  const activeNotes = notes?.filter((n) => n.text.trim()) ?? [];
  if (activeNotes.length > 0) {
    sections.push('## Operator Notes\n');
    for (let i = 0; i < activeNotes.length; i++) {
      sections.push(`${i + 1}. ${activeNotes[i].text}`);
    }
    sections.push('');
  }

  // Raw JSON in HTML comment for machine parsing
  const raw = JSON.stringify({ diffs, notes: activeNotes });
  sections.push(`<!-- frontend-editor-raw: ${raw} -->`);

  return sections.join('\n');
}

/** Describe compound children for prompt output. */
function describeCompoundChildren(
  children: readonly CompoundChildDescriptor[],
): string {
  return children.map(c => {
    let desc = `<${c.tagName}>`;
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
