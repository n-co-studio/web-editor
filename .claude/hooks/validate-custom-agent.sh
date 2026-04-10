#!/usr/bin/env bash
# validate-custom-agent.sh — Frontmatter validation and name collision check for custom agents.
# Callable from the app (pre-save validation) and from hooks (defense-in-depth).
#
# Usage:
#   validate-custom-agent.sh <path-to-agent.md> [--strip]
#
# Modes:
#   Default: Reports restricted frontmatter fields and name collisions. Exit 1 on violation.
#   --strip: Removes restricted frontmatter fields in-place and reports what was stripped.
#            Still exits 1 on name collision (cannot be auto-fixed).
#
# Exit codes:
#   0 — valid (or stripped successfully, no name collision)
#   1 — validation failure (restricted fields found without --strip, or name collision)
#   2 — usage error (missing arguments, file not found)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS_DIR="$(cd "$SCRIPT_DIR/../agents" && pwd)"
CUSTOM_DIR="$AGENTS_DIR/custom"

# --- Restricted frontmatter fields (plugin-tier security model) ---
RESTRICTED_FIELDS=("hooks" "mcpServers" "permissionMode")

# --- Usage ---
if [ $# -lt 1 ]; then
  echo "Usage: validate-custom-agent.sh <path-to-agent.md> [--strip]" >&2
  exit 2
fi

AGENT_PATH="$1"
STRIP_MODE=false
if [ "${2:-}" = "--strip" ]; then
  STRIP_MODE=true
fi

if [ ! -f "$AGENT_PATH" ]; then
  echo "Error: File not found: $AGENT_PATH" >&2
  exit 2
fi

# --- Extract frontmatter (between first and second '---' lines) ---
extract_frontmatter() {
  local file="$1"
  awk '/^---$/ { count++; if (count == 2) exit; if (count == 1) next } count == 1 { print }' "$file"
}

# --- Check for restricted frontmatter fields ---
FRONTMATTER=$(extract_frontmatter "$AGENT_PATH")
VIOLATIONS=()

for field in "${RESTRICTED_FIELDS[@]}"; do
  if echo "$FRONTMATTER" | grep -qE "^${field}:"; then
    VIOLATIONS+=("$field")
  fi
done

if [ ${#VIOLATIONS[@]} -gt 0 ]; then
  if [ "$STRIP_MODE" = true ]; then
    # Strip restricted fields in-place
    for field in "${VIOLATIONS[@]}"; do
      # Remove the field line and any subsequent indented lines (YAML block values)
      sed -i '' "/^${field}:/,/^[^ ]/{/^${field}:/d; /^  /d; /^$/d;}" "$AGENT_PATH"
      echo "Stripped restricted field: $field" >&2
    done
  else
    echo "Validation failed — restricted frontmatter fields found:" >&2
    for field in "${VIOLATIONS[@]}"; do
      echo "  - $field (plugin-tier restriction: custom agents cannot use this field)" >&2
    done
    exit 1
  fi
fi

# --- Name collision check against template agents ---
AGENT_FILENAME=$(basename "$AGENT_PATH")

# Only check if the file is in the custom directory
AGENT_DIR=$(dirname "$(cd "$(dirname "$AGENT_PATH")" && pwd)/$(basename "$AGENT_PATH")")
if [ "$(cd "$AGENT_DIR" && pwd)" = "$CUSTOM_DIR" ] || echo "$AGENT_PATH" | grep -q '/agents/custom/'; then
  # Check if a template agent with the same name exists in .claude/agents/
  if [ -f "$AGENTS_DIR/$AGENT_FILENAME" ]; then
    echo "Name collision: '$AGENT_FILENAME' already exists as a template agent in .claude/agents/" >&2
    echo "Custom agents cannot share names with template agents." >&2
    exit 1
  fi
fi

# --- All checks passed ---
if [ ${#VIOLATIONS[@]} -gt 0 ] && [ "$STRIP_MODE" = true ]; then
  echo "Validation passed after stripping ${#VIOLATIONS[@]} restricted field(s)." >&2
fi

exit 0
