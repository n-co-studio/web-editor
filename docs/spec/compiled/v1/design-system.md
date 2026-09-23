# Design System

The visual language for the project. This is a developer tool overlay — minimal, utility-focused UI that contrasts with any host page.

<!-- Tokens defined here can be consumed by companion tools (e.g., Visual Web Editor for AI Agents)
     that read this file to enable design-system-aware editing. Use the table format
     consistently: | Token | Value | Use | -->

## Source

- [x] **Defaults** — Using the built-in values below as-is
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
- **Sans (primary)**: system-ui, -apple-system, sans-serif
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

**Overlay note:** Extension overlay UI primarily uses `body-sm` (14px) and `caption` (12px) to remain unobtrusive on the host page.

### Overlay Type Scale

Permitted sizes within the Shadow DOM overlay context. Matches Chrome DevTools and VS Code panel density.

| Token | Size | Weight | Use |
|-------|------|--------|-----|
| overlay-heading | 13px | 600 | Panel titles |
| overlay-body | 12px | 400 | Property labels and values |
| overlay-mono | 11px | 400 | CSS values, token names, file paths |

The larger type scale tokens (display through h4) are available for the extension's popup page and non-overlay surfaces only. They must not be used inside the Shadow DOM overlay.

---

## Breakpoints

This is a desktop-only Chrome extension overlay. Breakpoints apply to overlay panel positioning, not mobile responsiveness.

| Token | Value | Target |
|-------|-------|--------|
| compact | 1024px | Small laptops — property panel uses bottom-sheet style |
| standard | 1280px | Desktops — property panel uses side panel (default) |

---

## Colors

### Neutrals (Tailwind Zinc scale)

| Token Range | Values | Use |
|-------------|--------|-----|
| gray-50–100 | #fafafa, #f4f4f5 | Page backgrounds, subtle fills |
| gray-200–300 | #e4e4e7, #d4d4d8 | Borders, dividers, disabled states |
| gray-400–500 | #a1a1aa, #71717a | Placeholder text, secondary text |
| gray-600–700 | #52525b, #3f3f46 | Body text, headings (light mode) |
| gray-800–950 | #27272a, #18181b, #09090b | Primary text, high contrast, near black |

### Brand Colors
<!-- Finalized by UX Strategist advisory board review — optimized for dark overlay contrast. -->

| Token | Value | Use |
|-------|-------|-----|
| primary | #06b6d4 | Selection highlights, active UI elements, key actions (Cyan 500, 5.1:1 on dark overlay) |
| primary-hover | #0891b2 | Hover state for primary (Cyan 600) |
| primary-light | #cffafe | Subtle backgrounds, selection tints (Cyan 100) |
| accent | #fb7185 | Secondary highlights, batch/queue indicators (Rose 400) |
| accent-hover | #f43f5e | Hover state for accent (Rose 500) |

### Overlay Colors
<!-- Dark overlay theme for contrast against any host page. -->

| Token | Value | Use |
|-------|-------|-----|
| overlay-bg | rgba(0, 0, 0, 0.85) | Panel backgrounds |
| overlay-bg-subtle | rgba(0, 0, 0, 0.65) | Tooltip backgrounds |
| overlay-text | #ffffff | Primary overlay text |
| overlay-text-muted | #a1a1aa | Secondary overlay text |
| overlay-border | rgba(255, 255, 255, 0.15) | Panel borders, dividers |

### Semantic Colors

| Token | Value | Use |
|-------|-------|-----|
| destructive | #ef4444 | Destructive actions, errors |
| success | #22c55e | Success states, confirmations |
| warning | #f59e0b | Warnings, caution |
| info | #3b82f6 | Informational highlights |

**Note:** The `info` token (#3b82f6) remains blue — its semantic meaning (informational) is independent of the brand color change from blue to cyan.

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

| Component | Padding | Radius | Font | Min Height | Notes |
|-----------|---------|--------|------|------------|-------|
| Button | 8px / 16px | sm (4px) | body-sm, 500 | 36/40/44px (sm/md/lg) | Touch target ≥44px |
| Input | 8px / 12px | sm (4px) | body (16px) | 40px | 16px prevents iOS zoom |
| Card | 20–24px | md (8px) | — | — | Border: gray-200, shadow: sm/md |
