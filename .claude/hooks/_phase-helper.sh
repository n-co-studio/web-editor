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
      echo "init plan approval build review verify commit op-review close" ;;
    taskgroup)
      echo "init contract-init plan approval build review verify commit contract-update op-review close" ;;
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
        plan)       echo "agent" ;;
        approval)   echo "operator" ;;
        build)      echo "agent" ;;
        review)     echo "agent" ;;
        verify)     echo "agent" ;;
        commit)     echo "agent" ;;
        op-review)  echo "operator" ;;
        *)          echo "agent" ;;
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
    *)                  echo "" ;;
  esac
}

# --- Read a field from the phase-state file ---
# Internal helper. Returns the value for a given key, or empty string.
_read_phase_field() {
  local key="$1"
  local state_file="$2"
  grep "^${key}:" "$state_file" 2>/dev/null | sed "s/^${key}: *//"
}

# --- Session ID validation ---
# Internal helper. Returns 0 if phase-state session_id matches current session.
_validate_phase_session() {
  local state_file="$1"
  local repo_root
  repo_root="$(get_repo_root)"
  local sid
  sid=$(_read_phase_field "session_id" "$state_file")
  local current_sid
  current_sid=$(cat "$repo_root/.claude/.session-id" 2>/dev/null)
  if [ -n "$sid" ] && [ "$sid" = "$current_sid" ]; then
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

  # Shell I/O — bypasses state-guard.sh (established pattern, see Decision 0014)
  printf 'session_type: %s\nsession_id: %s\nmode: review\ncurrent_phase: init\ncycle: 1\nphases_completed: \nsolo: false\ntag: %s\ntimestamp: %s\n' \
    "$stype" "$sid" "$tag" "$ts" \
    > "$state_dir/phase-state" 2>/dev/null || true
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

  # Session ID validation
  if ! _validate_phase_session "$state_file"; then
    echo "ERROR: Phase state is stale (session ID mismatch)" >&2
    return 1
  fi

  # Read current state
  local stype current_phase cycle phases_completed mode solo
  stype=$(_read_phase_field "session_type" "$state_file")
  current_phase=$(_read_phase_field "current_phase" "$state_file")
  cycle=$(_read_phase_field "cycle" "$state_file")
  phases_completed=$(_read_phase_field "phases_completed" "$state_file")
  mode=$(_read_phase_field "mode" "$state_file")
  solo=$(_read_phase_field "solo" "$state_file")
  local sid
  sid=$(_read_phase_field "session_id" "$state_file")

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

  # Shell I/O — bypasses state-guard.sh
  printf 'session_type: %s\nsession_id: %s\nmode: %s\ncurrent_phase: %s\ncycle: %s\nphases_completed: %s\nsolo: %s\ntag: %s\ntimestamp: %s\n' \
    "$stype" "$sid" "$mode" "$new_phase" "$cycle" "$phases_completed" "$solo" "$tag" "$ts" \
    > "$state_file" 2>/dev/null || true
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

  # Session ID validation
  if ! _validate_phase_session "$state_file"; then
    return 1
  fi

  local stype current_phase
  stype=$(_read_phase_field "session_type" "$state_file")
  current_phase=$(_read_phase_field "current_phase" "$state_file")

  local current_idx required_idx
  current_idx=$(get_phase_index "$stype" "$current_phase")
  required_idx=$(get_phase_index "$stype" "$required")

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

  # Session ID validation
  if ! _validate_phase_session "$state_file"; then
    echo ""
    return
  fi

  _read_phase_field "current_phase" "$state_file"
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

  local mode
  mode=$(_read_phase_field "mode" "$state_file")
  echo "${mode:-review}"
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

  # Session ID validation (consistent with get_phase, get_phase_mode, assert_phase)
  if ! _validate_phase_session "$state_file"; then
    echo ""
    return
  fi

  _read_phase_field "tag" "$state_file"
}

# --- Get solo mode flag ---
# Returns "true" or "false" (default: "false" if absent/stale).
# Solo mode controls merge strategy (direct vs PR) — orthogonal to mode (auto/review).
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

  local solo
  solo=$(_read_phase_field "solo" "$state_file")
  echo "${solo:-false}"
}

# --- Set solo mode ---
# Updates the solo field in phase-state. Solo controls merge strategy (direct vs PR).
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

  if ! _validate_phase_session "$state_file"; then
    return 1
  fi

  case "$new_solo" in
    true|false) ;;
    *) echo "ERROR: Invalid solo value '$new_solo' — must be 'true' or 'false'" >&2; return 1 ;;
  esac

  # Read all fields, replace solo, rewrite atomically
  local stype sid mode current_phase cycle phases_completed tag
  stype=$(_read_phase_field "session_type" "$state_file")
  sid=$(_read_phase_field "session_id" "$state_file")
  mode=$(_read_phase_field "mode" "$state_file")
  current_phase=$(_read_phase_field "current_phase" "$state_file")
  cycle=$(_read_phase_field "cycle" "$state_file")
  phases_completed=$(_read_phase_field "phases_completed" "$state_file")
  tag=$(_read_phase_field "tag" "$state_file")
  cycle="${cycle:-1}"
  mode="${mode:-review}"

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Shell I/O — bypasses state-guard.sh
  printf 'session_type: %s\nsession_id: %s\nmode: %s\ncurrent_phase: %s\ncycle: %s\nphases_completed: %s\nsolo: %s\ntag: %s\ntimestamp: %s\n' \
    "$stype" "$sid" "$mode" "$current_phase" "$cycle" "$phases_completed" "$new_solo" "$tag" "$ts" \
    > "$state_file" 2>/dev/null || true
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

  if ! _validate_phase_session "$state_file"; then
    return 1
  fi

  case "$new_mode" in
    auto|review) ;;
    *) echo "ERROR: Invalid mode '$new_mode' — must be 'auto' or 'review'" >&2; return 1 ;;
  esac

  # Read all fields, replace mode, rewrite atomically
  local stype sid current_phase cycle phases_completed solo tag
  stype=$(_read_phase_field "session_type" "$state_file")
  sid=$(_read_phase_field "session_id" "$state_file")
  current_phase=$(_read_phase_field "current_phase" "$state_file")
  cycle=$(_read_phase_field "cycle" "$state_file")
  phases_completed=$(_read_phase_field "phases_completed" "$state_file")
  solo=$(_read_phase_field "solo" "$state_file")
  tag=$(_read_phase_field "tag" "$state_file")
  cycle="${cycle:-1}"
  solo="${solo:-false}"

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Shell I/O — bypasses state-guard.sh
  printf 'session_type: %s\nsession_id: %s\nmode: %s\ncurrent_phase: %s\ncycle: %s\nphases_completed: %s\nsolo: %s\ntag: %s\ntimestamp: %s\n' \
    "$stype" "$sid" "$new_mode" "$current_phase" "$cycle" "$phases_completed" "$solo" "$tag" "$ts" \
    > "$state_file" 2>/dev/null || true
}
