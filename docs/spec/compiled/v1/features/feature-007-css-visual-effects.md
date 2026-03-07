# Feature: CSS Visual Effects Editing

## Summary
Edit CSS visual effects via a dedicated "Effects" panel on the selected element. Slider controls for CSS filter functions (hue-rotate, saturate, brightness, contrast, blur, grayscale, sepia, invert, drop-shadow). Named filter presets for common compositions. Dropdown for mix-blend-mode with automatic parent isolation. Basic clip-path shapes (circle, inset) with drag handles. All edits produce structured PropertyChange objects for the diff pipeline.

## User Flow
1. Operator selects an element (via feature-001)
2. Operator opens the "Effects" panel from the toolbar (same pattern as MediaEditor)
3. Panel shows sections: Filters, Blend Mode, Clip Path
4. Operator chooses an editing mode:
   - **Filter presets**: Named preset dropdown ("None", "Warm", "Cool", "Vintage", "High Contrast", "Soft", "Desaturate") applies a pre-composed filter chain
   - **Filter sliders**: "Advanced" disclosure triangle reveals per-function sliders for individual filter tuning
   - **Blend mode**: Dropdown with 16 mix-blend-mode values; selecting a non-normal value auto-adds `isolation: isolate` to the parent element when needed
   - **Clip path**: Shape selector (circle, inset) with drag handles on the element overlay
5. Value updates live on the element during manipulation (preview)
6. On release/confirm, the edit is added to the pending changes queue
7. Operator can continue editing the same element or select another

### Filter Presets
Pre-composed filter chains selectable by name. Operator picks a preset, sees the effect immediately. "Advanced" disclosure reveals the underlying per-function sliders, pre-populated with the preset's values, allowing fine-tuning.

| Preset | Filter Chain |
|--------|-------------|
| None | none |
| Warm | saturate(1.2) hue-rotate(10deg) brightness(1.05) |
| Cool | saturate(0.9) hue-rotate(-15deg) brightness(1.02) |
| Vintage | sepia(0.3) contrast(1.1) brightness(0.95) saturate(1.2) |
| High Contrast | contrast(1.4) brightness(1.05) |
| Soft | blur(0.5px) brightness(1.1) contrast(0.95) |
| Desaturate | grayscale(0.7) brightness(1.05) |

Presets are hardcoded in v1. A future version may source them from a design token category (`filters`).

### Filter Slider Ranges

| Function | Range | Default | Step | Unit |
|----------|-------|---------|------|------|
| hue-rotate | -180 to 180 | 0 | 1 | deg |
| saturate | 0 to 3 | 1 | 0.05 | (ratio) |
| brightness | 0 to 3 | 1 | 0.05 | (ratio) |
| contrast | 0 to 3 | 1 | 0.05 | (ratio) |
| blur | 0 to 20 | 0 | 0.5 | px |
| grayscale | 0 to 1 | 0 | 0.05 | (ratio) |
| sepia | 0 to 1 | 0 | 0.05 | (ratio) |
| invert | 0 to 1 | 0 | 0.05 | (ratio) |

Drop-shadow is a separate control with inputs for x-offset, y-offset, blur-radius, and color (reusing the color picker from feature-002).

### Blend Mode Values
The 16 standard `mix-blend-mode` values: `normal`, `multiply`, `screen`, `overlay`, `darken`, `lighten`, `color-dodge`, `color-burn`, `hard-light`, `soft-light`, `difference`, `exclusion`, `hue`, `saturation`, `color`, `luminosity`.

### Clip Path Shapes (v1)
- **circle()**: Single drag handle for radius, center inferred from element center. Produces `clip-path: circle(Rpx at 50% 50%)`.
- **inset()**: Four edge drag handles (top, right, bottom, left). Produces `clip-path: inset(Tpx Rpx Bpx Lpx)`.
- **polygon()**: Deferred to desktop app — too complex for overlay-based editing.

## UI States
- **Default**: Element selected, no effects active — "Effects" button visible in toolbar
- **Panel open**: Effects panel visible as a floating panel anchored to the toolbar (same positioning as MediaEditor)
- **Preset active**: Selected preset name highlighted, filter applied live
- **Advanced open**: Disclosure expanded, individual sliders visible with current values
- **Blend mode active**: Dropdown shows current value, parent isolation indicator shown if `isolation: isolate` was added
- **Clip path active**: Shape overlay visible on element with drag handles, shape selector shows current type
- **Committed**: Edit finalized and added to pending queue — pending count increments

## Panel Specification
The Effects panel renders as a floating dialog (same pattern as `MediaEditor` in `packages/chrome-extension/src/content/editing/media.ts`): fixed position, anchored to toolbar, draggable by header, 240px width. Sections are collapsible. The panel reuses `createElement`, `createText`, `createButton`, `makeDraggable` from `shared/ui-utils` and follows the same OVERLAY constants for styling.

## Live Preview Mechanism
Live preview applies filter and clip-path changes via `element.style.setProperty` (same as feature-002). For blend mode with parent isolation, the parent element's style is also mutated during preview. Preview changes are reverted if the operator cancels.

## Inputs
- Selected element's `ElementInfo` from feature-001
- Current computed `filter`, `mix-blend-mode`, and `clip-path` of the selected element
- Current computed `isolation` of the selected element's parent (for blend mode dependency detection)

## Outputs
- `PropertyChange` objects added to the pending `VisualDiff` queue (consumed by feature-004 batching and feature-005 MCP bridge)
- When blend mode requires parent isolation: a `VisualDiff` with `relatedChanges` containing the parent's `PropertyChange` for `isolation`

## Edge Cases
- **Multiple filter functions compose into a single `filter` property**: The extension builds the full `filter` string from all active slider values (e.g., `saturate(1.2) hue-rotate(10deg) blur(2px)`). The `PropertyChange` records the complete `filter` string as `toValue`, not individual functions. Parsing the existing `filter` into individual function values happens at panel open time.
- **Blend mode requiring parent context change**: When `mix-blend-mode` is set to any non-`normal` value and the parent does not already have `isolation: isolate`, the extension adds a `relatedChanges` entry to the `VisualDiff`. The parent's `ElementInfo` is captured and a `PropertyChange` for `isolation` is included. This ensures Claude Code applies both changes atomically.
- **Interaction with MediaEditor for `<img>` elements**: Both MediaEditor and EffectsEditor can operate on the same element. They edit orthogonal properties (src/object-fit vs filter/blend-mode/clip-path). Only one panel is open at a time — opening Effects closes Media and vice versa.
- **Existing filter values**: When the element already has a `filter` value, the panel parses it into individual function values and pre-populates the sliders. Unrecognized filter functions are preserved as-is and appended to the composed string.
- **clip-path with existing complex values**: If the element has a `clip-path` value that is not `circle()` or `inset()` (e.g., `polygon()`, `url()`), the clip-path section shows the raw value as read-only text. Editing is not offered for unsupported shapes.
- **Blend mode on stacking context elements**: Elements that already establish a stacking context (e.g., positioned with z-index, transform, opacity < 1) may not need parent isolation. The extension adds `isolation: isolate` conservatively — Claude Code can optimize during application.
- **Token snapping**: Filter values are numeric and do not snap to design tokens. Blend mode values are enumerated and do not snap. Clip-path values are geometric and do not snap. Token integration is not applicable for this feature.

## Acceptance Criteria
- [ ] Filter preset dropdown applies the correct composed filter string and produces a `PropertyChange` with before/after values
- [ ] "Advanced" disclosure reveals per-function sliders pre-populated from the current filter or selected preset
- [ ] Individual slider adjustments recompose the full filter string and produce a single `PropertyChange` for the `filter` property
- [ ] Drop-shadow control produces correct `drop-shadow()` function with x, y, blur, and color values
- [ ] `mix-blend-mode` dropdown produces correct `PropertyChange`
- [ ] Selecting a non-normal blend mode on an element whose parent lacks isolation produces a `VisualDiff` with `relatedChanges` containing the parent's `isolation: isolate` change
- [ ] `clip-path` circle() drag handle produces correct `PropertyChange` for `clip-path`
- [ ] `clip-path` inset() four-edge handles produce correct `PropertyChange` for `clip-path`
- [ ] Unsupported `clip-path` values are shown read-only, not editable
- [ ] Existing filter values are parsed into individual slider positions on panel open
- [ ] Live preview updates the element during manipulation without persisting until confirmed
- [ ] Effects panel follows the same floating panel pattern as MediaEditor (positioning, dragging, styling)
- [ ] Opening Effects panel closes MediaEditor and vice versa
