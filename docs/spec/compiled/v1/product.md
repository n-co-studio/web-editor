# Product Definition

## Product Name
Frontend Editor - Repo OS

## One-Line Description
Chrome extension + local MCP server that lets operators visually edit live front-end UI and feed deterministic change requests back to Claude Code in VS Code.

## Problem Statement
Operators working on projects inspect the front end and identify visual adjustments — spacing, font sizes, colors, layout shifts. Translating those observations into code changes requires manually describing them in a prompt or hunting through source files. This breaks flow and loses precision. Frontend Editor - Repo OS closes the loop: point, adjust, apply — with deterministic source mapping so changes land in the right file every time.

## Target Users

- **Operator (repo-OS user)**: Wants to make visual tweaks in the browser and have them reflected in source code without writing CSS by hand or describing changes in natural language
- **AI agent (Claude Code)**: Receives structured visual diffs with exact file paths and line numbers, applies precise edits

## Core User Flows

### Flow 1: Visual Edit → Code Change
1. Operator opens their project's dev server in Chrome
2. Activates Frontend Editor - Repo OS extension (toolbar icon or keyboard shortcut)
3. Overlay appears — elements become selectable on hover
4. Operator clicks an element → selection highlight + property panel appears
5. Operator adjusts a property (drag to resize, pick a color, change font size)
6. Extension snaps value to nearest design token and shows token name
7. Operator clicks "Apply Changes" — edit is added to the pending changes queue
8. Extension sends structured diff (file, line, property, old value, new value, token) via WebSocket when operator sends from the review panel
9. MCP server exposes diff to Claude Code
10. Claude Code applies the precise edit to the source file
11. Dev server hot-reloads → operator sees the update in browser

### Flow 2: Batch Edits
1. Operator makes multiple visual edits across different elements
2. Each edit appears in a "pending changes" panel with before/after values
3. Operator reviews the batch, removes any unwanted changes
4. Operator sends the full batch at once
5. Claude Code applies all changes sequentially

### Flow 3: Token-Aware Editing
1. Operator activates extension on a project with a design system
2. MCP server auto-discovers tokens from the project (Tailwind config, design-system.md, or tokens.json)
3. Extension loads tokens and constrains all editing to valid token values
4. Spacing drag handles snap to token stops with visual ruler
5. Color picker shows only palette colors
6. Typography dropdown shows only type scale options

## Success Metrics

- Visual edit → source code update completes in under 30 seconds (including Claude Code processing)
- Source element location (file and line) is deterministic when dev-plugin is installed. CSS rule location may require Claude Code resolution for CSS-in-separate-files patterns (CSS Modules, plain CSS).
- Token snapping resolves correctly for 95%+ of edits when tokens are available
- Works with JSX/TSX projects using Tailwind, plain CSS, and CSS Modules. Dev-plugin required for deterministic source mapping.
- Zero configuration in the target project beyond one MCP server entry in settings.json

## What This Product Is NOT

- Not a browser DevTools replacement
- Not a CSS editor — generates structured change requests, not raw stylesheets
- Not a component library or design system manager
- Not a hosted service — everything runs locally
- Not for production use — dev tooling only
- Does not handle JavaScript behavior changes — visual/CSS properties only
- Does not create or delete components — only edits existing elements
