# Design System

The visual language for the project. Defaults are baked in and ready to use as-is.
Override any value with your brand, or replace entirely via Figma MCP.

## Source
<!-- Check one. Delete the others. -->

- [ ] **Defaults** — Using the built-in values below as-is
- [ ] **Brand guide** — Values overridden from brand guide (source: ___)
- [ ] **Figma** — Values extracted via Figma MCP (file URL: ___)

---

## Spacing

Base unit: **4px** — all spacing is a multiple of 4.

| Token | Value | Use |
|-------|-------|-----|
| space-1 | 4px | Tight gaps, icon padding |
| space-2 | 8px | Inline spacing, small gaps |
| space-3 | 12px | Compact component padding |
| space-4 | 16px | Default component padding, form gaps |
| space-5 | 20px | Card padding |
| space-6 | 24px | Section gaps, comfortable padding |
| space-8 | 32px | Large section gaps |
| space-10 | 40px | Section margins |
| space-12 | 48px | Page section spacing |
| space-16 | 64px | Major section dividers |

---

## Typography

### Font Families
- **Sans (primary)**: Inter, system-ui, -apple-system, sans-serif
- **Mono (code)**: JetBrains Mono, Fira Code, Consolas, monospace

### Type Scale

| Token | Size | Weight | Line Height | Use |
|-------|------|--------|-------------|-----|
| display | 2.25rem (36px) | 800 | 1.2 | Hero headings |
| h1 | 1.875rem (30px) | 700 | 1.25 | Page titles |
| h2 | 1.5rem (24px) | 700 | 1.3 | Section headings |
| h3 | 1.25rem (20px) | 600 | 1.35 | Subsection headings |
| h4 | 1rem (16px) | 600 | 1.4 | Card/component headings |
| body | 1rem (16px) | 400 | 1.6 | Paragraph text |
| body-sm | 0.875rem (14px) | 400 | 1.5 | Secondary text, captions |
| caption | 0.75rem (12px) | 500 | 1.4 | Labels, metadata, timestamps |

---

## Breakpoints

| Token | Value | Target |
|-------|-------|--------|
| sm | 640px | Large phones (landscape) |
| md | 768px | Tablets |
| lg | 1024px | Small laptops |
| xl | 1280px | Desktops |
| 2xl | 1536px | Large screens |

**Mobile-first**: Base styles target phones. Use `min-width` media queries to scale up.

---

## Colors

### Neutrals (Zinc scale)

| Token | Value | Use |
|-------|-------|-----|
| gray-50 | #fafafa | Page backgrounds |
| gray-100 | #f4f4f5 | Subtle backgrounds, stripes |
| gray-200 | #e4e4e7 | Borders, dividers |
| gray-300 | #d4d4d8 | Disabled states, subtle borders |
| gray-400 | #a1a1aa | Placeholder text |
| gray-500 | #71717a | Secondary text |
| gray-600 | #52525b | Body text |
| gray-700 | #3f3f46 | Headings (light mode) |
| gray-800 | #27272a | Primary text |
| gray-900 | #18181b | High contrast text |
| gray-950 | #09090b | Near black |

### Brand Colors
<!-- Replace [DEFINE] with your hex values. -->

| Token | Value | Use |
|-------|-------|-----|
| primary | [DEFINE] | Primary actions, links, key UI elements |
| primary-hover | [DEFINE] | Hover state for primary |
| primary-light | [DEFINE] | Subtle backgrounds, highlights |
| accent | [DEFINE] | Secondary actions, highlights |
| accent-hover | [DEFINE] | Hover state for accent |

### Semantic Colors

| Token | Value | Use |
|-------|-------|-----|
| destructive | #ef4444 | Destructive actions, errors |
| success | #22c55e | Success states, confirmations |
| warning | #f59e0b | Warnings, caution |
| info | #3b82f6 | Informational highlights |

---

## Border Radius

| Token | Value | Use |
|-------|-------|-----|
| none | 0 | Sharp corners |
| sm | 4px | Inputs, buttons |
| md | 8px | Cards, panels |
| lg | 12px | Modals, large cards |
| xl | 16px | Feature cards, hero elements |
| full | 9999px | Pills, avatars, circular |

---

## Shadows

| Token | Value | Use |
|-------|-------|-----|
| sm | 0 1px 2px rgba(0,0,0,0.05) | Buttons, inputs |
| md | 0 4px 6px rgba(0,0,0,0.07) | Cards, dropdowns |
| lg | 0 10px 15px rgba(0,0,0,0.10) | Modals, popovers |
| xl | 0 20px 25px rgba(0,0,0,0.12) | Feature highlights |

---

## Layout

| Property | Value |
|----------|-------|
| Max content width | 1280px |
| Max prose width | 65ch |
| Page gutter (mobile) | 16px |
| Page gutter (desktop) | 24px |
| Grid columns | 12 |
| Grid gap (mobile) | 16px |
| Grid gap (desktop) | 24px |

---

## Component Patterns

### Buttons
- Padding: 8px vertical, 16px horizontal
- Border radius: sm (4px)
- Font: body-sm (14px), weight 500
- Min height: 36px (sm) / 40px (md) / 44px (lg)
- Touch target: minimum 44px

### Inputs
- Padding: 8px vertical, 12px horizontal
- Border: 1px solid gray-300
- Border radius: sm (4px)
- Font: body (16px) — prevents zoom on iOS
- Min height: 40px

### Cards
- Padding: 20px or 24px
- Border: 1px solid gray-200
- Border radius: md (8px)
- Shadow: sm or md

---

## Figma MCP Integration

If using Figma as the design source:

1. Connect the Figma MCP server to your IDE
2. During Prompt 0, the AI will query Figma for design tokens, component specs, and layout details
3. Extracted values replace the defaults above
4. Every extracted value is presented for operator review before being written
5. Use Code Connect to map Figma components to your actual codebase components
