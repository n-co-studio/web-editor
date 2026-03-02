#!/usr/bin/env bash
# Phase-aware flow management — sourced by hooks that need phase tracking.
# Provides functions to initialize, advance, and query session phase state.
# Phase state is persisted in .claude/.state/phase-state (session-scoped).
#
# Depends on _analytics-helper.sh (must be sourced first) for:
#   get_repo_root, get_session_id
#
# Usage (in hook scripts):
#   source "$SCRIPT_DIR/_analytics-helper.sh"
#   source "$SCRIPT_DIR/_phase-helper.sh"
#   init_phase "standard"
#   advance_phase "plan"
#   assert_phase "build" || echo "not yet in build phase"
#
# Decision 0014 — Phase-Aware Flow Model

# --- Phase sequence lookup (Bash 3 compatible — no associative arrays) ---
# Returns space-delimited ordered phase list for a session type.
get_phases_for_type() {
  local stype="$1"
  case "$stype" in
    standard)
      # user-review is skippable: forward-jump verify→commit permitted (Decision 0021)
      echo "init plan approval build review verify user-review commit op-review close" ;;
    taskgroup)
      # user-review is skippable: forward-jump verify→commit permitted (Decision 0021)
      echo "init contract-init plan approval build review verify user-review commit contract-update op-review close" ;;
    hotfix)
      echo "init plan approval build verify commit close" ;;
    experiment)
      echo "init build commit close" ;;
    spec-fresh|spec-update)
      echo "init interview write approval governance close" ;;
    prototype-napkin)
      echo "init build close" ;;
    prototype-spike)
      echo "init build evaluate close" ;;
    prototype-poc)
      echo "init build evaluate document close" ;;
    advisory-init)
      echo "init tier-select dispatch synthesize op-review validate governance close" ;;
    advisory-reinit)
      echo "init validate governance close" ;;
    audit)
      echo "init scope dispatch synthesize op-review close" ;;
    taskdef-query)
      echo "init conversation close" ;;
    taskdef-brief)
      echo "init dispatch synthesize op-review output close" ;;
    taskgroup-merge)
      echo "init contract-init cohesion verify commit op-review close" ;;
    *)
      echo "" ;;
  esac
}

# --- Automation tag lookup ---
# Returns the tag (agent/operator/both) for a given session type and phase.
get_tag_for_phase() {
  local stype="$1"
  local phase="$2"
  # Universal tags for init/close
  case "$phase" in
    init)  echo "agent"; return ;;
    close) echo "agent"; return ;;
  esac
  # Type-specific tags
  case "$stype" in
    standard)
      case "$phase" in
        plan)         echo "agent" ;;
        approval)     echo "operator" ;;
        build)        echo "agent" ;;
        review)       echo "agent" ;;
        verify)       echo "agent" ;;
        user-review)  echo "agent" ;;
        commit)       echo "agent" ;;
        op-review)    echo "operator" ;;
        *)            echo "agent" ;;
      esac
      ;;
    taskgroup)
      case "$phase" in
        contract-init)   echo "agent" ;;
        plan)            echo "agent" ;;
        approval)        echo "operator" ;;
        build)           echo "agent" ;;
        review)          echo "agent" ;;
        verify)          echo "agent" ;;
        user-review)     echo "agent" ;;
        commit)          echo "agent" ;;
        contract-update) echo "agent" ;;
        op-review)       echo "operator" ;;
        *)               echo "agent" ;;
      esac
      ;;
    hotfix)
      case "$phase" in
        plan)     echo "agent" ;;
        approval) echo "operator" ;;
        build)    echo "agent" ;;
        verify)   echo "agent" ;;
        commit)   echo "agent" ;;
        *)        echo "agent" ;;
      esac
      ;;
    experiment)
      echo "agent" ;;
    spec-fresh|spec-update)
      case "$phase" in
        interview)  echo "both" ;;
        write)      echo "agent" ;;
        approval)   echo "operator" ;;
        governance) echo "agent" ;;
        *)          echo "agent" ;;
      esac
      ;;
    prototype-napkin)
      echo "agent" ;;
    prototype-spike)
      case "$phase" in
        build)    echo "agent" ;;
        evaluate) echo "both" ;;
        *)        echo "agent" ;;
      esac
      ;;
    prototype-poc)
      case "$phase" in
        build)    echo "agent" ;;
        evaluate) echo "both" ;;
        document) echo "agent" ;;
        *)        echo "agent" ;;
      esac
      ;;
    advisory-init)
      case "$phase" in
        tier-select) echo "both" ;;
        dispatch)    echo "agent" ;;
        synthesize)  echo "agent" ;;
        op-review)   echo "operator" ;;
        validate)    echo "agent" ;;
        governance)  echo "agent" ;;
        *)           echo "agent" ;;
      esac
      ;;
    advisory-reinit)
      case "$phase" in
        validate)   echo "agent" ;;
        governance) echo "agent" ;;
        *)          echo "agent" ;;
      esac
      ;;
    audit)
      case "$phase" in
        scope)      echo "both" ;;
        dispatch)   echo "agent" ;;
        synthesize) echo "agent" ;;
        op-review)  echo "operator" ;;
        *)          echo "agent" ;;
      esac
      ;;
    taskdef-query)
      case "$phase" in
        conversation) echo "both" ;;
        *)            echo "agent" ;;
      esac
      ;;
    taskdef-brief)
      case "$phase" in
        dispatch)   echo "agent" ;;
        synthesize) echo "agent" ;;
        op-review)  echo "operator" ;;
        output)     echo "agent" ;;
        *)          echo "agent" ;;
      esac
      ;;
    taskgroup-merge)
      case "$phase" in
        contract-init) echo "agent" ;;
        cohesion)      echo "agent" ;;
        verify)        echo "agent" ;;
        commit)        echo "agent" ;;
        op-review)     echo "operator" ;;
        *)             echo "agent" ;;
      esac
      ;;
    *)
      echo "agent" ;;
  esac
}

# --- Plan gate check ---
# Returns 0 if the session type has an approval phase (i.e., requires plan gate
# enforcement), 1 otherwise. Session types without approval are self-exempting.
has_plan_gate() {
  local stype="$1"
  local phases
  phases=$(get_phases_for_type "$stype")
  for p in $phases; do
    if [ "$p" = "approval" ]; then
      return 0
    fi
  done
  return 1
}

# --- Post-approval phase lookup ---
# Returns the phase immediately after "approval" in the session type's sequence.
# Returns empty string if the type has no approval phase.
get_post_approval_phase() {
  local stype="$1"
  local phases
  phases=$(get_phases_for_type "$stype")
  local found_approval=false
  for p in $phases; do
    if [ "$found_approval" = true ]; then
      echo "$p"
      return
    fi
    if [ "$p" = "approval" ]; then
      found_approval=true
    fi
  done
  echo ""
}

# --- Phase index lookup ---
# Returns 1-based index of a phase within its session type's sequence.
# Returns 0 if the phase is not valid for the given session type.
get_phase_index() {
  local stype="$1"
  local phase="$2"
  local phases
  phases=$(get_phases_for_type "$stype")
  local idx=0
  for p in $phases; do
    idx=$((idx + 1))
    if [ "$p" = "$phase" ]; then
      echo "$idx"
      return
    fi
  done
  echo "0"
}

# --- Legal backward transitions (loops) ---
# Returns space-delimited "from:to" pairs for legal backward transitions.
# Empty string means no loops allowed.
get_loops_for_type() {
  local stype="$1"
  case "$stype" in
    standard|taskgroup) echo "review:build verify:build" ;;
    hotfix)             echo "verify:build" ;;
    taskgroup-merge)    echo "cohesion:cohesion" ;;
    *)                  echo "" ;;
  esac
}

# --- Bulk-read phase-state file into cached variables (zero-fork) ---
# Reads the 9-line phase-state file once using while-read with file redirect
# (current-shell, no subshell). Populates _PS_* module variables.
# Returns 1 if the file is missing.
_PS_SESSION_TYPE="" _PS_SESSION_ID="" _PS_MODE="" _PS_CURRENT_PHASE=""
_PS_CYCLE="" _PS_PHASES_COMPLETED="" _PS_SOLO="" _PS_TAG="" _PS_TIMESTAMP=""
# Audit C8: validation cache sentinel — avoids redundant file reads per invocation
_PS_VALIDATED=false

_load_phase_state() {
  local state_file="$1"
  _PS_SESSION_TYPE="" _PS_SESSION_ID="" _PS_MODE="" _PS_CURRENT_PHASE=""
  _PS_CYCLE="" _PS_PHASES_COMPLETED="" _PS_SOLO="" _PS_TAG="" _PS_TIMESTAMP=""
  [ -f "$state_file" ] || return 1
  local _line
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "session_type: "*)       _PS_SESSION_TYPE="${_line#session_type: }" ;;
      "session_id: "*)         _PS_SESSION_ID="${_line#session_id: }" ;;
      "mode: "*)               _PS_MODE="${_line#mode: }" ;;
      "current_phase: "*)      _PS_CURRENT_PHASE="${_line#current_phase: }" ;;
      "cycle: "*)              _PS_CYCLE="${_line#cycle: }" ;;
      "phases_completed: "*)   _PS_PHASES_COMPLETED="${_line#phases_completed: }" ;;
      "solo: "*)               _PS_SOLO="${_line#solo: }" ;;
      "tag: "*)                _PS_TAG="${_line#tag: }" ;;
      "timestamp: "*)          _PS_TIMESTAMP="${_line#timestamp: }" ;;
    esac
  done < "$state_file"
}

# --- Read a field from the phase-state file ---
# Single-field reader for callers that need only one field.
# Prefer _load_phase_state + _PS_* variables for bulk reads.
_read_phase_field() {
  local key="$1"
  local state_file="$2"
  grep "^${key}:" "$state_file" 2>/dev/null | sed "s/^${key}: *//"
}

# --- Session ID validation ---
# Internal helper. Returns 0 if phase-state session_id matches current session.
# Calls _load_phase_state to populate _PS_* cache for downstream callers.
# Audit C8: caches validation result to avoid redundant file reads.
_validate_phase_session() {
  local state_file="$1"

  # Fast path: already validated for this session (audit C8)
  if [ "$_PS_VALIDATED" = true ] && [ -n "$_PS_SESSION_ID" ]; then
    local _cached_sid
    _cached_sid=$(cat "$(get_repo_root)/.claude/.session-id" 2>/dev/null)
    if [ "$_PS_SESSION_ID" = "$_cached_sid" ]; then
      return 0
    fi
    # Session ID changed — invalidate cache
    _PS_VALIDATED=false
  fi

  _load_phase_state "$state_file" || return 1
  local repo_root
  repo_root="$(get_repo_root)"
  local current_sid
  current_sid=$(cat "$repo_root/.claude/.session-id" 2>/dev/null)
  if [ -n "$_PS_SESSION_ID" ] && [ "$_PS_SESSION_ID" = "$current_sid" ]; then
    _PS_VALIDATED=true
    return 0
  fi
  return 1
}

# ============================================================
# Public API
# ============================================================

# --- Initialize phase state ---
# Creates phase-state file with session_id from .session-id, sets current_phase to init.
# Usage: init_phase "standard"
init_phase() {
  local stype="$1"
  local repo_root
  repo_root="$(get_repo_root)"
  local state_dir="$repo_root/.claude/.state"

  # Validate session type
  local phases
  phases=$(get_phases_for_type "$stype")
  if [ -z "$phases" ]; then
    echo "ERROR: Unknown session type: $stype" >&2
    return 1
  fi

  # Read session ID (guaranteed to exist — _analytics-helper.sh sourced first)
  local sid
  sid=$(get_session_id "$repo_root")

  # Get tag for init phase
  local tag
  tag=$(get_tag_for_phase "$stype" "init")

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  mkdir -p "$state_dir" 2>/dev/null || true

  # Shell I/O — bypasses write-guard.sh (established pattern, see Decision 0014)
  printf 'session_type: %s\nsession_id: %s\nmode: review\ncurrent_phase: init\ncycle: 1\nphases_completed: \nsolo: false\ntag: %s\ntimestamp: %s\n' \
    "$stype" "$sid" "$tag" "$ts" \
    > "$state_dir/phase-state" 2>/dev/null || true

  # Invalidate validation cache — file contents changed (audit C8)
  _PS_VALIDATED=false

  # Register session in the session registry (Decision 0013 overlap awareness)
  register_session "$stype" || true
}

# --- Advance to a new phase ---
# Validates the transition is legal (forward-only + defined loops).
# Updates current_phase, phases_completed, tag, cycle, timestamp.
# Returns 0 on success, 1 on illegal transition or missing state.
# Usage: advance_phase "build"
advance_phase() {
  local new_phase="$1"
  local repo_root
  repo_root="$(get_repo_root)"
  local state_file="$repo_root/.claude/.state/phase-state"

  if [ ! -f "$state_file" ]; then
    echo "ERROR: No phase state — call init_phase first" >&2
    return 1
  fi

  # Session ID validation (also populates _PS_* cache)
  if ! _validate_phase_session "$state_file"; then
    echo "ERROR: Phase state is stale (session ID mismatch)" >&2
    return 1
  fi

  # Read current state from cache (zero forks)
  local stype="$_PS_SESSION_TYPE"
  local current_phase="$_PS_CURRENT_PHASE"
  local cycle="$_PS_CYCLE"
  local phases_completed="$_PS_PHASES_COMPLETED"
  local mode="$_PS_MODE"
  local solo="$_PS_SOLO"
  local sid="$_PS_SESSION_ID"

  # Defaults
  cycle="${cycle:-1}"
  mode="${mode:-review}"
  solo="${solo:-false}"

  # Check if this is a legal backward transition (loop)
  local loops
  loops=$(get_loops_for_type "$stype")
  local is_loop=false
  if [ -n "$loops" ]; then
    for pair in $loops; do
      local from_phase="${pair%%:*}"
      local to_phase="${pair##*:}"
      if [ "$current_phase" = "$from_phase" ] && [ "$new_phase" = "$to_phase" ]; then
        is_loop=true
        cycle=$((cycle + 1))
        break
      fi
    done
  fi

  if [ "$is_loop" = false ]; then
    # Forward-only validation
    local current_idx new_idx
    current_idx=$(get_phase_index "$stype" "$current_phase")
    new_idx=$(get_phase_index "$stype" "$new_phase")

    if [ "$new_idx" -eq 0 ]; then
      echo "ERROR: Phase '$new_phase' is not valid for session type '$stype'" >&2
      return 1
    fi

    if [ "$new_idx" -le "$current_idx" ]; then
      echo "ERROR: Cannot move backward from '$current_phase' to '$new_phase'" >&2
      return 1
    fi
  fi

  # Update phases_completed (append current phase)
  if [ -n "$phases_completed" ]; then
    phases_completed="${phases_completed},${current_phase}"
  else
    phases_completed="$current_phase"
  fi

  local tag
  tag=$(get_tag_for_phase "$stype" "$new_phase")
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Shell I/O — bypasses write-guard.sh
  printf 'session_type: %s\nsession_id: %s\nmode: %s\ncurrent_phase: %s\ncycle: %s\nphases_completed: %s\nsolo: %s\ntag: %s\ntimestamp: %s\n' \
    "$stype" "$sid" "$mode" "$new_phase" "$cycle" "$phases_completed" "$solo" "$tag" "$ts" \
    > "$state_file" 2>/dev/null || true

  # Invalidate validation cache — file contents changed (audit C8)
  _PS_VALIDATED=false
}

# --- Assert current phase meets requirement ---
# Returns 0 if current phase index >= required phase index.
# Returns 1 if phase-state is missing, stale, or current phase is before required.
# Usage: assert_phase "build" || echo "not in build phase yet"
assert_phase() {
  local required="$1"
  local repo_root
  repo_root="$(get_repo_root)"
  local state_file="$repo_root/.claude/.state/phase-state"

  if [ ! -f "$state_file" ]; then
    return 1
  fi

  # Session ID validation (also populates _PS_* cache)
  if ! _validate_phase_session "$state_file"; then
    return 1
  fi

  local current_idx required_idx
  current_idx=$(get_phase_index "$_PS_SESSION_TYPE" "$_PS_CURRENT_PHASE")
  required_idx=$(get_phase_index "$_PS_SESSION_TYPE" "$required")

  if [ "$required_idx" -eq 0 ]; then
    return 1
  fi

  # current >= required
  if [ "$current_idx" -ge "$required_idx" ]; then
    return 0
  fi
  return 1
}

# --- Get current phase ---
# Returns the current phase name, or empty string if missing/stale.
# Usage: phase=$(get_phase)
get_phase() {
  local repo_root
  repo_root="$(get_repo_root)"
  local state_file="$repo_root/.claude/.state/phase-state"

  if [ ! -f "$state_file" ]; then
    echo ""
    return
  fi

  # Session ID validation (also populates _PS_* cache)
  if ! _validate_phase_session "$state_file"; then
    echo ""
    return
  fi

  echo "$_PS_CURRENT_PHASE"
}

# --- Get auto/review mode ---
# Returns "auto" or "review" (default: "review" if absent).
# Named get_phase_mode to avoid collision with get_mode in _analytics-helper.sh.
# Usage: mode=$(get_phase_mode)
get_phase_mode() {
  local repo_root
  repo_root="$(get_repo_root)"
  local state_file="$repo_root/.claude/.state/phase-state"

  if [ ! -f "$state_file" ]; then
    echo "review"
    return
  fi

  # Load cache (validates session ID as side effect)
  _load_phase_state "$state_file" || { echo "review"; return; }
  echo "${_PS_MODE:-review}"
}

# --- Get current automation tag ---
# Returns the tag for the current phase (agent/operator/both), or empty if missing/stale.
# Usage: tag=$(get_tag)
get_tag() {
  local repo_root
  repo_root="$(get_repo_root)"
  local state_file="$repo_root/.claude/.state/phase-state"

  if [ ! -f "$state_file" ]; then
    echo ""
    return
  fi

  # Session ID validation (also populates _PS_* cache)
  if ! _validate_phase_session "$state_file"; then
    echo ""
    return
  fi

  echo "$_PS_TAG"
}

# --- Get solo mode flag ---
# Returns "true" or "false" (default: "false" if absent/stale).
# Solo mode controls merge strategy (direct merge to main) — orthogonal to mode (auto/review).
# Decision 0015 — Solo Mode.
# Usage: solo=$(get_solo)
get_solo() {
  local repo_root
  repo_root="$(get_repo_root)"
  local state_file="$repo_root/.claude/.state/phase-state"

  if [ ! -f "$state_file" ]; then
    echo "false"
    return
  fi

  if ! _validate_phase_session "$state_file"; then
    echo "false"
    return
  fi

  echo "${_PS_SOLO:-false}"
}

# --- Set solo mode ---
# Updates the solo field in phase-state. Solo controls merge strategy (direct merge to main).
# Returns 0 on success, 1 if phase-state is missing/stale or value invalid.
# Decision 0015 — Solo Mode.
# Usage: set_solo "true"
set_solo() {
  local new_solo="$1"
  local repo_root
  repo_root="$(get_repo_root)"
  local state_file="$repo_root/.claude/.state/phase-state"

  if [ ! -f "$state_file" ]; then
    return 1
  fi

  # _validate_phase_session populates _PS_* cache
  if ! _validate_phase_session "$state_file"; then
    return 1
  fi

  case "$new_solo" in
    true|false) ;;
    *) echo "ERROR: Invalid solo value '$new_solo' — must be 'true' or 'false'" >&2; return 1 ;;
  esac

  # Read all fields from cache (zero forks), replace solo, rewrite atomically
  local cycle="${_PS_CYCLE:-1}"
  local mode="${_PS_MODE:-review}"

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Shell I/O — bypasses write-guard.sh
  printf 'session_type: %s\nsession_id: %s\nmode: %s\ncurrent_phase: %s\ncycle: %s\nphases_completed: %s\nsolo: %s\ntag: %s\ntimestamp: %s\n' \
    "$_PS_SESSION_TYPE" "$_PS_SESSION_ID" "$mode" "$_PS_CURRENT_PHASE" "$cycle" "$_PS_PHASES_COMPLETED" "$new_solo" "$_PS_TAG" "$ts" \
    > "$state_file" 2>/dev/null || true

  # Invalidate validation cache — file contents changed (audit C8)
  _PS_VALIDATED=false
}

# --- Set auto/review mode ---
# Updates the mode field in phase-state. Must be called before advance_phase
# if the mode should change (advance_phase preserves the existing mode field).
# Returns 0 on success, 1 if phase-state is missing/stale or mode invalid.
# Usage: set_phase_mode "auto"
set_phase_mode() {
  local new_mode="$1"
  local repo_root
  repo_root="$(get_repo_root)"
  local state_file="$repo_root/.claude/.state/phase-state"

  if [ ! -f "$state_file" ]; then
    return 1
  fi

  # _validate_phase_session populates _PS_* cache
  if ! _validate_phase_session "$state_file"; then
    return 1
  fi

  case "$new_mode" in
    auto|review) ;;
    *) echo "ERROR: Invalid mode '$new_mode' — must be 'auto' or 'review'" >&2; return 1 ;;
  esac

  # Read all fields from cache (zero forks), replace mode, rewrite atomically
  local cycle="${_PS_CYCLE:-1}"
  local solo="${_PS_SOLO:-false}"

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Shell I/O — bypasses write-guard.sh
  printf 'session_type: %s\nsession_id: %s\nmode: %s\ncurrent_phase: %s\ncycle: %s\nphases_completed: %s\nsolo: %s\ntag: %s\ntimestamp: %s\n' \
    "$_PS_SESSION_TYPE" "$_PS_SESSION_ID" "$new_mode" "$_PS_CURRENT_PHASE" "$cycle" "$_PS_PHASES_COMPLETED" "$solo" "$_PS_TAG" "$ts" \
    > "$state_file" 2>/dev/null || true

  # Invalidate validation cache — file contents changed (audit C8)
  _PS_VALIDATED=false
}

# --- Write merge source signal ---
# Records the branch name in .claude/.state/merge-source-branch so the stop
# hook can detect that the agent completed the merge in the close phase.
# Shell I/O — bypasses write-guard.sh (same pattern as init_phase, set_solo).
# Called by the agent AFTER a successful git merge on main.
# Usage: write_merge_signal "feature/my-feature"
write_merge_signal() {
  local branch_name="$1"
  if [ -z "$branch_name" ]; then
    echo "ERROR: write_merge_signal requires a branch name" >&2
    return 1
  fi
  local repo_root
  repo_root="$(get_repo_root)"
  local state_dir="$repo_root/.claude/.state"
  mkdir -p "$state_dir" 2>/dev/null || true
  printf '%s\n' "$branch_name" > "$state_dir/merge-source-branch" 2>/dev/null || true
}
