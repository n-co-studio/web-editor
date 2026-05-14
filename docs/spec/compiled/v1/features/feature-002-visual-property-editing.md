# Feature: Visual Property Editing

## Summary
Edit CSS properties via direct manipulation on the selected element. Drag handles for spacing and dimensions. Dropdowns and pickers for typography and colors. All edits produce structured PropertyChange objects for the diff pipeline.

## User Flow
1. Operator selects an element (via feature-001)
2. Edit handles appear around the element based on context
3. Operator chooses an editing mode:
   - **Spacing**: Drag handles on padding/margin edges
   - **Dimensions**: Drag corner/edge handles for width/height
   - **Typography**: Dropdown for font-size, weight toggle, line-height slider
   - **Colors**: Color picker (constrained to palette when tokens loaded)
   - **Border radius**: Corner drag handles
4. Value updates live on the element during manipulation (preview)
5. On release/confirm, the edit is added to the pending changes queue
6. Operator can continue editing the same element or select another

### Color Picker Modes
- **Token mode**: Swatch grid (5 columns), named swatches, tooltip shows token name and hex on hover. WCAG 1.4.11 non-text contrast applies to swatch borders (3:1 against panel background).
- **Freeform mode**: Hex text input with color preview chip. "Enter custom value" link switches from token mode to freeform inline.

### Keyboard Editing
- Tab cycles through editable properties in the property panel
- Arrow keys step through token stops one at a time (or nudge by 1px in freeform mode)
- Shift+Arrow nudges by larger increments (4px or next token category step)
- Enter/Space commits the current edit
- Typing a number jumps to a specific value
- All drag handle interactions have keyboard equivalents

## UI States
- **Default**: Element selected, no edit active — edit mode buttons visible in property panel
- **Editing**: Handles visible on element, active manipulation in progress — value shown in real-time tooltip near cursor
- **Preview**: Live value applied to element during drag, before/after shown in property panel
- **Committed**: Edit finalized and added to pending queue — handles reset, pending count increments

## Drag Handle Specification
Drag handles render as a 6-8px visual indicator (pill/line) in the overlay color but have an expanded interactive hit area of at least 20px (pointer-events region). For edges narrower than the handle indicator, use a floating handle beside the element. Reference: Chrome DevTools box model inspector pattern.

## Live Preview Mechanism
Live preview applies via CSS custom property mutation (`element.style.setProperty`) rather than direct property mutation, to minimize reflow cost during drag.

## Inputs
- Selected element's `ElementInfo` from feature-001
- Current computed styles of the selected element
- Design tokens from MCP server (if loaded) for value snapping and constraint

## Outputs
- `PropertyChange` objects added to the pending `VisualDiff` queue (consumed by feature-004 batching and feature-005 MCP bridge)

## Edge Cases
- Flexbox/Grid children: flag that parent layout may need editing, include parent ElementInfo in diff
- Percentage-based values: maintain unit type, do not convert to px
- Responsive: changes apply to current viewport only, breakpoint is recorded in diff's PageContext; rules at other viewport-bound `@media` breakpoints may be surfaced on each PropertyChange's `allBreakpointSources` as context-only metadata for the diff consumer (not edit targets)
- Token snapping active: values constrain to token stops (see feature-003 for details)
- Token snapping inactive: freeform values accepted, sent as raw CSS
- CSS custom properties (`var(--x)`) as computed values: `getComputedStyle` returns the resolved value, not the variable reference. Diff records the resolved value — Claude Code must identify and update the variable source if applicable.
- Disabled/read-only elements: can still be visually edited (the extension edits computed styles, not element state)

## Acceptance Criteria
- [ ] Spacing drag handles produce correct padding/margin PropertyChange with before/after values
- [ ] Dimension drag handles produce correct width/height PropertyChange
- [ ] Typography controls produce correct font-size, font-weight, line-height PropertyChange
- [ ] Color picker produces correct color PropertyChange
- [ ] Border radius handles produce correct border-radius PropertyChange
- [ ] Values snap to design tokens when tokens are loaded
- [ ] Unit types are preserved (%, rem, em not converted to px)
- [ ] Flexbox/Grid children include parent element info in the diff
- [ ] Live preview updates the element during manipulation without persisting until confirmed
- [ ] All editing modes operable via keyboard (Tab, Arrow, Enter)
- [ ] Drag handle hit areas are at least 20px regardless of visual indicator size
