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
#
# ## Consumers (auto-generated — run .claude/tools/hook-dep-map.sh for live data)
#   Hooks: bash-guard, plan-approval, pre-commit-gates,
#          pretooluse-permission [conditional], session-close-check,
#          state-writer, write-guard
#   Automation: runner.sh, queue-cli.sh, intake.sh

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
    ephemeral)
      echo "init conversation close" ;;
    taskdef-query|queue-triage)
      echo "init conversation close" ;;
    taskdef-brief)
      echo "init dispatch synthesize approval output close" ;;
    taskgroup-merge)
      echo "init contract-init cohesion verify commit op-review close" ;;
    editor-live)
      echo "init build commit review verify op-review close" ;;
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
    ephemeral)
      case "$phase" in
        conversation) echo "both" ;;
        *)            echo "agent" ;;
      esac
      ;;
    taskdef-query|queue-triage)
      case "$phase" in
        conversation) echo "both" ;;
        *)            echo "agent" ;;
      esac
      ;;
    taskdef-brief)
      case "$phase" in
        dispatch)   echo "agent" ;;
        synthesize) echo "agent" ;;
        approval)   echo "operator" ;;
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
    editor-live)
      case "$phase" in
        build)     echo "agent" ;;
        commit)    echo "agent" ;;
        review)    echo "agent" ;;
        verify)    echo "agent" ;;
        op-review) echo "operator" ;;
        *)         echo "agent" ;;
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

# --- Operator gate check ---
# Returns 0 if the given phase in the given session type has an "operator" tag.
# Forward-looking helper: any session type that uses the "approval" phase name
# gets enforcement via has_plan_gate; this helper generalizes to any operator-tagged phase.
# No current consumers — added as structural scaffolding for future operator gate enforcement.
has_operator_gate() {
  local stype="$1"
  local phase="$2"
  local tag
  tag=$(get_tag_for_phase "$stype" "$phase")
  [ "$tag" = "operator" ]
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
    editor-live)        echo "commit:build verify:build" ;;
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
# Cached current session ID — avoids re-reading .session-id from disk on validated fast path
_CACHED_CURRENT_SID=""

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
  # Uses _CACHED_CURRENT_SID to avoid re-reading .session-id from disk
  if [ "$_PS_VALIDATED" = true ] && [ -n "$_PS_SESSION_ID" ]; then
    if [ -n "$_CACHED_CURRENT_SID" ] && [ "$_PS_SESSION_ID" = "$_CACHED_CURRENT_SID" ]; then
      return 0
    fi
    # Session ID changed or cache empty — invalidate
    _PS_VALIDATED=false
    _CACHED_CURRENT_SID=""
  fi

  _load_phase_state "$state_file" || return 1
  local current_sid
  if [ -n "${REPO_OS_SESSION_ID:-}" ]; then
    current_sid="$REPO_OS_SESSION_ID"
  else
    current_sid=$(cat "$_REPO_OS_ROOT/.claude/.session-id" 2>/dev/null)
  fi
  if [ -n "$_PS_SESSION_ID" ] && [ "$_PS_SESSION_ID" = "$current_sid" ]; then
    _PS_VALIDATED=true
    _CACHED_CURRENT_SID="$current_sid"
    return 0
  fi
  return 1
}

# --- Cycle cap threshold check (advisory only) ---
# Called by advance_phase() after incrementing cycle on backward transitions.
# Cycle 3: emit advisory warning to stderr.
# Cycle 5: emit stronger warning and write escalation marker to state dir.
# Never blocks — purely informational for orchestrator awareness.
# Arguments: $1 = current cycle count, $2 = state directory path
_check_cycle_limit() {
  local cycle="$1"
  local state_dir="$2"

  if [ "$cycle" -ge 5 ]; then
    echo "Advisory: Session cycle count is $cycle (threshold: 5). Consider whether continued looping is productive or if the task should be escalated/decomposed." >&2
    # Write escalation marker for orchestrator detection
    printf 'cycle_count: %s\nthreshold: 5\ntimestamp: %s\nmessage: Session has cycled %s times — review whether task needs decomposition or operator input.\n' \
      "$cycle" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$cycle" \
      > "$state_dir/cycle-escalation" 2>/dev/null || true
  elif [ "$cycle" -ge 3 ]; then
    echo "Advisory: Session cycle count is $cycle. Multiple review→build loops may indicate scope or complexity issues." >&2
  fi
}

# ============================================================
# Public API
# ============================================================

# --- Initialize phase state ---
# Creates phase-state file with session_id from .session-id, sets current_phase to init.
# Usage: init_phase "standard"
init_phase() {
  local stype="$1"
  local repo_root="$_REPO_OS_ROOT"
  local state_dir
  state_dir="$(get_session_state_dir)"

  # Double-init guard (adversarial M1): refuse re-init if phase-state exists
  # for the current session. Prevents progress reset via second init_phase call.
  # Override: REPO_OS_ALLOW_REINIT=1 for legitimate crash recovery scenarios.
  if [ -f "$state_dir/phase-state" ]; then
    local _existing_sid
    _existing_sid=$(grep '^session_id:' "$state_dir/phase-state" 2>/dev/null | sed 's/^session_id: *//' | tr -d '[:space:]' | head -1)
    local _current_sid
    if [ -n "${REPO_OS_SESSION_ID:-}" ]; then
      _current_sid="$REPO_OS_SESSION_ID"
    else
      _current_sid=$(cat "$repo_root/.claude/.session-id" 2>/dev/null || echo "")
    fi
    if [ -n "$_existing_sid" ] && [ "$_existing_sid" = "$_current_sid" ]; then
      if [ "${REPO_OS_ALLOW_REINIT:-0}" = "1" ]; then
        echo "WARNING: Re-initializing phase state (REPO_OS_ALLOW_REINIT=1 override)" >&2
      else
        echo "GATE-RECOVERABLE: Phase state already exists for this session — re-initialization blocked. NEXT: If crash recovery is needed, set REPO_OS_ALLOW_REINIT=1 and retry. (override: REPO_OS_ALLOW_REINIT=1)" >&2
        return 1
      fi
    elif [ -n "$_existing_sid" ] && [ "$_existing_sid" != "$_current_sid" ]; then
      # Stale phase-state from a different session — check if that session is alive
      local _stale_registry="$repo_root/.claude/.state/sessions/${_existing_sid}.yaml"
      if [ -f "$_stale_registry" ]; then
        local _stale_pid
        _stale_pid=$(grep '^pid: ' "$_stale_registry" 2>/dev/null | sed 's/^pid: *//')
        if [ -n "$_stale_pid" ] && kill -0 "$_stale_pid" 2>/dev/null; then
          if [ "${REPO_OS_ALLOW_REINIT:-0}" = "1" ]; then
            echo "WARNING: Overwriting active session $_existing_sid phase-state (REPO_OS_ALLOW_REINIT=1 override)" >&2
          else
            echo "GATE-RECOVERABLE: Another session ($_existing_sid) has active phase-state. NEXT: Wait for the other session to complete, or use REPO_OS_ALLOW_REINIT=1 to force." >&2
            return 1
          fi
        else
          echo "WARNING: Cleaning stale phase-state from crashed session $_existing_sid" >&2
        fi
      else
        echo "WARNING: Cleaning stale phase-state from crashed session $_existing_sid" >&2
      fi
    fi
  fi

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
  _CACHED_CURRENT_SID=""

  # Register session in the session registry (Decision 0013 overlap awareness)
  register_session "$stype" || true

  # Sweep stale registry entries (dead PID or age >24h) — two cleanup
  # opportunities per lifecycle: here at init and in unregister_session at close.
  sweep_stale_sessions || true

  # Write resume marker (compression recovery)
  write_resume_marker "$stype" "$sid" "init" ""

}

# --- Inject knowledge graph context at build phase entry ---
# When transitioning to the build phase, reads scope files from the task
# contract and runs kg-relevance.sh to produce a context file that agents
# can consult before searching the codebase.
# Decision 0034: graph reads are always allowed, no locking needed.
# Advisory only — failures are silently ignored.
_inject_kg_context() {
  local repo_root="$_REPO_OS_ROOT"
  local template_graph="$repo_root/docs/ai/knowledge-graph/graph.yaml"
  local product_graph="$repo_root/docs/ai/knowledge-graph/product-graph.yaml"
  local contract_file="$repo_root/.claude/local/task-contract.yaml"
  # Use flat .state/ path (not per-session dir) so agents can find it at a
  # well-known location regardless of worktree session state directory scoping.
  local output_file="$repo_root/.claude/.state/kg-relevance-context"

  # Gate: at least one graph must exist
  [ -f "$template_graph" ] || [ -f "$product_graph" ] || return 0

  # Gate: task contract must exist with scope_files
  [ -f "$contract_file" ] || return 0

  # Extract scope_files from task contract (YAML list items under scope_files:)
  local scope_files=""
  local in_scope=false
  while IFS= read -r line; do
    case "$line" in
      "scope_files:"*)
        in_scope=true
        continue
        ;;
    esac
    if [ "$in_scope" = true ]; then
      case "$line" in
        "  - "*)
          # Strip leading "  - " and quotes
          local file_entry="${line#  - }"
          file_entry="${file_entry#\"}"
          file_entry="${file_entry%\"}"
          scope_files="${scope_files:+$scope_files }$file_entry"
          ;;
        *)
          # End of scope_files list
          break
          ;;
      esac
    fi
  done < "$contract_file"

  [ -z "$scope_files" ] && return 0

  # Run kg-relevance.sh in context-inject mode (advisory — ignore failures)
  bash "$repo_root/.claude/tools/kg-relevance.sh" $scope_files \
    --context-inject --output "$output_file" 2>/dev/null || true
}

# --- Advance to a new phase ---
# Validates the transition is legal (forward-only + defined loops).
# Updates current_phase, phases_completed, tag, cycle, timestamp.
# Returns 0 on success, 1 on illegal transition or missing state.
# Usage: advance_phase "build"
advance_phase() {
  local new_phase="$1"
  local repo_root="$_REPO_OS_ROOT"
  local state_dir
  state_dir="$(get_session_state_dir)"
  local state_file="$state_dir/phase-state"

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

  # --- Cycle cap check (advisory) ---
  # After incrementing cycle on a backward transition, check thresholds.
  # Cycle >= 3: advisory warning. Cycle >= 5: escalation marker to state dir.
  # Advisory only — never blocks. Works for all 18 session types.
  if [ "$is_loop" = true ]; then
    _check_cycle_limit "$cycle" "$state_dir"
  fi

  if [ "$is_loop" = false ]; then
    # Forward-only validation with strict sequential enforcement (adversarial C2/C3/H1).
    # Non-adjacent forward jumps only allowed when every skipped phase is in the
    # skippable set: user-review (Decision 0021), op-review (auto mode skip).
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

    # Strict adjacency check: if jumping more than 1 step, verify all
    # intermediate phases are skippable (user-review, op-review).
    if [ "$new_idx" -gt $((current_idx + 1)) ]; then
      local phases_list skip_ok
      phases_list=$(get_phases_for_type "$stype")
      skip_ok=true
      local _idx=0
      for _p in $phases_list; do
        _idx=$((_idx + 1))
        # Check phases strictly between current and target
        if [ "$_idx" -gt "$current_idx" ] && [ "$_idx" -lt "$new_idx" ]; then
          case "$_p" in
            user-review|op-review) ;; # skippable
            *) skip_ok=false; break ;;
          esac
        fi
      done
      if [ "$skip_ok" = false ]; then
        echo "ERROR: Non-adjacent phase transition from '$current_phase' to '$new_phase' — intermediate phase '$_p' is not skippable" >&2
        return 1
      fi
    fi
  fi

  # --- Substance check: plan-approved required before post-approval phase ---
  # When the session type has a plan gate and we're advancing to the post-approval
  # phase (e.g., build for standard, governance for spec-*), verify that the
  # plan-approved state file exists and its session ID matches the current session.
  # This prevents force-advancing through approval without actual operator approval.
  # Ordering note (Critic C5): plan-approval.sh writes plan-approved (line 112)
  # BEFORE calling the double-advance (lines 124/127), so no deadlock occurs.
  if has_plan_gate "$stype"; then
    local post_approval
    post_approval=$(get_post_approval_phase "$stype")
    if [ -n "$post_approval" ] && [ "$new_phase" = "$post_approval" ]; then
      local pa_file="$state_dir/plan-approved"
      if [ ! -f "$pa_file" ]; then
        echo "GATE-RECOVERABLE: plan-approved state file missing — cannot advance to '$new_phase' without operator plan approval. NEXT: Call AskUserQuestion with your plan summary. Include options: \"Auto — proceed autonomously\" and \"Review — pause for my review before commit\". Conversational confirmation does NOT trigger the approval hook." >&2
        return 1
      fi
      # Session-bind note: both plan-approval.sh (interactive) and state-manager.sh
      # (runner) now write session_id into plan-approved. The existence check here
      # remains sufficient — session binding is double-enforced at commit time by
      # pre-commit-gates.sh _validate_state_session_id.
    fi
  fi

  # --- Substance check: pragmatist-signed required before approval ---
  # When the session type has a plan gate, the Pragmatist agent must have
  # reviewed the plan before the operator can approve it (Decision 0025).
  if [ "$new_phase" = "approval" ] && has_plan_gate "$stype"; then
    case "$stype" in
      experiment|prototype-*|ephemeral) ;; # exempt — no governance agents
      *)
        if [ "${REPO_OS_SKIP_PRAGMATIST_GATE:-0}" != "1" ]; then
          if [ ! -f "$state_dir/pragmatist-signed" ]; then
            echo "GATE-RECOVERABLE: pragmatist-signed state file missing — cannot advance to 'approval' without Pragmatist review. NEXT: Dispatch Pragmatist agent in plan-gating mode. (override: REPO_OS_SKIP_PRAGMATIST_GATE=1)" >&2
            return 1
          fi
        fi
        ;;
    esac
  fi

  # --- Substance check: cohesion-reviewed required before verify ---
  # When the session type has a review or cohesion phase that precedes verify
  # in the sequence, the Critic cohesion review must have completed.
  if [ "$new_phase" = "verify" ]; then
    local _review_idx=0 _verify_idx
    _verify_idx=$(get_phase_index "$stype" "verify")
    # Check for either "review" or "cohesion" phase (taskgroup-merge uses "cohesion")
    _review_idx=$(get_phase_index "$stype" "review")
    [ "$_review_idx" -eq 0 ] && _review_idx=$(get_phase_index "$stype" "cohesion")
    if [ "$_review_idx" -gt 0 ] && [ "$_review_idx" -lt "$_verify_idx" ]; then
      case "$stype" in
        experiment|prototype-*|ephemeral) ;; # exempt
        *)
          if [ "${REPO_OS_SKIP_COHESION_GATE:-0}" != "1" ]; then
            if [ ! -f "$state_dir/cohesion-reviewed" ]; then
              echo "GATE-RECOVERABLE: cohesion-reviewed state file missing — cannot advance to 'verify' without Critic cohesion review. NEXT: Dispatch Critic agent in cohesion mode. (override: REPO_OS_SKIP_COHESION_GATE=1)" >&2
              return 1
            fi
          fi
          ;;
      esac
    fi
  fi

  # --- Substance check: qa-verified required before commit ---
  # When the session type has a verify phase that precedes commit in the
  # sequence, QA verification must have completed. Editor-live auto-skips
  # because its verify phase follows commit (non-standard order).
  if [ "$new_phase" = "commit" ]; then
    local _qv_verify_idx _qv_commit_idx
    _qv_verify_idx=$(get_phase_index "$stype" "verify")
    _qv_commit_idx=$(get_phase_index "$stype" "commit")
    if [ "$_qv_verify_idx" -gt 0 ] && [ "$_qv_verify_idx" -lt "$_qv_commit_idx" ]; then
      case "$stype" in
        experiment|prototype-*|ephemeral) ;; # exempt
        *)
          if [ "${REPO_OS_SKIP_QA_GATE:-0}" != "1" ]; then
            if [ ! -f "$state_dir/qa-verified" ]; then
              echo "GATE-RECOVERABLE: qa-verified state file missing — cannot advance to 'commit' without QA verification. NEXT: Dispatch QA verifier agent. (override: REPO_OS_SKIP_QA_GATE=1)" >&2
              return 1
            fi
          fi
          ;;
      esac
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
  _CACHED_CURRENT_SID=""


  # Write resume marker (compression recovery)
  write_resume_marker "$stype" "$sid" "$new_phase" "$phases_completed"

  # Inject knowledge graph context when entering build phase (Decision 0034)
  # Advisory — failures silently ignored. Gated on graph existence + task contract.
  if [ "$new_phase" = "build" ]; then
    _inject_kg_context
  fi
}

# --- Assert current phase meets requirement ---
# Returns 0 if current phase index >= required phase index.
# Returns 1 if phase-state is missing, stale, or current phase is before required.
# Usage: assert_phase "build" || echo "not in build phase yet"
assert_phase() {
  local required="$1"
  local repo_root="$_REPO_OS_ROOT"
  local state_file="$(get_session_state_dir)/phase-state"

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
  local repo_root="$_REPO_OS_ROOT"
  local state_file="$(get_session_state_dir)/phase-state"

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
  local repo_root="$_REPO_OS_ROOT"
  local state_file="$(get_session_state_dir)/phase-state"

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
  local repo_root="$_REPO_OS_ROOT"
  local state_file="$(get_session_state_dir)/phase-state"

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
  local repo_root="$_REPO_OS_ROOT"
  local state_file="$(get_session_state_dir)/phase-state"

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
  local repo_root="$_REPO_OS_ROOT"
  local state_file="$(get_session_state_dir)/phase-state"

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
  _CACHED_CURRENT_SID=""
}

# --- Set auto/review mode ---
# Updates the mode field in phase-state. Must be called before advance_phase
# if the mode should change (advance_phase preserves the existing mode field).
# Returns 0 on success, 1 if phase-state is missing/stale or mode invalid.
# Usage: set_phase_mode "auto"
set_phase_mode() {
  local new_mode="$1"
  local repo_root="$_REPO_OS_ROOT"
  local state_file="$(get_session_state_dir)/phase-state"

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
  _CACHED_CURRENT_SID=""
}

# --- Upgrade session type (Phase 3b) ---
# Converts an ephemeral session to standard when code changes are needed.
# Resets phase to "plan" (standard sequence starting point post-init).
# Preserves session_id, mode, solo, cycle.
# Invalidates _PS_* and session type caches.
# Usage: upgrade_session_type
upgrade_session_type() {
  local repo_root="$_REPO_OS_ROOT"
  local state_file="$(get_session_state_dir)/phase-state"

  if [ ! -f "$state_file" ]; then
    echo "ERROR: upgrade_session_type — no phase-state file" >&2
    return 1
  fi

  # Read current state
  local current_type
  current_type=$(grep '^session_type:' "$state_file" 2>/dev/null | sed 's/^session_type: *//')
  if [ "$current_type" != "ephemeral" ]; then
    echo "ERROR: upgrade_session_type — current type is '$current_type', not 'ephemeral'" >&2
    return 1
  fi

  local sid mode solo cycle
  sid=$(grep '^session_id:' "$state_file" 2>/dev/null | sed 's/^session_id: *//')
  mode=$(grep '^mode:' "$state_file" 2>/dev/null | sed 's/^mode: *//')
  solo=$(grep '^solo:' "$state_file" 2>/dev/null | sed 's/^solo: *//')
  cycle=$(grep '^cycle:' "$state_file" 2>/dev/null | sed 's/^cycle: *//')

  local tag ts
  tag=$(get_tag_for_phase "standard" "plan")
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Shell I/O — bypasses write-guard.sh
  printf 'session_type: %s\nsession_id: %s\nmode: %s\ncurrent_phase: %s\ncycle: %s\nphases_completed: %s\nsolo: %s\ntag: %s\ntimestamp: %s\n' \
    "standard" "$sid" "${mode:-default}" "plan" "${cycle:-1}" "init" "${solo:-false}" "$tag" "$ts" \
    > "$state_file" 2>/dev/null || true

  # Invalidate caches
  _PS_VALIDATED=false
  _CACHED_CURRENT_SID=""
  # Invalidate session type cache in _analytics-helper.sh
  if type invalidate_session_type_cache &>/dev/null; then
    invalidate_session_type_cache
  fi

  # Analytics
  log_hook_event "phase-helper" "upgrade" "" "allow" "0" "ephemeral_to_standard" "" "" || true
}

# --- Write taskgroup brief signal ---
# Records that the active brief contains a ### Task Group marker.
# Shell I/O — bypasses write-guard.sh (same pattern as write_merge_signal).
# Called by the orchestrator when it detects ### Task Group in the brief text,
# before or immediately after init_phase. The hook layer reads this file to
# validate that the session type matches the brief type (Decision 0026).
# Usage: write_taskgroup_brief_signal
write_taskgroup_brief_signal() {
  local repo_root="$_REPO_OS_ROOT"
  local state_dir
  state_dir="$(get_session_state_dir)"
  mkdir -p "$state_dir" 2>/dev/null || true
  printf 'true\n' > "$state_dir/brief-has-taskgroup" 2>/dev/null || true
}

# --- Taskgroup brief mismatch check (Decision 0026) ---
# Reads .claude/.state/brief-has-taskgroup fingerprint file.
# If it exists and the current session type is NOT taskgroup or taskgroup-merge,
# emits a BLOCK and exits 2. No-ops when: fingerprint absent, phase-state
# absent, session type is correct, or REPO_OS_SKIP_TASKGROUP_CHECK=1.
# Usage: check_taskgroup_brief_mismatch "$START_MS"  (exits on mismatch)
check_taskgroup_brief_mismatch() {
  local start_ms="${1:-0}"
  local repo_root="$_REPO_OS_ROOT"
  local fingerprint="$(get_session_state_dir)/brief-has-taskgroup"

  # Override: REPO_OS_SKIP_TASKGROUP_CHECK=1
  if [ "${REPO_OS_SKIP_TASKGROUP_CHECK:-0}" = "1" ]; then
    log_override "taskgroup-check" "REPO_OS_SKIP_TASKGROUP_CHECK"
    log_hook_event "taskgroup-check" "PreToolUse" "" "allow" "$start_ms" "skip_override"
    return 0
  fi

  # No fingerprint → brief has no ### Task Group marker → no mismatch
  [ -f "$fingerprint" ] || return 0

  # No phase-state → session type unknown → skip check
  local state_file="$(get_session_state_dir)/phase-state"
  [ -f "$state_file" ] || return 0

  local stype
  stype=$(_read_phase_field "session_type" "$state_file")

  case "$stype" in
    taskgroup|taskgroup-merge)
      # Correct session type — allow
      return 0
      ;;
    *)
      log_hook_event "taskgroup-check" "PreToolUse" "" "block" "$start_ms" "taskgroup_brief_mismatch" "session_type:$stype"
      echo "BLOCKED: Brief contains ### Task Group but session type is '$stype' — expected 'taskgroup'. Re-initialize with init_phase(\"taskgroup\")." >&2
      exit 2
      ;;
  esac
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
  local repo_root="$_REPO_OS_ROOT"
  local state_dir
  state_dir="$(get_session_state_dir)"
  mkdir -p "$state_dir" 2>/dev/null || true
  printf '%s\n' "$branch_name" > "$state_dir/merge-source-branch" 2>/dev/null || true
}


# --- Write session resume marker ---
# Writes a structured resume marker so the orchestrator can re-orient after
# context compression without re-dispatching governance agents.
# Accepts state values as arguments to avoid re-reading phase-state from disk
# (callers have these values in local variables at the call site).
# Shell I/O — bypasses write-guard.sh (same pattern as init_phase, set_solo).
# Called at the end of advance_phase() and init_phase().
# Usage: write_resume_marker <stype> <sid> <phase> <phases_completed>
write_resume_marker() {
  local stype="$1"
  local sid="$2"
  local phase="$3"
  local phases_completed="$4"

  local state_dir
  state_dir="$(get_session_state_dir)"
  local resume_file="$state_dir/session-resume.yaml"

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

  # Preserve existing agent_verdicts if resume file already exists
  local existing_verdicts=""
  if [ -f "$resume_file" ]; then
    local in_verdicts=false
    local _line
    while IFS= read -r _line || [ -n "$_line" ]; do
      if [ "$_line" = "agent_verdicts:" ]; then
        in_verdicts=true
        continue
      fi
      if [ "$in_verdicts" = true ]; then
        case "$_line" in
          "  "*)
            existing_verdicts="${existing_verdicts}${_line}
"
            ;;
          *)
            break
            ;;
        esac
      fi
    done < "$resume_file"
  fi

  # Shell I/O — bypasses write-guard.sh
  {
    printf 'session_type: %s\n' "$stype"
    printf 'session_id: %s\n' "$sid"
    printf 'current_phase: %s\n' "$phase"
    printf 'phases_completed: %s\n' "$phases_completed"
    printf 'branch: %s\n' "$branch"
    printf 'timestamp: %s\n' "$ts"
    printf 'agent_verdicts:\n'
    if [ -n "$existing_verdicts" ]; then
      printf '%s' "$existing_verdicts"
    fi
  } > "$resume_file" 2>/dev/null || true
}

# --- Read session resume marker ---
# Reads and outputs the resume marker for orchestrator re-orientation after
# context compression. Returns key-value output to stdout.
# Usage: read_resume_marker
read_resume_marker() {
  local state_dir
  state_dir="$(get_session_state_dir)"
  local resume_file="$state_dir/session-resume.yaml"

  if [ ! -f "$resume_file" ]; then
    echo "ERROR: No resume marker found" >&2
    return 1
  fi

  cat "$resume_file"
}

# --- Record agent verdict in resume marker ---
# Appends or updates an agent verdict in the resume marker's agent_verdicts
# section. The orchestrator calls this after receiving each governance agent's
# result so that compression recovery can skip already-completed agents.
# Shell I/O — bypasses write-guard.sh (same pattern as write_resume_marker).
# Usage: record_agent_verdict "critic" "clean"
#        record_agent_verdict "pragmatist" "approved"
#        record_agent_verdict "qa" "pass"
record_agent_verdict() {
  local agent_name="$1"
  local verdict="$2"

  if [ -z "$agent_name" ] || [ -z "$verdict" ]; then
    echo "ERROR: record_agent_verdict requires agent_name and verdict" >&2
    return 1
  fi

  local state_dir
  state_dir="$(get_session_state_dir)"
  local resume_file="$state_dir/session-resume.yaml"

  if [ ! -f "$resume_file" ]; then
    echo "ERROR: No resume marker — call write_resume_marker first" >&2
    return 1
  fi

  local temp_file="$resume_file.tmp"
  local in_verdicts=false
  local verdict_written=false
  local _line

  {
    while IFS= read -r _line || [ -n "$_line" ]; do
      if [ "$_line" = "agent_verdicts:" ]; then
        in_verdicts=true
        printf '%s\n' "$_line"
        continue
      fi
      if [ "$in_verdicts" = true ]; then
        case "$_line" in
          "  ${agent_name}: "*)
            printf '  %s: %s\n' "$agent_name" "$verdict"
            verdict_written=true
            continue
            ;;
          "  "*)
            printf '%s\n' "$_line"
            continue
            ;;
          *)
            if [ "$verdict_written" = false ]; then
              printf '  %s: %s\n' "$agent_name" "$verdict"
              verdict_written=true
            fi
            in_verdicts=false
            printf '%s\n' "$_line"
            continue
            ;;
        esac
      fi
      printf '%s\n' "$_line"
    done < "$resume_file"

    if [ "$in_verdicts" = true ] && [ "$verdict_written" = false ]; then
      printf '  %s: %s\n' "$agent_name" "$verdict"
    fi
  } > "$temp_file" 2>/dev/null || true

  mv "$temp_file" "$resume_file" 2>/dev/null || true
}
