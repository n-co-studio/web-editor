#!/usr/bin/env bash
# Queue validator — validates queue entries against schema contracts.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0017 — Operator Automation Layer.
#
# Validates required fields, session_type against _phase-helper.sh,
# brief size limits, branch name sanitization, and optional HMAC
# signature verification for external-source entries.
#
# Depends on (sourced by runner.sh before this file):
#   runner.sh sets REPO_ROOT, AUTOMATION_DIR, CONFIG_FILE
#   _phase-helper.sh — get_phases_for_type
#   branch-manager.sh — sanitize_branch_name
#   queue-manager.sh — _load_queue_entry, _QE_*

set -euo pipefail

# --- Max brief size (50KB = 50000 bytes) ---
_MAX_BRIEF_SIZE=50000

# Note: sanitize_branch_name() is defined in branch-manager.sh (sourced
# earlier by runner.sh). This module reuses it for branch validation.

# --- Validate HMAC-SHA256 signature (opt-in) ---
# If runner-config has hmac_secret configured, verifies the entry
# signature. Skips silently if hmac_secret is not set.
#
# SECURITY: hmac_secret MUST only be configured in config.local.yaml
# (gitignored), never in config.yaml (tracked). Committing secrets to
# config.yaml exposes them in git history.
#
# Arguments:
#   $1 — entry_file path
#   $2 — signature (from entry metadata or external header)
# Returns: 0 if valid or not configured, 1 if invalid
validate_hmac() {
  local entry_file="$1"
  local signature="${2:-}"

  # Read hmac_secret from config
  local hmac_secret=""
  if [ -f "$CONFIG_FILE" ]; then
    hmac_secret=$(sed -n '/^runner:/,/^[a-z]/{/hmac_secret:/p;}' "$CONFIG_FILE" \
      | sed 's/.*hmac_secret: *//' | tr -d '[:space:]"'"'" | head -1)
  fi

  # Not configured — skip silently
  if [ -z "$hmac_secret" ]; then
    return 0
  fi

  # No signature provided — fail
  if [ -z "$signature" ]; then
    echo "ERROR: HMAC signature required but not provided" >&2
    return 1
  fi

  # Compute HMAC-SHA256 of the entry file content
  if ! command -v openssl > /dev/null 2>&1; then
    echo "ERROR: openssl not found — required for HMAC validation" >&2
    return 1
  fi

  local expected
  expected=$(openssl dgst -sha256 -hmac "$hmac_secret" "$entry_file" 2>/dev/null \
    | sed 's/.*= //')

  if [ "$expected" != "$signature" ]; then
    echo "ERROR: HMAC signature mismatch" >&2
    return 1
  fi

  return 0
}

# ============================================================
# Public API
# ============================================================

# --- Validate a queue entry ---
# Checks required fields, session_type, brief size, branch name.
# Arguments:
#   $1 — entry_file path (YAML queue entry)
# Returns: 0 if valid, 1 if invalid (errors on stderr)
validate_queue_entry() {
  local entry_file="$1"
  local errors=""

  # Load entry
  if ! _load_queue_entry "$entry_file"; then
    echo "ERROR: Cannot read queue entry: $entry_file" >&2
    return 1
  fi

  # --- Required fields ---
  if [ -z "$_QE_ID" ]; then
    errors="${errors}Missing required field: id\n"
  fi
  if [ -z "$_QE_STATUS" ]; then
    errors="${errors}Missing required field: status\n"
  fi
  if [ -z "$_QE_SESSION_TYPE" ]; then
    errors="${errors}Missing required field: session_type\n"
  fi

  # --- session_type validation ---
  if [ -n "$_QE_SESSION_TYPE" ]; then
    local phases
    phases=$(get_phases_for_type "$_QE_SESSION_TYPE" 2>/dev/null || true)
    if [ -z "$phases" ]; then
      errors="${errors}Invalid session_type: $_QE_SESSION_TYPE (not in Decision 0014 enum)\n"
    fi
  fi

  # --- Brief content validation ---
  local brief_content=""
  local brief_path="$_QE_BRIEF_PATH"
  # Strip YAML quotes and leading/trailing whitespace from brief_path
  # (parser preserves literal ""; trailing spaces from `brief_path: ` are legitimate empty)
  brief_path=$(printf '%s' "$brief_path" | tr -d '"'"'")
  brief_path="${brief_path#"${brief_path%%[![:space:]]*}"}"
  brief_path="${brief_path%"${brief_path##*[![:space:]]}"}"
  if [ -n "$brief_path" ] && [[ "$brief_path" == *'..'* ]]; then
    errors="${errors}Brief path contains traversal sequence: $brief_path\n"
  fi
  if [ -n "$brief_path" ]; then
    local resolved_path=""
    if [ -f "$REPO_ROOT/$brief_path" ]; then
      resolved_path="$REPO_ROOT/$brief_path"
    elif [ -f "$brief_path" ]; then
      resolved_path="$brief_path"
    fi

    if [ -n "$resolved_path" ]; then
      brief_content=$(cat "$resolved_path" 2>/dev/null || true)

      # Size check
      local brief_size
      brief_size=$(wc -c < "$resolved_path" 2>/dev/null | tr -d '[:space:]')
      if [ -n "$brief_size" ] && [ "$brief_size" -gt "$_MAX_BRIEF_SIZE" ]; then
        errors="${errors}Brief exceeds max size: ${brief_size} bytes (max: ${_MAX_BRIEF_SIZE})\n"
      fi
    fi

    # Non-empty check
    if [ -z "$brief_content" ]; then
      errors="${errors}Brief content is empty or file not found: $brief_path\n"
    fi
  fi

  # --- Branch validation (audit C3: required for taskgroup/taskgroup-merge) ---
  if [ -n "$_QE_BRANCH" ]; then
    local sanitized
    sanitized=$(sanitize_branch_name "$_QE_BRANCH")
    if [ "$sanitized" != "$_QE_BRANCH" ]; then
      errors="${errors}Branch name contains invalid characters. Sanitized: $sanitized\n"
    fi
    if [ ${#_QE_BRANCH} -gt 100 ]; then
      errors="${errors}Branch name exceeds 100 characters (${#_QE_BRANCH})\n"
    fi
  elif [ "$_QE_SESSION_TYPE" = "taskgroup" ] || [ "$_QE_SESSION_TYPE" = "taskgroup-merge" ]; then
    errors="${errors}Missing required field: branch (required for $_QE_SESSION_TYPE sessions)\n"
  fi

  # --- solo_mode validation (audit C3: must be "true" or "false" when set) ---
  if [ -n "$_QE_SOLO_MODE" ]; then
    case "$_QE_SOLO_MODE" in
      true|false) ;;
      *) errors="${errors}Invalid solo_mode: '$_QE_SOLO_MODE' (must be 'true' or 'false')\n" ;;
    esac
  fi

  # --- Report errors ---
  if [ -n "$errors" ]; then
    printf 'Queue entry validation failed for %s:\n' "$_QE_ID" >&2
    printf '%b' "$errors" >&2
    return 1
  fi

  return 0
}
