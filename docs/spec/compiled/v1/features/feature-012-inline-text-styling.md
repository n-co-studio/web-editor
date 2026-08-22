# Feature: Inline Text Styling

## Summary

While in text edit mode (contenteditable), the operator can select a sub-range of text and apply
semantic inline formatting via a floating mini-toolbar. Supported formats are **Bold** (`<strong>`),
**Italic** (`<em>`), **Underline** (`<u>`), **Strikethrough** (`<s>`), and **Clear Formatting**.
Toggling a format wraps or unwraps the selected range in the corresponding semantic element.
On blur or Enter the entire session's markup is committed as a single `TextChange` — with the new
`toHtml` field carrying the markup and `toText` carrying the plain-text fallback. Escape restores
the exact pre-edit `innerHTML`. See [data-contracts.md § TextChange](../data-contracts.md#textchange)
for the contract.

**Out of scope (explicitly deferred):**
- Per-word color or font-size changes (breaks element-scoped `PropertyChange` / token-snapping model)
- Link editing (future feature candidate)
- Paste of rich HTML (paste is forced to plain text; this is intentional)

Shared UI conventions follow [feature-002 Visual Property Editing](feature-002-visual-property-editing.md).
Design tokens reference [design-system.md § Overlay Colors](../design-system.md#overlay-colors).

---

## User Flow

1. Operator enters text edit mode on a selected element (existing text-mode activation path).
2. Operator selects a sub-range of text inside the contenteditable.
3. The mini-toolbar appears **above** the selection (flips below when the selection is within
   `TOOLBAR_HEIGHT + VIEWPORT_MARGIN` px of the viewport top; clamps horizontally to keep within
   the viewport).
4. Operator clicks a format button (Bold, Italic, Underline, Strikethrough) **or** uses the
   keyboard shortcut (Cmd/Ctrl+B, Cmd/Ctrl+I, Cmd/Ctrl+U):
   - The DOM updates **immediately** (live preview — no pending queue step).
   - The button reflects the new state (active/inactive/mixed).
5. Operator continues selecting and formatting additional ranges as desired.
6. On **blur** or **Enter**, the editor commits **one** `TextChange` for the whole session:
   - `fromText` / `fromHtml` — captured at edit-session start (pre-edit plain text / inner HTML).
   - `toText` / `toHtml` — captured at commit time (post-edit plain text / inner HTML after
     allowlist sanitization).
7. On **Escape**, the element's `innerHTML` is restored to the exact pre-edit markup (including
   any markup that existed before the edit session started, e.g. native Cmd+B output).

### Toolbar Repositioning

The toolbar re-runs its position calculation on:
- `selectionchange` (range changed — may show/hide toolbar)
- `scroll` (window or any scrollable ancestor)
- `resize` (window)

The toolbar is **hidden** whenever the selection is collapsed (no characters selected) or falls
outside the edited element.

---

## UI States

### Toolbar Container

| Property | Value |
|----------|-------|
| `role` | `toolbar` |
| `aria-label` | `"Text formatting"` |
| Background | OVERLAY token: `rgba(0,0,0,0.85)` |
| Border | OVERLAY token: `rgba(255,255,255,0.15)`, 1px solid |
| Border radius | `4px` |
| `z-index` | `102` (above selection overlay at 100, above panel at 101) |
| Entry animation | opacity 0→1 + 4px upward rise, `150ms ease-out` |
| Reduced motion | `@media (prefers-reduced-motion: reduce)` — skip animation, snap to final state |

### Format Buttons

Each button is 32×32px. Icons are 16×16px `currentColor`.

| State | Visual | ARIA |
|-------|--------|------|
| **Inactive** | No background | `aria-pressed="false"` |
| **Active** | `#06b6d4` (primary) at 12% opacity background | `aria-pressed="true"` |
| **Mixed** | `#06b6d4` at 8% opacity background | `aria-pressed="mixed"` |
| **Toolbar hidden** | Toolbar not in DOM / `display:none` | — (no collapsed-selection state button; toolbar hides entirely) |

**Mixed state** applies when the selection spans text that is partially styled and partially unstyled
for that format. Mixed → apply (same rule as toggle semantics below).

**Interaction model:** buttons use `mousedown` + `event.preventDefault()` so clicking never blurs
the contenteditable before the handler fires.

### Keyboard Shortcuts

| Action | Shortcut |
|--------|---------|
| Bold | Cmd/Ctrl+B |
| Italic | Cmd/Ctrl+I |
| Underline | Cmd/Ctrl+U |
| Strikethrough | *(button only — no standard shortcut)* |
| Clear Formatting | *(button only)* |

Shortcuts are intercepted in the text editor's `keydown` handler and must not conflict with the
host page or the extension's own shortcut layer. See text-edit shortcut conflict notes.

---

## Inputs

- Selected element's `ElementInfo` from feature-001 (element identity for TextChange)
- `originalHtml` — captured from `element.innerHTML` at the moment text edit mode is activated
- `originalText` — captured from `element.textContent` at activation (plain-text fallback)
- Current `Selection` and `Range` from `window.getSelection()` inside the Shadow DOM boundary

---

## Outputs

- One `TextChange` object per text edit session (appended to the pending `VisualDiff` queue on
  commit, consumed by feature-004 batching and feature-005 MCP bridge):
  - `type: 'text'`
  - `fromText: string` — pre-edit plain text (required)
  - `toText: string` — post-edit plain text after sanitization (required)
  - `fromHtml?: string` — pre-edit `innerHTML` (present only when markup was present before or
    was added during the session)
  - `toHtml?: string` — post-edit `innerHTML` after allowlist sanitization (present when markup
    is present in the committed result)

See [data-contracts.md § TextChange](../data-contracts.md#textchange) for the full contract and
Source Rewrite Semantics.

---

## Edge Cases

### 1. Selection partially overlapping an existing inline element

`Range.surroundContents()` throws `HierarchyRequestError` when the range only partially contains
an element (e.g. the selection starts inside an `<a>` but ends after it).

**Resolution:** The mechanism is `range.extractContents()` → wrap the resulting `DocumentFragment`
(or iterate text nodes via `TreeWalker`) → `range.insertNode(wrappedFragment)`. This splits
boundary nodes natively. Element boundaries (links, existing spans) are preserved; the format
wrapper encloses only the text on each side of the boundary separately. `Node.normalize()` is
called on the edited element after every toggle to merge adjacent text nodes.

### 2. Toggle semantics

- **Any text in the range is unstyled** → apply the format to the whole range.
- **All text in the range is uniformly styled with this format** → unwrap. When the selection is
  a sub-range of the existing wrapper, the wrapper is split into up to three pieces: pre-selection
  (retains wrapper), selection (unwrapped), post-selection (retains wrapper).
- **Mixed** (some styled, some not) → apply to the whole range (bring unstyled portions up).

### 3. Normalization after every toggle

After each format toggle, a pure function `normalizeInlineMarkup(el: HTMLElement): void` runs on
the edited element. It:
1. Merges adjacent identical wrappers (e.g. two consecutive `<strong>` → one `<strong>`).
2. Removes empty wrappers (elements with no text content).
3. Calls `Node.normalize()` to merge adjacent text nodes.

This is idempotent — repeated toggle-storms converge to clean, minimal markup.

### 4. Collapsed selection

When the selection is collapsed (cursor position only, no characters selected), the toolbar is
hidden. Format commands (keyboard shortcuts and button clicks) are **no-ops** — no empty tags are
inserted.

### 5. Selection extending outside the edited element

The active selection may extend beyond the contenteditable element's boundary (e.g. operator
accidentally drags outside). The editor clamps the range to the element's boundaries by
intersecting the live `Range` with the element's `Range` before applying any format. If the
clamped intersection is empty, the operation is a no-op.

### 6. Element already contains markup pre-edit (including native Cmd+B output)

Chrome's native Cmd+B emits `<b>` tags inside a contenteditable even today. Without this feature,
the prior `TextEditor` implementation captured only `textContent` at commit, silently stripping all
markup — a live bug that this feature fixes.

**Resolution:** At edit-session start, `originalHtml` is captured from `element.innerHTML` (not
`textContent`). On Escape, `element.innerHTML = originalHtml` restores the exact pre-edit markup.
On commit, `toHtml` carries the full post-edit markup (after allowlist sanitization strips any
disallowed tags such as native `<b>` and `<i>`, replacing them with the semantic equivalents
`<strong>` and `<em>` during sanitization).

### 7. Multi-line content (`<br>` from Shift+Enter)

`<br>` elements survive `innerHTML` capture, commit, and restore. The plain-text fallback
`toText` uses `textContent`, which loses `<br>` structure (all text on one run). Downstream
consumers that support `toHtml` receive the accurate multi-line markup. The `<br>` tag is included
in the serialization allowlist.

### 8. Serialization allowlist at commit

At commit, `toHtml` is produced by a hand-rolled DOM walker (no DOMPurify dependency — input is
operator-driven, paste is plain-text-forced). The allowlist is:

| Allowed tag | Semantic meaning |
|-------------|-----------------|
| `<strong>` | Bold |
| `<em>` | Italic |
| `<u>` | Underline |
| `<s>` | Strikethrough |
| `<br>` | Line break |

**Zero attributes** are permitted on any tag. All other tags are either:
- Replaced by their semantic equivalent during toggle (e.g. native `<b>` → `<strong>`, `<i>` → `<em>`), or
- Stripped (tag removed, text content preserved) by the sanitizer at commit time.

The WCAG H49 requirement (semantic markup only — no `<b>` or `<i>`) is enforced both during
toggle application and at sanitization.

---

## Acceptance Criteria

- [ ] Mini-toolbar appears above the selection when text is selected within text edit mode;
      flips below when within `TOOLBAR_HEIGHT + VIEWPORT_MARGIN`px of viewport top; clamps
      horizontally to remain within the viewport.
- [ ] Toolbar is hidden when the selection is collapsed or when no text edit session is active.
- [ ] Bold, Italic, Underline, Strikethrough buttons correctly toggle semantic wrap/unwrap on the
      selected range.
- [ ] Keyboard shortcuts Cmd/Ctrl+B, Cmd/Ctrl+I, Cmd/Ctrl+U trigger the corresponding format.
- [ ] Clear Formatting removes all inline format wrappers (`strong`, `em`, `u`, `s`) from the
      selection, leaving plain text.
- [ ] Button `aria-pressed` state reflects active/inactive/mixed correctly for each format.
- [ ] Toolbar container has `role="toolbar"` and `aria-label="Text formatting"`.
- [ ] Pressing Escape restores `innerHTML` to the exact pre-edit markup (including any markup
      present before the session, e.g. from prior edits or native Cmd+B).
- [ ] Pressing Enter or blurring commits exactly one `TextChange`; `toHtml` is present when the
      committed result contains markup; `fromText`/`toText` are always present.
- [ ] `toHtml` passes through only `strong`, `em`, `u`, `s`, `br` tags with zero attributes.
- [ ] No `<b>` or `<i>` tags appear in `toHtml` (WCAG H49).
- [ ] Selections partially overlapping existing inline elements (e.g. `<a>`, `<strong>`) do not
      throw; markup on both sides of the boundary is handled correctly.
- [ ] `normalizeInlineMarkup` merges adjacent identical wrappers and removes empty wrappers after
      every toggle.
- [ ] `prefers-reduced-motion` suppresses the toolbar entry animation.
- [ ] Multi-line content (`<br>`) survives commit and restore via `innerHTML`.
- [ ] No format buttons appear when the selection is collapsed; no empty tags are inserted.
