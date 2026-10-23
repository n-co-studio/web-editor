#!/usr/bin/env bash
# Unified queue CLI — operator entry point for queue lifecycle management.
# Lives alongside runner.sh at .claude/.automation/queue-cli.sh.
# Decision 0017 — Operator Automation Layer.
#
# Usage:
#   queue-cli.sh <subcommand> [options]
#
# Subcommands:
#   add --brief <path> [--branch NAME] [--session-type TYPE] [--auto-approve] [--solo] [--push] [--priority N] [--independent]
#   approve <id>
#   remove <id>
#   edit <id> <field> <value>
#   set-priority <id> <N>
#   status
#   list [--status <filter>]
#   show <id>
#   review
#   overlap [--branch <name>]
#   log [--lines N]
#   prune [--briefs-only] [--dry-run] [--fix]
#   recover-entry <id>
#   reopen-wo <work-order-id>
#   reset-group-worktree <group> [--yes]
#   stop-entry <id> [--force] [--reason TEXT]
#   resume-entry <id>
#   discard-entry <id> [--reason TEXT]
#   note-entry <id> (--text TEXT | --file PATH)
#   notes-entry <id>
#   follow-up-entry <parent-id> --brief <path> [--auto-approve] [--priority N]
#   follow-up-draft <parent-id>
#   close-status <id>
#   merge <id>
#   hold-merge <id> [--release]
#   set-close <id> solo|pr
#   pr open|refresh|status|rerun|update-branch <id>
#   pr merge <id> [--method merge|squash|rebase]
#   resolve-conflict <id> (--agent | --ours | --theirs | --manual) [--note TEXT]
#   start-daemon
#   halt
#   force-halt
#   resume
#
# Scope note: halt/force-halt/resume act on the DAEMON (every entry).
# stop-entry/resume-entry/discard-entry act on ONE entry and leave the daemon
# running. While an entry is stopping or stopped the queue holds every entry
# queued after it (t-0055 clause 10); resume-entry and discard-entry both
# resolve those holds.
#
# note-entry/notes-entry address ONE entry and never interrupt it: a note is
# context for the agent, not a control flag (t-0055 clause 13).
#
# follow-up-entry queues work that EXTENDS an entry rather than replacing it
# (t-0055 clause 14). The new entry carries `follow_up_of`, never overtakes its
# parent, and has its branch resolved at dequeue. follow-up-draft only prints a
# starting point for its brief — it queues nothing.
#
# close-status/merge/hold-merge/set-close are the close pipeline (Decision
# t-0057). Every finished entry has a close_state; `merge` runs the real
# pipeline via `runner.sh --close-entry` rather than re-implementing it, and
# refuses rather than guesses when a precondition cannot be verified. On a task
# group only the final brief closes the group (Decision 0015 §3) — the others
# are refused, and holding an earlier brief holds the next one's start.
#
# `pr` is the same pipeline for an entry on `close_path: pr` (t-0057 brief 2),
# where main is changed by GitHub rather than by a local merge. `pr status` is
# free — it prints what the last refresh recorded. The other five each spend gh
# round trips. `pr merge` is refused unless the checks pass and the pull request
# is mergeable, read LIVE at the moment of the merge and not from the entry.
#
# `resolve-conflict` is the one exit from close_state `conflict`, on EITHER path
# (t-0057 brief 3). It picks how the conflict is resolved and re-arms the entry
# so the close can run again; it never merges anything itself. `--agent` queues a
# fix brief as a follow-up of the entry, on the same branch, so the fix is a
# session with a brief and a contract rather than a free hand on main.
#
# Global flags:
#   --json    Machine-readable JSON output (status, list, show, review, overlap,
#             note-entry, notes-entry, follow-up-entry, follow-up-draft,
#             close-status, merge, hold-merge, set-close, pr)
#
# Exit codes:
#   0  Success
#   1  Validation or operational error

set -euo pipefail

# --- Self-locate and derive repo root ---
# queue-cli.sh lives at .claude/.automation/ — repo root is two levels up.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUTOMATION_DIR="$SCRIPT_DIR"
LIB_DIR="$AUTOMATION_DIR/lib"
CONFIG_FILE="$AUTOMATION_DIR/config.yaml"
CONFIG_LOCAL_FILE="$AUTOMATION_DIR/config.local.yaml"

# --- Source shared helpers ---
# shellcheck source=../../.claude/hooks/_analytics-helper.sh
source "$REPO_ROOT/.claude/hooks/_analytics-helper.sh"
# shellcheck source=../../.claude/hooks/_phase-helper.sh
source "$REPO_ROOT/.claude/hooks/_phase-helper.sh"
# shellcheck source=../../.claude/hooks/_cleanup-helper.sh
source "$REPO_ROOT/.claude/hooks/_cleanup-helper.sh"

# --- Source runner libraries ---
# shellcheck source=lib/queue-manager.sh
source "$LIB_DIR/queue-manager.sh"
# shellcheck source=lib/queue-reporter.sh
source "$LIB_DIR/queue-reporter.sh"
# shellcheck source=lib/work-order-manager.sh
source "$LIB_DIR/work-order-manager.sh"
# shellcheck source=lib/review-log.sh
source "$LIB_DIR/review-log.sh"
# shellcheck source=lib/file-lock.sh
source "$LIB_DIR/file-lock.sh"
# shellcheck source=lib/queue-validator.sh
source "$LIB_DIR/queue-validator.sh"
# shellcheck source=lib/branch-manager.sh
source "$LIB_DIR/branch-manager.sh"
# shellcheck source=lib/cleanup.sh
source "$LIB_DIR/cleanup.sh"
# shellcheck source=lib/overlap-report.sh
source "$LIB_DIR/overlap-report.sh"
# shellcheck source=lib/work-preserver.sh
source "$LIB_DIR/work-preserver.sh"
# shellcheck source=lib/pr-manager.sh
# Sourced AFTER queue-manager.sh and _cleanup-helper.sh, both of which it calls
# into at run time. Unlike `merge`, the `pr` subcommands do NOT hand off to
# runner.sh: nothing they do touches main except the --ff-only sync after a pull
# request has already merged, so there is no second merge gate to disagree with
# the runner's — GitHub holds the only one.
source "$LIB_DIR/pr-manager.sh"

# --- Global flags ---
JSON_OUTPUT=false

# Failure count at which the daemon's circuit breaker trips. This is a REPORTING
# copy: the authority is `_circuit_breaker_tripped` in runner.sh, which the CLI
# cannot source (runner.sh parses argv and runs a daemon loop at load). Named
# rather than inlined so the duplication is visible. If the runner's threshold
# ever becomes configurable, this must read the same field.
#
# Scope of the parity, stated precisely: what `status` mirrors is the THRESHOLD
# and the fail-closed direction, NOT the cooldown. The CLI does not read
# `last_failure_epoch`, so inside a window that has already elapsed `status`
# reports tripped while the daemon is about to allow one probe entry. That is
# deliberate — `status` answers "is the breaker set", not "will the next poll
# run something" — but it means `circuit_breaker_tripped` must be read as
# "count >= threshold", not as a prediction about the daemon's next action.
_CB_TRIP_THRESHOLD=3

# --- Usage ---
_usage() {
  cat >&2 << 'EOF'
Usage: queue-cli.sh [--json] <subcommand> [args]

Subcommands:
  add --brief <path> [--branch NAME] [--session-type TYPE] [--auto-approve] [--solo] [--push] [--priority N] [--independent]
  approve <id>
  remove <id>
  edit <id> <field> <value>
  set-priority <id> <N>
  status
  list [--status <filter>]
  show <id>
  review
  overlap [--branch <name>]
  log [--lines N]
  prune [--briefs-only] [--dry-run] [--fix]
  recover-entry <id>
  reopen-wo <work-order-id>
  reopen-entry <id>                           return one entry from review/ or failed/ to approved
  reset-breaker
  reset-group-worktree <group> [--yes]
  stop-entry <id> [--force] [--reason TEXT]   stop one entry's session (stop again to force)
  resume-entry <id>                           re-queue a stopped entry, same Claude session
  discard-entry <id> [--reason TEXT]          abandon one entry; escalates whatever it held
  note-entry <id> (--text TEXT | --file PATH) send the agent a note (alias: note; max 2000 chars)
  notes-entry <id>                            list this entry's notes, pending and delivered
  follow-up-entry <parent-id> --brief <path> [--auto-approve] [--priority N]
                                              queue work extending <parent-id> (alias: follow-up)
  follow-up-draft <parent-id>                 print a draft brief from what the parent left undone
  close-status <id>                           close_path, close_state and every recorded close step
  merge <id>                                  run the close pipeline now (rebase, re-verify, merge, push)
  hold-merge <id> [--release]                 hold this entry's merge, or let it run
  set-close <id> solo|pr                      choose how this entry's work reaches main
  pr status <id>                              the recorded pull request and close state (no gh call)
  pr open <id>                                push the branch and open its pull request
  pr refresh <id>                             re-read its checks, conflicts and merged state
  pr rerun <id>                               re-run the failed jobs of its latest failed run
  pr update-branch <id>                       bring the pull request up to date with main
  pr merge <id> [--method merge|squash|rebase]
                                              merge it, if its checks pass and it is mergeable
  resolve-conflict <id> (--agent|--ours|--theirs|--manual) [--note TEXT]
                                              pick how a close conflict is resolved, then re-arm it
  start-daemon
  halt
  force-halt
  resume
EOF
  exit 1
}

# --- JSON helpers ---
# Wraps _json_escape from review-log.sh for output formatting.
_json_kv() {
  local key="$1" val="$2"
  local esc_val
  esc_val=$(_json_escape "$val")
  printf '"%s":"%s"' "$key" "$esc_val"
}

_json_kv_raw() {
  local key="$1" val="$2"
  printf '"%s":%s' "$key" "$val"
}

# --- Project/milestone resolution helper (v1.4.0) ---
# Reads already-loaded _QE_* vars, loads the parent work order if present,
# and applies resolution: entry wins → work order wins → empty/zero.
# Sets: _RESOLVED_PROJECT _RESOLVED_MILESTONE_NAME _RESOLVED_MILESTONE_INDEX _RESOLVED_MILESTONE_TOTAL
_resolve_entry_metadata() {
  _RESOLVED_PROJECT="${_QE_PROJECT:-}"
  _RESOLVED_MILESTONE_NAME="${_QE_MILESTONE_NAME:-}"
  _RESOLVED_MILESTONE_INDEX="${_QE_MILESTONE_INDEX:-0}"
  _RESOLVED_MILESTONE_TOTAL="${_QE_MILESTONE_TOTAL:-0}"

  if [ -n "${_QE_WORK_ORDER_ID:-}" ]; then
    local _wo_file
    _wo_file="$(_wo_dir)/${_QE_WORK_ORDER_ID}.yaml"
    if [ -f "$_wo_file" ]; then
      _load_work_order "$_wo_file" 2>/dev/null || true
      [ -z "$_RESOLVED_PROJECT" ] && _RESOLVED_PROJECT="${_WO_PROJECT:-}"
      [ -z "$_RESOLVED_MILESTONE_NAME" ] && _RESOLVED_MILESTONE_NAME="${_WO_MILESTONE_NAME:-}"
      [ "${_RESOLVED_MILESTONE_INDEX:-0}" = "0" ] && _RESOLVED_MILESTONE_INDEX="${_WO_MILESTONE_INDEX:-0}"
      [ "${_RESOLVED_MILESTONE_TOTAL:-0}" = "0" ] && _RESOLVED_MILESTONE_TOTAL="${_WO_MILESTONE_TOTAL:-0}"
    fi
  fi
  # The last line above is an AND-list, so its status is the function's: an
  # entry that already carries a milestone_total returns 1 from here, and
  # `show --json` calls this as a plain command under `set -e` — the script
  # then died with no output and no message. Reachable from the moment an
  # entry has BOTH a work order and its own milestone, which is what a
  # follow-up inheriting its parent's metadata now routinely is.
  return 0
}

# --- session block for `show --json` (t-0055 clause 11) ---
# Emits the "session" member: what the operator needs to decide whether to stop,
# force or resume. Derived entirely from the entry's status, its control flags
# and its session record — nothing here is separately maintained state.
# Clobbers _QE_*: call it BEFORE the caller loads the fields it prints.
# Arguments: $1 — entry_id
_entry_session_json() {
  local eid="$1"
  local efile state="not-running" stopped_mode="" brief_seq="" started_at="" elapsed=0 csid=""

  efile=$(_find_entry_file "$eid") || efile=""
  if [ -n "$efile" ]; then
    _load_queue_entry "$efile"
    stopped_mode="${_QE_STOPPED_MODE:-}"
    if [ -n "${_QE_BRIEF_PATH:-}" ]; then
      brief_seq=$(_parse_brief_sequence "$_QE_BRIEF_PATH" 2>/dev/null) || brief_seq=""
    fi
    case "$_QE_STATUS" in
      running)           state="running" ;;
      stopped)           state="stopped" ;;
      completed|failed)  state="closed" ;;
      *)                 state="not-running" ;;
    esac
  fi

  # A pending stop flag on a still-running entry is the "stopping" window: the
  # flag is written but the child has not exited yet.
  if [ "$state" = "running" ] && _hold_entry_is_stopping "$eid"; then
    state="stopping"
  fi

  local cdir
  cdir=$(get_control_dir "$eid" 2>/dev/null) || cdir=""
  if [ -n "$cdir" ] && [ -f "$cdir/resume.yaml" ]; then
    csid=$(grep -E '^claude_session_id:' "$cdir/resume.yaml" 2>/dev/null | head -1 \
      | sed 's/^claude_session_id: *//; s/^"//; s/"$//') || csid=""
  fi

  local sid
  sid=$(_session_id_for_entry "$eid") || sid=""
  if [ -n "$sid" ]; then
    started_at=$(session_record_get "$sid" "started_at" 2>/dev/null) || started_at=""
    if [ -z "$csid" ]; then
      csid=$(session_record_get "$sid" "claude_session_id" 2>/dev/null) || csid=""
    fi
  fi

  if [ -n "$started_at" ]; then
    local s_epoch now_epoch
    s_epoch=$(_iso_to_epoch "$started_at" 2>/dev/null) || s_epoch=""
    if [ -n "$s_epoch" ]; then
      now_epoch=$(date -u +%s)
      elapsed=$(( now_epoch - s_epoch ))
      [ "$elapsed" -ge 0 ] || elapsed=0
    fi
  fi

  printf '"session":{%s,%s,%s,%s,%s,%s}' \
    "$(_json_kv "state" "$state")" \
    "$(_json_kv "stopped_mode" "$stopped_mode")" \
    "$(_json_kv "brief_seq" "$brief_seq")" \
    "$(_json_kv "started_at" "$started_at")" \
    "$(_json_kv_raw "elapsed_s" "$elapsed")" \
    "$(_json_kv "claude_session_id" "$csid")"
}

# --- hold block for `show --json` (t-0055 clause 10) ---
# Emits the "hold" member: which entries this one is holding back, and which
# ones queued after it the release predicate let through. Both are derived from
# held_by at read time, so they can never disagree with it.
# Clobbers _QE_*: call it BEFORE the caller loads the fields it prints.
# Arguments: $1 — entry_id
_entry_hold_json() {
  local eid="$1"
  printf '"hold":{"holding":%s,"released":%s}' \
    "$(_json_id_array "$(queue_hold_holding "$eid")")" \
    "$(_json_id_array "$(queue_hold_released "$eid")")"
}

# --- Render a newline-separated id list as a JSON string array ---
# Fed by a here-doc rather than `done < <(...)`: _entry_hold_json is itself
# invoked inside a command substitution, and process substitution nested in
# command substitution is the construct that misbehaves on the Bash 3.2 floor
# this repo targets.
_json_id_array() {
  local _line _first=true
  printf '['
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    if [ "$_first" = true ]; then _first=false; else printf ','; fi
    printf '"%s"' "$(_json_escape "$_line")"
  done <<EOF
${1:-}
EOF
  printf ']'
}

# --- Parse global flags and extract subcommand ---
if [ $# -eq 0 ]; then
  _usage
fi

# Consume leading --json flag
if [ "$1" = "--json" ]; then
  JSON_OUTPUT=true
  shift
fi

if [ $# -eq 0 ]; then
  _usage
fi

SUBCOMMAND="$1"
shift

# ============================================================
# Subcommand dispatch
# ============================================================

case "$SUBCOMMAND" in

  # --- add: create a queue entry ---
  add)
    ADD_BRIEF="" ADD_BRANCH="" ADD_SESSION_TYPE="standard"
    ADD_AUTO_APPROVE=false ADD_SOLO=false ADD_PUSH=false ADD_PRIORITY="0" ADD_INDEPENDENT=false
    ADD_PROJECT="" ADD_MILESTONE_NAME="" ADD_MILESTONE_INDEX="0" ADD_MILESTONE_TOTAL="0"
    SESSION_TYPE_EXPLICIT=false BRANCH_EXPLICIT=false

    while [ $# -gt 0 ]; do
      case "$1" in
        --brief)            ADD_BRIEF="$2"; shift 2 ;;
        --branch)           ADD_BRANCH="$2"; BRANCH_EXPLICIT=true; shift 2 ;;
        --session-type)     ADD_SESSION_TYPE="$2"; SESSION_TYPE_EXPLICIT=true; shift 2 ;;
        --auto-approve)     ADD_AUTO_APPROVE=true; shift ;;
        --solo)             ADD_SOLO=true; shift ;;
        --push)             ADD_PUSH=true; shift ;;
        --independent)      ADD_INDEPENDENT=true; shift ;;
        --project)          ADD_PROJECT="$2"; shift 2 ;;
        --milestone-name)   ADD_MILESTONE_NAME="$2"; shift 2 ;;
        --milestone-index)
          ADD_MILESTONE_INDEX="$2"
          case "$ADD_MILESTONE_INDEX" in
            ''|*[!0-9]*) echo "ERROR: --milestone-index requires a non-negative integer" >&2; exit 1 ;;
          esac
          shift 2 ;;
        --milestone-total)
          ADD_MILESTONE_TOTAL="$2"
          case "$ADD_MILESTONE_TOTAL" in
            ''|*[!0-9]*) echo "ERROR: --milestone-total requires a non-negative integer" >&2; exit 1 ;;
          esac
          shift 2 ;;
        --priority)
          ADD_PRIORITY="$2"
          # Validate numeric
          case "$ADD_PRIORITY" in
            ''|*[!0-9]*) echo "ERROR: --priority requires a non-negative integer" >&2; exit 1 ;;
          esac
          shift 2 ;;
        *) echo "ERROR: Unknown add option: $1" >&2; exit 1 ;;
      esac
    done

    if [ -z "$ADD_BRIEF" ]; then
      echo "ERROR: add requires --brief <path>" >&2
      exit 1
    fi

    # Resolve brief path
    if [ ! -f "$ADD_BRIEF" ] && [ -f "$REPO_ROOT/$ADD_BRIEF" ]; then
      ADD_BRIEF="$REPO_ROOT/$ADD_BRIEF"
    fi
    if [ ! -f "$ADD_BRIEF" ]; then
      echo "ERROR: Brief file not found: $ADD_BRIEF" >&2
      exit 1
    fi

    # Reject empty brief files (consistent with intake.sh)
    if [ ! -s "$ADD_BRIEF" ]; then
      echo "ERROR: Brief file is empty. Cannot queue an empty brief." >&2
      exit 1
    fi

    # Validate brief path is inside REPO_ROOT (catches silent prompt-assembler failure)
    _ADD_BRIEF_REAL=$(cd "$(dirname "$ADD_BRIEF")" && pwd)/$(basename "$ADD_BRIEF")
    case "$_ADD_BRIEF_REAL" in
      "$REPO_ROOT"/*)
        ;; # inside repo — OK
      *)
        echo "ERROR: Brief path must be inside the repo. Copy the file to .claude/.automation/briefs/ first." >&2
        echo "  Resolved path: $_ADD_BRIEF_REAL" >&2
        echo "  Repo root:     $REPO_ROOT" >&2
        exit 1
        ;;
    esac

    # Auto-detect task group metadata from brief
    _parse_brief_taskgroup_metadata "$ADD_BRIEF"

    if [ "$_BRIEF_TG_DETECTED" = true ]; then
      # Derive session type when not explicitly provided
      if [ "$SESSION_TYPE_EXPLICIT" = false ]; then
        if [ "$_BRIEF_TG_IS_MERGE" = true ]; then
          ADD_SESSION_TYPE="taskgroup-merge"
        else
          ADD_SESSION_TYPE="taskgroup"
        fi
      else
        # Warn on conflict between explicit and detected
        _expected_type="taskgroup"
        [ "$_BRIEF_TG_IS_MERGE" = true ] && _expected_type="taskgroup-merge"
        if [ "$ADD_SESSION_TYPE" != "$_expected_type" ]; then
          echo "WARNING: Brief has ### Task Group metadata (detected: $_expected_type) but --session-type=$ADD_SESSION_TYPE was explicit — using explicit value" >&2
        fi
      fi

      # Derive branch when not explicitly provided (skip for parallel groups)
      if [ "$BRANCH_EXPLICIT" = false ] && [ "$_BRIEF_TG_IS_PARALLEL" = false ]; then
        ADD_BRANCH="feature/${_BRIEF_TG_GROUP_NAME}"
      fi
    fi

    # Validate session type (after auto-detection so validated type reflects any upgrade)
    VALID_PHASES=$(get_phases_for_type "$ADD_SESSION_TYPE" 2>/dev/null || true)
    if [ -z "$VALID_PHASES" ]; then
      echo "ERROR: Invalid session type: $ADD_SESSION_TYPE" >&2
      exit 1
    fi

    # Branch warning for non-taskgroup
    if [ -n "$ADD_BRANCH" ]; then
      case "$ADD_SESSION_TYPE" in
        taskgroup|taskgroup-merge) ;;
        *) echo "WARNING: --branch is intended for taskgroup/taskgroup-merge sessions" >&2 ;;
      esac
    fi

    # Convert flags
    ADD_AUTO_MODE="false"
    [ "$ADD_AUTO_APPROVE" = true ] && ADD_AUTO_MODE="true"
    ADD_SOLO_STR="false"
    [ "$ADD_SOLO" = true ] && ADD_SOLO_STR="true"
    ADD_PUSH_STR="false"
    [ "$ADD_PUSH" = true ] && ADD_PUSH_STR="true"

    # Mutating — acquire lock
    if ! acquire_queue_lock; then
      echo "ERROR: Queue lock unavailable" >&2
      exit 1
    fi

    _ensure_queue_dirs
    ENTRY_ID=$(queue_enqueue "$ADD_BRIEF" "$ADD_SESSION_TYPE" "$ADD_AUTO_MODE" "$ADD_SOLO_STR" "$ADD_BRANCH" "" "$ADD_PUSH_STR" "$ADD_PRIORITY" "build" "$ADD_PROJECT" "$ADD_MILESTONE_NAME" "$ADD_MILESTONE_INDEX" "$ADD_MILESTONE_TOTAL")

    if [ -z "$ENTRY_ID" ]; then
      release_queue_lock
      echo "ERROR: Failed to create queue entry" >&2
      exit 1
    fi

    # Validate entry against schema (Fix 1: wire validator at intake)
    _ADD_ENTRY_FILE="$(_queue_dir)/pending-review/${ENTRY_ID}.yaml"
    if ! validate_queue_entry "$_ADD_ENTRY_FILE"; then
      # Validation failed — remove the entry and abort
      rm -f "$_ADD_ENTRY_FILE" 2>/dev/null || true
      _rebuild_queue_index
      release_queue_lock
      echo "ERROR: Queue entry validation failed — entry removed" >&2
      exit 1
    fi

    # Hold opt-out (t-0055 clause 10). Applied after validation rather than as a
    # 14th positional argument to queue_enqueue: it is operator policy on an
    # already-well-formed entry, not part of its identity.
    # Guarded like the two steps above it rather than left bare: this block runs
    # with the queue lock held under `set -e`, so an unguarded failure would exit
    # the script with the lock still on disk.
    if [ "$ADD_INDEPENDENT" = true ]; then
      if ! queue_edit "$ENTRY_ID" independent true; then
        release_queue_lock
        echo "ERROR: Entry $ENTRY_ID was created but --independent could not be applied" >&2
        exit 1
      fi
    fi

    ADD_STATUS="pending-review"
    if [ "$ADD_AUTO_APPROVE" = true ]; then
      queue_approve "$ENTRY_ID"
      ADD_STATUS="approved"
    fi

    release_queue_lock

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s,%s}\n' \
        "$(_json_kv "entry_id" "$ENTRY_ID")" \
        "$(_json_kv "status" "$ADD_STATUS")" \
        "$(_json_kv "session_type" "$ADD_SESSION_TYPE")" \
        "$(_json_kv "brief_path" "$ADD_BRIEF")"
    else
      printf 'entry_id: %s\nstatus: %s\nsession_type: %s\nbrief_path: %s\n' \
        "$ENTRY_ID" "$ADD_STATUS" "$ADD_SESSION_TYPE" "$ADD_BRIEF"
    fi
    ;;

  # --- approve: move entry to approved ---
  approve)
    if [ $# -lt 1 ]; then
      echo "ERROR: approve requires <id>" >&2
      exit 1
    fi
    APPROVE_ID="$1"

    if ! acquire_queue_lock; then
      echo "ERROR: Queue lock unavailable" >&2
      exit 1
    fi

    queue_approve "$APPROVE_ID"
    release_queue_lock

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s}\n' "$(_json_kv "entry_id" "$APPROVE_ID")" "$(_json_kv "status" "approved")"
    else
      printf 'Approved: %s\n' "$APPROVE_ID"
    fi
    ;;

  # --- remove: delete entry from queue ---
  remove)
    if [ $# -lt 1 ]; then
      echo "ERROR: remove requires <id>" >&2
      exit 1
    fi
    REMOVE_ID="$1"

    if ! acquire_queue_lock; then
      echo "ERROR: Queue lock unavailable" >&2
      exit 1
    fi

    queue_remove "$REMOVE_ID"
    release_queue_lock

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s}\n' "$(_json_kv "entry_id" "$REMOVE_ID")" "$(_json_kv "action" "removed")"
    else
      printf 'Removed: %s\n' "$REMOVE_ID"
    fi
    ;;

  # --- edit: modify entry field (or work order field with --work-order) ---
  edit)
    EDIT_WORK_ORDER=false
    # Strip optional --work-order flag before positional args
    if [ "${1:-}" = "--work-order" ]; then
      EDIT_WORK_ORDER=true
      shift
    fi

    if [ $# -lt 3 ]; then
      echo "ERROR: edit requires <id> <field> <value>" >&2
      exit 1
    fi
    EDIT_ID="$1" EDIT_FIELD="$2" EDIT_VALUE="$3"

    if ! acquire_queue_lock; then
      echo "ERROR: Queue lock unavailable" >&2
      exit 1
    fi

    if [ "$EDIT_WORK_ORDER" = true ]; then
      wo_edit "$EDIT_ID" "$EDIT_FIELD" "$EDIT_VALUE"
    else
      queue_edit "$EDIT_ID" "$EDIT_FIELD" "$EDIT_VALUE"
    fi
    release_queue_lock

    if [ "$JSON_OUTPUT" = true ]; then
      if [ "$EDIT_WORK_ORDER" = true ]; then
        printf '{%s,%s,%s}\n' \
          "$(_json_kv "work_order_id" "$EDIT_ID")" \
          "$(_json_kv "field" "$EDIT_FIELD")" \
          "$(_json_kv "value" "$EDIT_VALUE")"
      else
        printf '{%s,%s,%s}\n' \
          "$(_json_kv "entry_id" "$EDIT_ID")" \
          "$(_json_kv "field" "$EDIT_FIELD")" \
          "$(_json_kv "value" "$EDIT_VALUE")"
      fi
    else
      if [ "$EDIT_WORK_ORDER" = true ]; then
        printf 'Updated work order %s: %s = %s\n' "$EDIT_ID" "$EDIT_FIELD" "$EDIT_VALUE"
      else
        printf 'Updated %s: %s = %s\n' "$EDIT_ID" "$EDIT_FIELD" "$EDIT_VALUE"
      fi
    fi
    ;;

  # --- set-priority: convenience wrapper for edit <id> priority <N> ---
  set-priority)
    if [ $# -lt 2 ]; then
      echo "ERROR: set-priority requires <id> <N>" >&2
      exit 1
    fi
    SP_ID="$1" SP_VAL="$2"

    # Validate numeric
    case "$SP_VAL" in
      ''|*[!0-9]*) echo "ERROR: Priority must be a non-negative integer" >&2; exit 1 ;;
    esac

    if ! acquire_queue_lock; then
      echo "ERROR: Queue lock unavailable" >&2
      exit 1
    fi

    queue_edit "$SP_ID" "priority" "$SP_VAL"
    release_queue_lock

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s}\n' \
        "$(_json_kv "entry_id" "$SP_ID")" \
        "$(_json_kv "field" "priority")" \
        "$(_json_kv "value" "$SP_VAL")"
    else
      printf 'Updated %s: priority = %s\n' "$SP_ID" "$SP_VAL"
    fi
    ;;

  # --- status: queue summary ---
  status)
    if [ "$JSON_OUTPUT" = true ]; then
      # Build JSON from pipe-delimited output
      RAW=$(queue_status "pipe")
      printf '{'
      FIRST=true
      while IFS='|' read -r S_KEY S_VAL; do
        [ -z "$S_KEY" ] && continue
        # Normalize key for JSON (replace - with _)
        JSON_KEY="${S_KEY//-/_}"
        if [ "$FIRST" = true ]; then
          FIRST=false
        else
          printf ','
        fi
        printf '"%s":%s' "$JSON_KEY" "$S_VAL"
      done <<< "$RAW"
      # Circuit breaker state, appended to both output forms. A tripped breaker
      # is the one condition that stops the queue without any entry looking
      # wrong, and the playbook points operators at `status` to find it — but
      # until now it was only visible by reading `.circuit-breaker` by hand.
      _ST_CB="$(_queue_dir)/.circuit-breaker"
      _ST_CB_COUNT=""
      if [ -f "$_ST_CB" ]; then
        _ST_CB_COUNT=$(grep '^consecutive_failures:' "$_ST_CB" 2>/dev/null \
          | sed 's/^[^:]*: *//' | tr -d '[:space:]' | head -1) || true
      fi
      # The count is NOT interpolated raw. An unreadable value printed with %s
      # emits `"circuit_breaker_failures":abc` — invalid JSON, in precisely the
      # state this change set added fail-closed handling for, and `--json` is
      # the form Prompt Q parses. Unreadable becomes null, and the verdict
      # travels as its own boolean so a consumer never has to re-derive the
      # threshold from the count.
      case "${_ST_CB_COUNT:-}" in
        '')
          # No file, or a file with no count line: no failure record to honour.
          # Matches _circuit_breaker_tripped's `''` arm, which does not trip.
          printf ',"circuit_breaker_failures":0,"circuit_breaker_state":"ok","circuit_breaker_tripped":false'
          ;;
        *[!0-9]*)
          printf ',"circuit_breaker_failures":null,"circuit_breaker_state":"unreadable","circuit_breaker_tripped":true'
          ;;
        *)
          if [ "$_ST_CB_COUNT" -ge "$_CB_TRIP_THRESHOLD" ]; then
            printf ',"circuit_breaker_failures":%s,"circuit_breaker_state":"tripped","circuit_breaker_tripped":true' "$_ST_CB_COUNT"
          else
            printf ',"circuit_breaker_failures":%s,"circuit_breaker_state":"ok","circuit_breaker_tripped":false' "$_ST_CB_COUNT"
          fi
          ;;
      esac
      printf '}\n'
    else
      queue_status "text"
      _ST_CB="$(_queue_dir)/.circuit-breaker"
      if [ -f "$_ST_CB" ]; then
        _ST_CB_COUNT=$(grep '^consecutive_failures:' "$_ST_CB" 2>/dev/null \
          | sed 's/^[^:]*: *//' | tr -d '[:space:]' | head -1) || true
        _ST_CB_AT=$(grep '^last_failure_at:' "$_ST_CB" 2>/dev/null \
          | sed 's/^[^:]*: *//' | tr -d '[:space:]' | head -1) || true
        echo "circuit breaker: ${_ST_CB_COUNT:-unreadable} consecutive failure(s), last at ${_ST_CB_AT:-unknown}"
        case "${_ST_CB_COUNT:-0}" in
          ''|*[!0-9]*)
            echo "  TRIPPED (state unreadable — fails closed). Clear with: queue-cli.sh reset-breaker" ;;
          *)
            if [ "$_ST_CB_COUNT" -ge "$_CB_TRIP_THRESHOLD" ]; then
              echo "  TRIPPED — the daemon will not start entries. Diagnose with 'queue-cli.sh log --lines 20', then clear with 'queue-cli.sh reset-breaker'."
            fi ;;
        esac
      fi
    fi
    ;;

  # --- list: show entries ---
  list)
    LIST_FILTER=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --status) LIST_FILTER="$2"; shift 2 ;;
        *) echo "ERROR: Unknown list option: $1" >&2; exit 1 ;;
      esac
    done

    if [ "$JSON_OUTPUT" = true ]; then
      printf '['
      FIRST=true
      while IFS='|' read -r L_ID L_STATUS L_TYPE L_BRIEF L_UPDATED; do
        [ -z "$L_ID" ] && continue
        if [ "$FIRST" = true ]; then
          FIRST=false
        else
          printf ','
        fi
        # Load entry for resolved project/milestone
        L_ENTRY_FILE=$(_find_entry_file "$L_ID")
        if [ -n "$L_ENTRY_FILE" ]; then
          _load_queue_entry "$L_ENTRY_FILE"
          _resolve_entry_metadata
        else
          _RESOLVED_PROJECT="" _RESOLVED_MILESTONE_NAME=""
          _RESOLVED_MILESTONE_INDEX=0 _RESOLVED_MILESTONE_TOTAL=0
          # _QE_* still holds the PREVIOUS row's entry; without this the
          # unreadable row would report its neighbour's parent.
          _QE_FOLLOW_UP_OF=""
        fi
        # follow_up_of is flat on the list row, not the follow_ups array: a
        # list is a view of many entries, and the reverse direction costs a
        # whole-queue scan per row. `show` is where the links are walked.
        printf '{%s,%s,%s,%s,%s,%s,%s,%s,%s,%s}' \
          "$(_json_kv "id" "$L_ID")" \
          "$(_json_kv "status" "$L_STATUS")" \
          "$(_json_kv "session_type" "$L_TYPE")" \
          "$(_json_kv "brief_path" "$L_BRIEF")" \
          "$(_json_kv "updated_at" "$L_UPDATED")" \
          "$(_json_kv "follow_up_of" "${_QE_FOLLOW_UP_OF:-}")" \
          "$(_json_kv "project" "$_RESOLVED_PROJECT")" \
          "$(_json_kv "milestone_name" "$_RESOLVED_MILESTONE_NAME")" \
          "$(_json_kv_raw "milestone_index" "${_RESOLVED_MILESTONE_INDEX:-0}")" \
          "$(_json_kv_raw "milestone_total" "${_RESOLVED_MILESTONE_TOTAL:-0}")"
      done < <(queue_list "$LIST_FILTER")
      printf ']\n'
    else
      queue_list "$LIST_FILTER"
    fi
    ;;

  # --- show: entry detail ---
  show)
    if [ $# -lt 1 ]; then
      echo "ERROR: show requires <id>" >&2
      exit 1
    fi
    SHOW_ID="$1"

    if [ "$JSON_OUTPUT" = true ]; then
      ENTRY_FILE=$(_find_entry_file "$SHOW_ID")
      if [ -z "$ENTRY_FILE" ]; then
        echo "ERROR: Entry $SHOW_ID not found" >&2
        exit 1
      fi
      # All three derived blocks scan the queue and so clobber _QE_*. Build
      # them first, then load the entry's own fields for the flat members.
      _SHOW_SESSION_JSON=$(_entry_session_json "$SHOW_ID")
      _SHOW_HOLD_JSON=$(_entry_hold_json "$SHOW_ID")

      # Both directions of the follow-up link (t-0055 clause 14). The forward
      # one is the stored field below; this is the reverse, which is a scan
      # rather than a field precisely so it cannot disagree with it.
      _SHOW_FU_JSON=""
      while IFS="$_QH_TAB" read -r _SHOW_FU_ID _SHOW_FU_STATUS; do
        [ -n "$_SHOW_FU_ID" ] || continue
        _SHOW_FU_JSON="${_SHOW_FU_JSON:+$_SHOW_FU_JSON,}{$(_json_kv "id" "$_SHOW_FU_ID"),$(_json_kv "status" "$_SHOW_FU_STATUS")}"
      done <<EOF
$(queue_followups_of "$SHOW_ID")
EOF

      _load_queue_entry "$ENTRY_FILE"
      _resolve_entry_metadata
      # Truncate last_prompt for JSON output (first 500 chars)
      _SHOW_LP="${_QE_LAST_PROMPT:0:500}"
      # Close pipeline (t-0057). Both resolvers read _QE_* only, so they are
      # safe here after the load; close_steps is already JSON, emitted verbatim.
      _SHOW_CLOSE_PATH=$(queue_close_path)
      _SHOW_CLOSE_STATE=$(queue_close_state)
      printf '{%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"follow_ups":[%s],%s,%s,%s,%s,%s,"close_steps":%s}\n' \
        "$(_json_kv "id" "$_QE_ID")" \
        "$(_json_kv "status" "$_QE_STATUS")" \
        "$(_json_kv "priority" "${_QE_PRIORITY:-0}")" \
        "$(_json_kv "session_type" "$_QE_SESSION_TYPE")" \
        "$(_json_kv "branch" "$_QE_BRANCH")" \
        "$(_json_kv "brief_path" "$_QE_BRIEF_PATH")" \
        "$(_json_kv "auto_mode" "$_QE_AUTO_MODE")" \
        "$(_json_kv "solo_mode" "$_QE_SOLO_MODE")" \
        "$(_json_kv "push_on_complete" "$_QE_PUSH_ON_COMPLETE")" \
        "$(_json_kv "retry_count" "$_QE_RETRY_COUNT")" \
        "$(_json_kv "max_retries" "$_QE_MAX_RETRIES")" \
        "$(_json_kv "error_log" "$_QE_ERROR_LOG")" \
        "$(_json_kv "last_prompt" "$_SHOW_LP")" \
        "$(_json_kv "work_order_id" "$_QE_WORK_ORDER_ID")" \
        "$(_json_kv "project" "$_RESOLVED_PROJECT")" \
        "$(_json_kv "milestone_name" "$_RESOLVED_MILESTONE_NAME")" \
        "$(_json_kv_raw "milestone_index" "${_RESOLVED_MILESTONE_INDEX:-0}")" \
        "$(_json_kv_raw "milestone_total" "${_RESOLVED_MILESTONE_TOTAL:-0}")" \
        "$(_json_kv "created_at" "$_QE_CREATED_AT")" \
        "$(_json_kv "updated_at" "$_QE_UPDATED_AT")" \
        "$(_json_kv "completed_at" "$_QE_COMPLETED_AT")" \
        "$(_json_kv "held_by" "${_QE_HELD_BY:-}")" \
        "$(_json_kv "independent" "${_QE_INDEPENDENT:-false}")" \
        "$(_json_kv "follow_up_of" "${_QE_FOLLOW_UP_OF:-}")" \
        "$_SHOW_FU_JSON" \
        "$_SHOW_SESSION_JSON" \
        "$_SHOW_HOLD_JSON" \
        "$(_json_kv "close_path" "$_SHOW_CLOSE_PATH")" \
        "$(_json_kv "close_state" "$_SHOW_CLOSE_STATE")" \
        "$(_json_kv_raw "merge_hold" "${_QE_MERGE_HOLD:-false}")" \
        "${_QE_CLOSE_STEPS:-[]}"
    else
      queue_show "$SHOW_ID"
    fi
    ;;

  # --- review: items needing operator attention ---
  review)
    if [ "$JSON_OUTPUT" = true ]; then
      printf '['
      FIRST=true
      while IFS='|' read -r R_ID R_STATUS R_TYPE R_ERROR R_WO; do
        [ -z "$R_ID" ] && continue
        if [ "$FIRST" = true ]; then
          FIRST=false
        else
          printf ','
        fi
        printf '{%s,%s,%s,%s,%s}' \
          "$(_json_kv "id" "$R_ID")" \
          "$(_json_kv "status" "$R_STATUS")" \
          "$(_json_kv "session_type" "$R_TYPE")" \
          "$(_json_kv "error_log" "$R_ERROR")" \
          "$(_json_kv "work_order_id" "$R_WO")"
      done < <(review_items)
      printf ']\n'
    else
      ITEMS=$(review_items)
      if [ -z "$ITEMS" ]; then
        echo "No items need review."
      else
        echo "$ITEMS"
      fi
    fi
    ;;

  # --- overlap: shared files across open branches (read-only) ---
  # Takes no lock and writes no state, so it is safe to poll. See
  # lib/overlap-report.sh for the read-only contract.
  overlap)
    OVERLAP_BRANCH=""
    while [ $# -gt 0 ]; do
      case "$1" in
        # `$#` is checked before dereferencing `$2`: this script runs under
        # `set -u`, so a bare `--branch` would abort with "unbound variable"
        # instead of a usable message.
        --branch)
          if [ $# -lt 2 ]; then
            echo "ERROR: --branch requires a value" >&2
            exit 1
          fi
          OVERLAP_BRANCH="$2"; shift 2 ;;
        *) echo "ERROR: Unknown overlap option: $1" >&2; exit 1 ;;
      esac
    done

    if ! overlap_report_build "$REPO_ROOT"; then
      echo "ERROR: Could not build overlap report (no main branch?)" >&2
      exit 1
    fi

    if [ "$JSON_OUTPUT" = true ]; then
      overlap_report_json "$OVERLAP_BRANCH"
    else
      overlap_report_text "$OVERLAP_BRANCH"
    fi
    ;;

  # --- log: review log tail ---
  log)
    LOG_LINES=20
    while [ $# -gt 0 ]; do
      case "$1" in
        --lines) LOG_LINES="$2"; shift 2 ;;
        *) echo "ERROR: Unknown log option: $1" >&2; exit 1 ;;
      esac
    done

    review_log_tail "$LOG_LINES"
    ;;

  # --- prune: manual cleanup of stale artifacts ---
  prune)
    PRUNE_BRIEFS_ONLY=false
    PRUNE_DRY_RUN=false
    PRUNE_FIX=false

    while [ $# -gt 0 ]; do
      case "$1" in
        --briefs-only) PRUNE_BRIEFS_ONLY=true; shift ;;
        --dry-run)     PRUNE_DRY_RUN=true; shift ;;
        --fix)         PRUNE_FIX=true; shift ;;
        *) echo "ERROR: Unknown prune option: $1" >&2; exit 1 ;;
      esac
    done

    if [ "$PRUNE_DRY_RUN" = true ]; then
      # Dry-run is read-only — no lock needed
      _dry_run_cleanup
    elif [ "$PRUNE_BRIEFS_ONLY" = true ]  && [ "$PRUNE_FIX" = false ]; then
      # Mutating — acquire lock
      if ! acquire_queue_lock; then
        echo "ERROR: Queue lock unavailable" >&2
        exit 1
      fi

      PRUNE_QUEUE_DAYS=$(_parse_config_field "retention" "queue_days" 2>/dev/null || true)
      PRUNE_QUEUE_DAYS="${PRUNE_QUEUE_DAYS:-30}"

      PRUNE_COUNT=$(_clean_briefs_only "$PRUNE_QUEUE_DAYS")
      release_queue_lock

      if [ "$JSON_OUTPUT" = true ]; then
        printf '{%s,%s}\n' \
          "$(_json_kv "action" "prune-briefs")" \
          "$(_json_kv_raw "deleted" "$PRUNE_COUNT")"
      else
        echo "Pruned $PRUNE_COUNT brief file(s)."
      fi
    else
      # Full cleanup — acquire lock
      if ! acquire_queue_lock; then
        echo "ERROR: Queue lock unavailable" >&2
        exit 1
      fi

      run_cleanup

      # Repair directory/status mismatches (lock already held)
      PRUNE_REPAIRED=$(_repair_status_mismatches)

      # Stale WO reconciliation: detect non-terminal WOs with all-terminal children
      PRUNE_STALE_WO_COUNT=0
      PRUNE_STALE_WO_FIXED=0
      _prune_wo_dir="$(_queue_dir)/work-orders"
      if [ -d "$_prune_wo_dir" ]; then
        for _prune_wo_file in "$_prune_wo_dir"/*.yaml; do
          [ -f "$_prune_wo_file" ] || continue
          _load_work_order "$_prune_wo_file"
          # Skip terminal WOs
          case "$_WO_STATUS" in
            completed) continue ;;
          esac
          # Check if all children are terminal
          if [ -z "$_WO_ENTRY_IDS" ]; then
            PRUNE_STALE_WO_COUNT=$((PRUNE_STALE_WO_COUNT + 1))
            if [ "$PRUNE_FIX" = true ]; then
              wo_reconcile "$_WO_ID" > /dev/null 2>&1 || true
              PRUNE_STALE_WO_FIXED=$((PRUNE_STALE_WO_FIXED + 1))
            fi
            continue
          fi
          _prune_all_terminal=true
          _prune_old_ifs="$IFS"
          IFS=','
          # shellcheck disable=SC2086 — intentional word splitting
          set -- $_WO_ENTRY_IDS
          IFS="$_prune_old_ifs"
          for _prune_eid in "$@"; do
            _prune_ef=$(_find_entry_file "$_prune_eid") || true
            [ -z "$_prune_ef" ] && { _prune_all_terminal=false; break; }
            _load_queue_entry "$_prune_ef"
            case "$_QE_STATUS" in
              completed|failed) ;;
              *) _prune_all_terminal=false; break ;;
            esac
          done
          if [ "$_prune_all_terminal" = true ]; then
            PRUNE_STALE_WO_COUNT=$((PRUNE_STALE_WO_COUNT + 1))
            if [ "$PRUNE_FIX" = true ]; then
              # Reload WO after _load_queue_entry clobbered nothing — but _WO_* may have been reset
              _prune_wo_id="$_WO_ID"
              wo_reconcile "$_prune_wo_id" > /dev/null 2>&1 || true
              PRUNE_STALE_WO_FIXED=$((PRUNE_STALE_WO_FIXED + 1))
            fi
          fi
        done
      fi

      release_queue_lock

      if [ "$JSON_OUTPUT" = true ]; then
        printf '{%s,%s,%s,%s}\n' \
          "$(_json_kv "action" "prune-complete")" \
          "$(_json_kv_raw "status_repairs" "$PRUNE_REPAIRED")" \
          "$(_json_kv_raw "stale_work_orders_detected" "$PRUNE_STALE_WO_COUNT")" \
          "$(_json_kv_raw "stale_work_orders_fixed" "$PRUNE_STALE_WO_FIXED")"
      else
        if [ "$PRUNE_REPAIRED" -gt 0 ]; then
          echo "Repaired $PRUNE_REPAIRED status mismatch(es)."
        fi
        if [ "$PRUNE_STALE_WO_COUNT" -gt 0 ]; then
          if [ "$PRUNE_FIX" = true ]; then
            echo "Reconciled $PRUNE_STALE_WO_FIXED stale work order(s) (of $PRUNE_STALE_WO_COUNT detected)."
          else
            echo "Detected $PRUNE_STALE_WO_COUNT stale work order(s) with all-terminal children. Run with --fix to reconcile."
          fi
        fi
        echo "Prune complete."
      fi
    fi
    ;;

  # --- start-daemon: launch daemon if not already running ---
  start-daemon)
    PID_FILE="$AUTOMATION_DIR/runner.pid"
    DAEMON_LOCK_FILE="$AUTOMATION_DIR/.daemon-lock"

    # Check if daemon is already running (PID file + lock test)
    if [ -f "$PID_FILE" ]; then
      EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
      if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        if [ "$JSON_OUTPUT" = true ]; then
          printf '{%s,%s}\n' \
            "$(_json_kv "action" "already-running")" \
            "$(_json_kv "pid" "$EXISTING_PID")"
        else
          printf 'Daemon already running (pid %s)\n' "$EXISTING_PID"
        fi
        exit 0
      else
        # Stale PID file — clean up (lock will be reclaimed by runner.sh)
        rm -f "$PID_FILE" 2>/dev/null || true
        rmdir "$DAEMON_LOCK_FILE.d" 2>/dev/null || true
      fi
    fi

    # Check for HALT file
    if [ -f "$AUTOMATION_DIR/HALT" ]; then
      if [ "$JSON_OUTPUT" = true ]; then
        printf '{%s}\n' "$(_json_kv "error" "HALT file present — remove with: queue-cli.sh resume")"
      else
        echo "ERROR: HALT file present — remove with: queue-cli.sh resume" >&2
      fi
      exit 1
    fi

    # Ensure local config override enables the runner (merge-safe — preserves existing fields)
    if [ -f "$CONFIG_LOCAL_FILE" ]; then
      if ! grep -q 'enabled: true' "$CONFIG_LOCAL_FILE" 2>/dev/null; then
        if grep -q '^runner:' "$CONFIG_LOCAL_FILE" 2>/dev/null; then
          sed -i '' '/^runner:/,/^[a-z]/{s/enabled: false/enabled: true/;}' "$CONFIG_LOCAL_FILE"
        else
          printf '\nrunner:\n  enabled: true\n' >> "$CONFIG_LOCAL_FILE"
        fi
      fi
    else
      printf 'runner:\n  enabled: true\n' > "$CONFIG_LOCAL_FILE"
    fi

    # Ensure logs directory exists (gitignored — may not exist on fresh clone)
    mkdir -p "$AUTOMATION_DIR/logs" 2>/dev/null || true

    # Launch daemon in background
    nohup "$AUTOMATION_DIR/runner.sh" --daemon >> "$AUTOMATION_DIR/logs/daemon.log" 2>&1 &
    DAEMON_PID=$!

    # Brief wait to verify startup
    sleep 1
    if kill -0 "$DAEMON_PID" 2>/dev/null; then
      if [ "$JSON_OUTPUT" = true ]; then
        printf '{%s,%s}\n' \
          "$(_json_kv "action" "started")" \
          "$(_json_kv "pid" "$DAEMON_PID")"
      else
        printf 'Daemon started (pid %s)\n' "$DAEMON_PID"
      fi
    else
      if [ "$JSON_OUTPUT" = true ]; then
        printf '{%s}\n' "$(_json_kv "error" "Daemon failed to start — check logs/daemon.log")"
      else
        echo "ERROR: Daemon failed to start — check logs/daemon.log" >&2
      fi
      exit 1
    fi
    ;;

  # --- halt: stop daemon loop ---
  halt)
    touch "$AUTOMATION_DIR/HALT"
    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s}\n' "$(_json_kv "action" "halted")"
    else
      echo "HALT file created — daemon will stop after current entry completes."
    fi
    ;;

  # --- force-halt: immediate stop — kill active session ---
  force-halt)
    touch "$AUTOMATION_DIR/FORCE-HALT"
    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s}\n' "$(_json_kv "action" "force-halted")"
    else
      echo "FORCE-HALT file created — daemon will kill active session and stop immediately."
    fi
    ;;

  # --- resume: clear halt ---
  resume)
    rm -f "$AUTOMATION_DIR/HALT" "$AUTOMATION_DIR/FORCE-HALT"
    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s}\n' "$(_json_kv "action" "resumed")"
    else
      echo "HALT file removed — restart daemon with: queue-cli.sh start-daemon"
    fi
    ;;

  # --- reopen-entry: return a reviewed entry to the approved queue ---
  # The missing exit from review/. See queue_reopen_reviewed for why every
  # review:* outcome was previously a one-way door.
  reopen-entry)
    if [ $# -lt 1 ]; then
      echo "ERROR: reopen-entry requires <id>" >&2
      exit 1
    fi
    _RE_ID="$1"
    if ! acquire_queue_lock; then
      echo "ERROR: Queue lock unavailable" >&2
      exit 1
    fi
    if queue_reopen_reviewed "$_RE_ID"; then
      release_queue_lock
      # Pass the work order id, as every other entry-level event does
      # (entry-blocked, entry-deferred, entry-recovered). _QE_WORK_ORDER_ID is
      # populated by the call that just ran, and this is the one line recording
      # the work-order-clearing half of the command.
      review_log_append "entry-reopened" "${_QE_WORK_ORDER_ID:-}" "$_RE_ID" \
        "Entry $_RE_ID returned from ${_REOPEN_SRC_DIR:-review}/ to approved by operator — retry budget restored" 2>/dev/null || true
      # Report whether the parent work order was actually reopened. Both output
      # forms used to be identical whether it was cleared or deliberately left
      # failed, so neither a human nor a script could tell a full recovery from
      # a half one.
      if [ "$JSON_OUTPUT" = true ]; then
        printf '{%s,%s,%s,%s}\n' \
          "$(_json_kv "action" "reopen-entry")" \
          "$(_json_kv "id" "$_RE_ID")" \
          "$(_json_kv "work_order_reopened" "${_RR_WO_REOPENED:-n/a}")" \
          "$(_json_kv "work_order_blockers" "${_RR_WO_BLOCKERS:-}")"
      else
        echo "Entry $_RE_ID returned to approved from ${_REOPEN_SRC_DIR:-review}/ (retry budget reset to 0)."
        case "${_RR_WO_REOPENED:-n/a}" in
          true)         echo "Parent work order $_QE_WORK_ORDER_ID reopened — the entry is eligible on the next poll." ;;
          not-needed)   echo "Parent work order $_QE_WORK_ORDER_ID needed no reopen." ;;
          false)        echo "NOT fully recovered: work order $_QE_WORK_ORDER_ID was left as-is${_RR_WO_BLOCKERS:+ ($_RR_WO_BLOCKERS)}. This entry will be DEFERRED and then blocked until you run: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" ;;
          *)            : ;;
        esac
        echo "If it got here by exhausting its turn budget, raise runner.session_max_turns or split the brief FIRST — otherwise it will run just as long and end up back here."
      fi
    else
      release_queue_lock
      exit 1
    fi
    ;;

  # --- reset-breaker: clear the circuit breaker's consecutive-failure counter ---
  # Until this existed there was no sanctioned way out of a tripped breaker: the
  # counter is only cleared by a successful session, and the breaker prevents any
  # session from starting. Deleting the file by hand was the only recovery.
  reset-breaker)
    _RB_FILE="$(_queue_dir)/.circuit-breaker"
    if [ ! -f "$_RB_FILE" ]; then
      if [ "$JSON_OUTPUT" = true ]; then
        printf '{%s,%s}\n' "$(_json_kv "action" "reset-breaker")" "$(_json_kv "result" "not-tripped")"
      else
        echo "Circuit breaker is not set — nothing to reset."
      fi
      exit 0
    fi
    # `|| true` on both reads, and it is load-bearing, not defensive noise.
    # This arm runs under `set -euo pipefail`: on a breaker file that exists but
    # has no `consecutive_failures:` line, grep exits 1, pipefail propagates it,
    # and the assignment ends the script BEFORE the `rm -f` below — the command
    # would print nothing and leave the breaker set, which is the exact
    # hand-deletion-only state it was added to remove. The `${_RB_*:-unknown}`
    # fallbacks exist precisely because a miss has to be survivable.
    _RB_COUNT=$(grep '^consecutive_failures:' "$_RB_FILE" 2>/dev/null \
      | sed 's/^[^:]*: *//' | tr -d '[:space:]' | head -1) || true
    # `s/^[^:]*: *//`, not the `s/.*: *//` used elsewhere for numeric fields:
    # the value here is an ISO timestamp, and the greedy form eats up to its
    # LAST colon, printing "52Z" instead of "2026-10-20T17:57:52Z".
    _RB_AT=$(grep '^last_failure_at:' "$_RB_FILE" 2>/dev/null \
      | sed 's/^[^:]*: *//' | tr -d '[:space:]' | head -1) || true
    rm -f "$_RB_FILE" 2>/dev/null || true
    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s}\n' \
        "$(_json_kv "action" "reset-breaker")" \
        "$(_json_kv "cleared_failures" "${_RB_COUNT:-unknown}")" \
        "$(_json_kv "last_failure_at" "${_RB_AT:-unknown}")"
    else
      echo "Circuit breaker cleared (was ${_RB_COUNT:-unknown} consecutive failures, last at ${_RB_AT:-unknown})."
      echo "The daemon will pick up the next eligible entry; if the underlying cause is unfixed it will trip again after ${_CB_TRIP_THRESHOLD} failures."
    fi
    ;;

  # --- reset-group-worktree: clear a wedged sequential task group worktree ---
  # Operator-only (the runner never calls it). A group worktree can be left
  # mid-rebase, detached or dirty; the runner then blocks every brief of the group
  # rather than building on it. This discards the UNCOMMITTED state only —
  # committed work and the branch are kept — and only for a group whose work order
  # is failed/escalated. Same shape as reset-breaker: sanctioned, explicit, and
  # idempotent, instead of hand-deleting git state.
  reset-group-worktree)
    _RG_GROUP="" _RG_YES=false
    for _rg_arg in "$@"; do
      case "$_rg_arg" in
        --yes|-y) _RG_YES=true ;;
        -*)
          echo "ERROR: reset-group-worktree: unknown option $_rg_arg" >&2
          exit 1
          ;;
        *)
          if [ -n "$_RG_GROUP" ]; then
            echo "ERROR: reset-group-worktree takes one <group>" >&2
            exit 1
          fi
          _RG_GROUP="$_rg_arg"
          ;;
      esac
    done
    if [ -z "$_RG_GROUP" ]; then
      echo "ERROR: reset-group-worktree requires <group> [--yes]" >&2
      exit 1
    fi
    if ! _RG_WT=$(group_worktree_path "$_RG_GROUP"); then
      echo "ERROR: '$_RG_GROUP' is not a usable group name" >&2
      exit 1
    fi
    # Informational text goes to stdout, or stderr when --json owns stdout.
    _rg_say() { if [ "$JSON_OUTPUT" = true ]; then echo "$*" >&2; else echo "$*"; fi; }

    if [ ! -d "$_RG_WT" ]; then
      _rg_say "No worktree for group '$_RG_GROUP' ($_RG_WT) — nothing to reset."
      if [ "$JSON_OUTPUT" = true ]; then
        printf '{%s,%s}\n' "$(_json_kv "action" "reset-group-worktree")" "$(_json_kv "result" "nothing-to-reset")"
      fi
      exit 0
    fi
    if ! is_registered_worktree "$_RG_WT"; then
      # git -C on an unregistered directory would act on the PARENT repo.
      echo "ERROR: $_RG_WT exists but is not a registered git worktree — refusing to run git there. Inspect and remove it by hand." >&2
      exit 1
    fi

    # Which work orders belong to this group? Matched through each child entry's
    # brief (### Task Group → canonical "- **Group:**" line via
    # _parse_brief_taskgroup_metadata). A brief using only the legacy bare "Group:"
    # form (which the runner's _extract_group_name also accepts) will not match here.
    _RG_KEY=$(_sanitize_group_name "$_RG_GROUP")
    _RG_ACTIVE="" _RG_BRANCH="" _RG_REFUSE=""
    for _rg_wf in "$(_queue_dir)"/work-orders/*.yaml; do
      [ -f "$_rg_wf" ] || continue
      _load_work_order "$_rg_wf" || continue
      [ "$_WO_STATUS" = "completed" ] && continue
      _rg_wo_id="$_WO_ID"
      _rg_wo_status="$_WO_STATUS"
      _rg_hit=false
      _old_ifs="$IFS"
      IFS=','
      # shellcheck disable=SC2086 — intentional word splitting
      set -- $_WO_ENTRY_IDS
      IFS="$_old_ifs"
      for _eid in "$@"; do
        _ef=$(_find_entry_file "$_eid") || true
        [ -n "$_ef" ] || continue
        _load_queue_entry "$_ef" || continue
        _rg_bp="$_QE_BRIEF_PATH"
        case "$_rg_bp" in
          /*) ;;
          *) _rg_bp="$REPO_ROOT/$_rg_bp" ;;
        esac
        [ -f "$_rg_bp" ] || continue
        _parse_brief_taskgroup_metadata "$_rg_bp" 2>/dev/null || true
        if [ "$_BRIEF_TG_DETECTED" = true ] \
           && [ "$(_sanitize_group_name "$_BRIEF_TG_GROUP_NAME")" = "$_RG_KEY" ]; then
          _rg_hit=true
          if [ -z "$_RG_BRANCH" ] && [ -n "$_QE_BRANCH" ]; then
            _RG_BRANCH=$(sanitize_branch_name "$_QE_BRANCH")
          fi
        fi
      done
      if [ "$_rg_hit" = true ]; then
        _RG_ACTIVE="${_RG_ACTIVE:+$_RG_ACTIVE }$_rg_wo_id"
        case "$_rg_wo_status" in
          failed|escalated) ;;
          *) _RG_REFUSE="${_RG_REFUSE:+$_RG_REFUSE; }work order $_rg_wo_id is $_rg_wo_status" ;;
        esac
      fi
    done

    if [ -z "$_RG_ACTIVE" ]; then
      echo "ERROR: no failed or escalated work order found for group '$_RG_GROUP' — refusing to discard the worktree's state. (A group that is still progressing, or already completed, must not be reset.)" >&2
      exit 1
    fi
    if [ -n "$_RG_REFUSE" ]; then
      echo "ERROR: refusing to reset group '$_RG_GROUP': $_RG_REFUSE (reset is only for a failed or escalated work order)." >&2
      exit 1
    fi

    # A live session in the worktree must never have it pulled out from under it.
    _RG_LOCK=$(_group_worktree_lock_dir "$_RG_GROUP" 2>/dev/null) || _RG_LOCK=""
    if [ -n "$_RG_LOCK" ] && [ -d "$_RG_LOCK" ]; then
      _RG_LPID=$(cat "$_RG_LOCK/pid" 2>/dev/null || true)
      if [ -n "$_RG_LPID" ] && [ "$_RG_LPID" != "$$" ] && kill -0 "$_RG_LPID" 2>/dev/null; then
        echo "ERROR: group worktree '$_RG_GROUP' is occupied by a live session (pid $_RG_LPID) — stop it first." >&2
        exit 1
      fi
    fi

    # --- Preview: exactly what will be discarded ---
    _RG_CUR=$(group_worktree_branch "$_RG_WT")
    _RG_STATUS=$(git -C "$_RG_WT" status --porcelain 2>/dev/null || true)
    _RG_REBASING=false
    if _bm_rebase_in_progress "$_RG_WT"; then _RG_REBASING=true; fi
    _RG_NEEDS=false
    [ -n "$_RG_STATUS" ] && _RG_NEEDS=true
    [ "$_RG_REBASING" = true ] && _RG_NEEDS=true
    if [ -n "$_RG_BRANCH" ] && [ "$_RG_CUR" != "$_RG_BRANCH" ]; then _RG_NEEDS=true; fi

    if [ "$_RG_NEEDS" = false ]; then
      _rg_say "Group worktree '$_RG_GROUP' ($_RG_WT) is already clean on ${_RG_CUR:-?} — nothing to discard."
    else
      _rg_say "reset-group-worktree '$_RG_GROUP' will, in $_RG_WT:"
      if [ "$_RG_REBASING" = true ]; then
        _rg_say "  - abort the rebase that is in progress"
      fi
      if [ -n "$_RG_BRANCH" ] && [ "$_RG_CUR" != "$_RG_BRANCH" ]; then
        _rg_say "  - check out $_RG_BRANCH (HEAD is on '${_RG_CUR:-detached}')"
      fi
      if [ -n "$_RG_STATUS" ]; then
        _rg_say "  - DISCARD these uncommitted changes (git reset --hard + git clean -fd):"
        while IFS= read -r _rg_line; do
          [ -n "$_rg_line" ] && _rg_say "      $_rg_line"
        done <<< "$_RG_STATUS"
      fi
      _rg_say "  Kept: all committed work and the branch itself; gitignored files (dependencies, caches)."
    fi

    if [ "$_RG_NEEDS" = true ] && [ "$_RG_YES" != true ]; then
      if [ -t 0 ]; then
        printf 'Type "yes" to proceed: '
        read -r _rg_ans || _rg_ans=""
        if [ "$_rg_ans" != "yes" ]; then
          echo "Aborted — nothing was changed." >&2
          exit 1
        fi
      else
        echo "No terminal to confirm on — nothing was changed. Re-run with --yes to proceed." >&2
        exit 1
      fi
    fi

    if [ "$_RG_NEEDS" = true ]; then
      if [ "$_RG_REBASING" = true ]; then
        git -C "$_RG_WT" rebase --abort > /dev/null 2>&1 || true
      fi
      _RG_CUR=$(group_worktree_branch "$_RG_WT")
      if [ -n "$_RG_BRANCH" ] && [ "$_RG_CUR" != "$_RG_BRANCH" ]; then
        if ! git -C "$_RG_WT" checkout -f "$_RG_BRANCH" > /dev/null 2>&1; then
          echo "ERROR: could not check out $_RG_BRANCH in $_RG_WT — resolve by hand." >&2
          exit 1
        fi
      fi
      git -C "$_RG_WT" reset --hard > /dev/null 2>&1 || true
      git -C "$_RG_WT" clean -fd > /dev/null 2>&1 || true
      if [ -n "$(git -C "$_RG_WT" status --porcelain 2>/dev/null || true)" ] || _bm_rebase_in_progress "$_RG_WT"; then
        echo "ERROR: worktree $_RG_WT is still not clean after the reset — resolve by hand." >&2
        exit 1
      fi
      review_log_append "group-worktree-reset" "" "" \
        "Operator reset group worktree '$_RG_GROUP' ($_RG_WT)" 2>/dev/null || true
      _rg_say "Group worktree '$_RG_GROUP' reset and clean on $(group_worktree_branch "$_RG_WT")."
    fi

    # Next steps. Only "behind main" needs a rebase; say so when it applies.
    _RG_TIP="${_RG_BRANCH:-$(group_worktree_branch "$_RG_WT")}"
    _rg_say "Next steps:"
    if [ -n "$_RG_TIP" ] && ! git -C "$_RG_WT" merge-base --is-ancestor main "$_RG_TIP" 2>/dev/null; then
      _rg_say "  1. Bring the branch up to date: git -C $_RG_WT rebase main  (resolve conflicts, 'git add', 'git rebase --continue')"
      _rg_say "  2. Resume the group: queue-cli.sh reopen-wo ${_RG_ACTIVE%% *}"
    else
      _rg_say "  Resume the group: queue-cli.sh reopen-wo ${_RG_ACTIVE%% *}"
    fi
    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s}\n' "$(_json_kv "action" "reset-group-worktree")" \
        "$(_json_kv "group" "$_RG_GROUP")" "$(_json_kv "work_order" "${_RG_ACTIVE%% *}")"
    fi
    ;;

  # --- reopen-wo: reopen an escalated or failed work order and reset blocked/failed siblings ---
  reopen-wo)
    if [ $# -lt 1 ]; then
      echo "ERROR: reopen-wo requires <work-order-id>" >&2
      exit 1
    fi
    REOPEN_WO_ID="$1"

    if ! acquire_queue_lock; then
      echo "ERROR: Queue lock unavailable" >&2
      exit 1
    fi

    # Reopen the work order (escalated → open)
    if ! wo_reopen "$REOPEN_WO_ID"; then
      release_queue_lock
      exit 1
    fi

    # Find and reset blocked/failed siblings back to approved
    _REOPEN_RESET_COUNT=0
    _WO_FILE="$(_queue_dir)/work-orders/${REOPEN_WO_ID}.yaml"
    if [ -f "$_WO_FILE" ]; then
      _load_work_order "$_WO_FILE"
      if [ -n "$_WO_ENTRY_IDS" ]; then
        _old_ifs="$IFS"
        IFS=','
        # shellcheck disable=SC2086 — intentional word splitting
        set -- $_WO_ENTRY_IDS
        IFS="$_old_ifs"
        for _eid in "$@"; do
          _ef=$(_find_entry_file "$_eid") || true
          [ -z "$_ef" ] && continue
          _load_queue_entry "$_ef"
          case "$_QE_STATUS" in
            blocked|failed)
              # Transition back to approved
              _QE_STATUS="approved"
              _QE_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
              _QE_COMPLETED_AT=""
              _QE_ERROR_LOG=""
              _QE_PROMPT=""
              # Reset the retry budget too. A sibling reaches `failed` by
              # exhausting max_retries, so reopening it without clearing the
              # count returned an entry that was immediately out of retries:
              # the first failure sent it straight back to failed/ and the
              # operator had to run reopen-wo again per attempt. Reopening is an
              # explicit operator decision to try again, so the budget is
              # restored with it.
              _QE_RETRY_COUNT="0"
              # NOT `local`: this is the top-level `case` dispatch, not a
              # function, and bash errors with "local: can only be used in a
              # function" — which aborted this loop before any sibling was
              # reset. reopen-wo's advertised second step therefore never ran,
              # and a task group with a failed brief could not be resumed by the
              # documented recovery command. A plain global matches the
              # surrounding `_REOPEN_*` variables.
              _qdir=$(_queue_dir)
              _write_queue_entry "$_qdir/approved/${_eid}.yaml"
              rm -f "$_ef"
              _REOPEN_RESET_COUNT=$((_REOPEN_RESET_COUNT + 1))
              ;;
          esac
          # Clean up defer-count files
          rm -f "$(_queue_dir)/.defer-count-${_eid}" 2>/dev/null || true
        done
      fi
    fi
    _rebuild_queue_index

    # Post-reopen completion check: if all children are already terminal,
    # the WO should immediately reach the correct terminal state rather than
    # staying open indefinitely waiting for entries that are already done.
    _reopen_final_status=$(wo_check_completion "$REOPEN_WO_ID" 2>/dev/null) || {
      echo "WARNING: wo_check_completion failed for work order $REOPEN_WO_ID after reopen" >&2
    }

    release_queue_lock

    # Review log
    review_log_append "work-order-reopened" "$REOPEN_WO_ID" "" \
      "Work order $REOPEN_WO_ID reopened — $_REOPEN_RESET_COUNT sibling(s) reset to approved" 2>/dev/null || true

    if [ -n "$_reopen_final_status" ] && [ "$_reopen_final_status" != "open" ]; then
      review_log_append "work-order-${_reopen_final_status}" "$REOPEN_WO_ID" "" \
        "Work order $REOPEN_WO_ID immediately reached $_reopen_final_status after reopen — all children already terminal" 2>/dev/null || true
    fi

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s}\n' \
        "$(_json_kv "work_order_id" "$REOPEN_WO_ID")" \
        "$(_json_kv "action" "reopened")" \
        "$(_json_kv_raw "siblings_reset" "$_REOPEN_RESET_COUNT")"
    else
      printf 'Work order %s reopened. %s sibling(s) reset to approved.\n' \
        "$REOPEN_WO_ID" "$_REOPEN_RESET_COUNT"
    fi
    ;;

  # --- recover-entry: operator escape hatch for stale running entries ---
  recover-entry)
    if [ $# -lt 1 ]; then
      echo "ERROR: recover-entry requires <id>" >&2
      exit 1
    fi
    RECOVER_ID="$1"

    # Locate entry and verify it is in running/ status
    RECOVER_ENTRY_FILE=$(_find_entry_file "$RECOVER_ID")
    if [ -z "$RECOVER_ENTRY_FILE" ]; then
      echo "ERROR: Entry $RECOVER_ID not found" >&2
      exit 1
    fi

    # Check that entry is in running/ (not any other status)
    case "$RECOVER_ENTRY_FILE" in
      */running/*)
        ;; # expected — proceed
      *)
        _load_queue_entry "$RECOVER_ENTRY_FILE"
        echo "ERROR: Entry $RECOVER_ID is not running (current status: $_QE_STATUS). Only running entries can be recovered." >&2
        exit 1
        ;;
    esac

    # Acquire lock for queue mutation
    if ! acquire_queue_lock; then
      echo "ERROR: Queue lock unavailable" >&2
      exit 1
    fi

    # Transition running → failed
    _RECOVER_QDIR=$(_queue_dir)
    _load_queue_entry "$RECOVER_ENTRY_FILE"
    _QE_STATUS="failed"
    _QE_ERROR_LOG="operator-recovery"
    _QE_COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    _QE_UPDATED_AT="$_QE_COMPLETED_AT"
    _write_queue_entry "$_RECOVER_QDIR/failed/${RECOVER_ID}.yaml"
    rm -f "$RECOVER_ENTRY_FILE"

    # Remove stale heartbeat and defer-count files
    rm -f "$_RECOVER_QDIR/running/${RECOVER_ID}.heartbeat" 2>/dev/null || true
    rm -f "$_RECOVER_QDIR/.defer-count-${RECOVER_ID}" 2>/dev/null || true

    # Rebuild index
    _rebuild_queue_index

    # Propagate failure to work order if entry belongs to one
    if [ -n "$_QE_WORK_ORDER_ID" ]; then
      _RECOVER_WO_STATUS=$(wo_check_completion "$_QE_WORK_ORDER_ID" 2>/dev/null) || true
      case "$_RECOVER_WO_STATUS" in
        failed)
          review_log_append "work-order-failed" "$_QE_WORK_ORDER_ID" "" \
            "Work order $_QE_WORK_ORDER_ID failed — entry $RECOVER_ID recovered by operator. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
          ;;
        escalated)
          review_log_append "work-order-escalated" "$_QE_WORK_ORDER_ID" "" \
            "Work order $_QE_WORK_ORDER_ID escalated — entry $RECOVER_ID recovered by operator. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
          ;;
      esac
    fi

    release_queue_lock

    # Write escalation file with recovery context
    _RECOVER_ESC_DIR="$REPO_ROOT/.claude/.automation/escalations"
    mkdir -p "$_RECOVER_ESC_DIR" 2>/dev/null || true
    _RECOVER_ESC_ID="esc-${RECOVER_ID}-$(date +%Y%m%d-%H%M%S)"
    {
      printf 'escalation:\n'
      printf '  id: "%s"\n' "$_RECOVER_ESC_ID"
      printf '  queue_entry_id: "%s"\n' "$RECOVER_ID"
      printf '  type: "gate-failure"\n'
      printf '  severity: "blocking"\n'
      printf '  phase_at_exit: "unknown"\n'
      printf '  tag_at_exit: "operator"\n'
      printf '  message: "Entry recovered by operator — stale running entry transitioned to failed"\n'
      printf '  context: "Operator used recover-entry CLI to rescue stale entry"\n'
      printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '  resolved: false\n'
      printf '  resolution: ""\n'
    } > "$_RECOVER_ESC_DIR/${_RECOVER_ESC_ID}.yaml" 2>/dev/null || true

    # Log to review log
    review_log_append "entry-recovered" "" "$RECOVER_ID" \
      "Entry $RECOVER_ID recovered by operator — transitioned from running to failed" 2>/dev/null || true

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s}\n' \
        "$(_json_kv "entry_id" "$RECOVER_ID")" \
        "$(_json_kv "action" "recovered")" \
        "$(_json_kv "escalation_id" "$_RECOVER_ESC_ID")"
    else
      printf 'Recovered: %s (moved to failed/, escalation written)\n' "$RECOVER_ID"
    fi
    ;;

  # --- stop-entry: end one entry's session without halting the daemon ---
  # Writes the control flag the session's PreToolUse hook reads (STOP) or the one
  # the runner's stop watcher acts on (FORCE). Deliberately does NOT move the
  # entry: the runner owns the running/ → stopped/ transition, because only it
  # knows when the child has actually exited (Decision t-0055 clauses 6-7).
  stop-entry)
    if [ $# -lt 1 ]; then
      echo "ERROR: stop-entry requires <id>" >&2
      exit 1
    fi
    STOP_ID="$1"
    shift

    STOP_FORCE=false
    STOP_REASON=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --force)
          STOP_FORCE=true
          shift
          ;;
        --reason)
          if [ $# -lt 2 ]; then
            echo "ERROR: --reason requires a value" >&2
            exit 1
          fi
          STOP_REASON="$2"
          shift 2
          ;;
        *)
          echo "ERROR: Unknown stop-entry option: $1" >&2
          exit 1
          ;;
      esac
    done

    STOP_ENTRY_FILE=$(_find_entry_file "$STOP_ID")
    if [ -z "$STOP_ENTRY_FILE" ]; then
      echo "ERROR: Entry $STOP_ID not found" >&2
      exit 1
    fi
    _load_queue_entry "$STOP_ENTRY_FILE"
    case "$STOP_ENTRY_FILE" in
      */running/*)
        ;; # expected — proceed
      *)
        echo "ERROR: Entry $STOP_ID is not running (current status: $_QE_STATUS). Only a running entry has a session to stop." >&2
        exit 1
        ;;
    esac

    STOP_CONTROL_DIR=$(ensure_control_dir "$STOP_ID") || STOP_CONTROL_DIR=""
    if [ -z "$STOP_CONTROL_DIR" ]; then
      echo "ERROR: Could not create the control directory for entry $STOP_ID" >&2
      exit 1
    fi

    # Escalation: --force, or a second stop while an earlier one is still
    # pending. "Stop again to force" is the whole interaction — the operator
    # does not have to know which flag they are writing.
    STOP_MODE="graceful"
    if [ "$STOP_FORCE" = true ]; then
      STOP_MODE="forced"
    elif [ -f "$STOP_CONTROL_DIR/FORCE" ] || [ -f "$STOP_CONTROL_DIR/STOP" ]; then
      STOP_MODE="forced"
    fi
    if [ "$STOP_MODE" = "forced" ]; then
      STOP_FLAG="FORCE"
    else
      STOP_FLAG="STOP"
    fi

    # Flag content is advisory — the operator's reason, surfaced in the session's
    # stopReason. Existence is the signal, so an empty flag is still a stop.
    if [ -n "$STOP_REASON" ]; then
      printf '%s\n' "$STOP_REASON" > "$STOP_CONTROL_DIR/$STOP_FLAG"
    else
      : > "$STOP_CONTROL_DIR/$STOP_FLAG"
    fi

    # Session record → control_state: stopping, which is what the UI reads to
    # show "stopping" on an entry whose child has not exited yet. Records are
    # keyed by session id, so the session running this entry is found by scanning
    # the registry for its entry_id. Fail-soft: a missing record changes nothing
    # about the stop — the flag is the mechanism, control_state is the display.
    STOP_SESSION_ID=""
    STOP_SESSIONS_DIR="$(get_main_repo_root)/.claude/.state/sessions"
    if [ -d "$STOP_SESSIONS_DIR" ]; then
      for _STOP_REC in "$STOP_SESSIONS_DIR"/*.yaml; do
        [ -f "$_STOP_REC" ] || continue
        if grep -Fqx "entry_id: $STOP_ID" "$_STOP_REC" 2>/dev/null; then
          STOP_SESSION_ID=$(basename "$_STOP_REC" .yaml)
          break
        fi
      done
    fi
    if [ -n "$STOP_SESSION_ID" ]; then
      session_record_set "$STOP_SESSION_ID" "control_state=stopping" 2>/dev/null || \
        echo "WARNING: Could not set control_state on session record $STOP_SESSION_ID" >&2
    else
      echo "WARNING: No session record names entry $STOP_ID — the flag is set, but control_state could not be updated" >&2
    fi

    review_log_append "entry-stop-requested" "${_QE_WORK_ORDER_ID:-}" "$STOP_ID" \
      "Operator requested a $STOP_MODE stop of entry $STOP_ID${STOP_REASON:+ ($STOP_REASON)}. Resume with: queue-cli.sh resume-entry $STOP_ID" 2>/dev/null || true

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s,%s,%s}\n' \
        "$(_json_kv "entry_id" "$STOP_ID")" \
        "$(_json_kv "action" "stop")" \
        "$(_json_kv "mode" "$STOP_MODE")" \
        "$(_json_kv "flag" "$STOP_FLAG")" \
        "$(_json_kv "control_state" "stopping")"
    elif [ "$STOP_MODE" = "forced" ]; then
      printf 'Force-stopping %s: SIGTERM now, SIGKILL after 10s. The worktree and Claude session are kept — resume with: queue-cli.sh resume-entry %s\n' \
        "$STOP_ID" "$STOP_ID"
    else
      printf 'Stopping %s at its next tool call. The worktree and Claude session are kept — resume with: queue-cli.sh resume-entry %s (stop again to force)\n' \
        "$STOP_ID" "$STOP_ID"
    fi
    ;;

  # --- resume-entry: put a stopped entry back in the queue, same session ---
  resume-entry)
    if [ $# -lt 1 ]; then
      echo "ERROR: resume-entry requires <id>" >&2
      exit 1
    fi
    RESUME_ID="$1"

    RESUME_ENTRY_FILE=$(_find_entry_file "$RESUME_ID")
    if [ -z "$RESUME_ENTRY_FILE" ]; then
      echo "ERROR: Entry $RESUME_ID not found" >&2
      exit 1
    fi
    _load_queue_entry "$RESUME_ENTRY_FILE"
    case "$RESUME_ENTRY_FILE" in
      */stopped/*)
        ;; # expected — proceed
      *)
        echo "ERROR: Entry $RESUME_ID is not stopped (current status: $_QE_STATUS). Only a stopped entry can be resumed." >&2
        exit 1
        ;;
    esac
    RESUME_STOPPED_MODE="${_QE_STOPPED_MODE:-graceful}"
    RESUME_WO_ID="${_QE_WORK_ORDER_ID:-}"

    # Clear the flags BEFORE the entry becomes dequeuable. A flag left in place
    # would be read by the resumed session's first tool call and stop it again
    # (and by the runner's exit path, which would send it straight back to
    # stopped/). The runner clears them too when it honours a stop, so this is
    # the belt to that braces — a stop the runner never got to observe (daemon
    # crash, force-halt) leaves a flag behind that only this path removes.
    RESUME_CONTROL_DIR=$(get_control_dir "$RESUME_ID" 2>/dev/null) || RESUME_CONTROL_DIR=""
    if [ -n "$RESUME_CONTROL_DIR" ]; then
      rm -f "$RESUME_CONTROL_DIR/STOP" "$RESUME_CONTROL_DIR/FORCE" 2>/dev/null || true
    fi

    if ! acquire_queue_lock; then
      echo "ERROR: Queue lock unavailable" >&2
      exit 1
    fi
    if ! queue_resume "$RESUME_ID"; then
      release_queue_lock
      echo "ERROR: Could not resume entry $RESUME_ID" >&2
      exit 1
    fi
    # Resuming resolves the hold (t-0055 clause 9): the entries queued behind
    # this one were only waiting on its outcome. Any that are still genuinely
    # related are re-held by the next dequeue tick if it stops again.
    RESUME_FREED=$(queue_release_holds "$RESUME_ID") || RESUME_FREED=""
    release_queue_lock

    RESUME_FREED_COUNT=0
    if [ -n "$RESUME_FREED" ]; then
      RESUME_FREED_COUNT=$(printf '%s\n' "$RESUME_FREED" | grep -c .)
    fi

    # The resume handle (control/<id>/resume.yaml) is what makes the relaunch
    # continue the recorded transcript. Without it the entry still runs, but from
    # a fresh session — say so now rather than let the operator discover it from
    # a runner warning.
    RESUME_CLAUDE_SESSION=""
    if [ -n "$RESUME_CONTROL_DIR" ] && [ -f "$RESUME_CONTROL_DIR/resume.yaml" ]; then
      RESUME_CLAUDE_SESSION=$(grep -E '^claude_session_id:' "$RESUME_CONTROL_DIR/resume.yaml" 2>/dev/null | head -1 | sed 's/^claude_session_id: *//; s/^"//; s/"$//') || RESUME_CLAUDE_SESSION=""
    fi

    review_log_append "entry-resumed" "$RESUME_WO_ID" "$RESUME_ID" \
      "Entry $RESUME_ID resumed by operator after a $RESUME_STOPPED_MODE stop — back in approved/ with resume: true${RESUME_CLAUDE_SESSION:+, continuing claude session $RESUME_CLAUDE_SESSION}; released $RESUME_FREED_COUNT held entries" 2>/dev/null || true

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s,%s,%s}\n' \
        "$(_json_kv "entry_id" "$RESUME_ID")" \
        "$(_json_kv "action" "resumed")" \
        "$(_json_kv "stopped_mode" "$RESUME_STOPPED_MODE")" \
        "$(_json_kv "claude_session_id" "$RESUME_CLAUDE_SESSION")" \
        "$(_json_kv_raw "released_count" "$RESUME_FREED_COUNT")"
    elif [ -n "$RESUME_CLAUDE_SESSION" ]; then
      printf 'Resumed: %s (approved/, continuing claude session %s) — released %s held entries\n' \
        "$RESUME_ID" "$RESUME_CLAUDE_SESSION" "$RESUME_FREED_COUNT"
    else
      printf 'Resumed: %s (approved/) — no resume handle found, so the next run starts a fresh session. Released %s held entries\n' \
        "$RESUME_ID" "$RESUME_FREED_COUNT"
    fi
    ;;

  # --- close-status: where an entry's close pipeline has got to ---
  # Read-only. Prints close_path, close_state and the recorded steps.
  close-status)
    if [ $# -lt 1 ]; then
      echo "ERROR: close-status requires <id>" >&2
      exit 1
    fi
    CS_ID="$1"
    CS_FILE=$(_find_entry_file "$CS_ID") || CS_FILE=""
    if [ -z "$CS_FILE" ]; then
      echo "ERROR: Entry $CS_ID not found" >&2
      exit 1
    fi
    _load_queue_entry "$CS_FILE"
    CS_PATH=$(queue_close_path)
    CS_STATE=$(queue_close_state)
    CS_HOLD="${_QE_MERGE_HOLD:-false}"
    # close_steps is stored as text that is already valid JSON, so --json emits
    # it verbatim. There is no reader and deliberately no second representation.
    CS_STEPS="${_QE_CLOSE_STEPS:-[]}"
    CS_STATUS="${_QE_STATUS:-unknown}"

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s,%s,%s,"close_steps":%s}\n' \
        "$(_json_kv "entry_id" "$CS_ID")" \
        "$(_json_kv "status" "$CS_STATUS")" \
        "$(_json_kv "close_path" "$CS_PATH")" \
        "$(_json_kv "close_state" "$CS_STATE")" \
        "$(_json_kv_raw "merge_hold" "$CS_HOLD")" \
        "$CS_STEPS"
    else
      printf 'Entry:       %s (%s)\n' "$CS_ID" "$CS_STATUS"
      printf 'Close path:  %s\n' "$CS_PATH"
      printf 'Close state: %s\n' "$CS_STATE"
      if [ "$CS_HOLD" = "true" ]; then
        printf 'Merge hold:  held by operator — release with: queue-cli.sh hold-merge %s --release\n' "$CS_ID"
      fi
      if [ "$CS_STEPS" = "[]" ] || [ -z "$CS_STEPS" ]; then
        printf 'Steps:       (none recorded)\n'
      else
        printf 'Steps:\n'
        # Split the stored sequence on its row boundary with parameter
        # expansion, the same zero-fork style the entry parser uses. The rows
        # are written by one function (queue_close_step_json) in one fixed key
        # order, which is why four known keys can be lifted out positionally
        # without a JSON reader.
        CS_REST="${CS_STEPS#\[}"
        CS_REST="${CS_REST%\]}"
        while [ -n "$CS_REST" ]; do
          case "$CS_REST" in
            *'},{'*)
              CS_ROW="${CS_REST%%\},\{*}}"
              CS_REST="{${CS_REST#*\},\{}"
              ;;
            *)
              CS_ROW="$CS_REST"
              CS_REST=""
              ;;
          esac
          CS_F="${CS_ROW#*\"step\":\"}";   CS_STEP="${CS_F%%\"*}"
          CS_F="${CS_ROW#*\"status\":\"}"; CS_ST="${CS_F%%\"*}"
          CS_F="${CS_ROW#*\"at\":\"}";     CS_AT="${CS_F%%\"*}"
          CS_F="${CS_ROW#*\"detail\":\"}"; CS_DETAIL="${CS_F%%\"*}"
          printf '  %-14s %-8s %s%s\n' "$CS_STEP" "$CS_ST" "$CS_AT" "${CS_DETAIL:+  — $CS_DETAIL}"
        done
      fi
    fi
    ;;

  # --- hold-merge: hold an entry's merge, or release it ---
  # merge_hold is the operator's input; `close_state: held` is its rendering.
  # A hold may be placed BEFORE the entry reaches `ready` — on a task group,
  # holding brief N also holds brief N+1's start (the dequeue selector reads it).
  hold-merge)
    if [ $# -lt 1 ]; then
      echo "ERROR: hold-merge requires <id>" >&2
      exit 1
    fi
    HM_ID="$1"
    shift

    HM_RELEASE=false
    while [ $# -gt 0 ]; do
      case "$1" in
        --release)
          HM_RELEASE=true
          shift
          ;;
        *)
          echo "ERROR: Unknown hold-merge option: $1" >&2
          exit 1
          ;;
      esac
    done

    HM_FILE=$(_find_entry_file "$HM_ID") || HM_FILE=""
    if [ -z "$HM_FILE" ]; then
      echo "ERROR: Entry $HM_ID not found" >&2
      exit 1
    fi
    _load_queue_entry "$HM_FILE"
    HM_WO="${_QE_WORK_ORDER_ID:-}"
    HM_WAS="${_QE_MERGE_HOLD:-false}"

    if [ "$HM_RELEASE" = true ]; then
      HM_WANT=false
      HM_ACTION="released"
    else
      HM_WANT=true
      HM_ACTION="held"
    fi

    # Refuse rather than report a no-op as a change: an operator who thinks they
    # just placed a hold on an entry that was already held behaves differently
    # from one who knows it was already there.
    if [ "$HM_WAS" = "$HM_WANT" ]; then
      if [ "$HM_WANT" = true ]; then
        echo "ERROR: Entry $HM_ID is already held. Release it with: queue-cli.sh hold-merge $HM_ID --release" >&2
      else
        echo "ERROR: Entry $HM_ID is not held — nothing to release" >&2
      fi
      exit 1
    fi

    if ! acquire_queue_lock; then
      echo "ERROR: Queue lock unavailable" >&2
      exit 1
    fi
    if ! queue_set_merge_hold "$HM_FILE" "$HM_WANT"; then
      release_queue_lock
      echo "ERROR: Could not set merge_hold on entry $HM_ID" >&2
      exit 1
    fi
    release_queue_lock

    _load_queue_entry "$HM_FILE"
    HM_STATE=$(queue_close_state)

    review_log_append "entry-merge-${HM_ACTION}" "$HM_WO" "$HM_ID" \
      "Operator $HM_ACTION the merge of entry $HM_ID — close_state is now $HM_STATE" 2>/dev/null || true

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s,%s}\n' \
        "$(_json_kv "entry_id" "$HM_ID")" \
        "$(_json_kv "action" "$HM_ACTION")" \
        "$(_json_kv_raw "merge_hold" "$HM_WANT")" \
        "$(_json_kv "close_state" "$HM_STATE")"
    elif [ "$HM_WANT" = true ]; then
      printf 'Merge held: %s (close_state: %s). Nothing merges until you run: queue-cli.sh hold-merge %s --release\n' \
        "$HM_ID" "$HM_STATE" "$HM_ID"
    else
      printf 'Merge released: %s (close_state: %s). Merge it now with: queue-cli.sh merge %s\n' \
        "$HM_ID" "$HM_STATE" "$HM_ID"
    fi
    ;;

  # --- set-close: choose how an entry's work reaches main ---
  set-close)
    if [ $# -lt 2 ]; then
      echo "ERROR: set-close requires <id> and solo|pr" >&2
      exit 1
    fi
    SC_ID="$1"
    SC_WANT="$2"
    case "$SC_WANT" in
      solo|pr) ;;
      *)
        echo "ERROR: set-close takes solo or pr (got '$SC_WANT')" >&2
        exit 1
        ;;
    esac

    SC_FILE=$(_find_entry_file "$SC_ID") || SC_FILE=""
    if [ -z "$SC_FILE" ]; then
      echo "ERROR: Entry $SC_ID not found" >&2
      exit 1
    fi
    _load_queue_entry "$SC_FILE"
    SC_WAS=$(queue_close_path)
    SC_STATE=$(queue_close_state)
    SC_WO="${_QE_WORK_ORDER_ID:-}"
    SC_ID_SAFE="${_QE_ID:-$SC_ID}"

    # Only the final brief of a task group closes the group (Decision 0015 §3),
    # so switching an earlier brief's path would set up a close that must not
    # happen. Refused with the same predicate the runner seals on.
    if ! queue_is_final_taskgroup_entry "$SC_ID_SAFE" "$SC_WO"; then
      echo "ERROR: Entry $SC_ID is not the final brief of task group $SC_WO — the group's close path is set on its last brief" >&2
      exit 1
    fi

    # A pipeline that has already finished has nothing left to route. Switching
    # the path afterwards would describe a route the work did not take.
    case "$SC_STATE" in
      merged|pushed|pr_open|merging|rebasing|reverifying)
        echo "ERROR: Entry $SC_ID is $SC_STATE — its close path is settled and cannot be switched now" >&2
        exit 1
        ;;
    esac

    if [ "$SC_WAS" = "$SC_WANT" ]; then
      echo "ERROR: Entry $SC_ID is already on the $SC_WANT close path" >&2
      exit 1
    fi

    if ! acquire_queue_lock; then
      echo "ERROR: Queue lock unavailable" >&2
      exit 1
    fi
    if ! queue_set_close_path "$SC_FILE" "$SC_WANT"; then
      release_queue_lock
      echo "ERROR: Could not set close_path on entry $SC_ID" >&2
      exit 1
    fi
    release_queue_lock

    review_log_append "entry-close-path-set" "$SC_WO" "$SC_ID" \
      "Operator switched entry $SC_ID from the $SC_WAS close path to $SC_WANT" 2>/dev/null || true

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s,%s,%s}\n' \
        "$(_json_kv "entry_id" "$SC_ID")" \
        "$(_json_kv "action" "set-close")" \
        "$(_json_kv "close_path" "$SC_WANT")" \
        "$(_json_kv "previous_close_path" "$SC_WAS")" \
        "$(_json_kv "close_state" "$SC_STATE")"
    elif [ "$SC_WANT" = "solo" ]; then
      printf 'Close path: %s is now solo (was %s). Merge it with: queue-cli.sh merge %s\n' \
        "$SC_ID" "$SC_WAS" "$SC_ID"
    else
      printf 'Close path: %s is now pr (was %s). The pull request flow takes it from here.\n' \
        "$SC_ID" "$SC_WAS"
    fi
    ;;

  # --- merge: run the close pipeline for one entry, now ---
  # This does NOT implement the merge. It hands off to `runner.sh --close-entry`,
  # which runs the one real solo close pipeline (_solo_merge_if_needed) under the
  # merge lock. A second copy here would be a second merge gate, free to
  # disagree with the runner's about when a branch is safe to merge.
  merge)
    if [ $# -lt 1 ]; then
      echo "ERROR: merge requires <id>" >&2
      exit 1
    fi
    MG_ID="$1"
    shift
    if [ $# -gt 0 ]; then
      echo "ERROR: Unknown merge option: $1" >&2
      exit 1
    fi

    MG_FILE=$(_find_entry_file "$MG_ID") || MG_FILE=""
    if [ -z "$MG_FILE" ]; then
      echo "ERROR: Entry $MG_ID not found" >&2
      exit 1
    fi
    _load_queue_entry "$MG_FILE"
    MG_WO="${_QE_WORK_ORDER_ID:-}"
    MG_BRANCH="${_QE_BRANCH:-}"

    # Fail-closed precondition (Decision t-0061): an unverifiable entry is a
    # refusal, not a pass. The runner repeats this check before acting, because
    # it is reachable directly and the queue can move in between.
    MG_REFUSAL=$(queue_close_merge_allowed "$MG_FILE") || {
      if [ "$JSON_OUTPUT" = true ]; then
        printf '{%s,%s,%s}\n' \
          "$(_json_kv "entry_id" "$MG_ID")" \
          "$(_json_kv "action" "refused")" \
          "$(_json_kv "reason" "$MG_REFUSAL")"
      else
        printf 'REFUSED: %s\n' "$MG_REFUSAL" >&2
      fi
      exit 1
    }

    review_log_append "entry-merge-requested" "$MG_WO" "$MG_ID" \
      "Operator ran the close pipeline for entry $MG_ID (branch $MG_BRANCH)" 2>/dev/null || true

    # Output goes to stderr so --json stays parseable; the runner reports its
    # progress there too.
    MG_RC=0
    "$AUTOMATION_DIR/runner.sh" --close-entry "$MG_ID" >&2 || MG_RC=$?

    # Report the RECORDED state, not the exit code. The pipeline writes where it
    # got to at every transition, so re-reading the entry is the honest answer
    # even when the runner died halfway.
    MG_FILE=$(_find_entry_file "$MG_ID") || MG_FILE=""
    MG_STATE="unknown"
    MG_STEPS="[]"
    if [ -n "$MG_FILE" ]; then
      _load_queue_entry "$MG_FILE"
      MG_STATE=$(queue_close_state)
      MG_STEPS="${_QE_CLOSE_STEPS:-[]}"
    fi

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s,%s,"close_steps":%s}\n' \
        "$(_json_kv "entry_id" "$MG_ID")" \
        "$(_json_kv "action" "merge")" \
        "$(_json_kv "close_state" "$MG_STATE")" \
        "$(_json_kv_raw "runner_exit" "$MG_RC")" \
        "$MG_STEPS"
    else
      case "$MG_STATE" in
        merged|pushed)
          printf 'Merged: %s → main (close_state: %s)\n' "$MG_BRANCH" "$MG_STATE"
          ;;
        *)
          printf 'Close pipeline stopped at close_state: %s. See: queue-cli.sh close-status %s\n' \
            "$MG_STATE" "$MG_ID"
          ;;
      esac
    fi
    [ "$MG_RC" -eq 0 ] || exit 1
    ;;

  # --- pr: the operator controls for an entry on the pull request close path ---
  # Decision t-0057 brief 2 step 4. Six subcommands, every one of them a thin
  # shell over lib/pr-manager.sh: argv parsing, the entry lookup, and rendering
  # the result live here; which gh calls to make and when to refuse live there,
  # so the daemon's poll and these commands cannot come to different conclusions
  # about the same pull request.
  #
  # Every subcommand reports the state pr-manager RECORDED rather than inferring
  # one from an exit code, for the reason `merge` above gives: the record is the
  # honest answer even when the call died halfway.
  pr)
    if [ $# -lt 1 ]; then
      echo "ERROR: pr requires a subcommand: open|refresh|status|rerun|update-branch|merge" >&2
      exit 1
    fi
    PR_SUB="$1"
    shift
    case "$PR_SUB" in
      open|refresh|status|rerun|update-branch|merge) ;;
      *)
        echo "ERROR: Unknown pr subcommand '$PR_SUB' (open|refresh|status|rerun|update-branch|merge)" >&2
        exit 1
        ;;
    esac
    if [ $# -lt 1 ]; then
      echo "ERROR: pr $PR_SUB requires <id>" >&2
      exit 1
    fi
    PR_ID="$1"
    shift

    PR_METHOD=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --method)
          if [ "$PR_SUB" != "merge" ]; then
            echo "ERROR: --method applies to 'pr merge' only" >&2
            exit 1
          fi
          if [ $# -lt 2 ]; then
            echo "ERROR: --method requires a value (merge|squash|rebase)" >&2
            exit 1
          fi
          PR_METHOD="$2"
          shift 2
          ;;
        *)
          echo "ERROR: Unknown pr $PR_SUB option: $1" >&2
          exit 1
          ;;
      esac
    done

    PR_FILE=$(_find_entry_file "$PR_ID") || PR_FILE=""
    if [ -z "$PR_FILE" ]; then
      echo "ERROR: Entry $PR_ID not found" >&2
      exit 1
    fi
    _load_queue_entry "$PR_FILE"
    PR_WO="${_QE_WORK_ORDER_ID:-}"
    PR_BRANCH="${_QE_BRANCH:-}"
    PR_PATH_WAS=$(queue_close_path)

    # Refuse on a solo entry rather than opening a pull request for work that is
    # routed to a direct merge. Named here and not inside pr-manager because it
    # is an operator-input error with an operator-input remedy, and the daemon's
    # poll reaches pr-manager without ever being able to make this mistake.
    if [ "$PR_PATH_WAS" != "pr" ]; then
      echo "ERROR: Entry $PR_ID is on the $PR_PATH_WAS close path. Switch it with: queue-cli.sh set-close $PR_ID pr" >&2
      exit 1
    fi

    # `status` is read-only and takes no gh round trip at all — it prints what
    # the last refresh recorded. Kept separate from `refresh` so an operator can
    # look without spending an API call, and so a repo with no gh still has a
    # way to read where a pull request got to.
    if [ "$PR_SUB" = "status" ]; then
      PR_NUM="${_QE_PR_NUMBER:-0}"
      PR_URL="${_QE_PR_URL:-}"
      PR_STATE=$(queue_close_state)
      PR_STEPS="${_QE_CLOSE_STEPS:-[]}"
      if [ "$JSON_OUTPUT" = true ]; then
        printf '{%s,%s,%s,%s,%s,"close_steps":%s}\n' \
          "$(_json_kv "entry_id" "$PR_ID")" \
          "$(_json_kv "action" "pr-status")" \
          "$(_json_kv_raw "pr_number" "$PR_NUM")" \
          "$(_json_kv "pr_url" "$PR_URL")" \
          "$(_json_kv "close_state" "$PR_STATE")" \
          "$PR_STEPS"
      elif [ "$PR_NUM" = "0" ]; then
        printf 'No pull request recorded for %s (close_state: %s). Open one with: queue-cli.sh pr open %s\n' \
          "$PR_ID" "$PR_STATE" "$PR_ID"
      else
        printf 'Pull request #%s  %s\n' "$PR_NUM" "$PR_URL"
        printf 'Close state:     %s\n' "$PR_STATE"
        printf 'Re-read it with: queue-cli.sh pr refresh %s\n' "$PR_ID"
      fi
      exit 0
    fi

    review_log_append "entry-pr-${PR_SUB}" "$PR_WO" "$PR_ID" \
      "Operator ran 'pr $PR_SUB' for entry $PR_ID (branch $PR_BRANCH)" 2>/dev/null || true

    PR_RC=0
    case "$PR_SUB" in
      open)          pr_open "$PR_FILE" || PR_RC=$? ;;
      refresh)       pr_refresh "$PR_FILE" || PR_RC=$? ;;
      rerun)         pr_rerun "$PR_FILE" || PR_RC=$? ;;
      update-branch) pr_update_branch "$PR_FILE" || PR_RC=$? ;;
      merge)         pr_merge "$PR_FILE" "$PR_METHOD" || PR_RC=$? ;;
    esac

    # A conflict found by any of these is the same event the runner routes on
    # the solo path: the entry goes to review. pr-manager wrote the escalation
    # and recorded close_state: conflict; the status transition is the CLI's to
    # make, and queue_escalate is a no-op on an entry that is not in running/.
    PR_ESCALATED=false
    if [ "${_PR_OUTCOME:-}" = "review:merge-conflict" ]; then
      if queue_escalate "$PR_ID" "review:merge-conflict" 2>/dev/null; then
        PR_ESCALATED=true
      fi
    fi

    # Re-read: pr-manager may have moved the entry's close state several times,
    # and _find_entry_file is repeated because an escalation moves the file.
    PR_FILE=$(_find_entry_file "$PR_ID") || PR_FILE=""
    PR_STATE="unknown"
    PR_STEPS="[]"
    PR_NUM="0"
    PR_URL=""
    if [ -n "$PR_FILE" ]; then
      _load_queue_entry "$PR_FILE"
      PR_STATE=$(queue_close_state)
      PR_STEPS="${_QE_CLOSE_STEPS:-[]}"
      PR_NUM="${_QE_PR_NUMBER:-0}"
      PR_URL="${_QE_PR_URL:-}"
    fi

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s,%s,%s,%s,%s,%s,"close_steps":%s}\n' \
        "$(_json_kv "entry_id" "$PR_ID")" \
        "$(_json_kv "action" "pr-$PR_SUB")" \
        "$(_json_kv_raw "pr_number" "$PR_NUM")" \
        "$(_json_kv "pr_url" "$PR_URL")" \
        "$(_json_kv "close_state" "$PR_STATE")" \
        "$(_json_kv "reason" "${_PR_REASON:-}")" \
        "$(_json_kv "outcome" "${_PR_OUTCOME:-}")" \
        "$(_json_kv_raw "escalated" "$PR_ESCALATED")" \
        "$PR_STEPS"
    else
      if [ "$PR_RC" -ne 0 ] && [ -n "${_PR_REASON:-}" ]; then
        printf 'REFUSED: %s\n' "$_PR_REASON" >&2
      elif [ -n "${_PR_REASON:-}" ]; then
        printf 'NOTE: %s\n' "$_PR_REASON" >&2
      fi
      case "$PR_STATE" in
        merged)
          printf 'Pull request #%s merged. Local main synced and the branch sealed.\n' "$PR_NUM"
          ;;
        conflict)
          printf 'Conflict on pull request #%s. Escalation written; resolve it on the branch, then: queue-cli.sh pr update-branch %s\n' \
            "$PR_NUM" "$PR_ID"
          ;;
        pr_open)
          printf 'Pull request #%s  %s  (close_state: %s)\n' "$PR_NUM" "$PR_URL" "$PR_STATE"
          ;;
        *)
          printf 'Close pipeline is at close_state: %s. See: queue-cli.sh close-status %s\n' \
            "$PR_STATE" "$PR_ID"
          ;;
      esac
    fi
    [ "$PR_RC" -eq 0 ] || exit 1
    ;;

  # --- resolve-conflict: the one exit from close_state `conflict` ---
  # t-0057 brief 3. Both close paths arrive here: the solo path records
  # `conflict` from the runner's rebase, the pull request path from
  # pr-manager's mergeable check, and neither of them can decide what the
  # resolution should BE. This command picks, then re-arms the entry so the
  # pipeline runs again from its own beginning. It never merges anything.
  #
  # Four modes, one shape: choose, re-arm, report. The difference is only in
  # what "choose" writes.
  #   --agent  queues a fix brief as a follow-up of the entry, on the same
  #            branch. The fix is a session with a brief, a contract and the
  #            gates — not a free hand on the branch — which is the whole
  #            reason this is not "the agent resolves it inline".
  #   --ours   keep the branch's side; --theirs keep main's side. Stored, not
  #            applied: see below.
  #   --manual the operator resolves it in their editor and re-runs the close
  #            with `merge` or `pr merge`.
  #
  # --ours/--theirs are STORED on the entry rather than applied here, and that
  # is the load-bearing choice of this command. Resolving locally means merging
  # main into the branch, which empties overlap_report.main_changed — the one
  # trigger for the t-0056 close-time re-verification. The next close would then
  # skip re-verification and report success, making "all checks re-run before
  # the close" false precisely when a conflict proves main has moved. Carrying
  # the strategy to the single `git rebase` in reverify-merge.sh instead keeps
  # rebase → re-verify → merge inside one pipeline.
  resolve-conflict)
    if [ $# -lt 1 ]; then
      echo "ERROR: resolve-conflict requires <id>" >&2
      exit 1
    fi
    RC_ID="$1"
    shift

    RC_MODE="" RC_NOTE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --agent|--ours|--theirs|--manual)
          _RC_M="${1#--}"
          if [ -n "$RC_MODE" ] && [ "$RC_MODE" != "$_RC_M" ]; then
            echo "ERROR: resolve-conflict takes ONE of --agent, --ours, --theirs, --manual (got --$RC_MODE and --$_RC_M)" >&2
            exit 1
          fi
          RC_MODE="$_RC_M"
          shift
          ;;
        --note)
          if [ $# -lt 2 ]; then echo "ERROR: --note requires a value" >&2; exit 1; fi
          RC_NOTE="$2"
          shift 2
          ;;
        *)
          echo "ERROR: Unknown resolve-conflict option: $1" >&2
          exit 1
          ;;
      esac
    done

    # No default mode. Guessing one would pick a resolution strategy on the
    # operator's behalf, which is the single thing this command exists not to do.
    if [ -z "$RC_MODE" ]; then
      echo "ERROR: resolve-conflict requires one of --agent, --ours, --theirs, --manual" >&2
      echo "  --agent   queue a fix brief as a follow-up, on the same branch" >&2
      echo "  --ours    keep the branch's side on the next rebase" >&2
      echo "  --theirs  keep main's side on the next rebase" >&2
      echo "  --manual  resolve it yourself, then re-run the close" >&2
      exit 1
    fi

    RC_FILE=$(_find_entry_file "$RC_ID") || RC_FILE=""
    if [ -z "$RC_FILE" ]; then
      echo "ERROR: Entry $RC_ID not found" >&2
      exit 1
    fi
    _load_queue_entry "$RC_FILE"
    RC_WO="${_QE_WORK_ORDER_ID:-}"
    RC_BRANCH="${_QE_BRANCH:-}"
    RC_PATH=$(queue_close_path)

    # Fail-closed precondition (t-0061). Not _queue_close_preconditions — see
    # the comment on queue_conflict_resolve_allowed for why that gate refuses
    # the exact state this command exists to recover from.
    RC_REFUSAL=$(queue_conflict_resolve_allowed "$RC_FILE") || {
      if [ "$JSON_OUTPUT" = true ]; then
        printf '{%s,%s,%s,%s}\n' \
          "$(_json_kv "entry_id" "$RC_ID")" \
          "$(_json_kv "action" "refused")" \
          "$(_json_kv "mode" "$RC_MODE")" \
          "$(_json_kv "reason" "$RC_REFUSAL")"
      else
        printf 'REFUSED: %s\n' "$RC_REFUSAL" >&2
      fi
      exit 1
    }

    # --ours/--theirs reach git through reverify-merge.sh's rebase, which only
    # the solo path runs — on the pull request path the branch is updated by
    # `pr update-branch` through gh, where there is no local rebase to hand a
    # strategy to. Accepting the flag there would store a value nothing reads
    # and report a resolution that never happens.
    case "$RC_MODE" in
      ours|theirs)
        if [ "$RC_PATH" = "pr" ]; then
          RC_REFUSAL="--$RC_MODE is a local rebase strategy and entry $RC_ID is on the pr close path; use --agent or --manual, or switch paths with: queue-cli.sh set-close $RC_ID solo"
          if [ "$JSON_OUTPUT" = true ]; then
            printf '{%s,%s,%s,%s}\n' \
              "$(_json_kv "entry_id" "$RC_ID")" \
              "$(_json_kv "action" "refused")" \
              "$(_json_kv "mode" "$RC_MODE")" \
              "$(_json_kv "reason" "$RC_REFUSAL")"
          else
            printf 'REFUSED: %s\n' "$RC_REFUSAL" >&2
          fi
          exit 1
        fi
        ;;
    esac

    # The conflicting files come from the escalation the merge path wrote, not
    # from re-running the merge to find out. Newest unresolved esc-merge-* for
    # this entry wins: the glob sorts lexicographically and the ids carry a
    # timestamp. esc-merge-lock-* is excluded because it is a different event
    # (the merge lock, runner.sh) that shares the prefix and sorts after the
    # dated ones. The pull request path writes no file list, so this is often
    # empty — the fix brief says so rather than inventing one.
    RC_ESC="" RC_FILES=""
    for _RC_E in "$REPO_ROOT/.claude/.automation/escalations"/esc-merge-*.yaml; do
      [ -f "$_RC_E" ] || continue
      case "${_RC_E##*/}" in esc-merge-lock-*) continue ;; esac
      grep -Fq "queue_entry_id: \"$RC_ID\"" "$_RC_E" 2>/dev/null || continue
      grep -Fqx '  resolved: false' "$_RC_E" 2>/dev/null || continue
      RC_ESC="$_RC_E"
    done
    if [ -n "$RC_ESC" ]; then
      _RC_CTX=$(grep -F '  context:' "$RC_ESC" 2>/dev/null | head -1) || _RC_CTX=""
      _RC_CTX="${_RC_CTX#*context:}"; _RC_CTX="${_RC_CTX# }"
      _RC_CTX="${_RC_CTX#\"}"; _RC_CTX="${_RC_CTX%\"}"
      case "$_RC_CTX" in
        conflict_files:*) RC_FILES="${_RC_CTX#conflict_files: }" ;;
      esac
    fi

    # Both sides, named as the two refs the fix session will diff. Short SHAs
    # are recorded because the brief outlives the tips: by the time the fix runs
    # main may have moved again, and "the main I conflicted with" has to stay
    # nameable.
    RC_MAIN_SHA=$(git -C "$REPO_ROOT" rev-parse --short main 2>/dev/null) || RC_MAIN_SHA=""
    RC_BRANCH_SHA=""
    if [ -n "$RC_BRANCH" ]; then
      RC_BRANCH_SHA=$(git -C "$REPO_ROOT" rev-parse --short "$RC_BRANCH" 2>/dev/null) || RC_BRANCH_SHA=""
    fi

    RC_FOLLOW_UP=""
    if [ "$RC_MODE" = "agent" ]; then
      # Written into briefs/ under a dot-prefixed name so follow-up-entry can
      # resolve it (it refuses a brief outside the repo) while staying out of
      # the briefs/*.md glob that lists real briefs. follow-up-entry copies it
      # to followup-<id>-<n>.md, so this file is scaffolding and is removed.
      RC_DRAFT="$REPO_ROOT/.claude/.automation/briefs/.conflict-fix-${RC_ID}.md"
      if ! mkdir -p "$REPO_ROOT/.claude/.automation/briefs"; then
        echo "ERROR: Could not create the briefs directory" >&2
        exit 1
      fi
      {
        printf '# Follow-up: resolve the close conflict on %s\n\n' "${RC_BRANCH:-the branch}"
        printf 'Generated by `queue-cli.sh resolve-conflict %s --agent`. The close\n' "$RC_ID"
        printf 'pipeline for entry `%s` stopped at `close_state: conflict`; this\n' "$RC_ID"
        printf 'session is how it gets past it.\n\n'

        printf '## Parent task\n\n'
        printf -- '- Entry: `%s`\n' "$RC_ID"
        printf -- '- Branch: `%s`\n' "${RC_BRANCH:-unresolved}"
        printf -- '- Close path: `%s`\n' "$RC_PATH"
        [ -z "$RC_WO" ] || printf -- '- Work order: `%s`\n' "$RC_WO"
        [ -z "$RC_ESC" ] || printf -- '- Escalation: `%s`\n' "${RC_ESC##*/}"
        printf '\n'

        printf '## Goal\n\n'
        printf 'Resolve the merge conflict between `%s` and `main` on the branch, so\n' "${RC_BRANCH:-the branch}"
        printf 'that a rebase onto main applies cleanly and the close pipeline can\n'
        printf 'complete. Resolve the conflict only — this is not an opportunity to\n'
        printf 'change behaviour.\n\n'

        printf '## The two sides\n\n'
        printf -- '- Branch `%s` at `%s` — the work this group produced.\n' \
          "${RC_BRANCH:-unresolved}" "${RC_BRANCH_SHA:-unknown}"
        printf -- '- `main` at `%s` — what landed while the group was running.\n' \
          "${RC_MAIN_SHA:-unknown}"
        printf '\n'
        printf 'Read either side without checking anything out:\n\n'
        printf '```bash\n'
        printf 'git show %s:<file>   # main'"'"'s version\n' "${RC_MAIN_SHA:-main}"
        printf 'git show %s:<file>   # the branch'"'"'s version\n' "${RC_BRANCH_SHA:-HEAD}"
        printf 'git diff %s...%s -- <file>\n' "${RC_MAIN_SHA:-main}" "${RC_BRANCH_SHA:-HEAD}"
        printf '```\n\n'

        printf '## Conflicting files\n\n'
        if [ -n "$RC_FILES" ]; then
          _RC_OLD_IFS="$IFS"
          IFS=','
          # shellcheck disable=SC2086 — intentional split on the comma-delimited list
          set -- $RC_FILES
          IFS="$_RC_OLD_IFS"
          for _RC_F in "$@"; do
            _RC_F="${_RC_F# }"; _RC_F="${_RC_F% }"
            [ -z "$_RC_F" ] || printf -- '- [ ] `%s`\n' "$_RC_F"
          done
          printf '\n'
        else
          printf '_The merge path recorded no file list for this conflict (the pull\n'
          printf 'request path does not produce one). Find them first:_\n\n'
          printf '```bash\n'
          printf 'git merge-tree --write-tree %s %s\n' "${RC_MAIN_SHA:-main}" "${RC_BRANCH_SHA:-HEAD}"
          printf '```\n\n'
        fi

        if [ -n "$RC_NOTE" ]; then
          printf '## Operator note\n\n'
          printf '%s\n\n' "$RC_NOTE"
        fi

        printf '## Verify first\n\n'
        printf -- '- [ ] Every file above resolves to one version that keeps BOTH\n'
        printf '      intents — the branch'"'"'s change and main'"'"'s change — or the\n'
        printf '      session says plainly which one it dropped and why.\n'
        printf -- '- [ ] `git rebase main` on the branch applies with no conflict.\n'
        printf -- '- [ ] The checks that cover the resolved files pass on the result.\n\n'

        printf '## What happens when this completes\n\n'
        printf 'This entry is a follow-up of `%s`, so it runs on the same branch and\n' "$RC_ID"
        printf 'shares its work order. Its own close runs the whole close pipeline\n'
        printf 'again — rebase, close-time re-verification (t-0056), merge — which is\n'
        printf 'why the conflict does not need to be resolved against main by hand\n'
        printf 'here. Leave the merge to the pipeline.\n\n'

        printf '### Task Contract\n\n'
        printf '```yaml\n'
        printf 'goal: "Resolve the close conflict between %s and main."\n' "${RC_BRANCH:-the branch}"
        printf 'artifact: ""\n'
        printf 'constraints: ["Resolve the conflict only — no behaviour change", "Leave the merge to the close pipeline"]\n'
        printf 'lifecycle: task-scoped\n'
        printf 'scope_files: []\n'
        printf '```\n'
      } > "$RC_DRAFT" || {
        echo "ERROR: Could not write the conflict fix brief: $RC_DRAFT" >&2
        exit 1
      }

      # Delegated to `follow-up-entry` rather than reimplemented. That command
      # owns the linkage t-0055 clause 14 defines — the copy to
      # followup-<parent>-<n>.md, follow_up_of, the empty branch the dequeue
      # selector resolves, the inherited work order — and a second enqueue path
      # would be free to drift from it. Called without --json so the output
      # shape it is parsed from does not depend on OUR --json.
      RC_FU_RC=0
      RC_FU_OUT=$("$AUTOMATION_DIR/queue-cli.sh" follow-up-entry "$RC_ID" \
        --brief "$RC_DRAFT" --auto-approve 2>&1) || RC_FU_RC=$?
      rm -f "$RC_DRAFT" 2>/dev/null || true
      if [ "$RC_FU_RC" -ne 0 ]; then
        printf '%s\n' "$RC_FU_OUT" >&2
        echo "ERROR: Could not queue the fix brief for $RC_ID — nothing was re-armed" >&2
        exit 1
      fi
      RC_FOLLOW_UP=$(printf '%s\n' "$RC_FU_OUT" | grep '^entry_id:' | head -1) || RC_FOLLOW_UP=""
      RC_FOLLOW_UP="${RC_FOLLOW_UP#entry_id:}"
      RC_FOLLOW_UP="${RC_FOLLOW_UP## }"
    fi

    # Stored for the rebase in reverify-merge.sh, which reads it once and
    # clears it. --agent and --manual store nothing: the resolution arrives as
    # commits on the branch, and a leftover strategy would silently steer a
    # later rebase.
    case "$RC_MODE" in
      ours|theirs)
        if ! queue_set_conflict_resolution "$RC_FILE" "$RC_MODE"; then
          echo "ERROR: Could not record the conflict resolution on $RC_ID" >&2
          exit 1
        fi
        ;;
    esac

    # Re-armed LAST, and only last. Everything above can refuse; once the entry
    # is back at close_state `ready` the conflict is no longer visible as one,
    # so a failure after this point would leave an entry that looks mergeable
    # with nothing arranged to make it so.
    RC_NEW_FILE=$(queue_close_rearm "$RC_FILE" "$RC_MODE" "$RC_NOTE") || {
      echo "ERROR: Could not re-arm entry $RC_ID for the close" >&2
      exit 1
    }

    review_log_append "entry-conflict-resolved" "$RC_WO" "$RC_ID" \
      "Operator chose --$RC_MODE for the $RC_PATH close conflict on branch ${RC_BRANCH:-unresolved}${RC_FOLLOW_UP:+ — fix brief $RC_FOLLOW_UP}${RC_FILES:+ (files: $RC_FILES)}${RC_NOTE:+ — note: $RC_NOTE}" 2>/dev/null || true

    RC_STATE="unknown"
    RC_STEPS="[]"
    if [ -n "$RC_NEW_FILE" ] && [ -f "$RC_NEW_FILE" ]; then
      _load_queue_entry "$RC_NEW_FILE"
      RC_STATE=$(queue_close_state)
      RC_STEPS="${_QE_CLOSE_STEPS:-[]}"
    fi

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s,%s,%s,%s,%s,%s,"close_steps":%s}\n' \
        "$(_json_kv "entry_id" "$RC_ID")" \
        "$(_json_kv "action" "resolve-conflict")" \
        "$(_json_kv "mode" "$RC_MODE")" \
        "$(_json_kv "close_path" "$RC_PATH")" \
        "$(_json_kv "close_state" "$RC_STATE")" \
        "$(_json_kv "follow_up_entry_id" "$RC_FOLLOW_UP")" \
        "$(_json_kv "conflict_files" "$RC_FILES")" \
        "$(_json_kv "escalation" "${RC_ESC##*/}")" \
        "$RC_STEPS"
    else
      printf 'entry_id:        %s\n' "$RC_ID"
      printf 'mode:            --%s\n' "$RC_MODE"
      printf 'close_path:      %s\n' "$RC_PATH"
      printf 'close_state:     %s (re-armed)\n' "$RC_STATE"
      [ -z "$RC_FILES" ] || printf 'conflict_files:  %s\n' "$RC_FILES"
      case "$RC_MODE" in
        agent)
          printf 'fix brief:       %s (follow-up of %s, same branch, auto-approved)\n' \
            "${RC_FOLLOW_UP:-unknown}" "$RC_ID"
          printf 'next:            the daemon runs it once %s is out of the way; its close re-runs the pipeline\n' "$RC_ID"
          ;;
        ours|theirs)
          printf 'strategy:        --%s, applied at the next rebase and then cleared\n' "$RC_MODE"
          printf 'next:            queue-cli.sh %s %s\n' \
            "$([ "$RC_PATH" = "pr" ] && printf 'pr merge' || printf 'merge')" "$RC_ID"
          ;;
        manual)
          printf 'next:            resolve it on %s, commit, then: queue-cli.sh %s %s\n' \
            "${RC_BRANCH:-the branch}" \
            "$([ "$RC_PATH" = "pr" ] && printf 'pr merge' || printf 'merge')" "$RC_ID"
          ;;
      esac
    fi
    ;;

  # --- discard-entry: abandon one entry and resolve what it was holding ---
  # t-0055 clause 9. Deliberately NOT a stop: a running entry is refused rather
  # than killed from here, so "abandon this work" and "end this session" stay
  # separate operator decisions and the kill path keeps one implementation.
  discard-entry)
    if [ $# -lt 1 ]; then
      echo "ERROR: discard-entry requires <id>" >&2
      exit 1
    fi
    DISCARD_ID="$1"
    shift

    DISCARD_REASON="discarded-by-operator"
    while [ $# -gt 0 ]; do
      case "$1" in
        --reason)
          if [ $# -lt 2 ]; then
            echo "ERROR: --reason requires a value" >&2
            exit 1
          fi
          DISCARD_REASON="$2"
          shift 2
          ;;
        *)
          echo "ERROR: Unknown discard-entry option: $1" >&2
          exit 1
          ;;
      esac
    done

    DISCARD_ENTRY_FILE=$(_find_entry_file "$DISCARD_ID")
    if [ -z "$DISCARD_ENTRY_FILE" ]; then
      echo "ERROR: Entry $DISCARD_ID not found" >&2
      exit 1
    fi
    _load_queue_entry "$DISCARD_ENTRY_FILE"
    if [ "$_QE_STATUS" = "running" ]; then
      echo "ERROR: Entry $DISCARD_ID is still running. Stop it first:" >&2
      echo "  queue-cli.sh stop-entry $DISCARD_ID --force && queue-cli.sh discard-entry $DISCARD_ID" >&2
      exit 1
    fi
    DISCARD_WO_ID="${_QE_WORK_ORDER_ID:-}"
    DISCARD_SESSION_TYPE="${_QE_SESSION_TYPE:-}"
    DISCARD_BRANCH="${_QE_BRANCH:-}"

    # The DISCARD flag is the durable record in the control directory, beside
    # the STOP/FORCE flags and resume.yaml this entry may already have.
    DISCARD_CONTROL_DIR=$(ensure_control_dir "$DISCARD_ID") || DISCARD_CONTROL_DIR=""
    if [ -n "$DISCARD_CONTROL_DIR" ]; then
      printf '%s\n' "$DISCARD_REASON" > "$DISCARD_CONTROL_DIR/DISCARD"
    else
      echo "WARNING: Could not create the control directory for entry $DISCARD_ID — the discard proceeds without a flag" >&2
    fi

    if ! acquire_queue_lock; then
      echo "ERROR: Queue lock unavailable" >&2
      exit 1
    fi
    # Capture what this entry is holding BEFORE the hold is released, so the
    # escalations name the entries that were actually waiting on it. Read under
    # the lock: a concurrent dequeue tick re-evaluates held_by, so a read taken
    # before the lock could escalate a list the release then disagrees with.
    DISCARD_HELD=$(queue_hold_holding "$DISCARD_ID") || DISCARD_HELD=""
    # A follow-up of a discarded parent needs the same escalation, and the
    # hold list alone does not reach it: `held_by` is only ever set while the
    # parent is STOPPED, so a follow-up of a completed or failed parent is
    # unheld — and it is exactly the follow-up of a completed parent that the
    # operator is most likely to have queued. Union, deduped against the hold
    # list, so an entry that is both is escalated once.
    DISCARD_FU=$(queue_followups_of "$DISCARD_ID") || DISCARD_FU=""
    while IFS="$_QH_TAB" read -r _DISC_FU_ID _DISC_FU_STATUS; do
      [ -n "$_DISC_FU_ID" ] || continue
      # A follow-up that already ran is not waiting on anything.
      case "$_DISC_FU_STATUS" in completed|failed) continue ;; esac
      case "
$DISCARD_HELD
" in *"
$_DISC_FU_ID
"*) continue ;; esac
      DISCARD_HELD="${DISCARD_HELD:+$DISCARD_HELD
}$_DISC_FU_ID"
    done <<EOF
$DISCARD_FU
EOF
    if ! queue_discard "$DISCARD_ID" "$DISCARD_REASON"; then
      release_queue_lock
      echo "ERROR: Could not discard entry $DISCARD_ID" >&2
      exit 1
    fi
    DISCARD_FREED=$(queue_release_holds "$DISCARD_ID") || DISCARD_FREED=""
    release_queue_lock

    # Worktree (Decision t-0054): a single task owns its worktree, so discarding
    # it ends the worktree too. A group's worktree is shared by every brief in
    # the group and outlives any one of them — it is left in place and the work
    # order is escalated instead, which is the signal an operator acts on.
    DISCARD_WT=$(_hold_entry_worktree "$DISCARD_ID") || DISCARD_WT=""
    DISCARD_WT_ACTION="none"
    case "$DISCARD_SESSION_TYPE" in
      taskgroup|taskgroup-merge)
        DISCARD_WT_ACTION="kept-group-worktree"
        ;;
      *)
        if [ -n "$DISCARD_WT" ] && [ -d "$DISCARD_WT" ]; then
          # remove_session_worktree preserves uncommitted work as a patch first
          # and uses bare `git worktree ...`, so it runs from the main repo.
          ( cd "$REPO_ROOT" && remove_session_worktree "$DISCARD_WT" "" "$DISCARD_ID" "discarded-by-operator" ) || true
          DISCARD_WT_ACTION="removed"
        fi
        ;;
    esac

    # Escalate the parent work order for a group discard. Inlined rather than
    # given a public wrapper in work-order-manager.sh: this is the only caller.
    DISCARD_WO_ACTION="none"
    if [ "$DISCARD_WT_ACTION" = "kept-group-worktree" ] && [ -n "$DISCARD_WO_ID" ]; then
      _DISCARD_WO_FILE="$(_wo_dir)/${DISCARD_WO_ID}.yaml"
      if [ -f "$_DISCARD_WO_FILE" ] && _load_work_order "$_DISCARD_WO_FILE"; then
        if [ "$_WO_STATUS" = "escalated" ]; then
          DISCARD_WO_ACTION="already-escalated"
        elif _transition_work_order "escalated"; then
          _WO_FAILURE_ENTRY_ID="$DISCARD_ID"
          _write_work_order "$_DISCARD_WO_FILE"
          DISCARD_WO_ACTION="escalated"
        else
          echo "WARNING: Could not escalate work order $DISCARD_WO_ID (status: $_WO_STATUS)" >&2
        fi
      fi
    fi

    # Every entry that was waiting on this one is now waiting on nothing: the
    # outcome it would have been rebased onto never happened. That is an
    # operator decision, not an automatic one, so each gets an escalation.
    # "Waiting on" is both senses — held behind it (clause 10) and following
    # up on it (clause 14) — unioned above.
    DISCARD_ESC_DIR="$REPO_ROOT/.claude/.automation/escalations"
    DISCARD_ESC_COUNT=0
    if [ -n "$DISCARD_HELD" ]; then
      mkdir -p "$DISCARD_ESC_DIR" 2>/dev/null || true
      while IFS= read -r _DISC_HELD_ID; do
        [ -n "$_DISC_HELD_ID" ] || continue
        _DISC_ESC_ID="esc-parent-discarded-${_DISC_HELD_ID}-$(date +%Y%m%d-%H%M%S)"
        {
          printf 'escalation:\n'
          printf '  id: "%s"\n' "$_DISC_ESC_ID"
          printf '  queue_entry_id: "%s"\n' "$_DISC_HELD_ID"
          printf '  type: "parent-discarded"\n'
          printf '  severity: "blocking"\n'
          printf '  phase_at_exit: "queued"\n'
          printf '  tag_at_exit: "operator"\n'
          printf '  message: "Entry %s was waiting on %s, which the operator discarded"\n' \
            "$_DISC_HELD_ID" "$DISCARD_ID"
          printf '  context: "discarded_entry: %s | discarded_branch: %s | reason: %s | the hold was released, but the work this entry was waiting on never landed — re-check its scope before approving it"\n' \
            "$DISCARD_ID" "${DISCARD_BRANCH:-unknown}" "$DISCARD_REASON"
          printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          printf '  resolved: false\n'
          printf '  resolution: ""\n'
        } > "$DISCARD_ESC_DIR/${_DISC_ESC_ID}.yaml" 2>/dev/null || true
        DISCARD_ESC_COUNT=$(( DISCARD_ESC_COUNT + 1 ))
      done <<EOF
$DISCARD_HELD
EOF
    fi

    DISCARD_FREED_COUNT=0
    if [ -n "$DISCARD_FREED" ]; then
      DISCARD_FREED_COUNT=$(printf '%s\n' "$DISCARD_FREED" | grep -c .)
    fi

    review_log_append "entry-discarded" "$DISCARD_WO_ID" "$DISCARD_ID" \
      "Entry $DISCARD_ID discarded by operator ($DISCARD_REASON) — failed/, worktree: $DISCARD_WT_ACTION, work order: $DISCARD_WO_ACTION, released $DISCARD_FREED_COUNT held entries with $DISCARD_ESC_COUNT parent-discarded escalations" 2>/dev/null || true

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s,%s,%s,%s,%s}\n' \
        "$(_json_kv "entry_id" "$DISCARD_ID")" \
        "$(_json_kv "action" "discarded")" \
        "$(_json_kv "status" "failed")" \
        "$(_json_kv "error_log" "$DISCARD_REASON")" \
        "$(_json_kv "worktree" "$DISCARD_WT_ACTION")" \
        "$(_json_kv "work_order" "$DISCARD_WO_ACTION")" \
        "$(_json_kv_raw "escalated_held" "$DISCARD_ESC_COUNT")"
    else
      printf 'Discarded: %s → failed/ (%s)\n' "$DISCARD_ID" "$DISCARD_REASON"
      printf '  worktree:   %s%s\n' "$DISCARD_WT_ACTION" "${DISCARD_WT:+ ($DISCARD_WT)}"
      printf '  work order: %s%s\n' "$DISCARD_WO_ACTION" "${DISCARD_WO_ID:+ ($DISCARD_WO_ID)}"
      printf '  held:       released %s, escalated %s as parent-discarded\n' \
        "$DISCARD_FREED_COUNT" "$DISCARD_ESC_COUNT"
    fi
    ;;

  # --- note-entry: send the operator's note to one entry's agent ---
  # `note` is the short alias; `note-entry` is the canonical name, because
  # t-0055 clause 12 requires every per-entry command to end in -entry.
  note-entry|note)
    if [ $# -lt 1 ]; then
      echo "ERROR: note-entry requires <id>" >&2
      exit 1
    fi
    NOTE_ID="$1"
    shift

    NOTE_TEXT=""
    NOTE_SOURCE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --text)
          if [ $# -lt 2 ]; then
            echo "ERROR: --text requires a value" >&2
            exit 1
          fi
          NOTE_TEXT="$2"
          NOTE_SOURCE="text"
          shift 2
          ;;
        --file)
          if [ $# -lt 2 ]; then
            echo "ERROR: --file requires a path" >&2
            exit 1
          fi
          if [ ! -f "$2" ]; then
            echo "ERROR: Note file not found: $2" >&2
            exit 1
          fi
          NOTE_TEXT="$(cat "$2")"
          NOTE_SOURCE="file"
          shift 2
          ;;
        *)
          echo "ERROR: Unknown note-entry option: $1" >&2
          exit 1
          ;;
      esac
    done

    if [ -z "$NOTE_SOURCE" ]; then
      echo "ERROR: note-entry requires --text \"<note>\" or --file <path>" >&2
      exit 1
    fi
    if [ -z "$NOTE_TEXT" ]; then
      echo "ERROR: The note is empty. A note the agent cannot read is not worth queueing." >&2
      exit 1
    fi
    # 2,000 characters, plain text. A note competes with the brief for the
    # agent's attention and is injected into a tool result — anything longer
    # belongs in the brief, not in a note.
    if [ "${#NOTE_TEXT}" -gt 2000 ]; then
      echo "ERROR: Note is ${#NOTE_TEXT} characters; the limit is 2000. Shorten it, or put the detail in the brief." >&2
      exit 1
    fi

    NOTE_TARGET_VIA="entry"
    NOTE_ENTRY_FILE=$(_find_entry_file "$NOTE_ID")
    if [ -z "$NOTE_ENTRY_FILE" ]; then
      # A work order id is accepted too. With no brief of a group running, the
      # operator's note is for whichever brief runs next, and they should not
      # have to look up an id for work the group has not reached yet. Entry ids
      # are stored in declaration order, which for a sequential group is brief
      # order, so the first non-terminal one IS the next brief.
      NOTE_WO_FILE="$(_wo_dir)/${NOTE_ID}.yaml"
      if [ -f "$NOTE_WO_FILE" ] && _load_work_order "$NOTE_WO_FILE"; then
        NOTE_WO_ID="$NOTE_ID"
        NOTE_REST="$_WO_ENTRY_IDS"
        while [ -n "$NOTE_REST" ]; do
          NOTE_CAND="${NOTE_REST%%,*}"
          case "$NOTE_REST" in
            *,*) NOTE_REST="${NOTE_REST#*,}" ;;
            *)   NOTE_REST="" ;;
          esac
          [ -n "$NOTE_CAND" ] || continue
          NOTE_CAND_FILE=$(_find_entry_file "$NOTE_CAND") || NOTE_CAND_FILE=""
          [ -n "$NOTE_CAND_FILE" ] || continue
          _load_queue_entry "$NOTE_CAND_FILE"
          case "$_QE_STATUS" in
            completed|failed) continue ;;
          esac
          NOTE_ENTRY_FILE="$NOTE_CAND_FILE"
          NOTE_ID="$NOTE_CAND"
          NOTE_TARGET_VIA="work-order"
          break
        done
        if [ -z "$NOTE_ENTRY_FILE" ]; then
          echo "ERROR: Work order $NOTE_WO_ID has no entry left to notify — every entry is completed or failed" >&2
          exit 1
        fi
        echo "Work order $NOTE_WO_ID → next entry $NOTE_ID ($_QE_STATUS)" >&2
      fi
    fi
    if [ -z "$NOTE_ENTRY_FILE" ]; then
      echo "ERROR: Entry $NOTE_ID not found" >&2
      exit 1
    fi
    if [ "$NOTE_TARGET_VIA" = "entry" ]; then
      _load_queue_entry "$NOTE_ENTRY_FILE"
    fi
    # A closed entry has no agent left to read the note and will never run
    # again, so queueing one would be a note that is pending forever.
    case "$_QE_STATUS" in
      completed|failed)
        echo "ERROR: Entry $NOTE_ID is $_QE_STATUS — it is closed and has no session to notify. Reopen it first: queue-cli.sh reopen-entry $NOTE_ID" >&2
        exit 1
        ;;
    esac

    NOTE_CONTROL_DIR=$(ensure_control_dir "$NOTE_ID") || NOTE_CONTROL_DIR=""
    if [ -z "$NOTE_CONTROL_DIR" ]; then
      echo "ERROR: Could not create the control directory for entry $NOTE_ID" >&2
      exit 1
    fi
    if ! mkdir -p "$NOTE_CONTROL_DIR/notes"; then
      echo "ERROR: Could not create the notes directory for entry $NOTE_ID" >&2
      exit 1
    fi

    # <epoch>-<n>.md (t-0055 clause 4). The epoch orders delivery; <n>
    # disambiguates two notes sent in the same second.
    NOTE_EPOCH=$(date -u +%s)
    NOTE_SEQ=1
    while [ -e "$NOTE_CONTROL_DIR/notes/${NOTE_EPOCH}-${NOTE_SEQ}.md" ] \
       || [ -e "$NOTE_CONTROL_DIR/notes/delivered/${NOTE_EPOCH}-${NOTE_SEQ}.md" ]; do
      NOTE_SEQ=$(( NOTE_SEQ + 1 ))
    done
    NOTE_FILE="$NOTE_CONTROL_DIR/notes/${NOTE_EPOCH}-${NOTE_SEQ}.md"
    printf '%s\n' "$NOTE_TEXT" > "$NOTE_FILE"

    NOTE_SENT_AT=$(epoch_to_iso "$NOTE_EPOCH")

    # How this note will reach the agent, stated at send time so the operator
    # is not left guessing. Running entries depend on operator-notes.sh being
    # registered in settings.json; the other two routes are runner-side.
    case "$_QE_STATUS" in
      running)  NOTE_ROUTE="at the session's next tool step" ;;
      stopped)  NOTE_ROUTE="in the resume message (queue-cli.sh resume-entry $NOTE_ID)" ;;
      *)        NOTE_ROUTE="in the entry's prompt when it starts" ;;
    esac

    # When a work order id was resolved to an entry, the mapping goes in the log
    # too — otherwise the only record of which brief the operator actually
    # addressed is the stderr line, which nothing keeps.
    NOTE_LOG_VIA=""
    if [ "$NOTE_TARGET_VIA" = "work-order" ]; then
      NOTE_LOG_VIA=" (resolved from work order $NOTE_WO_ID)"
    fi
    review_log_append "entry-note-sent" "${_QE_WORK_ORDER_ID:-}" "$NOTE_ID" \
      "Operator sent a note to entry ${NOTE_ID}${NOTE_LOG_VIA} (${#NOTE_TEXT} chars, status $_QE_STATUS) — delivery $NOTE_ROUTE" 2>/dev/null || true

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s,%s,%s,%s,%s}\n' \
        "$(_json_kv "entry_id" "$NOTE_ID")" \
        "$(_json_kv "action" "note")" \
        "$(_json_kv "note_id" "${NOTE_EPOCH}-${NOTE_SEQ}")" \
        "$(_json_kv "state" "pending")" \
        "$(_json_kv "sent_at" "$NOTE_SENT_AT")" \
        "$(_json_kv "entry_status" "$_QE_STATUS")" \
        "$(_json_kv "resolved_via" "$NOTE_TARGET_VIA")"
    else
      printf 'Note queued for %s (%s): delivery %s\n' "$NOTE_ID" "${NOTE_EPOCH}-${NOTE_SEQ}" "$NOTE_ROUTE"
    fi
    ;;

  # --- notes-entry: what the operator sent, and what has landed ---
  notes-entry|notes)
    if [ $# -lt 1 ]; then
      echo "ERROR: notes-entry requires <id>" >&2
      exit 1
    fi
    NOTES_ID="$1"
    shift
    if [ $# -gt 0 ]; then
      echo "ERROR: Unknown notes-entry option: $1" >&2
      exit 1
    fi

    # No entry lookup: a discarded or pruned entry still has a control
    # directory, and its note history is exactly what an operator wants to read
    # when working out what the agent was told.
    NOTES_DIR="$(get_control_dir "$NOTES_ID")/notes"

    NOTES_JSON=""
    NOTES_TEXT=""
    NOTES_PENDING=0
    NOTES_DELIVERED=0
    for _NOTE_STATE in pending delivered; do
      if [ "$_NOTE_STATE" = "pending" ]; then
        _NOTE_SRC="$NOTES_DIR"
      else
        _NOTE_SRC="$NOTES_DIR/delivered"
      fi
      # Quoted directory, bare `*.md`: a glob held in a variable would be
      # word-split on a space in the path before the shell ever expanded it.
      for _NOTE_PATH in "$_NOTE_SRC"/*.md; do
        [ -f "$_NOTE_PATH" ] || continue
        _NOTE_BASE="${_NOTE_PATH##*/}"
        _NOTE_KEY="${_NOTE_BASE%.md}"
        _NOTE_SENT=$(epoch_to_iso "${_NOTE_KEY%%-*}")
        _NOTE_DELIVERED=""
        if [ "$_NOTE_STATE" = "delivered" ] && [ -f "${_NOTE_PATH}.at" ]; then
          _NOTE_DELIVERED=$(cat "${_NOTE_PATH}.at" 2>/dev/null) || _NOTE_DELIVERED=""
        fi
        _NOTE_BODY=$(cat "$_NOTE_PATH" 2>/dev/null) || _NOTE_BODY=""
        if [ "$_NOTE_STATE" = "pending" ]; then
          NOTES_PENDING=$(( NOTES_PENDING + 1 ))
        else
          NOTES_DELIVERED=$(( NOTES_DELIVERED + 1 ))
        fi
        NOTES_JSON="${NOTES_JSON:+$NOTES_JSON,}{$(_json_kv "note_id" "$_NOTE_KEY"),$(_json_kv "state" "$_NOTE_STATE"),$(_json_kv "sent_at" "$_NOTE_SENT"),$(_json_kv "delivered_at" "$_NOTE_DELIVERED"),$(_json_kv "text" "$_NOTE_BODY")}"
        NOTES_TEXT="${NOTES_TEXT}$(printf '  %-10s %-24s %-24s %s' \
          "$_NOTE_STATE" "$_NOTE_SENT" "${_NOTE_DELIVERED:--}" "$_NOTE_BODY")
"
      done
    done

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s,"notes":[%s]}\n' \
        "$(_json_kv "entry_id" "$NOTES_ID")" \
        "$(_json_kv_raw "pending" "$NOTES_PENDING")" \
        "$(_json_kv_raw "delivered" "$NOTES_DELIVERED")" \
        "$NOTES_JSON"
    elif [ "$NOTES_PENDING" -eq 0 ] && [ "$NOTES_DELIVERED" -eq 0 ]; then
      printf 'No notes for %s\n' "$NOTES_ID"
    else
      printf 'Notes for %s — %s pending, %s delivered\n' "$NOTES_ID" "$NOTES_PENDING" "$NOTES_DELIVERED"
      printf '  %-10s %-24s %-24s %s\n' "STATE" "SENT" "DELIVERED" "TEXT"
      printf '%s' "$NOTES_TEXT"
    fi
    ;;

  # --- follow-up-entry: queue work that extends an entry already in the queue ---
  # `follow-up` is the short alias; `follow-up-entry` is canonical, because
  # t-0055 clause 12 requires every per-entry command to end in -entry.
  #
  # Deliberately NOT a flag on `add`. A follow-up resolves its parent in any
  # status, names its brief after the parent, inherits the parent's work
  # metadata and leaves `branch` empty for the dequeue selector — four
  # behaviours `add` does not have and should not grow a mode switch for.
  follow-up-entry|follow-up)
    if [ $# -lt 1 ]; then
      echo "ERROR: follow-up-entry requires <parent-id>" >&2
      exit 1
    fi
    FU_PARENT_ID="$1"
    shift

    FU_BRIEF="" FU_AUTO_APPROVE=false FU_PRIORITY="" FU_SESSION_TYPE="" FU_PROJECT=""
    FU_MILESTONE_NAME="" FU_MILESTONE_INDEX="" FU_MILESTONE_TOTAL=""
    FU_PRIORITY_EXPLICIT=false
    while [ $# -gt 0 ]; do
      case "$1" in
        --brief)
          if [ $# -lt 2 ]; then echo "ERROR: --brief requires a path" >&2; exit 1; fi
          FU_BRIEF="$2"; shift 2 ;;
        --auto-approve)   FU_AUTO_APPROVE=true; shift ;;
        --session-type)
          if [ $# -lt 2 ]; then echo "ERROR: --session-type requires a value" >&2; exit 1; fi
          FU_SESSION_TYPE="$2"; shift 2 ;;
        --project)
          if [ $# -lt 2 ]; then echo "ERROR: --project requires a value" >&2; exit 1; fi
          FU_PROJECT="$2"; shift 2 ;;
        --milestone-name)
          if [ $# -lt 2 ]; then echo "ERROR: --milestone-name requires a value" >&2; exit 1; fi
          FU_MILESTONE_NAME="$2"; shift 2 ;;
        --milestone-index)
          if [ $# -lt 2 ]; then echo "ERROR: --milestone-index requires a value" >&2; exit 1; fi
          case "$2" in ''|*[!0-9]*) echo "ERROR: --milestone-index requires a non-negative integer" >&2; exit 1 ;; esac
          FU_MILESTONE_INDEX="$2"; shift 2 ;;
        --milestone-total)
          if [ $# -lt 2 ]; then echo "ERROR: --milestone-total requires a value" >&2; exit 1; fi
          case "$2" in ''|*[!0-9]*) echo "ERROR: --milestone-total requires a non-negative integer" >&2; exit 1 ;; esac
          FU_MILESTONE_TOTAL="$2"; shift 2 ;;
        --priority)
          if [ $# -lt 2 ]; then echo "ERROR: --priority requires a value" >&2; exit 1; fi
          case "$2" in ''|*[!0-9]*) echo "ERROR: --priority requires a non-negative integer" >&2; exit 1 ;; esac
          FU_PRIORITY="$2"; FU_PRIORITY_EXPLICIT=true; shift 2 ;;
        *)
          echo "ERROR: Unknown follow-up-entry option: $1" >&2
          exit 1
          ;;
      esac
    done

    if [ -z "$FU_BRIEF" ]; then
      echo "ERROR: follow-up-entry requires --brief <path>" >&2
      echo "  Start one from the parent's leftovers: queue-cli.sh follow-up-draft $FU_PARENT_ID > draft.md" >&2
      exit 1
    fi

    # The parent may be in any status — that is the point of the command. A
    # completed parent is the common case (its gaps are what the follow-up is
    # for); a running one is queued behind it by the dequeue guard.
    FU_PARENT_FILE=$(_find_entry_file "$FU_PARENT_ID") || FU_PARENT_FILE=""
    if [ -z "$FU_PARENT_FILE" ]; then
      echo "ERROR: Parent entry $FU_PARENT_ID not found" >&2
      exit 1
    fi
    _load_queue_entry "$FU_PARENT_FILE"
    FU_PARENT_STATUS="$_QE_STATUS"
    FU_PARENT_BRIEF="${_QE_BRIEF_PATH:-}"
    FU_PARENT_WO="${_QE_WORK_ORDER_ID:-}"
    FU_PARENT_TYPE="${_QE_SESSION_TYPE:-}"
    FU_PARENT_SOLO="${_QE_SOLO_MODE:-false}"
    FU_PARENT_PUSH="${_QE_PUSH_ON_COMPLETE:-false}"
    FU_PARENT_PROFILE="${_QE_PERMISSION_PROFILE:-build}"
    FU_PARENT_PRIORITY="${_QE_PRIORITY:-0}"
    FU_PARENT_PROJECT="${_QE_PROJECT:-}"
    FU_PARENT_MS_NAME="${_QE_MILESTONE_NAME:-}"
    FU_PARENT_MS_INDEX="${_QE_MILESTONE_INDEX:-0}"
    FU_PARENT_MS_TOTAL="${_QE_MILESTONE_TOTAL:-0}"

    # A follow-up of a follow-up points at the entry it actually extends, not
    # at the head of the chain. Flattening would misreport the hold graph: the
    # dequeue guard asks "is MY parent done", and that is the middle entry.
    if [ -n "${_QE_FOLLOW_UP_OF:-}" ]; then
      echo "Note: $FU_PARENT_ID is itself a follow-up of ${_QE_FOLLOW_UP_OF}; the new entry follows $FU_PARENT_ID, not the chain head" >&2
    fi

    # Inherit unless overridden.
    [ -n "$FU_SESSION_TYPE" ]    || FU_SESSION_TYPE="$FU_PARENT_TYPE"
    [ -n "$FU_PROJECT" ]         || FU_PROJECT="$FU_PARENT_PROJECT"
    [ -n "$FU_MILESTONE_NAME" ]  || FU_MILESTONE_NAME="$FU_PARENT_MS_NAME"
    [ -n "$FU_MILESTONE_INDEX" ] || FU_MILESTONE_INDEX="$FU_PARENT_MS_INDEX"
    [ -n "$FU_MILESTONE_TOTAL" ] || FU_MILESTONE_TOTAL="$FU_PARENT_MS_TOTAL"
    [ "$FU_PRIORITY_EXPLICIT" = true ] || FU_PRIORITY="$FU_PARENT_PRIORITY"

    # Resolve and validate the source brief exactly as `add` does.
    if [ ! -f "$FU_BRIEF" ] && [ -f "$REPO_ROOT/$FU_BRIEF" ]; then
      FU_BRIEF="$REPO_ROOT/$FU_BRIEF"
    fi
    if [ ! -f "$FU_BRIEF" ]; then
      echo "ERROR: Brief file not found: $FU_BRIEF" >&2
      exit 1
    fi
    if [ ! -s "$FU_BRIEF" ]; then
      echo "ERROR: Brief file is empty. Cannot queue an empty brief." >&2
      exit 1
    fi
    _FU_BRIEF_REAL=$(cd "$(dirname "$FU_BRIEF")" && pwd)/$(basename "$FU_BRIEF")
    case "$_FU_BRIEF_REAL" in
      "$REPO_ROOT"/*) ;;
      *)
        echo "ERROR: Brief path must be inside the repo. Copy the file to .claude/.automation/briefs/ first." >&2
        echo "  Resolved path: $_FU_BRIEF_REAL" >&2
        exit 1
        ;;
    esac

    # The brief is COPIED to briefs/followup-<parent-id>-<n>.md rather than
    # referenced where it lies. The name is the human-readable half of the
    # linkage — `ls briefs/` answers "what follows what" without parsing YAML —
    # and the dequeue selector reads <n> back out of it to name the branch.
    # Copying also means an operator editing their draft afterwards cannot
    # change what a queued entry will run.
    FU_BRIEFS_DIR="$REPO_ROOT/.claude/.automation/briefs"
    if ! mkdir -p "$FU_BRIEFS_DIR"; then
      echo "ERROR: Could not create the briefs directory: $FU_BRIEFS_DIR" >&2
      exit 1
    fi
    # <n> counts existing follow-up briefs for this parent, not live entries:
    # a pruned sibling must not free its number, or two briefs would collide.
    FU_N=1
    while [ -e "$FU_BRIEFS_DIR/followup-${FU_PARENT_ID}-${FU_N}.md" ]; do
      FU_N=$(( FU_N + 1 ))
    done
    FU_BRIEF_DEST="$FU_BRIEFS_DIR/followup-${FU_PARENT_ID}-${FU_N}.md"
    if ! cp "$FU_BRIEF" "$FU_BRIEF_DEST"; then
      echo "ERROR: Could not write the follow-up brief: $FU_BRIEF_DEST" >&2
      exit 1
    fi

    VALID_PHASES=$(get_phases_for_type "$FU_SESSION_TYPE" 2>/dev/null || true)
    if [ -z "$VALID_PHASES" ]; then
      rm -f "$FU_BRIEF_DEST" 2>/dev/null || true
      echo "ERROR: Invalid session type: $FU_SESSION_TYPE" >&2
      exit 1
    fi

    if ! acquire_queue_lock; then
      rm -f "$FU_BRIEF_DEST" 2>/dev/null || true
      echo "ERROR: Queue lock unavailable" >&2
      exit 1
    fi

    _ensure_queue_dirs
    # Argument 5 (branch) is empty ON PURPOSE. Whether this entry continues the
    # parent's branch or starts a new one off main depends on whether that
    # branch is still unmerged, which is only knowable when the follow-up
    # reaches the front of the queue — so the dequeue selector resolves it
    # there and writes the answer back (_followup_resolve_branch).
    FU_ENTRY_ID=$(queue_enqueue "$FU_BRIEF_DEST" "$FU_SESSION_TYPE" "false" \
      "$FU_PARENT_SOLO" "" "$FU_PARENT_WO" "$FU_PARENT_PUSH" "$FU_PRIORITY" \
      "$FU_PARENT_PROFILE" "$FU_PROJECT" "$FU_MILESTONE_NAME" \
      "$FU_MILESTONE_INDEX" "$FU_MILESTONE_TOTAL" "" "$FU_PARENT_ID")

    if [ -z "$FU_ENTRY_ID" ]; then
      release_queue_lock
      rm -f "$FU_BRIEF_DEST" 2>/dev/null || true
      echo "ERROR: Failed to create the follow-up entry" >&2
      exit 1
    fi

    _FU_ENTRY_FILE="$(_queue_dir)/pending-review/${FU_ENTRY_ID}.yaml"
    if ! validate_queue_entry "$_FU_ENTRY_FILE"; then
      rm -f "$_FU_ENTRY_FILE" 2>/dev/null || true
      _rebuild_queue_index
      release_queue_lock
      rm -f "$FU_BRIEF_DEST" 2>/dev/null || true
      echo "ERROR: Queue entry validation failed — entry removed" >&2
      exit 1
    fi

    FU_STATUS="pending-review"
    if [ "$FU_AUTO_APPROVE" = true ]; then
      queue_approve "$FU_ENTRY_ID"
      FU_STATUS="approved"
    fi

    release_queue_lock

    # What the operator will see happen, said at creation time rather than
    # left to be discovered at dequeue. This is a FORECAST of the branch, not
    # the stored value: the entry's `branch` is still empty and the selector
    # re-asks the same question when the entry actually runs.
    FU_BRANCH_FORECAST=$(_followup_resolve_branch "$FU_PARENT_ID" "$FU_N") || FU_BRANCH_FORECAST=""

    review_log_append "entry-follow-up-created" "$FU_PARENT_WO" "$FU_ENTRY_ID" \
      "Follow-up $FU_ENTRY_ID created for parent $FU_PARENT_ID ($FU_PARENT_STATUS) — brief followup-${FU_PARENT_ID}-${FU_N}.md, branch resolved at dequeue (forecast: ${FU_BRANCH_FORECAST:-unknown})" 2>/dev/null || true

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s,%s,%s,%s,%s}\n' \
        "$(_json_kv "entry_id" "$FU_ENTRY_ID")" \
        "$(_json_kv "follow_up_of" "$FU_PARENT_ID")" \
        "$(_json_kv "parent_status" "$FU_PARENT_STATUS")" \
        "$(_json_kv "status" "$FU_STATUS")" \
        "$(_json_kv "session_type" "$FU_SESSION_TYPE")" \
        "$(_json_kv "brief_path" "$FU_BRIEF_DEST")" \
        "$(_json_kv "branch_forecast" "$FU_BRANCH_FORECAST")"
    else
      printf 'entry_id:        %s\n' "$FU_ENTRY_ID"
      printf 'follow_up_of:    %s (%s)\n' "$FU_PARENT_ID" "$FU_PARENT_STATUS"
      printf 'status:          %s\n' "$FU_STATUS"
      printf 'session_type:    %s\n' "$FU_SESSION_TYPE"
      printf 'brief_path:      %s\n' "$FU_BRIEF_DEST"
      printf 'branch:          resolved at dequeue (forecast: %s)\n' "${FU_BRANCH_FORECAST:-unknown}"
      # The dequeue guard releases on `completed` and on `missing` only. A parent
      # that reached `failed` — the discard destination too — therefore never
      # releases on its own, and saying "held until it completes" of an entry that
      # has stopped moving would be a lie the operator only discovers by waiting.
      case "$FU_PARENT_STATUS" in
        completed|missing) ;;
        failed) printf 'order:           held indefinitely — %s is in failed/ and will not complete; discard this follow-up or re-queue the parent\n' "$FU_PARENT_ID" ;;
        *) printf 'order:           held until %s completes\n' "$FU_PARENT_ID" ;;
      esac
    fi
    ;;

  # --- follow-up-draft: what the parent left undone, as a brief skeleton ---
  # Queues nothing. It prints a draft to stdout for the operator to edit and
  # hand back to `follow-up-entry --brief`, because the four sources below are
  # evidence of a gap, not agreement that the gap is worth another session.
  follow-up-draft)
    if [ $# -lt 1 ]; then
      echo "ERROR: follow-up-draft requires <parent-id>" >&2
      exit 1
    fi
    FUD_PARENT_ID="$1"
    shift
    if [ $# -gt 0 ]; then
      echo "ERROR: Unknown follow-up-draft option: $1" >&2
      exit 1
    fi

    FUD_FILE=$(_find_entry_file "$FUD_PARENT_ID") || FUD_FILE=""
    if [ -z "$FUD_FILE" ]; then
      echo "ERROR: Entry $FUD_PARENT_ID not found" >&2
      exit 1
    fi
    _load_queue_entry "$FUD_FILE"
    FUD_STATUS="$_QE_STATUS"
    FUD_BRIEF="${_QE_BRIEF_PATH:-}"
    FUD_BRANCH="${_QE_BRANCH:-}"
    FUD_ERROR_LOG="${_QE_ERROR_LOG:-}"
    FUD_WO="${_QE_WORK_ORDER_ID:-}"

    # --- source 1: the parent brief's own goal, as context ---
    # First non-empty line under a `## Goal` / `### Goal` heading. A brief that
    # does not use the template heading contributes nothing rather than
    # guessing at some other paragraph.
    FUD_GOAL=""
    FUD_TITLE=""
    if [ -n "$FUD_BRIEF" ] && [ -f "$FUD_BRIEF" ]; then
      FUD_IN_GOAL=false
      while IFS= read -r _FUD_LINE; do
        case "$_FUD_LINE" in
          "# "*)
            [ -n "$FUD_TITLE" ] || FUD_TITLE="${_FUD_LINE#\# }"
            FUD_IN_GOAL=false
            ;;
          "## Goal"*|"### Goal"*) FUD_IN_GOAL=true ;;
          "#"*) FUD_IN_GOAL=false ;;
          "")  ;;
          *)
            if [ "$FUD_IN_GOAL" = true ] && [ -z "$FUD_GOAL" ]; then
              FUD_GOAL="$_FUD_LINE"
              FUD_IN_GOAL=false
            fi
            ;;
        esac
      done < "$FUD_BRIEF"
    fi
    [ -n "$FUD_TITLE" ] || FUD_TITLE="Follow-up to $FUD_PARENT_ID"

    # --- source 2: unticked checklist items in the parent brief ---
    # `- [ ]` is the brief template's verification shape. An unticked box is
    # the strongest single signal of unfinished work, and unlike the verdict
    # file it exists even for an entry that never reached the review phase.
    FUD_UNMET=""
    FUD_UNMET_N=0
    if [ -n "$FUD_BRIEF" ] && [ -f "$FUD_BRIEF" ]; then
      while IFS= read -r _FUD_LINE; do
        case "$_FUD_LINE" in
          *"- [ ]"*)
            FUD_UNMET="${FUD_UNMET}- [ ] ${_FUD_LINE#*- \[ \] }
"
            FUD_UNMET_N=$(( FUD_UNMET_N + 1 ))
            ;;
        esac
      done < "$FUD_BRIEF"
    fi

    # --- source 3: criteria the verdict file did not record as met ---
    # docs/ai/governance/criteria-verdicts/<session-id>.yaml, written by the
    # completeness gate. PARTIAL and INCONCLUSIVE are the interesting verdicts:
    # a criterion nobody could confirm is exactly what a follow-up is for. The
    # file is keyed by session id, so an entry that never got a session record
    # contributes nothing — which is correct, not a failure.
    FUD_SID=$(_session_id_for_entry "$FUD_PARENT_ID") || FUD_SID=""
    FUD_VERDICT_FILE=""
    FUD_CRITERIA=""
    FUD_CRITERIA_N=0
    if [ -n "$FUD_SID" ]; then
      _FUD_VF="$REPO_ROOT/docs/ai/governance/criteria-verdicts/${FUD_SID}.yaml"
      if [ -f "$_FUD_VF" ]; then
        FUD_VERDICT_FILE="$_FUD_VF"
        # One pass, remembering the last `criterion:` seen. The verdict lines
        # come AFTER their criterion text in the record's shape, so a criterion
        # is emitted when a non-clean verdict names it — not when it is read.
        _FUD_CRIT=""
        while IFS= read -r _FUD_LINE; do
          case "$_FUD_LINE" in
            *"criterion:"*)
              _FUD_CRIT="${_FUD_LINE#*criterion:}"
              _FUD_CRIT="${_FUD_CRIT# }"
              _FUD_CRIT="${_FUD_CRIT#\"}"; _FUD_CRIT="${_FUD_CRIT%\"}"
              _FUD_CRIT="${_FUD_CRIT#\\\"}"; _FUD_CRIT="${_FUD_CRIT%\\\"}"
              ;;
            *"verdict: PARTIAL"*|*"verdict: INCONCLUSIVE"*|*"verdict: FAILED"*)
              if [ -n "$_FUD_CRIT" ]; then
                _FUD_V="${_FUD_LINE#*verdict: }"
                FUD_CRITERIA="${FUD_CRITERIA}- [ ] ${_FUD_CRIT} (${_FUD_V} in ${FUD_SID})
"
                FUD_CRITERIA_N=$(( FUD_CRITERIA_N + 1 ))
                _FUD_CRIT=""
              fi
              ;;
          esac
        done < "$_FUD_VF"
      fi
    fi

    # --- source 4: escalations naming this entry ---
    # An unresolved escalation is a gap the parent reported and could not close
    # itself — brief 5's inert hook route is exactly this case.
    FUD_ESCALATIONS=""
    FUD_ESC_N=0
    for _FUD_ESC in "$REPO_ROOT/.claude/.automation/escalations"/*.yaml; do
      [ -f "$_FUD_ESC" ] || continue
      grep -Fq "queue_entry_id: \"$FUD_PARENT_ID\"" "$_FUD_ESC" 2>/dev/null || continue
      grep -Fqx '  resolved: false' "$_FUD_ESC" 2>/dev/null || continue
      _FUD_ESC_TYPE=$(grep -F '  type:' "$_FUD_ESC" 2>/dev/null) || _FUD_ESC_TYPE=""
      _FUD_ESC_TYPE="${_FUD_ESC_TYPE#*type:}"; _FUD_ESC_TYPE="${_FUD_ESC_TYPE# }"
      _FUD_ESC_TYPE="${_FUD_ESC_TYPE#\"}"; _FUD_ESC_TYPE="${_FUD_ESC_TYPE%\"}"
      FUD_ESCALATIONS="${FUD_ESCALATIONS}- [ ] Resolve escalation ${_FUD_ESC##*/} (${_FUD_ESC_TYPE:-unknown}, unresolved)
"
      FUD_ESC_N=$(( FUD_ESC_N + 1 ))
    done

    FUD_TOTAL=$(( FUD_UNMET_N + FUD_CRITERIA_N + FUD_ESC_N ))

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s,%s,%s,%s,%s,%s,%s}\n' \
        "$(_json_kv "parent_id" "$FUD_PARENT_ID")" \
        "$(_json_kv "parent_status" "$FUD_STATUS")" \
        "$(_json_kv "parent_brief" "$FUD_BRIEF")" \
        "$(_json_kv "parent_goal" "$FUD_GOAL")" \
        "$(_json_kv "verdict_file" "$FUD_VERDICT_FILE")" \
        "$(_json_kv_raw "unmet_checklist" "$FUD_UNMET_N")" \
        "$(_json_kv_raw "open_criteria" "$FUD_CRITERIA_N")" \
        "$(_json_kv_raw "open_escalations" "$FUD_ESC_N")" \
        "$(_json_kv "draft" "$(printf '%s%s%s' "$FUD_UNMET" "$FUD_CRITERIA" "$FUD_ESCALATIONS")")"
    else
      printf '# Follow-up: %s\n\n' "$FUD_TITLE"
      printf 'Drafted from entry `%s` (%s). Nothing is queued: edit this, then\n' \
        "$FUD_PARENT_ID" "$FUD_STATUS"
      printf '`queue-cli.sh follow-up-entry %s --brief <this file>`.\n\n' "$FUD_PARENT_ID"

      printf '## Parent task\n\n'
      printf -- '- Entry: `%s` (%s)\n' "$FUD_PARENT_ID" "$FUD_STATUS"
      printf -- '- Branch: `%s`\n' "${FUD_BRANCH:-unresolved}"
      printf -- '- Brief: `%s`\n' "${FUD_BRIEF:-none}"
      [ -n "$FUD_WO" ] && printf -- '- Work order: `%s`\n' "$FUD_WO"
      [ -n "$FUD_SID" ] && printf -- '- Session: `%s`\n' "$FUD_SID"
      [ -n "$FUD_ERROR_LOG" ] && printf -- '- Recorded failure: %s\n' "$FUD_ERROR_LOG"
      printf '\n'
      if [ -n "$FUD_GOAL" ]; then
        printf 'Its goal was: %s\n\n' "$FUD_GOAL"
      fi

      printf '## Goal\n\n'
      if [ "$FUD_TOTAL" -eq 0 ]; then
        printf '_Nothing was detected as left undone — no unticked checklist item, no\n'
        printf 'open criterion and no unresolved escalation names this entry. Say here\n'
        printf 'what this follow-up is for, or do not queue it._\n\n'
      else
        printf '_Replace this with one sentence. The %s item(s) below are evidence of a\n' "$FUD_TOTAL"
        printf 'gap, not a goal — delete the ones that do not deserve a session._\n\n'
      fi

      printf '## Verify first\n\n'
      if [ "$FUD_UNMET_N" -gt 0 ]; then
        printf '**Unticked in the parent brief (%s):**\n\n' "$FUD_UNMET_N"
        printf '%s\n' "$FUD_UNMET"
      fi
      if [ "$FUD_CRITERIA_N" -gt 0 ]; then
        printf '**Not confirmed met by the completeness gate (%s):**\n\n' "$FUD_CRITERIA_N"
        printf '%s\n' "$FUD_CRITERIA"
      fi
      if [ "$FUD_ESC_N" -gt 0 ]; then
        printf '**Unresolved escalations (%s):**\n\n' "$FUD_ESC_N"
        printf '%s\n' "$FUD_ESCALATIONS"
      fi
      if [ "$FUD_TOTAL" -eq 0 ]; then
        printf -- '- [ ] _Add the checks this follow-up must pass._\n\n'
      fi

      printf '## Scope\n\n'
      printf '_List the files this follow-up may touch. The parent'"'"'s scope is a\n'
      printf 'starting point, not an inheritance — a follow-up that needs the same\n'
      printf 'breadth as its parent is probably a new task._\n\n'

      printf '### Task Contract\n\n'
      printf '```yaml\n'
      printf 'artifact: ""\n'
      printf 'constraints: []\n'
      printf 'lifecycle: task-scoped\n'
      printf 'scope_files: []\n'
      printf '```\n'
    fi
    ;;

  *)
    echo "ERROR: Unknown subcommand: $SUBCOMMAND" >&2
    _usage
    ;;
esac
