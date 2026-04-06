#!/usr/bin/env bash
# A3 Design Token Enforcement — helper for pre-commit-gates.sh.
# Sourced (not standalone). Provides progressive design token checks.
#
# A3: Design Token Enforcement (Progressive)
# Activation: Install eslint-plugin-tailwindcss + custom design-token rules in child repo.
# Generate .tokens-manifest.json via `npm run tokens:build`.
# Gate is inert until tooling detected. Advisory when grep-only. Blocking when ESLint active.
#
# Exports:
#   check_design_token_tooling() — 0 if tooling present, 1 if absent
#   run_eslint_staged()          — runs ESLint on staged frontend files, returns exit code
#   run_grep_fallback()          — regex scan on staged diff, echoes findings, returns 0/1
#   get_staged_frontend_files()  — staged .tsx/.ts/.css files in src/ only
#
# ## Consumers (auto-generated — run .claude/tools/hook-dep-map.sh for live data)
#   Hooks: pre-commit-gates

# Guard against direct execution
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "Error: _a3-design-token-check.sh must be sourced, not executed directly." >&2
  exit 1
fi

# --- Path allowlist ---
# Files matching these patterns are exempt from A3 token enforcement.
# Checked in get_staged_frontend_files() to pre-filter the file list.
_a3_is_exempt() {
  local f="$1"
  case "$f" in
    # Token build pipeline — necessarily contains raw values
    src/shared/tokens/*)          return 0 ;;
    # Test and fixture files
    *.test.tsx|*.test.ts)         return 0 ;;
    *.spec.tsx|*.spec.ts)         return 0 ;;
    *.stories.tsx)                return 0 ;;
    # Generated type definitions
    *.d.ts)                       return 0 ;;
    # Build config
    tailwind.config.*|postcss.config.*) return 0 ;;
    # Non-frontend (outside src/) — handled by get_staged_frontend_files()
    *) return 1 ;;
  esac
}

# --- get_staged_frontend_files ---
# Returns staged .tsx/.ts/.css files within src/ that are not on the allowlist.
# One file per line. Empty output = no frontend files staged.
get_staged_frontend_files() {
  local files
  files=$(git diff --cached --name-only --diff-filter=ACMR -- 'src/*.tsx' 'src/**/*.tsx' \
    'src/*.ts' 'src/**/*.ts' 'src/*.css' 'src/**/*.css' 2>/dev/null || true)
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    _a3_is_exempt "$f" && continue
    printf '%s\n' "$f"
  done <<< "$files"
}

# --- check_design_token_tooling ---
# Returns 0 if BOTH ESLint token rules AND .tokens-manifest.json are present.
# Returns 1 if neither is present (inert/advisory mode).
# Partial: only one present → still advisory (Stage 1 advisory fires, not fully active).
check_design_token_tooling() {
  local has_eslint=false
  local has_manifest=false

  # Check for ESLint plugin with token rules in package.json
  if [ -f package.json ]; then
    if grep -qE '"eslint-plugin-tailwindcss"|"eslint-plugin-design-tokens"' package.json 2>/dev/null; then
      has_eslint=true
    fi
  fi

  # Check for token manifest
  [ -f ".tokens-manifest.json" ] && has_manifest=true

  [ "$has_eslint" = true ] && [ "$has_manifest" = true ] && return 0
  return 1
}

# --- run_eslint_staged ---
# Runs ESLint on staged frontend files.
# Returns ESLint exit code (0 = clean, 1 = violations, 2 = config error).
# Outputs ESLint findings to stdout for capture by caller.
run_eslint_staged() {
  local staged_files
  staged_files=$(get_staged_frontend_files)

  if [ -z "$staged_files" ]; then
    return 0
  fi

  if ! command -v npx &>/dev/null; then
    echo "A3 ADVISORY: npx not found — ESLint check skipped" >&2
    return 0
  fi

  # Build space-separated file list for ESLint CLI
  local file_args=""
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    file_args="${file_args:+$file_args }$f"
  done <<< "$staged_files"

  # Run ESLint on staged files. --no-error-on-unmatched-pattern avoids failure
  # when a glob expands to nothing. --quiet suppresses warnings; only errors block.
  # Tailwind v4 beta: if plugin load fails, ESLint exits 2 (config error) not 1.
  # Treat exit 2 as advisory (plugin failure) to avoid false blocks.
  local eslint_exit=0
  # shellcheck disable=SC2086 — $file_args intentionally word-splits on spaces
  npx eslint --no-error-on-unmatched-pattern --quiet $file_args 2>/dev/null
  eslint_exit=$?

  # Exit 2 = config/plugin load error — degrade to advisory (not blocking)
  if [ "$eslint_exit" -eq 2 ]; then
    echo "A3 ADVISORY: ESLint config/plugin error (exit 2) — check eslint-plugin-tailwindcss version compatibility" >&2
    return 0
  fi

  return "$eslint_exit"
}

# --- run_grep_fallback ---
# Scans staged diff for common design-token escape vectors.
# Outputs findings to stdout (one line per finding). Returns 1 if any found, 0 if clean.
#
# Patterns detected:
#   Raw hex colors in className strings:  className="... text-[#abc123] ..."
#   Arbitrary px/rem in Tailwind brackets: p-[16px], m-[2.5rem]
#   Inline style with hardcoded values:    style={{ color: '#fff', ... }}
#
# False-positive notes:
#   - Data attribute selectors (data-[state=open]) are NOT matched; the pattern
#     requires a hex digit or digit after [ to distinguish token escapes from
#     attribute selectors.
#   - CSS variable references (var(--token)) are not matched (no hex/digit pattern).
run_grep_fallback() {
  local staged_diff
  staged_diff=$(git diff --cached -U0 -- 'src/*.tsx' 'src/**/*.tsx' \
    'src/*.ts' 'src/**/*.ts' 'src/*.css' 'src/**/*.css' 2>/dev/null || true)

  if [ -z "$staged_diff" ]; then
    return 0
  fi

  local findings=""
  local added_lines
  added_lines=$(printf '%s\n' "$staged_diff" | awk '
    /^\+\+\+ / { file=substr($0,5); next }
    /^\+[^+]/ { print file "\t" substr($0,2) }
  ')

  # Pattern 1: Raw hex in Tailwind bracket notation (className or CSS)
  # Matches: [#abc], [#123456], [#ABC123] — excludes [#] (empty, unlikely)
  # Does NOT match: data-[state=open] (no hex chars after [)
  local hex_hits
  hex_hits=$(printf '%s\n' "$added_lines" | grep -E '\[#[0-9a-fA-F]{3,6}\]' 2>/dev/null || true)
  if [ -n "$hex_hits" ]; then
    local _f
    while IFS= read -r _f; do
      findings="${findings:+$findings\n}$_f"
    done <<< "$hex_hits"
  fi

  # Pattern 2: Arbitrary pixel values in Tailwind brackets
  # Matches: p-[16px], m-[2.5rem], w-[100px], gap-[8px]
  # Does NOT match: data-[aria-hidden=true] (no digit+px pattern)
  local px_hits
  px_hits=$(printf '%s\n' "$added_lines" | grep -E '\[[0-9]+(\.[0-9]+)?(px|rem)\]' 2>/dev/null || true)
  if [ -n "$px_hits" ]; then
    local _p
    while IFS= read -r _p; do
      findings="${findings:+$findings\n}$_p"
    done <<< "$px_hits"
  fi

  # Pattern 3: Inline style={{ with hardcoded color/size values
  # Matches: style={{ color: '#fff' }}, style={{ fontSize: 14 }}
  # Does NOT match: style={{ color: tokenVar }} (no quotes around value)
  local style_hits
  style_hits=$(printf '%s\n' "$added_lines" | grep -E "style=\{\{[^}]*(color|fontSize|padding|margin|width|height):[[:space:]]*['\"][^'\"]*['\"]" 2>/dev/null || true)
  if [ -n "$style_hits" ]; then
    local _s
    while IFS= read -r _s; do
      findings="${findings:+$findings\n}$_s"
    done <<< "$style_hits"
  fi

  if [ -n "$findings" ]; then
    printf '%b\n' "$findings"
    return 1
  fi
  return 0
}
