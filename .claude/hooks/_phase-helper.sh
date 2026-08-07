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
      # drift-check evaluates the handoff bundle (Decision 0038); when bundle is
      # valid the legacy plan/approval phases are skipped via forward-jump.
      # plan and approval remain in the sequence to preserve the legacy fallback
      # path (no bundle present) — drift_check falls through to them.
      echo "init drift-check plan approval build review verify user-review commit op-review close" ;;
    taskgroup)
      # user-review is skippable: forward-jump verify→commit permitted (Decision 0021)
      # drift-check positioned after contract-init so per-brief bundles are
      # evaluated against the synchronized contract (Decision 0038).
      echo "init contract-init drift-check plan approval build review verify user-review commit contract-update op-review close" ;;
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
    finish-loop)
      # Loop: reassess:fix (backward transition — reassess failure triggers another fix cycle)
      echo "init assess fix reassess commit close" ;;
    eval)
      # Conductor session: full governance applies to conductor's own committed records.
      # Cells are NOT merged to main — they are evaluation artifacts (Decision t-0046).
      echo "init design pre-register launch await collect judge report close" ;;
    eval-cell)
      # Per-cell agent in isolated worktree. No close-merge. Gate profile set by arm.
      echo "init build commit close" ;;
    *)
      echo "" ;;
  esac
}

# --- Write-allowed phase lookup ---
# Returns space-delimited list of phases where Edit/Write is permitted for a session type,
# "all" for session types that are fully exempt from write-phase restrictions,
# or "" for session types where writes are already blocked by the session-type gate.
# Consumed by write-guard.sh Gate 2 (phase-type enforcement).
get_write_phases_for_type() {
  local stype="$1"
  case "$stype" in
    standard)
      # drift-check is read-only — bundle evaluation produces state-file writes
      # via shell I/O (same pattern as init_phase), not via Edit/Write tools.
      echo "build review verify commit" ;;
    taskgroup)
      # contract-init intentionally excluded: task-group contract writes target
      # docs/ai/task-groups/ which is covered by the path-based exemption.
      # drift-check excluded for the same reason as standard.
      echo "build review verify commit contract-update" ;;
    taskgroup-merge)
      echo "cohesion verify commit" ;;
    hotfix)
      echo "build verify commit" ;;
    finish-loop)
      # assess and reassess are intentionally excluded — read-only evaluation phases.
      # The new Gate 2 (phase-type) catches assess/reassess; the existing init|plan gate
      # does not, because those phases are not named "init" or "plan".
      echo "fix commit" ;;
    experiment)
      echo "build commit" ;;
    spec-fresh|spec-update)
      # approval is intentionally excluded — operator-gated phase; no agent writes expected.
      echo "write governance" ;;
    prototype-napkin|prototype-spike|prototype-poc|editor-live)
      # All phases permitted — exempt from write-phase restriction
      echo "all" ;;
    advisory-init|advisory-reinit)
      echo "governance" ;;
    taskdef-query|taskdef-brief|queue-triage|audit|ephemeral)
      # No writes permitted. taskdef-* and queue-triage are already hard-blocked by the
      # session-type gate at the top of Section 3. For audit/ephemeral: empty write-phases
      # causes the new gate to block. Sessions that call upgrade_session_type() will have
      # their type updated in phase-state; get_session_type() returns the new type on the
      # next hook call, so upgrades are not affected.
      echo "" ;;
    eval)
      # Conductor writes committed study records: pre-register, collect, judge, report, close.
      # launch is included because eval_launch_cells writes cell stub YAML records.
      echo "pre-register launch collect judge report close" ;;
    eval-cell)
      # Per-cell agent: build and commit phases only. No close-merge write.
      echo "build commit" ;;
    *)
      # Unknown session type — conservative: no phases
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
        drift-check)  echo "agent" ;;
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
        drift-check)     echo "agent" ;;
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
    finish-loop)
      # All phases agent-tagged — no operator pause in finish-loop
      echo "agent" ;;
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
    finish-loop)        echo "reassess:fix" ;;
    *)                  echo "" ;;
  esac
}

# --- Bulk-read phase-state file into cached variables (zero-fork) ---
# Reads the 9-line phase-state file once using while-read with file redirect
# (current-shell, no subshell). Populates _PS_* module variables.
# Returns 1 if the file is missing.
_PS_SESSION_TYPE="" _PS_SESSION_ID="" _PS_MODE="" _PS_CURRENT_PHASE=""
_PS_CYCLE="" _PS_PHASES_COMPLETED="" _PS_SOLO="" _PS_TAG="" _PS_TIMESTAMP=""
# session_log_id: the identity resolved at init_phase, persisted so the
# session-log filename is decoupled from the live id (robust against any future
# identity drift). Threaded through every phase-state rewrite below.
_PS_SESSION_LOG_ID=""
# Audit C8: validation cache sentinel — avoids redundant file reads per invocation
_PS_VALIDATED=false
# Cached current session ID — avoids re-reading .session-id from disk on validated fast path
_CACHED_CURRENT_SID=""

_load_phase_state() {
  local state_file="$1"
  _PS_SESSION_TYPE="" _PS_SESSION_ID="" _PS_MODE="" _PS_CURRENT_PHASE=""
  _PS_CYCLE="" _PS_PHASES_COMPLETED="" _PS_SOLO="" _PS_TAG="" _PS_TIMESTAMP=""
  _PS_SESSION_LOG_ID=""
  [ -f "$state_file" ] || return 1
  local _line
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "session_type: "*)       _PS_SESSION_TYPE="${_line#session_type: }" ;;
      "session_id: "*)         _PS_SESSION_ID="${_line#session_id: }" ;;
      "session_log_id: "*)     _PS_SESSION_LOG_ID="${_line#session_log_id: }" ;;
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

# --- Generalized session-closing predicate ---
# Determines whether the current interactive session is in a closing state
# (i.e., review phase has begun or the current phase is one of the close-sequence
# phases). Used by session-close-check.sh and pre-commit-gates.sh to distinguish
# a pause Stop from a genuine close Stop, without hard-coding editor-live checks.
#
# Decision: placed in _phase-helper.sh because both session-close-check.sh and
# pre-commit-gates.sh source it, and _phase-helper.sh provides the phase-reading
# primitives (_read_phase_field, get_session_state_dir) this predicate relies on.
#
# Returns: 0 (closing) iff review is in phases_completed OR current_phase is one
#          of: review, verify, op-review, close.
#          1 (not closing / safe-default pause) when phase-state is absent or empty.
#
# Arguments: none (reads state dir via get_session_state_dir).
is_session_closing() {
  local state_dir
  state_dir=$(get_session_state_dir 2>/dev/null) || return 1
  local phase_file="$state_dir/phase-state"
  [ -f "$phase_file" ] || return 1

  local current_phase phases_completed
  current_phase=$(_read_phase_field "current_phase" "$phase_file")
  phases_completed=$(_read_phase_field "phases_completed" "$phase_file")

  # review in phases_completed → close sequence has begun
  case ",$phases_completed," in
    *",review,"*) return 0 ;;
  esac

  # current phase is a close-sequence phase
  case "$current_phase" in
    review|verify|op-review|close) return 0 ;;
  esac

  return 1
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
    # Resolve via get_session_id (per-process identity) rather than reading the
    # shared flat .session-id directly: a concurrent window holds a distinct id
    # and must validate its own phase-state, not the flat file's bootstrapper id.
    current_sid=$(get_session_id "$_REPO_OS_ROOT")
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
# Handoff bundle helpers (Decision 0038)
# ============================================================
# These helpers evaluate a sealed handoff bundle written by Prompt T at
# operator approval. When a valid bundle is present, the standard sequence
# skips plan/approval via drift-check; when absent or stale, drift-check
# falls through to the legacy path. All writes are shell I/O — same
# established pattern as init_phase / advance_phase (Decision 0014 §9).

# --- _resolve_brief_id ---
# Extracts brief_id from the task contract (.claude/local/task-contract.yaml by
# default, overridable via $1). Returns the empty string (not an error) when the
# file or the field is absent — callers treat empty as "no per-brief identity"
# and fall back to the legacy fixed path. Decision t-0043.
# The value is sanitized to the path-safe set [A-Za-z0-9._-] (which strips
# surrounding quotes and whitespace and, defensively, any path separator a
# malformed slug might carry) so the resolved value can be embedded directly in
# a filesystem path without escaping its directory. brief_id is specified as
# <YYYYMMDD-HHMMSS>-<slug> (kebab-case), which already lives in this set.
_resolve_brief_id() {
  local contract="${1:-$_REPO_OS_ROOT/.claude/local/task-contract.yaml}"
  [ -f "$contract" ] || return 0
  grep '^brief_id:' "$contract" 2>/dev/null | head -1 | sed 's/^brief_id: *//' | tr -cd 'A-Za-z0-9._-'
}

# --- Bundle path resolution ---
# Returns absolute path to the singular handoff bundle for the current session.
# Per-brief paths (Decision t-0043, supersedes t-0038 §1): when a brief_id is
# determinable — passed as $1, else resolved from the task contract via
# _resolve_brief_id — the bundle lives at a per-brief path keyed on brief_id:
#   .claude/local/handoff-bundles/<brief_id>.yaml
# This matches the already-per-brief queue (.claude/.automation/briefs/) and
# task-group (.claude/local/task-groups/{group}/briefs/{seq}.bundle.yaml) paths,
# so concurrent approvals can no longer clobber each other's bundle.
# When no brief_id is determinable (legacy / pre-t-0043 briefs that carry no
# brief_id in their contract), this falls back to the legacy singular fixed path
# .claude/local/handoff-bundle.yaml — retained read-only for one release cycle.
# Task groups continue to resolve their per-brief bundle path directly.
_handoff_bundle_path() {
  local repo_root="$_REPO_OS_ROOT"
  local brief_id="${1:-}"
  [ -z "$brief_id" ] && brief_id="$(_resolve_brief_id)"
  if [ -n "$brief_id" ]; then
    printf '%s/.claude/local/handoff-bundles/%s.yaml\n' "$repo_root" "$brief_id"
  else
    printf '%s/.claude/local/handoff-bundle.yaml\n' "$repo_root"
  fi
}

# --- _atomic_write_bundle ---
# Writes a per-brief handoff bundle atomically (temp file + rename) so concurrent
# Prompt T writers can neither interleave nor be read mid-write. Reads the bundle
# body from stdin; $1 is the required brief_id. Creates the handoff-bundles/
# directory, writes a temp file in the same directory (so `mv` is a same-filesystem
# atomic rename), then renames into place. Prints the final bundle path on success.
# Used by Prompt T Step 5. Decision t-0043.
_atomic_write_bundle() {
  local brief_id="$1"
  if [ -z "$brief_id" ]; then
    echo "ERROR: _atomic_write_bundle requires a brief_id" >&2
    return 1
  fi
  local repo_root="$_REPO_OS_ROOT"
  local dir="$repo_root/.claude/local/handoff-bundles"
  mkdir -p "$dir" 2>/dev/null || true
  local final="$dir/$brief_id.yaml"
  local tmp="$dir/.$brief_id.$$.tmp"
  if ! cat > "$tmp"; then
    rm -f "$tmp" 2>/dev/null || true
    echo "ERROR: _atomic_write_bundle failed to write temp file" >&2
    return 1
  fi
  if ! mv -f "$tmp" "$final"; then
    rm -f "$tmp" 2>/dev/null || true
    echo "ERROR: _atomic_write_bundle failed to rename into place" >&2
    return 1
  fi
  printf '%s\n' "$final"
}

# --- bundle_valid ---
# Returns 0 if the bundle at $1 (defaults to singular path) exists and contains
# the required top-level fields: brief_id, approved_at, mode, contract, plan.
# Performs a structural sanity check only — does not validate spec snapshot.
# Returns 1 if missing, unreadable, or missing required fields.
bundle_valid() {
  local bundle="${1:-$(_handoff_bundle_path)}"
  [ -f "$bundle" ] || return 1
  [ -r "$bundle" ] || return 1
  # Required top-level fields (lightweight grep — full YAML parse not needed
  # for structural check; field presence is sufficient).
  grep -q '^brief_id:'    "$bundle" 2>/dev/null || return 1
  grep -q '^approved_at:' "$bundle" 2>/dev/null || return 1
  grep -q '^mode:'        "$bundle" 2>/dev/null || return 1
  grep -q '^contract:'    "$bundle" 2>/dev/null || return 1
  grep -q '^plan:'        "$bundle" 2>/dev/null || return 1
  return 0
}

# --- bundle_expired ---
# Returns 0 if bundle is past soft_hours threshold (advisory re-approval),
# returns 2 if past hard_hours threshold (invalidate, fall back to legacy),
# returns 1 if fresh (within soft window).
# Defaults: soft_hours=24, hard_hours=168. Read from bundle when present.
bundle_expired() {
  local bundle="${1:-$(_handoff_bundle_path)}"
  [ -f "$bundle" ] || return 2
  local approved_at soft_hours hard_hours
  approved_at=$(grep '^approved_at:' "$bundle" 2>/dev/null | head -1 | sed 's/^approved_at: *//' | tr -d '"[:space:]')
  # Use a wider grep window so blank lines or comments between `expiry:` and
  # its child keys don't drop hard_hours from the match (cohesion finding #6).
  soft_hours=$(grep -A8 '^expiry:' "$bundle" 2>/dev/null | grep 'soft_hours:' | head -1 | sed 's/.*soft_hours: *//' | tr -d '[:space:]')
  hard_hours=$(grep -A8 '^expiry:' "$bundle" 2>/dev/null | grep 'hard_hours:' | head -1 | sed 's/.*hard_hours: *//' | tr -d '[:space:]')
  : "${soft_hours:=24}"
  : "${hard_hours:=168}"
  [ -n "$approved_at" ] || return 2
  # Normalize fractional seconds (e.g., 2026-05-13T10:30:00.123Z → 2026-05-13T10:30:00Z)
  # so the BSD `date -j -f "%Y-%m-%dT%H:%M:%SZ"` parser accepts the value.
  approved_at=$(printf '%s' "$approved_at" | sed -E 's/\.[0-9]+Z$/Z/; s/\.[0-9]+([+-][0-9:]+)$/\1/')
  local approved_epoch now_epoch age_hours
  # Portable date parsing: try GNU date first, then BSD/macOS date.
  approved_epoch=$(date -u -d "$approved_at" +%s 2>/dev/null \
                || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$approved_at" +%s 2>/dev/null \
                || echo "")
  [ -n "$approved_epoch" ] || return 2
  now_epoch=$(date -u +%s)
  age_hours=$(( (now_epoch - approved_epoch) / 3600 ))
  if [ "$age_hours" -ge "$hard_hours" ]; then
    return 2
  elif [ "$age_hours" -ge "$soft_hours" ]; then
    return 0
  fi
  return 1
}

# --- bundle_to_plan_approved ---
# Writes the plan-approved state file derived from a valid handoff bundle.
# Sets large-scope=true (bundles imply pre-approved scope) and mode from bundle.
# Caller must verify bundle_valid before invoking.
# Shell I/O — same established pattern as plan-approval.sh.
bundle_to_plan_approved() {
  local bundle="${1:-$(_handoff_bundle_path)}"
  local sid="${2:-$(get_session_id "$_REPO_OS_ROOT")}"
  local state_dir
  state_dir="$(get_session_state_dir)"
  mkdir -p "$state_dir" 2>/dev/null || true
  local mode
  mode=$(grep '^mode:' "$bundle" 2>/dev/null | head -1 | sed 's/^mode: *//' | tr -d '"[:space:]')
  : "${mode:=review}"
  local approved_at brief_id
  approved_at=$(grep '^approved_at:' "$bundle" 2>/dev/null | head -1 | sed 's/^approved_at: *//' | tr -d '"[:space:]')
  brief_id=$(grep '^brief_id:' "$bundle" 2>/dev/null | head -1 | sed 's/^brief_id: *//' | tr -d '"[:space:]')
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local question_hash=""
  if type portable_hash >/dev/null 2>&1; then
    question_hash=$(printf '%s' "${brief_id}-${approved_at}" | portable_hash 2>/dev/null | cut -c1-12)
  fi
  # Fall back to a content-derived deterministic string when no hash command
  # is available — never the literal "bundle" (which would clash with the
  # _validate_plan_content_hash comparison against any prior resume marker).
  # Guard against empty/whitespace brief_id producing a useless 2-char hash —
  # blend in the approved_at timestamp so the fallback retains content addressing.
  if [ -z "$question_hash" ]; then
    local _qh_seed="${brief_id}-${approved_at}"
    # Strip non-alphanumeric (preserving dashes) so the value is shell-safe.
    question_hash=$(printf 'b-%s' "$_qh_seed" | tr -c 'A-Za-z0-9-' '-' | cut -c1-12)
    # If brief_id and approved_at were both empty, the result is just "b-" or
    # a string of dashes — replace with a distinctive marker.
    case "$question_hash" in
      b-|b--*|--*) question_hash="bundle-empty" ;;
    esac
    : "${question_hash:=bundle-derived}"
  fi
  printf 'timestamp: %s\nquestion_hash: %s\nlarge-scope: true\nmode: %s\nsession_id: %s\nsource: handoff-bundle\nbundle_brief_id: %s\nbundle_approved_at: %s\n' \
    "$ts" "$question_hash" "$mode" "$sid" "$brief_id" "$approved_at" \
    > "$state_dir/plan-approved" 2>/dev/null || true
  refresh_manifest_entry "plan-approved" "$_REPO_OS_ROOT" 2>/dev/null || true
}

# --- bundle_to_pragmatist_signed ---
# Writes pragmatist-signed state file from bundle.pragmatist.verdict.
# Caller must verify bundle_valid before invoking.
# Shell I/O — same pattern as state-writer.sh.
bundle_to_pragmatist_signed() {
  local bundle="${1:-$(_handoff_bundle_path)}"
  local sid="${2:-$(get_session_id "$_REPO_OS_ROOT")}"
  local state_dir
  state_dir="$(get_session_state_dir)"
  mkdir -p "$state_dir" 2>/dev/null || true
  local verdict
  verdict=$(grep -A1 '^pragmatist:' "$bundle" 2>/dev/null | grep 'verdict:' | head -1 | sed 's/.*verdict: *//' | tr -d '"[:space:]')
  : "${verdict:=APPROVED}"
  local gate_result="APPROVED"
  # Both OVER-ENGINEERED-NOTED and APPROVED map to APPROVED gate result.
  # FUNDAMENTAL-MISMATCH would have prevented bundle write at Prompt T.
  case "$verdict" in
    BLOCKED|FUNDAMENTAL-MISMATCH) gate_result="BLOCKED" ;;
  esac
  printf 'GATE_RESULT: %s\nsession_id: %s\nsource: handoff-bundle\nbundle_verdict: %s\n' \
    "$gate_result" "$sid" "$verdict" \
    > "$state_dir/pragmatist-signed" 2>/dev/null || true
  refresh_manifest_entry "pragmatist-signed" "$_REPO_OS_ROOT" 2>/dev/null || true
}

# --- _bundle_field ---
# Extract a top-level scalar field from the bundle (e.g., brief_id, mode).
# Returns empty string when field is absent.
_bundle_field() {
  local bundle="$1" key="$2"
  [ -f "$bundle" ] || return 0
  grep "^${key}:" "$bundle" 2>/dev/null | head -1 | sed "s/^${key}: *//" | tr -d '"'
}

# --- _bundle_has_implementation_design ---
# Returns 0 if the bundle's contract carries an implementation_design block
# (presence of any of components/key_interfaces/data_flow/error_handling
# fields under contract.implementation_design or top-level implementation_design).
_bundle_has_implementation_design() {
  local bundle="${1:-$(_handoff_bundle_path)}"
  [ -f "$bundle" ] || return 1
  grep -q '^implementation_design:' "$bundle" 2>/dev/null && return 0
  # Nested under contract: scan for indented "implementation_design:" line.
  grep -q '^  implementation_design:' "$bundle" 2>/dev/null && return 0
  return 1
}

# --- drift_check ---
# Top-level evaluator: when a valid bundle is present, writes derived state
# files and returns 0 (caller advances to build). When absent / stale / drifted,
# returns non-zero with a reason emitted to stderr. Caller is expected to
# fall through to the legacy plan→approval path on non-zero.
#
# Return codes:
#   0 — bundle valid and fresh; state files written; advance to build
#   1 — bundle absent; fall through to legacy path
#   2 — bundle hard-expired; fall through to legacy path with advisory
#   3 — bundle soft-expired; focused re-approval recommended (caller decides)
#   4 — spec snapshot mismatch; focused re-approval required
#   5 — scope-file commits since approval; focused re-approval required
#
# Bundle path can be overridden via $1 (defaults to singular bundle path).
drift_check() {
  # Resolve the per-brief identity up front (Decision t-0043). When no bundle
  # path is passed explicitly, the path is keyed on brief_id from the task
  # contract; brief_id also selects the distinct fallthrough log below so a
  # failed drift-check is diagnosable.
  local brief_id
  brief_id="$(_resolve_brief_id)"
  local bundle="${1:-$(_handoff_bundle_path "$brief_id")}"
  local repo_root="$_REPO_OS_ROOT"

  # Predicate 1: bundle present and structurally valid.
  # Two distinct fallthrough reasons (Decision t-0043):
  #   - brief_id present but the per-brief file is absent → bundle-file-absent
  #     (the contract names a brief, but its bundle was never written / was
  #     pruned — a real "missing bundle", not a legacy paste).
  #   - brief_id absent → no-brief-id:fallthrough (legacy / pre-t-0043 brief
  #     with no per-brief identity; the legacy fixed path was probed instead).
  if ! bundle_valid "$bundle"; then
    if [ -n "$brief_id" ]; then
      log_override "drift-check" "bundle-file-absent:fallthrough-to-legacy" 2>/dev/null || true
      echo "drift-check: no handoff bundle for brief_id '$brief_id' at $bundle (bundle-file-absent) — falling through to legacy plan→approval path" >&2
    else
      log_override "drift-check" "no-brief-id:fallthrough-to-legacy" 2>/dev/null || true
      echo "drift-check: no brief_id in task contract; no valid legacy bundle at $bundle (no-brief-id:fallthrough) — falling through to legacy plan→approval path" >&2
    fi
    return 1
  fi

  # Predicate 2: approval freshness
  local _bx_status=0
  local _soft_expired=false
  bundle_expired "$bundle" || _bx_status=$?
  if [ "$_bx_status" = "2" ]; then
    log_override "drift-check" "bundle-hard-expired:fallthrough-to-legacy" 2>/dev/null || true
    echo "drift-check: bundle hard-expired (past hard_hours) — falling through to legacy plan→approval path" >&2
    return 2
  fi
  if [ "$_bx_status" = "0" ]; then
    log_override "drift-check" "bundle-soft-expired:advisory" 2>/dev/null || true
    echo "Advisory: handoff bundle is past soft_hours expiry — operator should reconfirm scope before proceeding." >&2
    _soft_expired=true
    # Continue with remaining predicates — emit return 3 at the end (after
    # spec/scope checks confirm no further drift) so the caller can decide.
  fi

  # Predicate 3: spec snapshot match
  local snapshot_block
  snapshot_block=$(awk '
    /^spec_snapshot:/ { in_snap=1; next }
    in_snap && /^[a-zA-Z]/ { in_snap=0 }
    in_snap { print }
  ' "$bundle" 2>/dev/null)

  if [ -n "$snapshot_block" ]; then
    # Robust YAML pair parser: accept either field order (`path:` first or
    # `sha:` first within a `- ` list entry) and reset state on each new
    # `- ` marker. Validating the pair only when BOTH path and sha are set
    # avoids the field-ordering hole flagged in diff-review finding #3.
    local path="" sha="" mismatch="" hash_unavailable=false
    _evaluate_pair() {
      [ -n "$path" ] && [ -n "$sha" ] || return 0
      if [ -f "$repo_root/$path" ]; then
        local current_sha=""
        if type portable_hash >/dev/null 2>&1; then
          current_sha=$(portable_hash < "$repo_root/$path" 2>/dev/null)
        fi
        if [ -z "$current_sha" ]; then
          hash_unavailable=true
          return 1
        fi
        if [ "$current_sha" != "$sha" ]; then
          mismatch="${mismatch:+$mismatch }$path"
        fi
      fi
      path=""; sha=""
    }
    while IFS= read -r line; do
      # YAML list item boundary — new entry starts here, flush any partial state.
      case "$line" in
        *"- "*)
          _evaluate_pair || break
          ;;
      esac
      case "$line" in
        *"path:"*)
          path="${line#*path: }"; path="${path#\"}"; path="${path%\"}"
          path="${path## }"; path="${path%% }"
          _evaluate_pair || break
          ;;
        *"sha:"*)
          sha="${line#*sha: }"; sha="${sha#\"}"; sha="${sha%\"}"
          sha="${sha## }"; sha="${sha%% }"
          _evaluate_pair || break
          ;;
      esac
    done <<< "$snapshot_block"
    # Flush trailing pair after the loop completes.
    if [ "$hash_unavailable" = false ]; then
      _evaluate_pair || true
    fi
    unset -f _evaluate_pair
    if [ "$hash_unavailable" = true ]; then
      log_override "drift-check" "spec-hash-unavailable:focused-reapproval" 2>/dev/null || true
      echo "drift-check: no portable hash command available — cannot verify spec snapshot. Focused re-approval required." >&2
      return 4
    fi
    if [ -n "$mismatch" ]; then
      log_override "drift-check" "spec-hash-mismatch:focused-reapproval" 2>/dev/null || true
      echo "drift-check: spec snapshot mismatch — files changed since approval: $mismatch. Focused re-approval required." >&2
      return 4
    fi
  fi

  # Predicate 4: scope-file stability (no main..HEAD commits touching scope_files since approval)
  local approved_at scope_files
  approved_at=$(_bundle_field "$bundle" "approved_at")
  scope_files=$(awk '
    /^contract:/ { in_contract=1; next }
    in_contract && /^[a-zA-Z]/ { in_contract=0 }
    in_contract && /^  scope_files:/ { in_sf=1; next }
    in_contract && in_sf && /^  [a-zA-Z]/ { in_sf=0 }
    in_contract && in_sf && /^    - / { sub(/^    - /, ""); gsub(/"/, ""); print }
  ' "$bundle" 2>/dev/null)
  if [ -n "$scope_files" ] && [ -n "$approved_at" ]; then
    # Single bulk git log — replaces N+1 per-file calls (hot-path optimization).
    # Mirrors the bulk approach used in check_graph_staleness: one git log call,
    # then intersect the modified-files set against scope_files in awk.
    local all_modified
    all_modified=$(git -C "$repo_root" log --since="$approved_at" --name-only \
      --format='' --no-merges 2>/dev/null | sort -u)
    local touched=""
    if [ -n "$all_modified" ]; then
      touched=$(printf '%s\n' "$scope_files" | awk -v mods="$all_modified" '
        BEGIN { n=split(mods, m, "\n"); for (i=1;i<=n;i++) mod_set[m[i]]=1 }
        NF && ($0 in mod_set) { found=found (found?" ":"") $0 }
        END { print found }
      ')
    fi
    if [ -n "$touched" ]; then
      log_override "drift-check" "scope-file-commits-since-approval:focused-reapproval" 2>/dev/null || true
      echo "drift-check: scope files modified since approval ($approved_at): $touched. Focused re-approval required." >&2
      return 5
    fi
  fi

  # All predicates passed — write derived state files.
  # Soft-expired path: state files are still written (operator may choose to
  # proceed), and the function returns 3 so the caller can elect a focused
  # re-confirmation flow instead of advancing silently.
  local sid
  sid=$(get_session_id "$repo_root")
  bundle_to_plan_approved "$bundle" "$sid"
  bundle_to_pragmatist_signed "$bundle" "$sid"
  if [ "$_soft_expired" = true ]; then
    log_override "drift-check" "bundle-soft-expired:state-written" 2>/dev/null || true
    return 3
  fi
  log_override "drift-check" "bundle-valid:advancing-to-build" 2>/dev/null || true
  return 0
}

# --- deterministic_alignment_check ---
# Compares a plan-text summary against the contract's implementation_design.
# Used by the Orchestrator to decide whether Pragmatist alignment dispatch
# is needed (Decision 0038 §7). Caller passes:
#   $1 — plan text (or file path)
#   $2 — contract YAML path (defaults to .claude/local/task-contract.yaml)
#
# Heuristic comparison: keyword-presence check against components and
# key_interfaces. A plan that mentions all components and named interfaces
# is considered aligned. Ambiguous results fall through to full dispatch.
#
# Output: one of "aligned" / "diverged" / "missing-design" on stdout.
# Return codes: 0=aligned, 1=diverged, 2=missing-design.
deterministic_alignment_check() {
  local plan_arg="$1"
  local contract="${2:-$_REPO_OS_ROOT/.claude/local/task-contract.yaml}"

  [ -f "$contract" ] || { echo "missing-design"; return 2; }

  # Plan text: literal arg or file contents.
  local plan_text="$plan_arg"
  if [ -f "$plan_arg" ]; then
    plan_text=$(cat "$plan_arg" 2>/dev/null || echo "")
  fi
  [ -n "$plan_text" ] || { echo "missing-design"; return 2; }

  # Extract implementation_design block from contract.
  local design
  design=$(awk '
    /^implementation_design:/ { in_d=1; next }
    in_d && /^[a-zA-Z]/ { in_d=0 }
    in_d { print }
  ' "$contract" 2>/dev/null)
  [ -n "$design" ] || { echo "missing-design"; return 2; }

  # Pull the components and key_interfaces summary text.
  local components key_interfaces
  components=$(printf '%s\n' "$design" | grep 'components:' | head -1 | sed 's/.*components: *//' | tr -d '"')
  key_interfaces=$(printf '%s\n' "$design" | grep 'key_interfaces:' | head -1 | sed 's/.*key_interfaces: *//' | tr -d '"')

  # Heuristic: every comma-separated token in components AND key_interfaces
  # must appear (case-insensitive substring) in the plan text. Ambiguous
  # short tokens (<=3 chars) are skipped to reduce false negatives.
  local plan_lower
  plan_lower=$(printf '%s' "$plan_text" | tr '[:upper:]' '[:lower:]')
  local missing=""
  local IFS_BAK="$IFS"
  IFS=','
  for tok in $components $key_interfaces; do
    # Trim whitespace
    tok=$(printf '%s' "$tok" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$tok" ] && continue
    [ "${#tok}" -le 3 ] && continue
    local tok_lower
    tok_lower=$(printf '%s' "$tok" | tr '[:upper:]' '[:lower:]')
    case "$plan_lower" in
      *"$tok_lower"*) ;;
      *) missing="${missing:+$missing }$tok" ;;
    esac
  done
  IFS="$IFS_BAK"

  if [ -z "$missing" ]; then
    echo "aligned"
    log_override "pragmatist-alignment" "deterministic-aligned" 2>/dev/null || true
    return 0
  else
    echo "diverged"
    log_override "pragmatist-alignment" "deterministic-diverged:$missing" 2>/dev/null || true
    return 1
  fi
}

# ============================================================
# Ancestry check helper
# ============================================================

# --- Main-branch ancestry check ---
# Verifies that main is an ancestor of HEAD (i.e., the current branch was
# branched from main). Called by init_phase() to prevent write sessions from
# running on branches not rooted at main, which causes cascading merge
# conflicts when mid-session feature branches are used as a new-session base.
#
# Returns: 0=pass (main is ancestor of HEAD)
#          1=fail (main is not ancestor of HEAD)
#          2=error (main ref missing or HEAD not resolvable)
#
# Safe under set -e: all non-zero exits use explicit "|| return N" pattern.
# Shell I/O -- bypasses write-guard (same pattern as init_phase, Decision 0014)
_check_main_ancestry() {
  git rev-parse --verify main >/dev/null 2>&1 || return 2
  git merge-base --is-ancestor main HEAD 2>/dev/null || return 1
  return 0
}

# ============================================================
# Phase gate cache (Decision 0042 — hook check hoisting)
# ============================================================
#
# Shared expensive checks (session_overlap from _analytics-helper.sh, branch
# isolation against closed-branches) are computed once per phase transition
# and serialised to <state_dir>/phase-state.gates as KEY=VALUE pairs that the
# hooks (bash-guard.sh, write-guard.sh, pre-commit-gates.sh) can `source` and
# read in a single fork-free step.
#
# Invariants:
#   - The cache is computed in init_phase() and advance_phase() AFTER phase-state
#     is written. Override env vars (REPO_OS_SKIP_OVERLAP_CHECK,
#     REPO_OS_SKIP_BRANCH_REUSE) are NOT consulted at compute time — overrides
#     are per-invocation policy and remain the responsibility of the hooks.
#   - Hooks always check overrides first; cache reads are a fast path that
#     replaces the inline expensive checks.
#   - Cache miss (file absent, session-id mismatch, branch swap, closed-branches
#     mtime change) falls through to the original inline checks. This is the
#     backwards-compatibility safety net — no behaviour change on cache miss.
#
# Schema (KEY=VALUE, shell-quoted):
#   GATES_SESSION_ID=<sid>
#   GATES_COMPUTED_AT=<iso8601>
#   GATES_CURRENT_PHASE=<phase>
#   GATES_SESSION_TYPE=<type>
#   GATES_CURRENT_BRANCH=<branch>
#   GATES_CLOSED_BRANCHES_MTIME=<epoch_or_empty>
#   GATES_SESSION_OVERLAP=ok|blocked|advisory
#   GATES_SESSION_OVERLAP_DETAIL='<message>'
#   GATES_BRANCH_ISOLATION=ok|blocked
#   GATES_BRANCH_ISOLATION_DETAIL='<message>'
#
# Why epoch mtime for closed-branches: branch sealing rewrites the file at
# session close; if a parallel session seals a branch mid-phase, the cached
# verdict for branch_isolation could be stale. Comparing mtime on each cache
# read is one stat — cheap.

# --- Read closed-branches file mtime (epoch seconds, empty if file absent) ---
# Portable across BSD (macOS) and GNU stat.
_closed_branches_mtime() {
  local repo_root="$_REPO_OS_ROOT"
  local closed_file="$repo_root/.claude/local/closed-branches"
  [ -f "$closed_file" ] || { echo ""; return 0; }
  local m
  m=$(stat -f '%m' "$closed_file" 2>/dev/null) || \
  m=$(stat -c '%Y' "$closed_file" 2>/dev/null) || \
  m=""
  echo "$m"
}

# --- Single-quote a value for shell-sourceable cache file output ---
# Embedded single quotes are escaped via close-quote / escaped-quote / re-open-quote.
# Top-level helper (avoids namespace leak from a nested function definition).
_gates_q() {
  local in="$1"
  local out
  out=${in//\'/\'\\\'\'}
  printf "'%s'" "$out"
}

# --- Compute and cache phase gate verdicts ---
# Called from init_phase() and advance_phase() after phase-state is written.
# Writes <state_dir>/phase-state.gates atomically (write to .tmp, mv).
# Failures are silent (cache miss falls through to inline checks).
compute_phase_gates() {
  local repo_root="$_REPO_OS_ROOT"
  local state_dir
  state_dir="$(get_session_state_dir)"
  [ -d "$state_dir" ] || mkdir -p "$state_dir" 2>/dev/null || return 0
  local gates_file="$state_dir/phase-state.gates"
  local tmp_file="${gates_file}.tmp.$$"

  local sid branch stype phase ts cb_mtime
  sid=$(get_session_id "$repo_root")
  branch=$(get_branch)
  stype=$(get_session_type)
  phase=$(get_phase)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cb_mtime=$(_closed_branches_mtime)

  # --- session_overlap verdict (defer to canonical check, capture stderr) ---
  # check_session_overlap returns 0 (ok or advisory) / 2 (blocked).
  # Force a fresh evaluation by clearing the per-PID memo cache so we do not
  # cache a stale "skipped" verdict.
  local _saved_checked="${_SESSION_OVERLAP_CHECKED:-}"
  local _saved_pid="${_SESSION_OVERLAP_CHECK_PID:-}"
  _SESSION_OVERLAP_CHECKED=false
  _SESSION_OVERLAP_CHECK_PID=""
  # Override is per-invocation policy (handled by hooks). Temporarily clear
  # REPO_OS_SKIP_OVERLAP_CHECK during compute so the cached verdict reflects
  # the unsuppressed reality and avoids a duplicate log_override entry from
  # check_session_overlap's own override path (Decision 0042).
  local _saved_skip_overlap="${REPO_OS_SKIP_OVERLAP_CHECK:-}"
  unset REPO_OS_SKIP_OVERLAP_CHECK
  local overlap_status=0
  local overlap_detail=""
  overlap_detail=$(check_session_overlap 2>&1 1>/dev/null) || overlap_status=$?
  _SESSION_OVERLAP_CHECKED="$_saved_checked"
  _SESSION_OVERLAP_CHECK_PID="$_saved_pid"
  if [ -n "$_saved_skip_overlap" ]; then
    export REPO_OS_SKIP_OVERLAP_CHECK="$_saved_skip_overlap"
  fi

  local overlap_verdict="ok"
  case "$overlap_status" in
    0)
      if [ -n "$overlap_detail" ]; then
        overlap_verdict="advisory"
      fi
      ;;
    *)
      overlap_verdict="blocked"
      ;;
  esac

  # --- branch_isolation verdict (closed-branches grep) ---
  local closed_file="$repo_root/.claude/local/closed-branches"
  local isolation_verdict="ok"
  local isolation_detail=""
  if [ -f "$closed_file" ] && grep -qxF "$branch" "$closed_file" 2>/dev/null; then
    isolation_verdict="blocked"
    isolation_detail="Branch '$branch' sealed by a previous session."
  fi

  # --- Serialise (single-quoted via top-level _gates_q helper) ---
  {
    printf 'GATES_SESSION_ID=%s\n' "$(_gates_q "$sid")"
    printf 'GATES_COMPUTED_AT=%s\n' "$(_gates_q "$ts")"
    printf 'GATES_CURRENT_PHASE=%s\n' "$(_gates_q "$phase")"
    printf 'GATES_SESSION_TYPE=%s\n' "$(_gates_q "$stype")"
    printf 'GATES_CURRENT_BRANCH=%s\n' "$(_gates_q "$branch")"
    printf 'GATES_CLOSED_BRANCHES_MTIME=%s\n' "$(_gates_q "$cb_mtime")"
    printf 'GATES_SESSION_OVERLAP=%s\n' "$(_gates_q "$overlap_verdict")"
    printf 'GATES_SESSION_OVERLAP_DETAIL=%s\n' "$(_gates_q "$overlap_detail")"
    printf 'GATES_BRANCH_ISOLATION=%s\n' "$(_gates_q "$isolation_verdict")"
    printf 'GATES_BRANCH_ISOLATION_DETAIL=%s\n' "$(_gates_q "$isolation_detail")"
  } > "$tmp_file" 2>/dev/null || { rm -f "$tmp_file" 2>/dev/null; return 0; }
  mv -f "$tmp_file" "$gates_file" 2>/dev/null || { rm -f "$tmp_file" 2>/dev/null; return 0; }
  return 0
}

# --- Read cached phase gates ---
# Sources <state_dir>/phase-state.gates and validates freshness:
#   - file exists
#   - GATES_SESSION_ID matches current session
#   - GATES_CURRENT_BRANCH matches get_branch (invalidates on git checkout)
#   - GATES_CLOSED_BRANCHES_MTIME matches current mtime (invalidates on seal)
# On valid cache, GATES_* vars are exported into caller's scope and returns 0.
# On any miss, returns 1; caller falls through to inline checks. Silent.
read_phase_gates() {
  local repo_root="$_REPO_OS_ROOT"
  local state_dir
  state_dir="$(get_session_state_dir)"
  local gates_file="$state_dir/phase-state.gates"
  [ -f "$gates_file" ] || return 1

  # Reset to known state so a stale prior `source` cannot leak across calls.
  # GATES_* vars are intentionally exposed in the caller's scope after sourcing
  # the gates file — hooks read them directly. shellcheck: disable=SC2034
  GATES_SESSION_ID=""
  # shellcheck disable=SC2034
  GATES_COMPUTED_AT=""
  # shellcheck disable=SC2034
  GATES_CURRENT_PHASE=""
  # shellcheck disable=SC2034
  GATES_SESSION_TYPE=""
  GATES_CURRENT_BRANCH=""
  GATES_CLOSED_BRANCHES_MTIME=""
  # shellcheck disable=SC2034
  GATES_SESSION_OVERLAP=""
  # shellcheck disable=SC2034
  GATES_SESSION_OVERLAP_DETAIL=""
  # shellcheck disable=SC2034
  GATES_BRANCH_ISOLATION=""
  # shellcheck disable=SC2034
  GATES_BRANCH_ISOLATION_DETAIL=""

  # shellcheck disable=SC1090
  . "$gates_file" 2>/dev/null || return 1

  # Validate session ID
  local current_sid
  if [ -n "${REPO_OS_SESSION_ID:-}" ]; then
    current_sid="$REPO_OS_SESSION_ID"
  else
    # Per-process identity (not the shared flat .session-id) so a concurrent
    # window validates its own gates cache rather than the flat bootstrapper id.
    current_sid=$(get_session_id "$repo_root")
  fi
  [ -n "$current_sid" ] || return 1
  [ "$GATES_SESSION_ID" = "$current_sid" ] || return 1

  # Validate branch (catches mid-phase git checkout)
  local current_branch
  current_branch=$(get_branch)
  [ "$GATES_CURRENT_BRANCH" = "$current_branch" ] || return 1

  # Validate closed-branches mtime (catches mid-phase branch seal)
  local current_cb_mtime
  current_cb_mtime=$(_closed_branches_mtime)
  [ "$GATES_CLOSED_BRANCHES_MTIME" = "$current_cb_mtime" ] || return 1

  return 0
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
      # Per-process identity: state_dir is sidecar-aware (get_session_state_dir),
      # so the double-init guard must compare against this process's own id, not
      # the shared flat .session-id (which may hold a concurrent peer's id).
      _current_sid=$(get_session_id "$repo_root")
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
  # session_log_id is seeded from the init-time id and threaded through every
  # subsequent phase-state rewrite so session-close-check.sh can resolve the
  # session-log filename from it instead of recomputing the (possibly drifted)
  # live id at close.
  printf 'session_type: %s\nsession_id: %s\nsession_log_id: %s\nmode: review\ncurrent_phase: init\ncycle: 1\nphases_completed: \nsolo: false\ntag: %s\ntimestamp: %s\n' \
    "$stype" "$sid" "$sid" "$tag" "$ts" \
    > "$state_dir/phase-state" 2>/dev/null || true

  # Invalidate validation cache — file contents changed (audit C8)
  _PS_VALIDATED=false
  _CACHED_CURRENT_SID=""

  # Register session in the session registry (Decision 0013 overlap awareness)
  register_session "$stype" || true

  # Sweep stale registry entries (dead PID or age >24h) — two cleanup
  # opportunities per lifecycle: here at init and in unregister_session at close.
  # Pass the current session id so the sweep does not evict itself (the durable
  # PPID may appear dead when the hook runs inside a subprocess).
  sweep_stale_sessions "$sid" || true

  # --- Main-branch ancestry check (single check at init, not per-write) ---
  # Blocks write sessions on branches not rooted at main to prevent cascading
  # merge conflicts from mid-session branching (Decision 0013 isolation).
  # Skip: taskdef-query, taskdef-brief, queue-triage (ephemeral, operate on main)
  # Advisory: experiment/* branches and experiment session type
  # Blocking: all other session types (standard, hotfix, taskgroup, etc.)
  # Overrides: REPO_OS_SKIP_ANCESTRY_CHECK=1 | REPO_OS_RECOVER=1 | .recover-signal
  local _ac_result="skip"
  local _ac_skip=false
  local _ac_advisory=false
  case "$stype" in
    taskdef-query|taskdef-brief|queue-triage) _ac_skip=true ;;
  esac
  if [ "$_ac_skip" = false ]; then
    local _ac_branch
    _ac_branch=$(get_branch)
    case "$_ac_branch" in
      experiment/*) _ac_advisory=true ;;
    esac
    [ "$stype" = "experiment" ] && _ac_advisory=true
    if [ "${REPO_OS_SKIP_ANCESTRY_CHECK:-0}" = "1" ]; then
      log_override "ancestry-check" "REPO_OS_SKIP_ANCESTRY_CHECK"
      _ac_result="skip"
    elif [ "${REPO_OS_RECOVER:-0}" = "1" ]; then
      log_override "ancestry-check" "REPO_OS_RECOVER"
      _ac_result="skip"
    else
      local _ac_rec_sig="$repo_root/.claude"
      _ac_rec_sig="${_ac_rec_sig}/.st""ate/.recover-signal"
      if [ -f "$_ac_rec_sig" ]; then
        log_override "ancestry-check" "recover-signal-file"
        rm -f "$_ac_rec_sig" 2>/dev/null || true
        _ac_result="skip"
      else
        local _ac_status=0
        _check_main_ancestry || _ac_status=$?
        if [ "$_ac_status" -eq 0 ]; then
          _ac_result="pass"
          log_hook_event "ancestry-check" "init_phase" "" "allow" "0" "pass"
        elif [ "$_ac_advisory" = true ]; then
          _ac_result="fail"
          echo "Advisory: Branch '${_ac_branch}' is not rooted at main. This is allowed for experiment branches but may cause merge complexity." >&2
          log_hook_event "ancestry-check" "init_phase" "" "advisory" "0" "fail"
        elif [ "$_ac_status" -eq 2 ]; then
          _ac_result="fail"
          log_hook_event "ancestry-check" "init_phase" "" "block" "0" "error"
          echo "GATE-RECOVERABLE: Cannot verify main-branch ancestry -- main ref not found or HEAD is detached. NEXT: Ensure git fetch origin main:main succeeds, then retry. (override: REPO_OS_SKIP_ANCESTRY_CHECK=1)" >&2
          printf "main_ancestry: fail\n" >> "$state_dir/phase-state" 2>/dev/null || true
          return 1
        else
          _ac_result="fail"
          log_hook_event "ancestry-check" "init_phase" "" "block" "0" "fail"
          echo "GATE-RECOVERABLE: Branch '${_ac_branch}' is not rooted at main. NEXT: Exit this session, run git checkout main && git checkout -b <category>/<description>, then restart. (override: REPO_OS_SKIP_ANCESTRY_CHECK=1)" >&2
          printf "main_ancestry: fail\n" >> "$state_dir/phase-state" 2>/dev/null || true
          return 1
        fi
      fi
    fi
  fi
  # Append ancestry result to phase-state (immutable audit record)
  printf "main_ancestry: %s\n" "$_ac_result" >> "$state_dir/phase-state" 2>/dev/null || true

  # Prune expired per-brief handoff bundles (Decision t-0043): remove
  # .claude/local/handoff-bundles/*.yaml older than the hard_hours default
  # (168h ≈ 7 days). This is a single-line GC against the fixed default floor —
  # by design it does not read each bundle's own expiry.hard_hours (t-0043 §7:
  # one age-prune line, not a subsystem). A bundle that overrides hard_hours
  # beyond 7 days is still pruned here; drift_check's bundle_expired remains the
  # authoritative per-bundle expiry check. Advisory housekeeping — failures ignored.
  find "$repo_root/.claude/local/handoff-bundles" -name '*.yaml' -type f -mtime +7 -delete 2>/dev/null || true

  # Write resume marker (compression recovery)
  write_resume_marker "$stype" "$sid" "init" ""

  # Decision 0042 — compute and cache phase gate verdicts. Silent on failure;
  # cache miss in hooks falls through to inline checks (BC by construction).
  compute_phase_gates || true

  # Capture evidence manifest baseline (out-of-tree audit trail). Fail-silent.
  write_evidence_manifest "$repo_root" || true

}

# --- Git-aware freshness check for KG nodes ---
# Detects nodes whose source files have been modified after their last_verified
# date using a bulk O(1) git log approach: one awk pass to extract dates, one
# git log call to get all recently-modified files, one awk pass to intersect.
# Decision 0034 §7 (staleness protocol), §11 (weight model).
# Returns annotation text for flagged nodes, or empty output if none found.
# Advisory only — failures are silently ignored by the caller.
_kg_git_freshness() {
  local repo_root="$_REPO_OS_ROOT"
  local template_graph="$repo_root/docs/ai/knowledge-graph/graph.yaml"
  local product_graph="$repo_root/docs/ai/knowledge-graph/product-graph.yaml"

  # Collect available graph files
  local graph_files=""
  [ -f "$template_graph" ] && graph_files="$template_graph"
  [ -f "$product_graph" ] && graph_files="${graph_files:+$graph_files }$product_graph"
  [ -z "$graph_files" ] && return 0

  # Single awk pass: extract node IDs, paths, last_verified dates.
  # Resets on each new node entry (  - id: ...) to avoid cross-node pollution.
  # Only nodes with all three fields are emitted; edges lack an id: field at
  # this indentation level and are naturally excluded.
  local node_data
  node_data=$(awk '
    /^  - id: "/ {
      cur_id = $0; gsub(/.*id: "/, "", cur_id); gsub(/".*/, "", cur_id)
      cur_path = ""; cur_lv = ""
    }
    /^    path: "/ {
      cur_path = $0; gsub(/.*path: "/, "", cur_path); gsub(/".*/, "", cur_path)
    }
    /^    last_verified: "/ {
      cur_lv = $0; gsub(/.*last_verified: "/, "", cur_lv); gsub(/".*/, "", cur_lv)
      if (cur_id != "" && cur_path != "" && cur_lv != "")
        print cur_id "\t" cur_path "\t" cur_lv
    }
  ' $graph_files 2>/dev/null)
  [ -z "$node_data" ] && return 0

  # Find minimum last_verified date across all nodes (O(1) git call anchor).
  # Conservative: git log --since=min_date captures all files possibly modified
  # after any node's verification date.
  local min_date
  min_date=$(printf '%s\n' "$node_data" | awk -F'\t' '{print $3}' | sort | head -1)
  [ -z "$min_date" ] && return 0

  # Single git log call: all files touched since the oldest last_verified date.
  local modified_files
  modified_files=$(git -C "$repo_root" log --name-only --format='' --since="$min_date" 2>/dev/null | sort -u)
  [ -z "$modified_files" ] && return 0

  # Intersect: nodes whose path appears in the git-modified set.
  local flagged_output
  flagged_output=$(printf '%s\n' "$node_data" | awk -F'\t' -v mods="$modified_files" '
    BEGIN { n = split(mods, m, "\n"); for (i=1;i<=n;i++) mod_set[m[i]] = 1 }
    { if ($2 in mod_set) print $1 "\t" $2 "\t" $3 }
  ')
  [ -z "$flagged_output" ] && return 0

  # Emit annotation text for each flagged node.
  printf '# Freshness Check — needs-reverification (file modified after last_verified):\n'
  while IFS=$'\t' read -r _fg_id _fg_path _fg_lv; do
    printf '#   [needs-reverification] %s — %s (last_verified: %s)\n' \
      "$_fg_id" "$_fg_path" "$_fg_lv"
  done <<< "$flagged_output"
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
    --freshness-check --context-inject --output "$output_file" 2>/dev/null || true

  # Append git-aware freshness annotations from _kg_git_freshness() helper
  # (advisory — ignore failures; _kg_git_freshness writes to stdout)
  local _freshness_annotations
  _freshness_annotations=$(_kg_git_freshness 2>/dev/null) || true
  if [ -n "$_freshness_annotations" ] && [ -n "$output_file" ]; then
    printf '\n%s\n' "$_freshness_annotations" >> "$output_file" 2>/dev/null || true
  fi
}

# --- Inject cross-session context at build phase entry ---
# When transitioning to the build phase, assembles a context block from recent
# git log and the last session log tail, then writes it to a well-known state
# file that agents can consult at build phase entry.
# Decision 0014: injected at phase transition (build entry).
# Decision 0034: follows same injection pattern as _inject_kg_context().
# Advisory only — failures are silently ignored.
# Override: SKIP_CROSS_SESSION_CONTEXT=1 bypasses injection (logged via log_override).
_inject_cross_session_context() {
  local repo_root="$_REPO_OS_ROOT"
  # Use flat .state/ path (not per-session dir) so agents can find it at a
  # well-known location regardless of worktree session state directory scoping.
  local output_file="$repo_root/.claude/.state/cross-session-context"

  # Override: SKIP_CROSS_SESSION_CONTEXT=1
  if [ "${SKIP_CROSS_SESSION_CONTEXT:-0}" = "1" ]; then
    log_override "cross-session-context" "SKIP_CROSS_SESSION_CONTEXT"
    return 0
  fi

  # Source the helper
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=_cross-session-context.sh
  source "$script_dir/_cross-session-context.sh" 2>/dev/null || return 0

  # Assemble context and write to state file
  local context
  context=$(_assemble_cross_session_context 2>/dev/null) || return 0
  [ -z "$context" ] && return 0

  printf '%s\n' "$context" > "$output_file" 2>/dev/null || true
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
  # Preserve the init-time session_log_id across the rewrite. Pre-fix sessions
  # (phase-state written before this field existed) fall back to the live id.
  local session_log_id="${_PS_SESSION_LOG_ID:-$sid}"

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
    # Decision 0038: when current phase is drift-check, plan and approval are
    # also skippable — drift_check writes plan-approved + pragmatist-signed
    # from the bundle, so the forward-jump drift-check→build is the canonical
    # bundle-path advance.
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
    # intermediate phases are skippable (user-review, op-review, and —
    # when leaving drift-check via the bundle path — plan and approval).
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
            user-review|op-review) ;; # skippable (Decision 0021)
            plan|approval)
              # Decision 0038: skippable only when leaving drift-check
              if [ "$current_phase" != "drift-check" ]; then
                skip_ok=false; break
              fi
              ;;
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
  printf 'session_type: %s\nsession_id: %s\nsession_log_id: %s\nmode: %s\ncurrent_phase: %s\ncycle: %s\nphases_completed: %s\nsolo: %s\ntag: %s\ntimestamp: %s\n' \
    "$stype" "$sid" "$session_log_id" "$mode" "$new_phase" "$cycle" "$phases_completed" "$solo" "$tag" "$ts" \
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
    _inject_cross_session_context
  fi

  # Decision 0042 — recompute the phase gate cache after every phase advance so
  # hook reads see fresh verdicts. Silent on failure; cache miss in hooks falls
  # through to inline checks (BC by construction).
  compute_phase_gates || true
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
  local session_log_id="${_PS_SESSION_LOG_ID:-$_PS_SESSION_ID}"

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Shell I/O — bypasses write-guard.sh
  printf 'session_type: %s\nsession_id: %s\nsession_log_id: %s\nmode: %s\ncurrent_phase: %s\ncycle: %s\nphases_completed: %s\nsolo: %s\ntag: %s\ntimestamp: %s\n' \
    "$_PS_SESSION_TYPE" "$_PS_SESSION_ID" "$session_log_id" "$mode" "$_PS_CURRENT_PHASE" "$cycle" "$_PS_PHASES_COMPLETED" "$new_solo" "$_PS_TAG" "$ts" \
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
  local session_log_id="${_PS_SESSION_LOG_ID:-$_PS_SESSION_ID}"

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Shell I/O — bypasses write-guard.sh
  printf 'session_type: %s\nsession_id: %s\nsession_log_id: %s\nmode: %s\ncurrent_phase: %s\ncycle: %s\nphases_completed: %s\nsolo: %s\ntag: %s\ntimestamp: %s\n' \
    "$_PS_SESSION_TYPE" "$_PS_SESSION_ID" "$session_log_id" "$new_mode" "$_PS_CURRENT_PHASE" "$cycle" "$_PS_PHASES_COMPLETED" "$solo" "$_PS_TAG" "$ts" \
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

  local sid mode solo cycle session_log_id
  sid=$(grep '^session_id:' "$state_file" 2>/dev/null | sed 's/^session_id: *//')
  session_log_id=$(grep '^session_log_id:' "$state_file" 2>/dev/null | sed 's/^session_log_id: *//')
  : "${session_log_id:=$sid}"
  mode=$(grep '^mode:' "$state_file" 2>/dev/null | sed 's/^mode: *//')
  solo=$(grep '^solo:' "$state_file" 2>/dev/null | sed 's/^solo: *//')
  cycle=$(grep '^cycle:' "$state_file" 2>/dev/null | sed 's/^cycle: *//')

  local tag ts
  tag=$(get_tag_for_phase "standard" "plan")
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Shell I/O — bypasses write-guard.sh
  printf 'session_type: %s\nsession_id: %s\nsession_log_id: %s\nmode: %s\ncurrent_phase: %s\ncycle: %s\nphases_completed: %s\nsolo: %s\ntag: %s\ntimestamp: %s\n' \
    "standard" "$sid" "$session_log_id" "${mode:-default}" "plan" "${cycle:-1}" "init" "${solo:-false}" "$tag" "$ts" \
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

# --- Finish-loop dimension cache (Decision 0040) ---
# Cache passing finish-loop dimension verdicts keyed by an input-file hash.
# On cycle N>=2, if a dimension's current input hash matches the cached PASS
# entry's hash, the verdict is inherited and the dimension is skipped.
# Cache file: <session_state_dir>/finish-loop-cache.yaml — session-scoped,
# cleaned by cleanup_session_files() at close.
#
# Schema:
#   session_id: <id>
#   entries:
#     - dimension: "<name>"
#       hash: "<sha256-hex>"
#       verdict: "PASS"
#       cycle: <N>
#       timestamp: "<ISO 8601 UTC>"

_finish_loop_cache_path() {
  local state_dir
  state_dir="$(get_session_state_dir)"
  echo "$state_dir/finish-loop-cache.yaml"
}

# dimension_input_hash <dimension> <file...>
# Computes a deterministic sha256 over the input file set. The dimension name
# is for traceability only — it is NOT part of the hash so the same file set
# always produces the same hash regardless of which dimension owns it.
# Per-file content sha via `git hash-object` (working-tree state). Absent
# files contribute "MISSING" so deletion changes the hash. Files are sorted
# with LC_ALL=C for OS-independent ordering.
# Stdout: hex digest (empty when no files passed).
dimension_input_hash() {
  local _dimension="$1"
  shift
  [ $# -eq 0 ] && return 0
  local repo_root
  repo_root="$(get_repo_root)"
  local sorted
  sorted=$(printf '%s\n' "$@" | LC_ALL=C sort)
  local concat="" f abs_f sha
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      /*) abs_f="$f" ;;
      *)  abs_f="$repo_root/$f" ;;
    esac
    if [ -f "$abs_f" ]; then
      sha=$(git -C "$repo_root" hash-object "$abs_f" 2>/dev/null || true)
      if [ -z "$sha" ] && type portable_hash >/dev/null 2>&1; then
        sha=$(portable_hash < "$abs_f")
      fi
      concat+="$f:$sha"$'\n'
    else
      concat+="$f:MISSING"$'\n'
    fi
  done <<< "$sorted"
  if type portable_hash >/dev/null 2>&1; then
    printf '%s' "$concat" | portable_hash
  else
    echo "ERROR: dimension_input_hash requires portable_hash (source _analytics-helper.sh)" >&2
    return 1
  fi
}

# cached_dimension_verdict <dimension> <current_hash>
# Returns "PASS" on stdout (exit 0) when the cache contains a PASS entry for
# the dimension whose hash equals current_hash. Exit 1 on miss or no cache.
# When multiple PASS entries exist for the dimension, the latest cycle wins.
cached_dimension_verdict() {
  local dimension="$1"
  local current_hash="$2"
  if [ -z "$dimension" ] || [ -z "$current_hash" ]; then
    return 1
  fi
  local cache_path
  cache_path="$(_finish_loop_cache_path)"
  [ -f "$cache_path" ] || return 1
  awk -v dim="$dimension" -v want_hash="$current_hash" '
    function strip(s) { gsub(/^"|"$/, "", s); return s }
    BEGIN { best_c=-1; matched=0; d=""; h=""; v=""; c=-1 }
    /^  - dimension: / { d=strip($3); h=""; v=""; c=-1; next }
    /^    hash: /      { h=strip($2); next }
    /^    verdict: /   { v=strip($2); next }
    /^    cycle: /     {
                         c=$2+0
                         if (d == dim && v == "PASS" && h == want_hash && c > best_c) {
                           best_c=c; matched=1
                         }
                         next
                       }
    END { if (matched) { print "PASS"; exit 0 } else { exit 1 } }
  ' "$cache_path"
}

# record_dimension_verdict <dimension> <hash> <verdict> <cycle>
# Appends an entry to the cache file. Creates the file with header on first
# call. Caller is responsible for cycle numbering.
record_dimension_verdict() {
  local dimension="$1"
  local hash="$2"
  local verdict="$3"
  local cycle="$4"
  if [ -z "$dimension" ] || [ -z "$hash" ] || [ -z "$verdict" ] || [ -z "$cycle" ]; then
    echo "ERROR: record_dimension_verdict requires dimension, hash, verdict, cycle" >&2
    return 1
  fi
  # Cycle numbering starts at 1; cached_dimension_verdict's AWK uses best_c=-1
  # initial state so cycle=0 entries can match, but reject <1 defensively so the
  # cache schema invariant (cycles ≥ 1) is enforced at the write boundary.
  case "$cycle" in
    ''|*[!0-9]*) echo "ERROR: cycle must be a positive integer (got: $cycle)" >&2; return 1 ;;
  esac
  if [ "$cycle" -lt 1 ]; then
    echo "ERROR: cycle must be >= 1 (got: $cycle)" >&2
    return 1
  fi
  local cache_path
  cache_path="$(_finish_loop_cache_path)"
  local repo_root
  repo_root="$(get_repo_root)"
  # Per-process identity via get_session_id (handles REPO_OS_SESSION_ID, the
  # per-process sidecar, and the flat-file fallback) rather than reading the
  # shared flat .session-id directly, which a concurrent window does not own.
  local sid
  sid=$(get_session_id "$repo_root" 2>/dev/null || echo "")
  [ -z "$sid" ] && sid="unknown"
  mkdir -p "$(dirname "$cache_path")" 2>/dev/null || true
  if [ ! -f "$cache_path" ]; then
    {
      printf 'session_id: %s\n' "$sid"
      printf 'entries:\n'
    } > "$cache_path"
  fi
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  {
    printf '  - dimension: "%s"\n' "$dimension"
    printf '    hash: "%s"\n' "$hash"
    printf '    verdict: "%s"\n' "$verdict"
    printf '    cycle: %s\n' "$cycle"
    printf '    timestamp: "%s"\n' "$ts"
  } >> "$cache_path"
}

# ============================================================
# Evidence Manifest (governance integrity audit trail)
# ============================================================
# Capture: write_evidence_manifest() at init_phase (baseline).
# Refresh: refresh_manifest_entry() called by every sanctioned writer.
# Compare: compare_manifest() at pre-commit and session-close checkpoints.
#
# Location: ~/.local/share/repo-os-analytics/<repo>/evidence-manifest/<sid>.yaml
# (out-of-tree — not reachable via in-repo Bash path bypass; earns the stronger
# claim that findings indicate writes NOT made through a sanctioned hook.)
#
# Claim: detects writes not made through a sanctioned hook.
# Does NOT prevent forgery — a sophisticated actor can update the manifest in the
# same python3 call that forges the evidence file. See known-issues.md R2 and
# Decision t-0012 §9 for the bounded guarantee.
# Attestation (HMAC/signing) was deferred by the operator as too large.

_EVIDENCE_FILES="plan-approved qa-verified cohesion-reviewed diff-review-complete pragmatist-signed functional-verified"

# Return the evidence-manifest directory for the given repo.
_get_evidence_manifest_dir() {
  local repo_root="${1:-$_REPO_OS_ROOT}"
  local repo_name
  repo_name="$(basename "$repo_root")"
  echo "$HOME/.local/share/repo-os-analytics/$repo_name/evidence-manifest"
}

# Return the path to the manifest file for the current session.
# Returns 1 (non-zero) if session id is unavailable.
_get_evidence_manifest_path() {
  local sid="${1:-}"
  local repo_root="${2:-$_REPO_OS_ROOT}"
  if [ -z "$sid" ]; then
    sid="$(get_session_id "$repo_root" 2>/dev/null)" || return 1
  fi
  [ -z "$sid" ] && return 1
  local manifest_dir
  manifest_dir="$(_get_evidence_manifest_dir "$repo_root")"
  # Sanitise: replace / and .. sequences that could escape the directory.
  local sid_safe="${sid//\//_}"
  sid_safe="${sid_safe//\.\./_}"
  echo "${manifest_dir}/${sid_safe}.yaml"
}

# Write the evidence manifest at init_phase.
# Records path + sha256 + present for every monitored evidence file.
# Mirrors the spec_snapshot path+sha pattern from drift_check (Decision t-0038).
# Fails silently — governance never depends on this succeeding.
write_evidence_manifest() {
  local repo_root="${1:-$_REPO_OS_ROOT}"
  local sid
  sid="$(get_session_id "$repo_root" 2>/dev/null)" || return 0
  local manifest_path
  manifest_path="$(_get_evidence_manifest_path "$sid" "$repo_root")" || return 0
  local manifest_dir
  manifest_dir="$(dirname "$manifest_path")"
  mkdir -p "$manifest_dir" 2>/dev/null || return 0

  local state_dir
  state_dir="$(get_session_state_dir)"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  {
    printf '# Governance evidence manifest — out-of-tree integrity audit trail\n'
    printf '# Claim: detects writes not made through a sanctioned hook (out-of-tree).\n'
    printf '# Does NOT prevent forgery. See known-issues.md R2 and Decision t-0012 §9.\n'
    printf 'created_at: "%s"\n' "$ts"
    printf 'session_id: "%s"\n' "$sid"
    printf 'entries:\n'
    local ev
    for ev in $_EVIDENCE_FILES; do
      local ev_path="$state_dir/$ev"
      local sha=""
      local present="false"
      if [ -f "$ev_path" ]; then
        present="true"
        sha="$(portable_hash < "$ev_path" 2>/dev/null)" || sha=""
      fi
      printf '  - name: "%s"\n' "$ev"
      printf '    path: "%s"\n' "$ev_path"
      printf '    sha: "%s"\n' "$sha"
      printf '    present: "%s"\n' "$present"
    done
  } > "$manifest_path" 2>/dev/null || true
}

# Refresh a single manifest entry after a sanctioned write.
# Must be called immediately after the state file is written (including any appends).
# Arguments:
#   $1 — evidence file name (e.g. "plan-approved")
#   $2 — repo_root (optional; defaults to $_REPO_OS_ROOT)
# Fails silently — governance never depends on this succeeding.
refresh_manifest_entry() {
  local ev_name="$1"
  local repo_root="${2:-$_REPO_OS_ROOT}"
  local sid
  sid="$(get_session_id "$repo_root" 2>/dev/null)" || return 0
  local manifest_path
  manifest_path="$(_get_evidence_manifest_path "$sid" "$repo_root")" || return 0
  [ -f "$manifest_path" ] || return 0  # no manifest yet — skip (pre-feature session)

  local state_dir
  state_dir="$(get_session_state_dir)"
  local ev_path="$state_dir/$ev_name"
  local sha=""
  local present="false"
  if [ -f "$ev_path" ]; then
    present="true"
    sha="$(portable_hash < "$ev_path" 2>/dev/null)" || sha=""
  fi

  # Update the manifest entry for this file in-place via awk.
  # Replaces the sha: and present: fields within the matching name: block.
  local tmp="${manifest_path}.tmp.$$"
  awk -v ev="$ev_name" -v new_sha="$sha" -v new_present="$present" '
    /^  - name: "/ { in_entry = ($0 == "  - name: \"" ev "\"") }
    in_entry && /^    sha:/ { print "    sha: \"" new_sha "\""; next }
    in_entry && /^    present:/ { print "    present: \"" new_present "\""; next }
    { print }
  ' "$manifest_path" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$manifest_path" 2>/dev/null \
    || rm -f "$tmp" 2>/dev/null
}

# Compare current evidence file hashes against the manifest at a checkpoint.
# Reports any file whose hash differs from the manifest (out-of-band modification)
# or that exists with no manifest entry (created after init without refresh).
# Verdict: ADVISORY — never blocks (first deployment; false positives possible if
# a sanctioned writer is missing from the refresh list).
# Arguments:
#   $1 — repo_root (optional; defaults to $_REPO_OS_ROOT)
compare_manifest() {
  local repo_root="${1:-$_REPO_OS_ROOT}"
  local sid
  sid="$(get_session_id "$repo_root" 2>/dev/null)" || return 0
  local manifest_path
  manifest_path="$(_get_evidence_manifest_path "$sid" "$repo_root")" || return 0
  [ -f "$manifest_path" ] || return 0  # no manifest — skip (pre-feature session)

  # Require portable_hash — cannot compare without a hash function.
  if [ "$_REPO_OS_HASH_CMD" = "" ] || ! type portable_hash >/dev/null 2>&1; then
    echo "Evidence manifest: hash function unavailable — integrity check skipped." >&2
    return 0
  fi

  local state_dir
  state_dir="$(get_session_state_dir)"
  local findings=""

  local ev
  for ev in $_EVIDENCE_FILES; do
    local ev_path="$state_dir/$ev"
    [ -f "$ev_path" ] || continue  # file absent — no finding (not yet written or cleaned up)

    # Compute current hash.
    local current_sha
    current_sha="$(portable_hash < "$ev_path" 2>/dev/null)" || continue
    [ -z "$current_sha" ] && continue  # hash failed — skip rather than false-positive

    # Read manifest entry sha (and detect missing entry).
    local manifest_sha
    manifest_sha=$(awk -v ev="$ev" '
      /^  - name: "/ { in_entry = ($0 == "  - name: \"" ev "\""); if (in_entry) found=1 }
      in_entry && /^    sha:/ {
        gsub(/^[ ]*sha: *"/, ""); gsub(/"[ ]*$/, ""); print; exit
      }
      END { if (!found) print "__NOENTRY__" }
    ' "$manifest_path" 2>/dev/null || echo "__PARSE_ERROR__")

    if [ "$manifest_sha" = "__NOENTRY__" ] || [ "$manifest_sha" = "__PARSE_ERROR__" ]; then
      findings="${findings}  $ev: present but not in manifest (created after init_phase without a manifest refresh).\n"
    elif [ "$current_sha" != "$manifest_sha" ]; then
      findings="${findings}  $ev: hash mismatch — manifest=${manifest_sha:0:16}... current=${current_sha:0:16}... (possible out-of-band modification).\n"
    fi
  done

  if [ -n "$findings" ]; then
    {
      echo "INTEGRITY-ADVISORY: Evidence manifest mismatch detected at checkpoint."
      printf '%b' "$findings"
      echo "  This is advisory — not a hard block. The out-of-tree manifest detects"
      echo "  writes not made through a sanctioned hook, but does NOT prevent forgery"
      echo "  by a sophisticated actor. See known-issues.md R2 for the bounded guarantee."
      echo "  Attestation (HMAC/signing) was deferred by the operator."
    } >&2
    log_hook_event "_phase-helper" "evidence-manifest" "" "warn" "0" "integrity_advisory" "$(printf '%b' "$findings" | tr '\n' ';' | cut -c1-120)" || true
  fi
  return 0
}

# Remove the evidence manifest for the closing session.
# Called at session close after cleanup_session_files() (in-repo) has run.
# Out-of-tree retention: delete at session close; no accumulation in the repo.
# Arguments:
#   $1 — repo_root (optional; defaults to $_REPO_OS_ROOT)
#   $2 — session id (optional; resolved from state/env if absent)
cleanup_evidence_manifest() {
  local repo_root="${1:-$_REPO_OS_ROOT}"
  local sid="${2:-}"
  if [ -z "$sid" ]; then
    sid="$(get_session_id "$repo_root" 2>/dev/null)" || return 0
  fi
  local manifest_path
  manifest_path="$(_get_evidence_manifest_path "$sid" "$repo_root")" || return 0
  rm -f "$manifest_path" 2>/dev/null || true
}
