# Editor Log

Usage notes, lessons learned, and ideas for the n'co studio Web Editor extension.

---

## Format

Each entry follows this structure:

```
### YYYY-MM-DD — Short title

**Context:** What you were doing
**Observation:** What happened / what you noticed
**Action:** Fix needed, improvement idea, or lesson learned
**Priority:** low | medium | high
**Status:** open | fixed | wontfix
```

---

## Entries

<!-- Add new entries at the top -->

### 2026-02-19 — MCP changes produce incorrect CSS for positioned elements

**Context:** Trying to align nav links using the MCP-generated CSS changes. The MCP was asked to reposition elements and adjust their widths.

**Observation:** The MCP changes didn't work correctly for two reasons:

1. **Computed left pixel values vs authored right rem values** — The MCP read `getComputedStyle` values (e.g. `left: 342px`) and tried to set new pixel-based left positions. But the elements were actually positioned using `right` in rem units in the authored CSS. Setting `left` in pixels conflicted with the existing `right` declarations and produced wrong results.

2. **`width: fit-content` was a no-op** — The MCP set `width: fit-content` on elements that already sized themselves to their content. This change did nothing visible because it matched the existing intrinsic behavior.

**Why the flex solution works:** Instead of fighting individual positioning, using flexbox on the parent container (`display: flex`, `gap`) lets the browser handle spacing and alignment naturally. The elements flow correctly without needing to compute absolute positions.

**Action:** The MCP (and by extension, the editor's diff pipeline) needs to:
1. **Resolve to authored values** — Read the actual stylesheet declarations, not just computed values, so changes target the right properties and units
2. **Understand positioning context** — Know whether an element is positioned via `left`, `right`, `top`, `bottom`, and in what units, before suggesting position changes
3. **Detect no-ops** — Recognize when a proposed change (like `width: fit-content` on an already-intrinsically-sized element) won't have any visible effect
4. **Suggest structural changes** — When individual property tweaks won't work, recommend layout-level changes (e.g. switching to flexbox) instead of piecemeal position adjustments

**Priority:** high
**Status:** open
