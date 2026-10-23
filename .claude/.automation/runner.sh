#!/usr/bin/env bash
# Operator automation layer — headless session runner.
# Entry point for automated claude -p invocations with governance parity.
# Decision 0017 — Operator Automation Layer.
#
# Two modes:
#   Single-shot: runner.sh --brief-id <id> [--branch <branch>] [--session-type <type>]
#   Daemon:      runner.sh --daemon
#
# Single-shot mode runs one brief directly (backward compatible with Brief 2).
# Daemon mode loops: dequeue from approved queue, assemble prompt, execute,
# transition based on outcome. Supports live config toggle and HALT file.
#
# Exits:
#   0 — completed (success or clean no-op)
#   1 — failed (crash or clean failure)
#   2 — review (escalation or operator tag)

set -euo pipefail

# --- Self-locate and derive repo root ---
# runner.sh lives at .claude/.automation/ — repo root is two levels up.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUTOMATION_DIR="$SCRIPT_DIR"
LIB_DIR="$AUTOMATION_DIR/lib"

# --- Source shared helpers ---
# shellcheck source=../../.claude/hooks/_analytics-helper.sh
source "$REPO_ROOT/.claude/hooks/_analytics-helper.sh"
# shellcheck source=../../.claude/hooks/_phase-helper.sh
source "$REPO_ROOT/.claude/hooks/_phase-helper.sh"
# shellcheck source=../../.claude/hooks/_cleanup-helper.sh
source "$REPO_ROOT/.claude/hooks/_cleanup-helper.sh"

# --- Source runner libraries ---
# shellcheck source=lib/state-manager.sh
source "$LIB_DIR/state-manager.sh"
# shellcheck source=lib/branch-manager.sh
source "$LIB_DIR/branch-manager.sh"
# shellcheck source=lib/outcome-detector.sh
source "$LIB_DIR/outcome-detector.sh"
# shellcheck source=lib/work-preserver.sh
source "$LIB_DIR/work-preserver.sh"
# shellcheck source=lib/queue-manager.sh
source "$LIB_DIR/queue-manager.sh"
# shellcheck source=lib/prompt-assembler.sh
source "$LIB_DIR/prompt-assembler.sh"
# shellcheck source=lib/permission-profiles.sh
source "$LIB_DIR/permission-profiles.sh"
# shellcheck source=lib/blocker-reporter.sh
source "$LIB_DIR/blocker-reporter.sh"
# shellcheck source=lib/cohesion-trigger.sh
source "$LIB_DIR/cohesion-trigger.sh"
# shellcheck source=lib/group-worktree-sweep.sh
# Sourced BEFORE cleanup.sh: run_cleanup() calls sweep_stale_group_worktrees
# through a `type` guard, so the definition must already exist (Decision 0054).
source "$LIB_DIR/group-worktree-sweep.sh"
# shellcheck source=lib/cleanup.sh
source "$LIB_DIR/cleanup.sh"
# shellcheck source=lib/work-order-manager.sh
source "$LIB_DIR/work-order-manager.sh"
# shellcheck source=lib/review-log.sh
source "$LIB_DIR/review-log.sh"
# shellcheck source=lib/drift-detector.sh
source "$LIB_DIR/drift-detector.sh"
# shellcheck source=lib/queue-validator.sh
source "$LIB_DIR/queue-validator.sh"
# shellcheck source=lib/cache-builder.sh
source "$LIB_DIR/cache-builder.sh"
# shellcheck source=lib/file-lock.sh
source "$LIB_DIR/file-lock.sh"
# shellcheck source=lib/health-check.sh
source "$LIB_DIR/health-check.sh"
# shellcheck source=lib/remediation-trigger.sh
source "$LIB_DIR/remediation-trigger.sh"
# shellcheck source=lib/overlap-report.sh
# Sourced for the two stateless helpers only (overlap_report_main_changed /
# _main_commit), which the close-time re-verification gate uses. The report
# builders are not called from here and the `_OR_*` module state stays unused.
source "$LIB_DIR/overlap-report.sh"
# shellcheck source=lib/reverify-merge.sh
# Sourced AFTER overlap-report.sh, queue-manager.sh and permission-profiles.sh:
# it calls into all three at run time.
source "$LIB_DIR/reverify-merge.sh"
# shellcheck source=lib/pr-manager.sh
# Sourced AFTER queue-manager.sh (it calls queue_close_record, queue_set_pr and
# queue_pr_merge_allowed) and AFTER _cleanup-helper.sh, whose record_closed_branch
# and delete_merged_session_branch it reaches through `type` guards when a merged
# pull request's branch is sealed.
source "$LIB_DIR/pr-manager.sh"

# --- Runner merge lock helpers (Decision 0030 — worktree merge serialization) ---
_RUNNER_MERGE_LOCK_FD=7
_RUNNER_MERGE_LOCK_HELD=false
_RUNNER_MERGE_LOCK_PATH=""

_acquire_runner_merge_lock() {
  local lock_path="$1"
  _RUNNER_MERGE_LOCK_PATH="$lock_path"
  mkdir -p "$(dirname "$lock_path")" 2>/dev/null || true

  # Bounded retry: 3 attempts × 10s before fail-closed (C3 isolation patch)
  local retry=0
  while [ "$retry" -lt 3 ]; do
    retry=$((retry + 1))
    local _acquired=false

    if command -v flock > /dev/null 2>&1; then
      eval "exec ${_RUNNER_MERGE_LOCK_FD}>\"$lock_path\""
      if flock -n -x "$_RUNNER_MERGE_LOCK_FD" 2>/dev/null; then
        _acquired=true
      fi
    else
      local attempts=0
      while [ "$attempts" -lt 20 ]; do
        attempts=$((attempts + 1))
        if mkdir "${lock_path}.dir" 2>/dev/null; then
          echo "$$" > "${lock_path}.dir/pid" 2>/dev/null || true
          _acquired=true
          break
        fi
        if [ -f "${lock_path}.dir/pid" ]; then
          local lock_pid
          lock_pid=$(cat "${lock_path}.dir/pid" 2>/dev/null || echo "")
          if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -rf "${lock_path}.dir" 2>/dev/null || true
            continue
          fi
        fi
        sleep 0.5
      done
    fi

    if [ "$_acquired" = true ]; then
      _RUNNER_MERGE_LOCK_HELD=true
      return 0
    fi

    if [ "$retry" -lt 3 ]; then
      echo "WARNING: Runner merge lock attempt $retry/3 failed — retrying in 10s" >&2
      sleep 10
    fi
  done

  # Fail-closed: all 3 attempts exhausted
  echo "ERROR: Runner merge lock timeout (3 attempts × 10s) — fail-closed, merge blocked" >&2
  return 1
}

# --- Warn when the merge lock was held longer than the re-verify budget ---
# Arguments: $1 — epoch at acquisition (0 = not measured); $2 — branch
#
# Deliberately measured on the HOLDER, not the waiter. The brief asks for a
# warning when holding the lock blocks another merge for more than the timeout,
# but a holder cannot see who is queued behind it, and the waiter side already
# prints a line per retry in _acquire_runner_merge_lock. What the holder CAN
# state, and what an operator greps for after a stalled close, is that this
# merge held the lock past the budget everything else waits on.
_warn_if_merge_lock_held_long() {
  local started="${1:-0}" branch="${2:-}" budget held
  case "$started" in ''|*[!0-9]*) return 0 ;; esac
  [ "$started" -gt 0 ] || return 0
  budget=$(_reverify_timeout)
  held=$(( $(date +%s) - started ))
  if [ "$held" -gt "$budget" ]; then
    echo "WARNING: Runner merge lock held ${held}s for '$branch' — longer than reverify_timeout_seconds (${budget}s). Any other close waiting to merge was blocked for that long." >&2
  fi
  return 0
}

_release_runner_merge_lock() {
  if [ "$_RUNNER_MERGE_LOCK_HELD" = true ] && [ -n "$_RUNNER_MERGE_LOCK_PATH" ]; then
    if command -v flock > /dev/null 2>&1; then
      eval "exec ${_RUNNER_MERGE_LOCK_FD}>&-" 2>/dev/null || true
    else
      rm -rf "${_RUNNER_MERGE_LOCK_PATH}.dir" 2>/dev/null || true
    fi
    _RUNNER_MERGE_LOCK_HELD=false
  fi
}

# --- Config files ---
CONFIG_FILE="$AUTOMATION_DIR/config.yaml"
CONFIG_LOCAL_FILE="$AUTOMATION_DIR/config.local.yaml"

# --- Heartbeat state ---
_HEARTBEAT_PID=""

# --- Child process tracking (for FORCE-HALT) ---
_CLAUDE_CHILD_PID=""
# The in-session FORCE-HALT watcher's pid. Declared here with its peer rather
# than only being assigned inside _start_force_halt_watcher: the whole file runs
# under `set -u`, so any read before the first launch would abort the daemon.
_FORCE_HALT_WATCHER_PID=""

# --- Worktree tracking (for cleanup on crash/FORCE-HALT) ---
_CURRENT_WORKTREE_DIR=""

# --- Task group worktree tracking (Decision 0054) ---
# A sequential task group's worktree outlives the session that created it, so
# every removal site must consult _CURRENT_WORKTREE_IS_GROUP before removing
# _CURRENT_WORKTREE_DIR. _CURRENT_GROUP_NAME names the group whose occupancy
# lock this runner holds; it is the handle the crash/FORCE-HALT paths use to
# release that lock without removing the worktree.
_CURRENT_WORKTREE_IS_GROUP=false
_CURRENT_GROUP_NAME=""

# --- Operator stop/resume tracking (Decision t-0055) ---
# _STOP_WATCHER_PID — pid of the background poller that honours FORCE and
#                     escalates a stalled graceful stop ("" when none runs).
# _RESUME_ENTRY     — true when the dequeued entry carries `resume: true`, so
#                     the child continues the recorded Claude session instead of
#                     starting a fresh one. Set by the daemon loop before
#                     _run_single_entry, which reads it. Single-shot mode never
#                     sets it, hence the default here.
# _RESUME_WORKTREE_EXEMPT — true when the group worktree's clean-start check is
#                     waived because this entry is resuming into the very
#                     worktree its own stop left dirty. An input to
#                     _resolve_group_worktree, not one of its _GWT_* outputs.
_STOP_WATCHER_PID=""
_RESUME_ENTRY=false
_RESUME_WORKTREE_EXEMPT=false

# --- Daemon lifecycle state ---
_SHUTDOWN_REQUESTED=false
_DAEMON_START_EPOCH=""
_SESSIONS_COMPLETED=0
_SESSIONS_FAILED=0
_LAST_SESSION_AT="never"
_CURRENT_ENTRY_ID=""
_CONSECUTIVE_SESSION_COUNT=0

# --- Parse arguments ---
BRIEF_ID=""
EXISTING_BRANCH=""
SESSION_TYPE="standard"
DAEMON_MODE=false
# (t-0057) Close-only mode: run the close pipeline for one already-completed
# entry and exit. No session is launched. This is how `queue-cli.sh merge`
# reaches the real merge path instead of re-implementing it.
CLOSE_ENTRY_ID=""
# Set true only inside that mode. Read by _close_merge_held.
_CLOSE_ENTRY_MODE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --brief-id)
      BRIEF_ID="$2"
      shift 2
      ;;
    --close-entry)
      CLOSE_ENTRY_ID="$2"
      shift 2
      ;;
    --branch)
      EXISTING_BRANCH="$2"
      shift 2
      ;;
    --session-type)
      SESSION_TYPE="$2"
      shift 2
      ;;
    --daemon)
      DAEMON_MODE=true
      shift
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      echo "Usage: runner.sh --brief-id <id> [--branch <name>] [--session-type <type>]" >&2
      echo "       runner.sh --daemon" >&2
      echo "       runner.sh --close-entry <id>" >&2
      exit 1
      ;;
  esac
done

# Validate mode: the three modes are mutually exclusive
if [ "$DAEMON_MODE" = true ] && [ -n "$BRIEF_ID" ]; then
  echo "ERROR: --daemon and --brief-id are mutually exclusive" >&2
  exit 1
fi
if [ -n "$CLOSE_ENTRY_ID" ] && { [ "$DAEMON_MODE" = true ] || [ -n "$BRIEF_ID" ]; }; then
  echo "ERROR: --close-entry cannot be combined with --daemon or --brief-id" >&2
  exit 1
fi

# Single-shot mode requires --brief-id
if [ "$DAEMON_MODE" = false ] && [ -z "$CLOSE_ENTRY_ID" ] && [ -z "$BRIEF_ID" ]; then
  echo "ERROR: --brief-id is required (or use --daemon for queue mode, --close-entry to close one entry)" >&2
  exit 1
fi

# Validate config file exists
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

# Bootstrap config.local.yaml if absent — ensures the daemon's runtime toggle
# uses the gitignored override file so the tracked config.yaml is never
# modified at runtime (Decision 0017).
if [ ! -f "$CONFIG_LOCAL_FILE" ]; then
  printf 'runner:\n  enabled: true\n' > "$CONFIG_LOCAL_FILE"
fi

# ============================================================
# Operator notes — the two runner-side delivery routes
# ============================================================

# Drains an entry's pending operator notes and prints them as a markdown
# section (Decision t-0055 clause 13). Prints nothing when there is nothing
# pending, so callers can append the result unconditionally.
#
# This is the route for a note that was written while the entry was NOT
# running: the queued case (the section is appended to the assembled prompt)
# and the stopped case (appended to the resume message). The third route —
# a note written to a session already running — is operator-notes.sh.
#
# Delivered notes are MOVED to notes/delivered/ with a .at sidecar carrying
# delivery time, matching what operator-notes.sh does, so `notes-entry`
# reports one history whichever route delivered a note. No cap here: unlike
# the hook, this runs once per session start, and a brief's whole backlog of
# operator context belongs in its opening prompt.
#
# Fails open and silent at every step. A note that cannot be read must not
# stop the entry from running.
_drain_operator_notes() {
  local entry_id="$1"
  local notes_dir body="" count=0
  notes_dir="$(get_control_dir "$entry_id" 2>/dev/null)/notes" || return 0
  [ -d "$notes_dir" ] || return 0

  local note_file base epoch sent now text
  for note_file in "$notes_dir"/*.md; do
    [ -f "$note_file" ] || continue
    text="$(cat "$note_file" 2>/dev/null)" || continue
    [ -n "$text" ] || continue

    base="${note_file##*/}"
    epoch="${base%%-*}"
    sent="$(epoch_to_iso "$epoch" 2>/dev/null)" || sent=""
    [ -n "$sent" ] || sent="$base"

    mkdir -p "$notes_dir/delivered" 2>/dev/null || continue
    mv "$note_file" "$notes_dir/delivered/$base" 2>/dev/null || continue
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || now=""
    printf '%s\n' "$now" > "$notes_dir/delivered/$base.at" 2>/dev/null || true

    body="${body}- (${sent}) ${text}
"
    count=$((count + 1))
  done

  [ "$count" -gt 0 ] || return 0
  printf '## Operator notes

The operator sent %s note(s) for this entry. Treat them as operator direction
for this brief. Follow them within the brief'"'"'s scope; if one conflicts with the
brief or a gate, escalate rather than guess. Governance gates still apply.
Record each note and what you did about it in the session log.

%s' "$count" "$body"
}

# ============================================================
# Parent task section — context a follow-up inherits (t-0055 clause 14)
# ============================================================

# --- `## Parent task` markdown for entry $1, whose parent is $2 ---
# Emits nothing (success, empty output) when the entry is not a follow-up or
# the parent can no longer be read. Fails open at every step for the same
# reason _drain_operator_notes does: missing context must not stop the entry.
#
# This is the context half of the linkage. The ordering half is the dequeue
# guard and the branch half is _followup_resolve_branch — all three read the
# same `follow_up_of` pointer, none of them stores a second copy of it.
#
# Clobbers _QE_*, so callers must have captured what they need first.
_build_parent_task_section() {
  local entry_id="$1" parent_id="$2"
  [ -n "$parent_id" ] || return 0

  local pfile="" ptitle="" pgoal="" pstatus="" pbranch="" pbrief="" perror="" prange=""
  pfile=$(_find_entry_file "$parent_id" 2>/dev/null) || pfile=""
  if [ -n "$pfile" ] && _load_queue_entry "$pfile" 2>/dev/null; then
    pstatus="${_QE_STATUS:-}"
    pbranch="${_QE_BRANCH:-}"
    pbrief="${_QE_BRIEF_PATH:-}"
    perror="${_QE_ERROR_LOG:-}"
  fi

  # Title and goal come from the parent's brief, not from the entry: an entry
  # has no prose. Same two headings `follow-up-draft` reads, so the draft the
  # operator edited and the prompt the agent receives describe one parent.
  if [ -n "$pbrief" ] && [ -f "$pbrief" ]; then
    local line in_goal=false
    while IFS= read -r line; do
      case "$line" in
        "# "*)
          [ -n "$ptitle" ] || ptitle="${line#\# }"
          in_goal=false
          ;;
        "## Goal"*|"### Goal"*) in_goal=true ;;
        "#"*) in_goal=false ;;
        "") ;;
        *)
          if [ "$in_goal" = true ] && [ -z "$pgoal" ]; then
            pgoal="$line"
            in_goal=false
          fi
          ;;
      esac
    done < "$pbrief"
  fi

  # The commit range is what the parent actually left on the branch. It only
  # resolves while the branch still exists and is not yet in main: once the
  # branch is merged and sealed the commits are in main's history and
  # `main..<branch>` is empty, which is correct rather than broken — a
  # follow-up of merged work starts from main and has no range to read.
  if [ -n "$pbranch" ] \
     && git -C "$REPO_ROOT" rev-parse --verify --quiet "$pbranch" > /dev/null 2>&1; then
    local n
    n=$(git -C "$REPO_ROOT" rev-list --count "main..$pbranch" 2>/dev/null) || n=""
    case "$n" in
      ''|0|*[!0-9]*) prange="" ;;
      *) prange="main..$pbranch ($n commit(s))" ;;
    esac
  fi

  printf '## Parent task

This entry is a FOLLOW-UP. It extends `%s` rather than replacing it; that
entry'"'"'s work has already landed (or has been abandoned) and is not yours to
redo. Read this section as background, and your own brief as the task.

- Parent entry: `%s` (%s)
- Parent branch: `%s`
' "$parent_id" "$parent_id" "${pstatus:-unknown}" "${pbranch:-unresolved}"

  [ -n "$ptitle" ] && printf -- '- Parent title: %s\n' "$ptitle"
  [ -n "$pbrief" ] && printf -- '- Parent brief: `%s`\n' "$pbrief"
  [ -n "$prange" ] && printf -- '- Commits it left: `%s`\n' "$prange"
  [ -n "$perror" ] && printf -- '- Recorded outcome: %s\n' "$perror"
  [ -n "$pgoal" ] && printf -- '- Its goal was: %s\n' "$pgoal"

  printf '
If your brief conflicts with what the parent actually did, escalate rather
than silently reversing it — the parent'"'"'s result is a governed outcome, not a
draft. Entry: `%s`.
' "$entry_id"
}

# ============================================================
# Heartbeat — background timestamp writer for running entries
# ============================================================

_start_heartbeat() {
  local entry_id="$1"
  local qdir
  qdir=$(_queue_dir)
  local hb_file="$qdir/running/${entry_id}.heartbeat"
  local interval
  interval=$(_parse_config_field "runner" "heartbeat_interval")
  interval="${interval:-30}"

  (
    while true; do
      date -u +%Y-%m-%dT%H:%M:%SZ > "${hb_file}.tmp" 2>/dev/null \
        && mv "${hb_file}.tmp" "$hb_file" 2>/dev/null || true
      # Also update the health file to keep it current during long sessions
      _write_health "running" 2>/dev/null || true
      sleep "$interval"
    done
  ) &
  _HEARTBEAT_PID=$!
}

_stop_heartbeat() {
  if [ -n "$_HEARTBEAT_PID" ]; then
    kill "$_HEARTBEAT_PID" 2>/dev/null || true
    wait "$_HEARTBEAT_PID" 2>/dev/null || true
    _HEARTBEAT_PID=""
  fi
}

# --- Crash cleanup handler (audit 2.2/3.1/3.3) ---
# On any exit (success, failure, SIGTERM), clean up session state, heartbeat
# files, and the session registry. Without this, runner crashes leave orphaned
# state files that block new sessions.
_runner_crash_cleanup() {
  # Clean heartbeat files (3.3: survive EXIT trap)
  local _qdir
  _qdir=$(_queue_dir 2>/dev/null) || true
  if [ -n "$_qdir" ] && [ -d "$_qdir/running" ]; then
    rm -f "$_qdir/running/"*.heartbeat 2>/dev/null || true
  fi
  # Release a held group worktree lock (Decision 0054).
  # Keyed on _CURRENT_GROUP_NAME alone, NOT on _CURRENT_WORKTREE_IS_GROUP: the
  # lock is acquired in _resolve_group_worktree, which runs before the worktree
  # block that sets _CURRENT_WORKTREE_IS_GROUP. A crash in that window would
  # otherwise skip this release. (A dead holder's lock is broken on the next
  # acquire anyway, so this is belt-and-suspenders — but it makes "the lock is
  # released on every crash path" true rather than merely self-correcting.)
  if [ -n "$_CURRENT_GROUP_NAME" ]; then
    release_group_worktree_lock "$_CURRENT_GROUP_NAME" "$$" "" 2>/dev/null || true
    _CURRENT_GROUP_NAME=""
  fi
  # Clean up worktree if one was created (Decision 0033).
  # Task group worktrees are exempt (Decision 0054): a crashed brief leaves its
  # worktree in place so the operator can inspect what the crash left behind,
  # and so the restart reuses the same tree.
  if [ "$_CURRENT_WORKTREE_IS_GROUP" = true ]; then
    if [ -n "$_CURRENT_WORKTREE_DIR" ]; then
      echo "Task group worktree '$_CURRENT_WORKTREE_DIR' left in place for inspection (Decision 0054)" >&2
    fi
    _CURRENT_WORKTREE_DIR=""
    _CURRENT_WORKTREE_IS_GROUP=false
  elif [ -n "$_CURRENT_WORKTREE_DIR" ] && [ -d "$_CURRENT_WORKTREE_DIR" ]; then
    remove_session_worktree "$_CURRENT_WORKTREE_DIR" "${_RESULT_BASELINE:-}" "${_CURRENT_ENTRY_ID:-}" "failed:runner-crash"
    _CURRENT_WORKTREE_DIR=""
  fi
  # Clean session state (3.1: runner_external_cleanup on crash)
  # With REPO_OS_SESSION_ID set, cleanup targets the per-session state dir.
  # Without it (legacy), fall back to .session-id file check.
  if [ -n "${REPO_ROOT:-}" ]; then
    if [ -n "${REPO_OS_SESSION_ID:-}" ] || [ -f "$REPO_ROOT/.claude/.session-id" ]; then
      runner_external_cleanup "$REPO_ROOT" "${_CURRENT_ENTRY_ID:-}" "crash" "${_RESULT_BASELINE:-}" 2>/dev/null || true
    fi
  fi
}

# Clean up on exit (guard each function to prevent cascade under set -euo pipefail)
trap '_stop_heartbeat || true; _stop_stop_watcher || true; _runner_crash_cleanup || true' EXIT

# ============================================================
# Circuit breaker — 3 consecutive global failures pauses daemon
# ============================================================

_CB_FILE=""
_cb_file() {
  if [ -z "$_CB_FILE" ]; then
    _CB_FILE="$(_queue_dir)/.circuit-breaker"
  fi
  printf '%s' "$_CB_FILE"
}

_circuit_breaker_tripped() {
  local cb_file
  cb_file=$(_cb_file)
  [ -f "$cb_file" ] || return 1
  local count
  count=$(grep '^consecutive_failures:' "$cb_file" 2>/dev/null \
    | sed 's/.*: *//' | tr -d '[:space:]' | head -1)
  # A corrupt count fails CLOSED, matching the epoch policy below. Previously
  # `[ xyz -ge 3 ]` exited 2, so an unreadable breaker file reported "not
  # tripped" and the daemon kept pulling entries — the opposite direction from
  # every other malformed-input path here, and the one that turns a hard stop
  # into an unbounded retry loop. A file that exists but cannot be read is not
  # evidence that nothing is wrong. `reset-breaker` is the way out.
  case "$count" in
    '') return 1 ;;                                  # no count line: not tripped
    *[!0-9]*)
      echo "Circuit breaker file has an unreadable consecutive_failures value ('$count') — treating the breaker as TRIPPED. Clear it with 'queue-cli.sh reset-breaker'." >&2
      return 0
      ;;
  esac
  [ "$count" -ge 3 ] || return 1

  # Cooldown. Before this, a tripped breaker had NO way out: nothing read the
  # timestamp, no command reset it, and the only reset path runs on a successful
  # entry — which the breaker itself prevents. On 2026-10-20 that left the daemon
  # wedged from 04:08 until the counter file was deleted by hand.
  #
  # Once the window has passed the breaker reports "not tripped" so ONE entry can
  # be attempted. The counter is deliberately NOT cleared: if that probe fails,
  # _circuit_breaker_increment bumps the count and writes a fresh timestamp, so
  # the breaker re-trips for another full window. That gives one probe per
  # window rather than the retry loop a counter reset would produce. Only a
  # SUCCESS clears the file, via the existing _circuit_breaker_reset.
  local cooldown
  cooldown=$(_parse_config_field "runner" "circuit_breaker_cooldown_seconds" 2>/dev/null || echo "")
  cooldown="${cooldown:-1800}"
  case "$cooldown" in ''|*[!0-9]*) cooldown=1800 ;; esac
  [ "$cooldown" -gt 0 ] || return 0   # 0 disables the cooldown — stay tripped

  # The epoch field is written alongside the ISO timestamp precisely so this
  # comparison needs no date parsing: `date -d` is GNU-only and `date -j` is
  # BSD-only, and this repo targets bash 3.2 on macOS.
  local failed_epoch
  failed_epoch=$(grep '^last_failure_epoch:' "$cb_file" 2>/dev/null \
    | sed 's/.*: *//' | tr -d '[:space:]' | head -1)
  # Missing or unparseable: stay tripped. Fails closed, not open — a breaker
  # written by an older runner has no epoch field and must not silently expire.
  case "$failed_epoch" in ''|*[!0-9]*) return 0 ;; esac

  local now_epoch elapsed
  now_epoch=$(date +%s)
  elapsed=$(( now_epoch - failed_epoch ))
  if [ "$elapsed" -ge "$cooldown" ]; then
    echo "Circuit breaker cooldown elapsed (${elapsed}s >= ${cooldown}s) — allowing ONE probe entry. The failure count stays at ${count}: if the probe fails the breaker re-trips for another ${cooldown}s. Diagnose with 'queue-cli.sh review', or clear it with 'queue-cli.sh reset-breaker'." >&2
    return 1
  fi
  return 0
}

_circuit_breaker_increment() {
  local cb_file
  cb_file=$(_cb_file)
  local count=0
  if [ -f "$cb_file" ]; then
    # `|| true`: this function is called as a plain command from the daemon
    # loop's failure arm, so errexit is live (unlike _circuit_breaker_tripped,
    # which is always called from an `if`). A breaker file with no
    # `consecutive_failures:` line makes grep exit 1, pipefail propagates it,
    # and the daemon dies while recording a failure — the count guard below
    # would never be reached.
    count=$(grep '^consecutive_failures:' "$cb_file" 2>/dev/null \
      | sed 's/.*: *//' | tr -d '[:space:]' | head -1) || true
    count="${count:-0}"
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  count=$((count + 1))
  local ts epoch
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # The epoch is written for _circuit_breaker_tripped's cooldown arithmetic;
  # the ISO timestamp stays because it is what operators read. Parsing the ISO
  # form back is not portable (`date -d` GNU-only, `date -j -f` BSD-only), so
  # the value is recorded in both shapes rather than converted later.
  epoch=$(date +%s)
  printf 'consecutive_failures: %s\nlast_failure_at: %s\nlast_failure_epoch: %s\n' \
    "$count" "$ts" "$epoch" \
    > "${cb_file}.tmp"
  mv "${cb_file}.tmp" "$cb_file"
}

_circuit_breaker_reset() {
  local cb_file
  cb_file=$(_cb_file)
  rm -f "$cb_file" 2>/dev/null || true
}

# Health check functions sourced from lib/health-check.sh above.
# Provides: _health_file, _write_health, _remove_health, health_status, health_is_alive

# ============================================================
# Startup crash recovery — detect and clean orphaned state
# ============================================================

_startup_crash_recovery() {
  local recovered=0

  # 1. Stale health file — prior daemon crashed without cleanup
  local hf
  hf=$(_health_file)
  if [ -f "$hf" ]; then
    local old_pid
    old_pid=$(grep '^pid:' "$hf" 2>/dev/null | sed 's/.*: *//' | tr -d '[:space:]' | head -1)
    if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
      echo "Startup recovery: stale health file from dead pid $old_pid — removing" >&2
      rm -f "$hf" 2>/dev/null || true
      recovered=$((recovered + 1))
    elif [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      # Another daemon is still running — this shouldn't happen (PID guard catches it)
      echo "WARNING: Health file shows pid $old_pid is still running — aborting startup recovery" >&2
      return 0
    fi
  fi

  # 2. Orphaned running/ entries — no heartbeat or stale heartbeat with dead PID
  local qdir
  qdir=$(_queue_dir)
  if [ -d "$qdir/running" ]; then
    local entry_file
    for entry_file in "$qdir/running"/*.yaml; do
      [ -f "$entry_file" ] || continue
      local entry_id
      entry_id=$(basename "$entry_file" .yaml)
      local hb_file="$qdir/running/${entry_id}.heartbeat"

      # Determine if entry is truly orphaned or legitimately running
      local should_recover=false
      if [ ! -f "$hb_file" ]; then
        # No heartbeat at all — definitely orphaned
        should_recover=true
      else
        # Heartbeat exists — check if the writing process is still alive.
        # At startup, no heartbeat writer from THIS daemon exists yet,
        # so a fresh heartbeat implies another process wrote it.
        local hb_ts_raw
        hb_ts_raw=$(cat "$hb_file" 2>/dev/null || true)
        if [ -z "$hb_ts_raw" ]; then
          should_recover=true
        else
          local hb_epoch_sr now_epoch_sr hb_age_sr
          hb_epoch_sr=$(_iso_to_epoch "$hb_ts_raw" 2>/dev/null || echo "0")
          now_epoch_sr=$(date +%s)
          hb_age_sr=$((now_epoch_sr - hb_epoch_sr))
          # If heartbeat is older than 1 hour, the writer is dead
          if [ "$hb_age_sr" -gt 3600 ]; then
            should_recover=true
          else
            # Recent heartbeat with no live daemon — fail-closed: write escalation
            echo "WARNING: Running entry $entry_id has recent heartbeat (${hb_age_sr}s old) — writing escalation instead of recovering" >&2
            local esc_dir_ambig="$REPO_ROOT/.claude/.automation/escalations"
            mkdir -p "$esc_dir_ambig" 2>/dev/null || true
            local esc_id_ambig="esc-ambiguous-$(date +%Y%m%d-%H%M%S)"
            {
              printf 'escalation:\n'
              printf '  id: "%s"\n' "$esc_id_ambig"
              printf '  queue_entry_id: "%s"\n' "$entry_id"
              printf '  type: "gate-failure"\n'
              printf '  severity: "blocking"\n'
              printf '  phase_at_exit: "init"\n'
              printf '  tag_at_exit: "agent"\n'
              printf '  message: "Ambiguous state: running entry has recent heartbeat (%ss) but no live daemon PID"\n' "$hb_age_sr"
              printf '  context: "entry_id: %s, heartbeat_age: %ss"\n' "$entry_id" "$hb_age_sr"
              printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
              printf '  resolved: false\n'
              printf '  resolution: ""\n'
            } > "$esc_dir_ambig/${esc_id_ambig}.yaml" 2>/dev/null || true
            should_recover=false
          fi
        fi
      fi

      if [ "$should_recover" = true ]; then
        echo "Startup recovery: orphaned running entry $entry_id — transitioning to failed" >&2
        if acquire_queue_lock; then
          _load_queue_entry "$entry_file"
          _QE_STATUS="failed"
          _QE_ERROR_LOG="orphaned entry — recovered at daemon startup"
          _QE_COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          _QE_UPDATED_AT="$_QE_COMPLETED_AT"
          _write_queue_entry "$qdir/failed/${entry_id}.yaml"
          rm -f "$entry_file"
          rm -f "$hb_file" 2>/dev/null || true
          # Propagate failure to work order if entry belongs to one
          if [ -n "$_QE_WORK_ORDER_ID" ]; then
            _sr_wo_status=$(wo_check_completion "$_QE_WORK_ORDER_ID" 2>/dev/null) || {
              echo "WARNING: wo_check_completion failed for work order $_QE_WORK_ORDER_ID after startup recovery of entry $entry_id" >&2
            }
            case "$_sr_wo_status" in
              failed)
                review_log_append "work-order-failed" "$_QE_WORK_ORDER_ID" "" \
                  "Work order $_QE_WORK_ORDER_ID failed — orphaned entry $entry_id recovered at startup. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                ;;
              escalated)
                review_log_append "work-order-escalated" "$_QE_WORK_ORDER_ID" "" \
                  "Work order $_QE_WORK_ORDER_ID escalated — orphaned entry $entry_id recovered at startup. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                ;;
              completed)
                review_log_append "work-order-completed" "$_QE_WORK_ORDER_ID" "" \
                  "Work order $_QE_WORK_ORDER_ID completed — all children terminal after startup recovery of $entry_id" 2>/dev/null || true
                ;;
              "")
                echo "WARNING: wo_check_completion returned empty status for work order $_QE_WORK_ORDER_ID (startup recovery, entry $entry_id)" >&2
                ;;
            esac
          fi
          _rebuild_queue_index || true
          release_queue_lock
          recovered=$((recovered + 1))
        else
          echo "WARNING: Could not acquire lock for startup recovery of $entry_id — writing escalation" >&2
          local esc_dir="$REPO_ROOT/.claude/.automation/escalations"
          mkdir -p "$esc_dir" 2>/dev/null || true
          local esc_id="esc-startup-$(date +%Y%m%d-%H%M%S)"
          {
            printf 'escalation:\n'
            printf '  id: "%s"\n' "$esc_id"
            printf '  queue_entry_id: "%s"\n' "$entry_id"
            printf '  type: "gate-failure"\n'
            printf '  severity: "blocking"\n'
            printf '  phase_at_exit: "init"\n'
            printf '  tag_at_exit: "agent"\n'
            printf '  message: "Startup crash recovery could not acquire queue lock for orphaned entry"\n'
            printf '  context: "entry_id: %s, lock_file: %s"\n' "$entry_id" "$qdir/.queue-lock"
            printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '  resolved: false\n'
            printf '  resolution: ""\n'
          } > "$esc_dir/${esc_id}.yaml" 2>/dev/null || true
        fi
      fi
    done
  fi

  # 3. Stale lock file — queue lock with no holder
  local lock_file="$qdir/.queue-lock"
  if [ -f "$lock_file" ]; then
    # flock-based locks are released on process death, but the file may remain
    # Try to acquire and immediately release to verify it's not stuck
    if acquire_queue_lock 2>/dev/null; then
      release_queue_lock
    else
      echo "WARNING: Stale queue lock detected at startup — cannot acquire" >&2
      echo "Investigate $lock_file before proceeding" >&2
    fi
  fi

  # 4. Orphaned session state — DIAGNOSTIC ONLY. Deliberately does not mutate.
  #
  # This step used to call `runner_external_cleanup` whenever
  # `.claude/.session-id` existed. Two things were wrong with that:
  #
  #   - It had NO liveness predicate. The condition was the mere existence of a
  #     file the glossary documents as persistent and immune, so it fired on
  #     essentially every daemon start.
  #   - `runner_external_cleanup` is a session CLOSE routine, not an orphan
  #     sweep: it unregisters the session, deletes its state directory via
  #     `cleanup_session_files`, and writes dirty-tree and unsealed-branch
  #     escalations. Called with an empty entry id it resolves the session
  #     itself through `get_session_id` — i.e. whichever session is CURRENT.
  #
  # So starting the daemon closed the live interactive session. On 2026-10-21
  # that deleted this very session's `.claude/.state/wt-sessions/<id>/` and its
  # registry entry, taking its plan approval and every recorded verdict with
  # them; `write-guard.sh` then refused every edit with "No phase-state" and the
  # session could not complete its own close. A daemon start must never be able
  # to brick a concurrent human session.
  #
  # The legitimate intent — clean up state left behind by a session that
  # actually died — is step 5's job. Adding a liveness predicate here would
  # have produced a second, independently-maintained notion of "live" sitting
  # six lines above an existing one, so the fix is a deletion.
  #
  # Being precise about what step 5 does guarantee, because an earlier version
  # of this comment overclaimed it: `sweep_stale_sessions` reaps per-process
  # sidecars on the decisive sidecar test, and removes a registry entry when the
  # recorded pid is dead. Its 24h and TTL arms used to remove the entry
  # "regardless of PID" — which took the state directory with it, since the
  # orphaned-state-dir loop keys on a missing registry entry. That is what
  # actually destroyed a live ~16h session's state on 2026-10-21, and both arms
  # are now gated on pid liveness. The deletion site itself — the orphaned
  # state-dir loop — is gated too, on the per-process sidecar and on
  # REPO_OS_SESSION_ID, so a live session keeps its state even if something else
  # has already removed its registry entry. That belt-and-braces matters because
  # the call below passes no exclude_sid and cannot: the daemon does not register
  # itself and has no way to name a concurrent interactive session.
  #
  # Known not covered by step 5, deliberately (see known-issues): repo-level
  # operational files that `cleanup_session_files` removes, and the out-of-tree
  # evidence manifest. A hard-killed session leaves those behind.
  local session_id_file="$REPO_ROOT/.claude/.session-id"
  if [ -f "$session_id_file" ]; then
    echo "Startup recovery: session-id file present — leaving it to the stale-session sweep (step 5). No state is touched here." >&2
  fi

  # 5. Sweep stale session registry entries (C7 orphan TTL patch)
  # Owns orphaned session state outright, since step 4 no longer mutates.
  sweep_stale_sessions || true

  if [ "$recovered" -gt 0 ]; then
    echo "Startup recovery complete: $recovered item(s) recovered" >&2
  fi
}

# ============================================================
# Pre-flight checks
# ============================================================

# Verify queue and repo are on the same filesystem (required for atomic mv).
_check_same_filesystem() {
  local qdir
  qdir=$(_queue_dir)
  mkdir -p "$qdir" 2>/dev/null || true
  local repo_dev queue_dev
  # Audit C4: cross-platform stat for device ID
  case "${OSTYPE:-}" in
    darwin*)
      repo_dev=$(stat -f %d "$REPO_ROOT" 2>/dev/null || echo "unknown_r")
      queue_dev=$(stat -f %d "$qdir" 2>/dev/null || echo "unknown_q")
      ;;
    *)
      repo_dev=$(stat -c %d "$REPO_ROOT" 2>/dev/null || echo "unknown_r")
      queue_dev=$(stat -c %d "$qdir" 2>/dev/null || echo "unknown_q")
      ;;
  esac
  if [ "$repo_dev" != "$queue_dev" ]; then
    echo "ERROR: Queue ($qdir) and repo ($REPO_ROOT) are on different filesystems" >&2
    echo "Atomic mv requires same filesystem. Aborting." >&2
    return 1
  fi
}

# Warn about stale running entries (heartbeat older than 24h).
# Returns 1 if stale lock found (caller should break loop).
_check_stale_locks() {
  local qdir
  qdir=$(_queue_dir)
  local hb_file
  for hb_file in "$qdir/running"/*.heartbeat; do
    [ -f "$hb_file" ] || continue
    local hb_ts
    hb_ts=$(cat "$hb_file" 2>/dev/null || true)
    [ -z "$hb_ts" ] && continue

    # Parse ISO 8601 to epoch (portable via _iso_to_epoch from _analytics-helper.sh)
    local hb_epoch now_epoch age_hours
    hb_epoch=$(_iso_to_epoch "$hb_ts" 2>/dev/null)
    [ -z "$hb_epoch" ] && hb_epoch=0
    now_epoch=$(date +%s)
    if [ "$hb_epoch" -gt 0 ]; then
      age_hours=$(( (now_epoch - hb_epoch) / 3600 ))
      if [ "$age_hours" -ge 24 ]; then
        local stale_id
        stale_id=$(basename "$hb_file" .heartbeat)
        echo "WARNING: Stale lock detected — entry $stale_id heartbeat is ${age_hours}h old" >&2
        echo "Possible orphaned runner. Investigate before restarting." >&2
        return 1
      fi
    fi
  done
}

# ============================================================
# Task group branch seal guard (Decision 0013)
# ============================================================
# Determines whether an entry is the final entry in a task group work order.
# Non-final entries must NOT have their branch sealed (recorded in closed-branches).
# Fail-open: on error, returns 0 (seal the branch — safe default).
#
# Arguments:
#   $1 — brief_id (queue entry ID)
#   $2 — work_order_id (empty for non-task-group entries)
# Returns: 0 if this is the final entry (seal OK), 1 if siblings remain (don't seal)
#
# The body moved to queue_is_final_taskgroup_entry in lib/queue-manager.sh
# (t-0057) so queue-cli.sh can refuse an operator `merge` on a non-final brief
# using the SAME predicate the runner seals on. This wrapper is kept because
# every call site here, the parity contract in RUNNER-PARITY.md and the blocker
# playbook all name it. Behaviour is unchanged, fail-open default included.
_is_final_taskgroup_entry() {
  queue_is_final_taskgroup_entry "$1" "${2:-}"
}

# ============================================================
# Task group worktree resolution (Decision 0054)
# ============================================================
# A sequential task group gets ONE worktree for the whole life of its branch:
# brief 1 creates `.worktrees/tg-<group>`, briefs 2..N reuse it. Standalone
# entries keep the per-session worktree of Decision 0033; parallel task groups
# keep the per-brief branches and worktrees of Decision 0032.
#
# Outputs (globals, reset on every call):
#   _GWT_GROUP          group name ("" when not applicable)
#   _GWT_DIR            resolved group worktree path
#   _GWT_REUSE          true when an existing worktree is being reused, in which
#                       case the caller MUST skip branch_manager_setup
#   _GWT_BRANCH         sanitized group branch
#   _GWT_BLOCK_OUTCOME  _RESULT_OUTCOME value to report when blocked
_GWT_GROUP=""
_GWT_DIR=""
_GWT_REUSE=false
_GWT_BRANCH=""
_GWT_BLOCK_OUTCOME=""

# --- Write a group-worktree escalation ---
# Uses the existing `governance-block` type and the `esc-dirty-tree-` /
# `esc-group-worktree-` id conventions rather than growing the escalation type
# enum: the schema's 10 types already cover "hook enforcement prevented action",
# and state-manager.sh already writes a dirty-tree escalation under that type.
# Arguments:
#   $1 — escalation id prefix
#   $2 — brief_id (queue entry id)
#   $3 — message
#   $4 — context
_write_group_worktree_escalation() {
  local prefix="$1"
  local brief_id="$2"
  local message="$3"
  local context="$4"
  local esc_dir="$REPO_ROOT/.claude/.automation/escalations"
  mkdir -p "$esc_dir" 2>/dev/null || true
  local esc_id="${prefix}-$(date +%Y%m%d-%H%M%S)"
  {
    printf 'escalation:\n'
    printf '  id: "%s"\n' "$esc_id"
    printf '  queue_entry_id: "%s"\n' "$brief_id"
    printf '  type: "governance-block"\n'
    printf '  severity: "blocking"\n'
    printf '  phase_at_exit: "init"\n'
    printf '  tag_at_exit: "operator"\n'
    printf '  message: "%s"\n' "$message"
    printf '  context: "%s"\n' "$context"
    printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  resolved: false\n'
    printf '  resolution: ""\n'
  } > "$esc_dir/${esc_id}.yaml" 2>/dev/null || true
  echo "$esc_id"
}

# --- Does this brief belong to a sequential task group? ---
# Parallel groups are out of scope for Decision 0054 — they keep per-brief
# branches (Decision 0032), so a shared group worktree would be wrong for them.
# Arguments:
#   $1 — brief path (repo-relative or absolute; may be empty)
# Returns: 0 sequential, 1 parallel or undeterminable
_brief_is_sequential_group() {
  local brief_path="${1:-}"
  [ -n "$brief_path" ] || return 1
  local resolved=""
  if [ -f "$REPO_ROOT/$brief_path" ]; then
    resolved="$REPO_ROOT/$brief_path"
  elif [ -f "$brief_path" ]; then
    resolved="$brief_path"
  else
    return 1
  fi
  # Absence of an Execution: line means sequential (the documented default).
  #
  # Both brief formats must match. The canonical one the templates emit is
  # `- **Execution:** parallel`; older briefs use a bare `Execution: parallel`.
  # The original pattern allowed the leading "- " but not the bold markers, so a
  # CANONICAL parallel brief fell through as sequential and would have been
  # handed a shared group worktree — precisely what Decision 0032 forbids, and a
  # race between parallel briefs on one working tree. Same root cause as the
  # `_extract_group_name` defect fixed alongside this.
  # Scoped to the ### Task Group section first, for the same reason
  # _extract_group_name is: a stray phrase elsewhere in the brief must not
  # decide execution mode.
  #
  # But the fallback is deliberately file-wide, NOT scope-only, because the two
  # error directions are not equally costly. Missing a `parallel` marker
  # (false negative) hands a parallel group a SHARED worktree and races its
  # briefs against one working tree — the exact harm Decision 0032 exists to
  # prevent. Spuriously reading `parallel` (false positive) merely gives a
  # sequential group per-session worktrees, i.e. the pre-t-0054 behaviour.
  # So when the section carries no Execution line at all, fall back to scanning
  # the whole brief: being permissive toward "parallel" is the fail-safe side.
  local _tg_section
  _tg_section=$(sed -n '/^### Task Group$/,/^###/p' "$resolved" 2>/dev/null || true)
  local _exec_pat='^[[:space:]]*(-[[:space:]]*)?(\*\*)?Execution:?(\*\*)?:?[[:space:]]*'
  if printf '%s\n' "$_tg_section" | grep -qE "${_exec_pat}parallel"; then
    return 1
  fi
  if printf '%s\n' "$_tg_section" | grep -qE "${_exec_pat}sequential"; then
    return 0
  fi
  # No Execution line in the section — scan the whole brief (legacy briefs).
  if grep -qE "${_exec_pat}parallel" "$resolved" 2>/dev/null; then
    return 1
  fi
  return 0
}

# --- Resolve (create-or-reuse) a sequential task group's worktree ---
# Arguments:
#   $1 — session_type
#   $2 — brief_path
#   $3 — existing_branch (the group branch)
#   $4 — brief_id (for escalation context)
# Returns: 0 applicable and ready, 1 not applicable (standalone / parallel),
#          2 blocked — caller must abort the entry without launching
_resolve_group_worktree() {
  local session_type="$1"
  local brief_path="$2"
  local existing_branch="$3"
  local brief_id="$4"

  _GWT_GROUP=""
  _GWT_DIR=""
  _GWT_REUSE=false
  _GWT_BRANCH=""
  _GWT_BLOCK_OUTCOME=""

  # Only sequential task group entries with a real group branch qualify.
  [ "$session_type" = "taskgroup" ] || return 1
  [ -n "$existing_branch" ] || return 1
  [ "${REPO_OS_WORKTREE_ISOLATE:-1}" != "0" ] || return 1
  _brief_is_sequential_group "$brief_path" || return 1

  local group
  group=$(_extract_group_name "$brief_path" 2>/dev/null || true)
  if [ -z "$group" ]; then
    # No group name means no stable worktree identity. Fall back to the
    # per-session worktree rather than inventing one — correct, just without
    # the brief-to-brief carry-over.
    echo "WARNING: Task group entry $brief_id has no 'Group:' field — falling back to a per-session worktree (Decision 0054)" >&2
    return 1
  fi

  local wt_dir
  wt_dir=$(group_worktree_path "$group") || return 1
  _GWT_GROUP="$group"
  _GWT_DIR="$wt_dir"
  _GWT_BRANCH=$(sanitize_branch_name "$existing_branch")

  # --- Single occupant (Decision 0054) ---
  # Blocking, unlike the registry's advisory task-group overlap warning: a
  # shared worktree cannot tolerate two concurrent sessions the way a shared
  # branch across sequential briefs can.
  local lock_rc=0
  acquire_group_worktree_lock "$group" "$$" "${REPO_OS_SESSION_ID:-}" || lock_rc=$?
  if [ "$lock_rc" -ne 0 ]; then
    local lock_dir holder_pid holder_sid esc_id
    lock_dir=$(_group_worktree_lock_dir "$group" 2>/dev/null || echo "")
    holder_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "unknown")
    holder_sid=$(cat "$lock_dir/session_id" 2>/dev/null || echo "unknown")
    esc_id=$(_write_group_worktree_escalation "esc-group-worktree-locked" "$brief_id" \
      "Task group worktree already occupied — only one session may run in a group worktree at a time" \
      "group: $group, worktree: $wt_dir, holder_pid: $holder_pid, holder_session: $holder_sid")
    echo "ERROR: Group worktree for '$group' is occupied (holder pid $holder_pid) — escalation $esc_id" >&2
    _GWT_BLOCK_OUTCOME="failed:group-worktree-locked"
    return 2
  fi

  # --- Nothing there yet: brief 1 creates it ---
  if [ ! -d "$wt_dir" ]; then
    return 0
  fi

  # --- Something is there: it must be the group's worktree on the group branch ---
  if ! is_registered_worktree "$wt_dir"; then
    local esc_id
    esc_id=$(_write_group_worktree_escalation "esc-group-worktree-unregistered" "$brief_id" \
      "Path exists at the task group worktree location but git does not know it as a worktree — refusing to recreate it" \
      "group: $group, path: $wt_dir, recovery: inspect the directory, then 'git worktree prune' and remove it by hand")
    echo "ERROR: $wt_dir exists but is not a registered worktree — escalation $esc_id" >&2
    release_group_worktree_lock "$group" "$$" "${REPO_OS_SESSION_ID:-}" || true
    _GWT_BLOCK_OUTCOME="failed:group-worktree-unregistered"
    return 2
  fi

  local wt_branch
  wt_branch=$(group_worktree_branch "$wt_dir")
  if [ "$wt_branch" != "$_GWT_BRANCH" ]; then
    # Fail loudly, never silently recreate: a worktree on an unexpected branch
    # means either two groups collided on one name or someone moved it, and
    # both need a human.
    local esc_id
    esc_id=$(_write_group_worktree_escalation "esc-group-worktree-branch-mismatch" "$brief_id" \
      "Task group worktree is checked out on an unexpected branch — refusing to recreate it" \
      "group: $group, worktree: $wt_dir, expected_branch: $_GWT_BRANCH, actual_branch: ${wt_branch:-detached}")
    echo "ERROR: Group worktree '$wt_dir' is on '${wt_branch:-detached}', expected '$_GWT_BRANCH' — escalation $esc_id" >&2
    release_group_worktree_lock "$group" "$$" "${REPO_OS_SESSION_ID:-}" || true
    _GWT_BLOCK_OUTCOME="failed:group-worktree-branch-mismatch"
    return 2
  fi

  # --- Clean-start guarantee (Decision 0054) ---
  # Each brief must still begin from a clean committed state. Gitignored files
  # are exempt by construction (git status --porcelain omits them) — preserving
  # them is the entire point of reusing the worktree.
  #
  # One exemption (Decision t-0055 clause 7): an entry resuming from an operator
  # stop re-enters the worktree its own session was stopped in, and a force stop
  # kills the child mid-edit, so that worktree is dirty by construction. Refusing
  # it would make "still resumable" false for every forced stop. The exemption is
  # narrow — same entry, same worktree, only on the resume path — so t-0055's
  # "a dirty tree blocks the next brief" still holds for every *other* brief.
  local clean_rc=0 clean_reason=""
  clean_reason=$(check_group_worktree_clean "$wt_dir" "$_GWT_BRANCH") || clean_rc=$?
  if [ "$clean_rc" -ne 0 ] && [ "${_RESUME_WORKTREE_EXEMPT:-false}" = true ]; then
    echo "Group worktree '$wt_dir' is not clean ($clean_reason) — allowed because entry $brief_id is resuming into the worktree its own stop left dirty (Decision t-0055)" >&2
    clean_rc=0
  fi
  if [ "$clean_rc" -ne 0 ]; then
    local esc_id
    esc_id=$(_write_group_worktree_escalation "esc-dirty-tree" "$brief_id" \
      "Task group worktree is not at a clean committed state — brief not started" \
      "group: $group, worktree: $wt_dir, branch: $_GWT_BRANCH, detail: $clean_reason, recovery: commit or discard the changes in the worktree, then requeue the brief")
    echo "ERROR: Group worktree '$wt_dir' is not clean ($clean_reason) — escalation $esc_id" >&2
    release_group_worktree_lock "$group" "$$" "${REPO_OS_SESSION_ID:-}" || true
    _GWT_BLOCK_OUTCOME="failed:group-worktree-dirty"
    return 2
  fi

  # --- Branch freshness, handled worktree-side ---
  # branch_manager_setup()'s own freshness paths cannot run against a branch
  # that is checked out in a live worktree: Case 1 does `git branch -D` and
  # Case 3 does `git checkout`, and git refuses both. Mirror the same three
  # cases here using `git -C <worktree>` instead, leaving branch-manager.sh
  # untouched for every other entry type.
  if git -C "$REPO_ROOT" merge-base --is-ancestor "$_GWT_BRANCH" main 2>/dev/null; then
    # Case 1: fully merged into main — the group is finished (or its branch was
    # merged out from under it). Retire the worktree and let the normal create
    # path rebuild it from current main.
    echo "Group branch $_GWT_BRANCH is an ancestor of main — retiring group worktree and recreating from current main" >&2
    release_group_worktree_lock "$group" "$$" "${REPO_OS_SESSION_ID:-}" || true
    remove_group_worktree "$group" "$$" "${REPO_OS_SESSION_ID:-}" || true
    local relock_rc=0
    acquire_group_worktree_lock "$group" "$$" "${REPO_OS_SESSION_ID:-}" || relock_rc=$?
    if [ "$relock_rc" -ne 0 ]; then
      _GWT_BLOCK_OUTCOME="failed:group-worktree-locked"
      return 2
    fi
    return 0
  fi

  if ! git -C "$REPO_ROOT" merge-base --is-ancestor main "$_GWT_BRANCH" 2>/dev/null; then
    # Case 3: has unique commits but is behind main — rebase inside the
    # worktree. The tree is known clean (checked above), so a rebase is safe.
    echo "Group branch $_GWT_BRANCH is behind main — rebasing inside $wt_dir" >&2
    local rebase_rc=0
    _bm_rebase_onto_main "$wt_dir" || rebase_rc=$?
    if [ "$rebase_rc" -ne 0 ]; then
      # A rebase that cannot be finished mechanically is NOT "continue as-is":
      # the group would build on a stale base, and its final merge would hit the
      # same conflict with the work already done. The abort has been verified
      # (tree clean, no rebase in progress), so the worktree is launchable once
      # an operator rebases the branch by hand — or reset-group-worktree clears it.
      local conflict_files="${_BM_REBASE_CONFLICT_FILES:-none reported}"
      local esc_id
      esc_id=$(_write_group_worktree_escalation "esc-group-worktree-rebase-conflict" "$brief_id" \
        "Task group branch cannot be rebased onto main without manual conflict resolution — brief not started" \
        "group: $group, worktree: $wt_dir, branch: $_GWT_BRANCH, conflicting_files: $conflict_files, detail: $_BM_REBASE_DETAIL, recovery: run 'git -C $wt_dir rebase main', resolve the conflicts, 'git -C $wt_dir add' them and 'git -C $wt_dir rebase --continue', then 'queue-cli.sh reopen-wo <work-order>' (or discard a wedged worktree with 'queue-cli.sh reset-group-worktree $group')")
      echo "ERROR: Group branch $_GWT_BRANCH cannot be rebased onto main — conflicting files: $conflict_files — escalation $esc_id" >&2
      release_group_worktree_lock "$group" "$$" "${REPO_OS_SESSION_ID:-}" || true
      _GWT_BLOCK_OUTCOME="failed:group-worktree-rebase-conflict"
      return 2
    fi
  fi

  # Case 2 (ahead of main, main is ancestor): nothing to do.
  _GWT_REUSE=true
  return 0
}

# --- Message for a branch with commits ahead of main that is not merged ---
# Defect C: the original message ("not merged to main — retrying") was logged
# unconditionally. For a NON-FINAL brief of a sequential task group the unmerged
# branch is the designed state (Decision t-0013 §7: only the final brief merges),
# so "retrying" was wrong. This is message-only: both cases fall through to the
# same normal execution path in the caller.
# Arguments: $1 entry_id, $2 branch, $3 commits_ahead, $4 brief path, $5 work_order_id
# Output: the message on stdout (caller redirects to stderr)
_unmerged_branch_message() {
  local entry_id="$1" branch="$2" ahead="$3" brief_path="${4:-}" wo_id="${5:-}"
  if [ -n "$wo_id" ] && _brief_is_sequential_group "$brief_path" \
     && ! _is_final_taskgroup_entry "$entry_id" "$wo_id"; then
    printf 'Entry %s: branch %s has %s commit(s) ahead of main and is intentionally unmerged — only the final brief of a sequential task group merges; running this brief on the group branch\n' \
      "$entry_id" "$branch" "$ahead"
  else
    printf 'Entry %s: branch %s has %s commit(s) ahead but is not merged to main — retrying\n' \
      "$entry_id" "$branch" "$ahead"
  fi
}

# --- Handle an entry whose work order is escalated or failed ---
# The entry is deferred back to approved/ (retry_count untouched). Once it has been
# deferred max_deferral_cycles times, the work order cannot make progress, so the
# entry AND every approved sibling of the same work order go to blocked/ with ONE
# escalation naming the work order — instead of starving unrelated queue entries.
#
# Defect B: the inline version called queue_block on an entry queue_defer had just
# moved to approved/; queue_block only accepts running/, so it failed under set -e,
# killed the daemon and left the queue lock held. This function never exits, never
# leaves the lock held, and always returns 0 — except when the queue lock cannot be
# taken (returns 1, entry still in running/; the caller ignores it; the entry is not lost but
# stays running until the idle-cycle stale-running warning / `queue-cli.sh recover-entry`).
# Arguments: $1 entry_id, $2 work_order_id, $3 reason ("failed" | "escalated")
_handle_wo_deferral() {
  local entry_id="$1" wo_id="$2" reason="$3"
  local attempts=0 defer_count max_deferrals
  while ! acquire_queue_lock; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 3 ]; then
      echo "ERROR: Lock unavailable for work-order defer ($entry_id)" >&2
      return 1
    fi
    sleep 1
  done

  defer_count=$(queue_defer "$entry_id" "work-order-${reason}") || defer_count=""
  max_deferrals=$(_parse_config_field "runner" "max_deferral_cycles" 2>/dev/null || true)
  max_deferrals="${max_deferrals:-3}"

  if ! [ "$defer_count" -ge "$max_deferrals" ] 2>/dev/null; then
    release_queue_lock || true
    review_log_append "entry-deferred" "$wo_id" "$entry_id" \
      "Entry $entry_id deferred — work order $wo_id $reason (sibling has failed or needs review) [cycle ${defer_count:-?}/$max_deferrals]" 2>/dev/null || true
    return 0
  fi

  # Cap reached: the work order cannot progress. Block this entry and its
  # approved siblings; one escalation covers them all.
  local qdir blocked_ids="" sib failure_entry=""
  qdir=$(_queue_dir)
  _WO_ENTRY_IDS=""
  _WO_FAILURE_ENTRY_ID=""
  _load_work_order "$qdir/work-orders/${wo_id}.yaml" 2>/dev/null || true
  failure_entry="${_WO_FAILURE_ENTRY_ID:-unknown}"
  local block_reason="work order $wo_id $reason (failed entry: $failure_entry) — max_deferral_cycles exceeded ($defer_count/$max_deferrals)"
  local old_ifs="$IFS" sibs="$entry_id"
  [ -n "$_WO_ENTRY_IDS" ] && sibs="$entry_id,$_WO_ENTRY_IDS"
  IFS=','
  # shellcheck disable=SC2086 — intentional word splitting on comma-delimited list
  set -- $sibs
  IFS="$old_ifs"
  for sib in "$@"; do
    case ",$blocked_ids," in *",$sib,"*) continue ;; esac
    [ -f "$qdir/approved/${sib}.yaml" ] || continue
    if queue_block_deferred "$sib" "$block_reason" >/dev/null 2>&1; then
      blocked_ids="${blocked_ids:+$blocked_ids,}$sib"
      rm -f "$qdir/.defer-count-${sib}"
      review_log_append "entry-blocked" "$wo_id" "$sib" \
        "Entry $sib blocked — $block_reason" 2>/dev/null || true
    fi
  done
  release_queue_lock || true

  local esc_id
  esc_id=$(_write_group_worktree_escalation "esc-wo-blocked-${wo_id}" "$entry_id" \
    "Work order $wo_id cannot progress ($reason) — its remaining entries were blocked so they do not starve the queue" \
    "work_order: $wo_id, status: $reason, failed_entry: $failure_entry, blocked_entries: ${blocked_ids:-none}, recovery: fix the cause, then run 'queue-cli.sh reopen-wo $wo_id' to restore the blocked entries") || esc_id=""
  echo "Work order $wo_id is $reason — blocked entries: ${blocked_ids:-none} — escalation ${esc_id:-not written}; recovery: queue-cli.sh reopen-wo $wo_id" >&2
  review_log_append "work-order-${reason}" "$wo_id" "" \
    "Work order $wo_id $reason — remaining entries blocked (deferral cap). Recovery: queue-cli.sh reopen-wo $wo_id" 2>/dev/null || true
  return 0
}

# --- Honour HALT / FORCE-HALT at the launch boundary ---
# The loop-top flag check runs well before an entry is dequeued: a circuit-breaker
# sleep (60s) and a queue-lock acquisition sit between them, so a flag raised in
# that window was never seen and a fresh session started (observed 2026-10-21).
# Narrowing the window does not close it; the flag has to be re-read AFTER the
# decision to run and BEFORE the run begins. This is that read.
#
# If either flag exists the entry — already moved to running/ by queue_dequeue —
# goes back to approved/ via queue_defer in "nocount" mode: retry_count untouched
# (it never ran), and no deferral cycle consumed (a halt is not the entry's
# fault). The flag is left in place so the loop-top handler does its normal
# teardown (HALT: stop; FORCE-HALT: worktree sweep, flag removal, exit).
#
# Residual window (known, deliberately not closed here): _run_single_entry still
# creates the branch/worktree and registers the session before it execs claude,
# and the dirty-tree cleanup runs before this check. A flag raised in that span
# is not seen here; FORCE-HALT is still caught by the watcher's first poll, a
# plain HALT lets that one session finish. Closing it means cleanup logic inside
# the protected launch region.
#
# Never fatal. If the queue lock cannot be taken the entry stays in running/ —
# still not started — and the message names the recovery command.
# Arguments: $1 entry_id
# Returns: 0 if a flag was present (caller must NOT launch), 1 if not (proceed)
_return_entry_if_halted() {
  local entry_id="$1" flag="" attempts=0
  if [ -f "$AUTOMATION_DIR/FORCE-HALT" ]; then
    flag="FORCE-HALT"
  elif [ -f "$AUTOMATION_DIR/HALT" ]; then
    flag="HALT"
  else
    return 1
  fi

  while ! acquire_queue_lock; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 3 ]; then
      echo "ERROR: $flag present but the queue lock is unavailable — entry $entry_id was NOT started and is still in running/ (recover with: queue-cli.sh recover-entry $entry_id)" >&2
      return 0
    fi
    sleep 1
  done
  if queue_defer "$entry_id" "halt-requested" nocount > /dev/null; then
    echo "$flag present — entry $entry_id returned to approved/ unstarted (retry_count and deferral count unchanged)" >&2
  else
    echo "ERROR: $flag present but entry $entry_id could not be returned to approved/ — it was NOT started and may be stranded in running/ (recover with: queue-cli.sh recover-entry $entry_id)" >&2
  fi
  release_queue_lock || true
  return 0
}

# ============================================================
# Model routing — resolve CLI --model flag for claude -p
# ============================================================

# Maps config model names to Claude CLI model IDs.
# Returns the --model flag value for a given session type.
# Precedence: model_routing_overrides[session_type] → model_routing.default → "".
# Empty return means no --model flag (use CLI default).
_resolve_model_for_session() {
  local session_type="$1"
  local model=""

  # Check model_routing_overrides for this session type.
  # _parse_config_field handles local → tracked fallback.
  # model_routing_overrides is a top-level block (not nested under model_routing)
  # because _parse_config_field requires column-0 keys for its sed range pattern.
  model=$(_parse_config_field "model_routing_overrides" "$session_type")

  # Fall back to model_routing.default
  if [ -z "$model" ]; then
    model=$(_parse_config_field "model_routing" "default")
  fi

  # Map config names to CLI model IDs (Claude 5 family — Decision t-0046 Amendment 3)
  # Any cost or latency comparison straddling this change is not comparable:
  # audit/queue-triage (haiku) and standard/taskgroup-merge/eval/eval-cell (sonnet)
  # all moved from Claude 4 generation to Claude 5.
  case "$model" in
    sonnet) printf '%s' "claude-sonnet-5-5" ;;
    haiku)  printf '%s' "claude-haiku-5-5" ;;
    opus)   printf '%s' "claude-opus-5-5" ;;
    "")     printf '' ;;  # no model flag — use CLI default
    *)      printf '%s' "$model" ;;  # pass through unknown values as-is
  esac
}

# ============================================================
# Core execution — run a single entry (used by both modes)
# ============================================================

# --- Global return variables (eliminates subshell stdout loss) ---
# Set by _run_single_entry, read by caller. No subshell = no lost output.
_RESULT_OUTCOME=""
_RESULT_BASELINE=""
_RESULT_SOLO_MODE=""
_RESULT_BRANCH=""
# Path of the patch work-preserver wrote for this entry's uncommitted work, or "".
_RESULT_PRESERVED_PATCH=""
# Close-time re-verification result, recorded on the completed queue entry.
# _RESULT_REVERIFIED:    "" not run (main changed nothing this branch touched)
#                        | "true" rebased and re-verified | "false" did not pass
# _RESULT_OVERLAP_FILES: newline list of the files both sides changed.
_RESULT_REVERIFIED=""
_RESULT_OVERLAP_FILES=""

# --- _start_force_halt_watcher ---
# Makes FORCE-HALT interrupt a RUNNING entry.
#
# The daemon loop checks the FORCE-HALT file only BETWEEN entries (and once more
# at the launch boundary — see _return_entry_if_halted), so an
# operator who force-halted during a long brief had to wait for that brief to
# finish. On 2026-10-20 a running brief had to be stopped by signalling its
# process by hand, which is not something an operator should need to do. This
# watcher polls for the flag and ends the child at the next poll.
#
# It deliberately does NOT delete the flag. The loop handler still needs to see
# it to clean up the worktree and the entry and to stop the daemon; deleting it
# here would silently turn a force-halt into "kill this one brief and carry on".
#
# One helper, called from both launch sites, rather than two inline copies: the
# two branches are already near-duplicates and this keeps the kill ladder in a
# single place. The TTL watchdog stays inline and unchanged — unifying the
# watchers into one supervisor is a follow-up, not something to attempt inside a
# liveness repair, because the kill path is exactly what must stay stable.
#
# Arguments:
#   $1 — child pid to end when the flag appears
# Sets: _FORCE_HALT_WATCHER_PID ("" when no watcher could be started)
_start_force_halt_watcher() {
  local child_pid="$1"
  _FORCE_HALT_WATCHER_PID=""
  [ -n "$child_pid" ] || return 0
  [ -n "${AUTOMATION_DIR:-}" ] || return 0

  (
    while kill -0 "$child_pid" 2>/dev/null; do
      if [ -f "$AUTOMATION_DIR/FORCE-HALT" ]; then
        echo "FORCE-HALT seen while an entry is running — sending SIGTERM to child pid $child_pid" >&2
        kill -TERM "$child_pid" 2>/dev/null || true
        _fhw_waited=0
        while [ "$_fhw_waited" -lt 10 ] && kill -0 "$child_pid" 2>/dev/null; do
          sleep 1
          _fhw_waited=$(( _fhw_waited + 1 ))
        done
        if kill -0 "$child_pid" 2>/dev/null; then
          echo "FORCE-HALT: child pid $child_pid survived SIGTERM for 10s — sending SIGKILL" >&2
          kill -KILL "$child_pid" 2>/dev/null || true
        fi
        exit 0
      fi
      sleep 5
    done
  ) &
  _FORCE_HALT_WATCHER_PID=$!
}

# Generate a lowercase RFC 4122 UUID on stdout, or return 1 if neither source
# is available. `claude --session-id` rejects anything that is not a valid
# UUID, so a malformed value must fail loudly rather than be passed through.
# Decision t-0055.
_generate_uuid() {
  local u=""
  if command -v uuidgen >/dev/null 2>&1; then
    u=$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')
  fi
  if [ -z "$u" ] && [ -r /dev/urandom ]; then
    # 16 random bytes as hex, reformatted 8-4-4-4-12 with the version (4) and
    # variant (8) nibbles pinned so the result is a well-formed v4 UUID.
    local hex
    hex=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')
    if [ "${#hex}" -eq 32 ]; then
      u="${hex:0:8}-${hex:8:4}-4${hex:13:3}-8${hex:17:3}-${hex:20:12}"
    fi
  fi
  case "$u" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$u"
}

# --- _standalone_resume_reuse_applicable ---
# True when a RESUMED standalone entry should re-enter its kept worktree instead
# of creating one (Decision t-0055 clause 8).
#
# Why this exists: a resumed entry reuses its recorded REPO_OS_SESSION_ID, and a
# standalone worktree path is `.worktrees/<session-id>` — the very worktree the
# entry was stopped in, still registered with its branch checked out. `git
# worktree add` refuses that path, so before this the entry returned
# failed:worktree-creation and burned a retry, and the retry failed identically.
# RUNNER-PARITY rows 64-65 asserted standalone resume worked when only the group
# path could actually do it.
#
# A predicate rather than an inline condition so it can be tested directly
# against real git worktrees — see tests/test-operator-control.sh. Deliberately
# NOT unified with the group reuse arm: that refactor is a separate change.
#
# Arguments:
#   $1 — candidate worktree directory
#   $2 — branch the entry is set up on ($_SETUP_BRANCH)
# Returns 0 when the directory should be reused as-is, 1 otherwise.
_standalone_resume_reuse_applicable() {
  local wt_dir="${1:-}"
  local want_branch="${2:-}"

  # Gate on resume: a FRESH standalone launch must keep the old create path.
  # Its `.worktrees/<new session id>` cannot already exist, so this is belt and
  # braces, but it keeps the blast radius of this arm at exactly "resumes".
  [ "${_RESUME_ENTRY:-false}" = true ] || return 1
  [ -n "$wt_dir" ] && [ -n "$want_branch" ] || return 1
  [ -d "$wt_dir" ] || return 1
  is_registered_worktree "$wt_dir" || return 1

  # Branch equality is what stops a stale directory being adopted for the wrong
  # branch — reusing one would run the brief against someone else's checkout.
  local have_branch
  have_branch=$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
  [ "$have_branch" = "$want_branch" ] || return 1
  return 0
}

# --- Operator stop watcher (Decision t-0055 clauses 6-7) ---
# A background poller started alongside the TTL watchdog and torn down with it.
#
# The PreToolUse hook (operator-control.sh) is the graceful path: it ends the
# run at the next tool call, which is clean because no tool is mid-flight. This
# watcher covers the two cases the hook cannot:
#   - FORCE: the operator wants the process gone now, not at the next tool call.
#   - A graceful STOP that no tool call ever reaches — the session is waiting on
#     a long model turn, or on one of the tools the delegated hook path does not
#     cover. After stop_grace_seconds the watcher writes FORCE itself, so the
#     escalation goes through exactly the same code path as an explicit force.
#
# The kill sequence mirrors FORCE-HALT: SIGTERM, up to 10s, then SIGKILL.
#
# Arguments:
#   $1 — entry_id
#   $2 — child pid to watch
#   $3 — stop_grace_seconds (0 disables the graceful-stop escalation)
#   $4 — session root (optional; see below)
# Sets: _STOP_WATCHER_PID ("" when no watcher could be started)
_start_stop_watcher() {
  local entry_id="$1"
  local child_pid="$2"
  local grace="${3:-120}"
  # $4 — session root (the launch dir: the worktree when one is used, else
  # REPO_ROOT). Used ONLY to locate the child's phase-state so the grace
  # escalation can hold during the close phase. Absent means no phase awareness,
  # which degrades to the pre-2026-10-19 behaviour (escalate regardless).
  local session_root="${4:-}"

  _STOP_WATCHER_PID=""
  [ -n "$entry_id" ] && [ -n "$child_pid" ] || return 0

  local control_dir
  control_dir=$(get_control_dir "$entry_id" 2>/dev/null) || control_dir=""
  # No control directory means no operator control for this entry — the session
  # runs unwatched rather than being wedged by a missing directory.
  [ -n "$control_dir" ] || return 0

  # Phase-state path for the close-phase hold below. Resolved once, outside the
  # loop: the file appears when the child initialises and its path never moves.
  local phase_file=""
  if [ -n "$session_root" ] && [ -n "${REPO_OS_SESSION_ID:-}" ]; then
    phase_file="$session_root/.claude/.state/wt-sessions/${REPO_OS_SESSION_ID}/phase-state"
  fi

  (
    _sw_stop_seen=""
    _sw_close_logged=""
    while kill -0 "$child_pid" 2>/dev/null; do
      if [ -f "$control_dir/FORCE" ]; then
        echo "Operator force-stop for entry $entry_id — sending SIGTERM to child pid $child_pid" >&2
        kill -TERM "$child_pid" 2>/dev/null || true
        _sw_waited=0
        while [ "$_sw_waited" -lt 10 ] && kill -0 "$child_pid" 2>/dev/null; do
          sleep 1
          _sw_waited=$(( _sw_waited + 1 ))
        done
        if kill -0 "$child_pid" 2>/dev/null; then
          echo "Child pid $child_pid survived SIGTERM for 10s — sending SIGKILL" >&2
          kill -KILL "$child_pid" 2>/dev/null || true
        fi
        exit 0
      fi
      if [ -f "$control_dir/STOP" ]; then
        if [ "$grace" -gt 0 ]; then
          _sw_now=$(date +%s)
          if [ -z "$_sw_stop_seen" ]; then
            # First sighting, not the write time — the two differ by at most one
            # poll interval, which is well inside a grace period measured in
            # minutes.
            _sw_stop_seen="$_sw_now"
          elif [ $(( _sw_now - _sw_stop_seen )) -ge "$grace" ]; then
            # Close-phase hold. operator-control.sh deliberately ignores STOP
            # during `close` — stopping there leaves the work uncommitted and
            # the branch unsealed, and t-0055 clause 6 says the flag stays set
            # for the runner to honour once the child exits. Escalating here
            # would SIGTERM then SIGKILL mid-close and produce exactly the
            # outcome that guard exists to prevent, for any close longer than
            # the grace period. So: hold instead, and let the child finish.
            #
            # The hold is bounded by the child exiting (this loop's condition)
            # and by the existing TTL watchdog — deliberately NOT by a new
            # "close grace" setting, which would be configuration for no gain.
            #
            # Fails TOWARD escalation: an unreadable, missing or non-close
            # phase-state escalates as before, so a corrupt file cannot hold a
            # runaway session open forever.
            if [ -n "$phase_file" ] && [ -f "$phase_file" ] \
               && grep -q '^current_phase: close$' "$phase_file" 2>/dev/null; then
              if [ -z "$_sw_close_logged" ]; then
                echo "Graceful stop for entry $entry_id reached its ${grace}s grace, but the session is in the close phase — holding escalation until it finishes (Decision t-0055 clause 6)" >&2
                _sw_close_logged=1
              fi
            else
              echo "Graceful stop for entry $entry_id saw no tool call within ${grace}s — escalating to force" >&2
              printf 'escalated from a graceful stop after %ss without a tool call\n' "$grace" \
                > "$control_dir/FORCE" 2>/dev/null || true
              continue
            fi
          fi
        fi
      else
        # STOP withdrawn before the grace period elapsed — restart the clock.
        _sw_stop_seen=""
      fi
      sleep 5
    done
  ) &
  _STOP_WATCHER_PID=$!
}

# --- Tear down the stop watcher ---
# Safe to call when no watcher is running.
_stop_stop_watcher() {
  if [ -n "${_STOP_WATCHER_PID:-}" ]; then
    kill "$_STOP_WATCHER_PID" 2>/dev/null || true
    wait "$_STOP_WATCHER_PID" 2>/dev/null || true
    _STOP_WATCHER_PID=""
  fi
}

# --- _run_single_entry ---
# Arguments:
#   $1 — brief_id (for branch naming)
#   $2 — prompt (assembled prompt text)
#   $3 — session_type (Decision 0014 enum)
#   $4 — existing_branch (optional, for task group)
#   $5 — permission_profile (optional, default: "build")
#   $6 — push_on_complete (optional, default: "false")
#   $7 — brief_path (optional; required for sequential task group worktree
#        reuse — Decision 0054 reads the Group: and Execution: fields from it)
#   $8 — entry_model (optional; per-entry model pin — used verbatim, bypasses
#        _resolve_model_for_session; Decision t-0046 Amendment 3)
# Sets globals: _RESULT_OUTCOME, _RESULT_BASELINE, _RESULT_SOLO_MODE, _RESULT_BRANCH
_run_single_entry() {
  local brief_id="$1"
  local prompt="$2"
  local session_type="$3"
  local existing_branch="${4:-}"
  local permission_profile="${5:-build}"
  local push_on_complete="${6:-false}"
  local brief_path="${7:-}"
  local entry_model="${8:-}"

  # Reset globals
  _RESULT_OUTCOME=""
  _RESULT_BASELINE=""
  _RESULT_SOLO_MODE=""
  _RESULT_BRANCH=""
  _RESULT_PRESERVED_PATCH=""
  # Re-verification results (lib/reverify-merge.sh). These MUST be cleared per
  # entry: the daemon-loop write-back fires whenever either is non-empty, so a
  # value left over from a previous cycle would be stamped onto an entry whose
  # merge never reached the gate (non-solo, non-feature branch, or _main_br
  # other than main).
  _RESULT_REVERIFIED=""
  _RESULT_OVERLAP_FILES=""
  _CURRENT_WORKTREE_IS_GROUP=false
  _CURRENT_GROUP_NAME=""

  # --- Resume handle (Decision t-0055 clause 8) ---
  # Read BEFORE the session id is minted, because a resume reuses the stopped
  # session's REPO_OS_SESSION_ID rather than minting a new one. That is what
  # makes the resumed session's commits carry the same Session: trailer as the
  # work it is continuing. (The phase chain does not survive: the stop runs the
  # normal close cleanup, which removes phase-state — see the resume message
  # assembled in the daemon loop.)
  # The handle is a file, not the session record: runner_external_cleanup calls
  # unregister_session() at close, so the record is gone by the time a resume
  # reads it.
  local _resume_session_id=""
  local _resume_claude_session=""
  local _resume_worktree=""
  _RESUME_WORKTREE_EXEMPT=false
  if [ "${_RESUME_ENTRY:-false}" = true ]; then
    local _resume_file="" _resume_dir=""
    _resume_dir=$(get_control_dir "$brief_id" 2>/dev/null) || _resume_dir=""
    if [ -n "$_resume_dir" ]; then
      _resume_file="$_resume_dir/resume.yaml"
    fi
    if [ -n "$_resume_file" ] && [ -f "$_resume_file" ]; then
      local _rl
      while IFS= read -r _rl || [ -n "$_rl" ]; do
        case "$_rl" in
          "repo_os_session_id: "*)  _resume_session_id="${_rl#repo_os_session_id: }" ;;
          "claude_session_id: "*)   _resume_claude_session="${_rl#claude_session_id: }" ;;
          "worktree: "*)            _resume_worktree="${_rl#worktree: }" ;;
        esac
      done < "$_resume_file"
      _resume_session_id=$(_strip_quotes "$_resume_session_id")
      _resume_claude_session=$(_strip_quotes "$_resume_claude_session")
      _resume_worktree=$(_strip_quotes "$_resume_worktree")
    fi
    if [ -z "$_resume_claude_session" ]; then
      # No handle, or no session id in it: the entry is still runnable, it just
      # cannot continue the old transcript. Falling back to a fresh session is
      # the only alternative to failing an entry the operator asked to resume.
      echo "WARNING: entry $brief_id is marked for resume but no resumable Claude session id was found at ${_resume_file:-<no control dir>} — starting a fresh session" >&2
      _RESUME_ENTRY=false
    else
      # A resumed entry re-enters the worktree it was stopped in, which a force
      # stop may well have left dirty. Exempt that one worktree from the
      # clean-start check (Decision 0054) — see _resolve_group_worktree.
      _RESUME_WORKTREE_EXEMPT=true
    fi
  fi

  # Generate per-session ID for state directory isolation (prevents daemon
  # sessions from overwriting interactive session phase-state). Exported so
  # hooks in the claude -p child process route state to wt-sessions/{id}/.
  if [ "${_RESUME_ENTRY:-false}" = true ] && [ -n "$_resume_session_id" ]; then
    export REPO_OS_SESSION_ID="$_resume_session_id"
    echo "Resuming entry $brief_id in session $REPO_OS_SESSION_ID (claude session $_resume_claude_session)" >&2
  elif [ -n "${EPOCHREALTIME:-}" ]; then
    local _frac="${EPOCHREALTIME#*.}"
    export REPO_OS_SESSION_ID="daemon-$(date +%Y%m%d-%H%M%S)-${_frac:0:4}"
  else
    export REPO_OS_SESSION_ID="daemon-$(date +%Y%m%d-%H%M%S)-$$"
  fi

  # Pre-launch setup
  state_manager_setup "$REPO_ROOT" "$session_type"

  # Task group worktree resolution (Decision 0054) — MUST run before
  # branch_manager_setup. When an existing group worktree is reused, the group
  # branch is already checked out in it, and branch_manager_setup's freshness
  # paths cannot operate on a checked-out branch (Case 1 does `git branch -D`,
  # Case 3 does `git checkout`, and git refuses both). _resolve_group_worktree
  # therefore handles freshness worktree-side and tells us to skip the branch
  # manager entirely on the reuse path.
  local _gwt_rc=0
  _resolve_group_worktree "$session_type" "$brief_path" "$existing_branch" "$brief_id" || _gwt_rc=$?
  if [ "$_gwt_rc" -eq 2 ]; then
    # Blocked: occupied, dirty, or on an unexpected branch. The escalation is
    # already written and the lock already released. Do not launch the session.
    _RESULT_OUTCOME="$_GWT_BLOCK_OUTCOME"
    _RESULT_BRANCH="$existing_branch"
    unset REPO_OS_AUTOMATION_ENTRY 2>/dev/null || true
    runner_external_cleanup "$REPO_ROOT" "$brief_id" "init" "" 2>/dev/null || true
    unset REPO_OS_SESSION_ID
    return
  fi
  if [ "$_gwt_rc" -eq 0 ] && [ -n "$_GWT_GROUP" ]; then
    _CURRENT_GROUP_NAME="$_GWT_GROUP"
  fi

  # Branch setup — sets _SETUP_BRANCH; when worktree-isolate active, does NOT checkout
  if [ "$_GWT_REUSE" = true ]; then
    # Reused group worktree: the branch already exists, is checked out, and has
    # been freshness-checked above. Set the output variable the caller expects
    # without touching the branch ref.
    _SETUP_BRANCH="$_GWT_BRANCH"
  else
    # Capture the return code: a bare call lets `set -e` kill the daemon on any
    # non-zero return. rc 3 = the branch is behind main and its rebase hit a
    # conflict (already aborted and verified clean) — block BEFORE any worktree
    # is created, with an escalation naming the files, instead of launching on a
    # stale base.
    local _bm_rc=0
    branch_manager_setup "$brief_id" "$existing_branch" || _bm_rc=$?
    if [ "$_bm_rc" -ne 0 ]; then
      local _bm_outcome="failed:branch-setup" _bm_esc=""
      if [ "$_bm_rc" -eq 3 ]; then
        _bm_outcome="failed:branch-rebase-conflict"
        _bm_esc=$(_write_group_worktree_escalation "esc-branch-rebase-conflict" "$brief_id" \
          "Branch cannot be rebased onto main without manual conflict resolution — brief not started" \
          "branch: $existing_branch, conflicting_files: ${_BM_REBASE_CONFLICT_FILES:-none reported}, detail: ${_BM_REBASE_DETAIL:-}, recovery: rebase the branch onto main by hand, resolve the conflicts, then requeue the brief")
        echo "ERROR: Branch $existing_branch cannot be rebased onto main — conflicting files: ${_BM_REBASE_CONFLICT_FILES:-none reported} — escalation $_bm_esc" >&2
      else
        echo "ERROR: Branch setup failed for $existing_branch (rc $_bm_rc)" >&2
      fi
      _RESULT_OUTCOME="$_bm_outcome"
      _RESULT_BRANCH="$existing_branch"
      unset REPO_OS_AUTOMATION_ENTRY 2>/dev/null || true
      runner_external_cleanup "$REPO_ROOT" "$brief_id" "init" "" 2>/dev/null || true
      unset REPO_OS_SESSION_ID
      return
    fi
  fi

  # Record baseline SHA — when worktree-isolate active, HEAD is still main,
  # so use the branch ref directly
  if [ "${REPO_OS_WORKTREE_ISOLATE:-1}" != "0" ] && [ -n "$_SETUP_BRANCH" ]; then
    _RESULT_BASELINE=$(git rev-parse "$_SETUP_BRANCH")
  else
    _RESULT_BASELINE=$(git rev-parse HEAD)
  fi

  # Set automation context for analytics hooks (inherited by claude -p child)
  export REPO_OS_AUTOMATION_ENTRY="$brief_id"
  # Set headless flag for hooks. Consumed by:
  #   ask-user-deny.sh — blocks AskUserQuestion
  #   pre-commit-gates.sh — adjusts GATE-RECOVERABLE messages, writes A1 escalation
  #   permission-request.sh — denies fall-through (fail-closed)
  export CLAUDE_HEADLESS=1

  # Resolve permission profile to --disallowedTools string
  local disallowed
  disallowed=$(get_disallowed_tools "$permission_profile")

  # Capture stderr AND stdout to temp files: blocker reports read stderr, and
  # detect_outcome scans the tail of both for the turn-budget banner (which stream
  # the CLI prints it on was never established). Both are needed or neither is:
  # if either mktemp fails the session runs uncaptured — no banner detection, but
  # no crash — which is the pre-existing degraded path.
  local stderr_file stdout_file
  stderr_file=$(mktemp "${TMPDIR:-/tmp}/runner-stderr-XXXXXX" 2>/dev/null || echo "")
  stdout_file=$(mktemp "${TMPDIR:-/tmp}/runner-stdout-XXXXXX" 2>/dev/null || echo "")
  if [ -z "$stderr_file" ] || [ -z "$stdout_file" ]; then
    [ -n "$stderr_file" ] && rm -f "$stderr_file" 2>/dev/null
    [ -n "$stdout_file" ] && rm -f "$stdout_file" 2>/dev/null
    stderr_file=""
    stdout_file=""
  fi

  # Resolve model: per-entry pin wins over session-type routing (Decision t-0046 Amendment 3).
  # A per-entry model is used verbatim — re-mapping it through the alias table
  # would let a later map change silently rewrite what a study used.
  local model_id
  if [ -n "${entry_model:-}" ]; then
    model_id="$entry_model"
  else
    model_id=$(_resolve_model_for_session "$session_type")
  fi
  local model_flag=""
  if [ -n "$model_id" ]; then
    model_flag="--model $model_id"
  fi

  # Launch headless session
  # Trust model for headless execution:
  #   --permission-mode bypassPermissions — required because PermissionRequest
  #   hooks do NOT fire in `claude -p` mode (Anthropic SDK documented limitation).
  #   Without bypass, every tool call would block on an unattended permission dialog.
  #
  #   Three-layer compensating defense:
  #     1. --disallowedTools — CLI-level deny list (primary gate, prevents tool
  #        invocation entirely for blocked tools)
  #     2. PreToolUse hooks (pretooluse-permission.sh) — belt-and-suspenders deny
  #        list + headless fail-closed for unknown commands
  #     3. Governance gates (pre-commit-gates.sh, pre-push-gates.sh, bash-guard.sh,
  #        write-guard.sh) — enforce phase model, secret scanning, branch isolation
  #
  #   REVISIT: check PermissionRequest hook behavior at each Anthropic SDK upgrade.
  #   If PermissionRequest hooks begin firing in -p mode, consider switching from
  #   bypassPermissions to a permission-request-based allow/deny model.

  # Worktree isolation (Decision 0033): create a worktree targeting the feature
  # branch so the session runs in isolation. Manual git worktree add is used
  # instead of --worktree flag because --worktree creates from the invoking
  # process's HEAD (main), not the target branch.
  #
  # Sequential task groups (Decision 0054) target the group-scoped path
  # `.worktrees/tg-<group>` instead, and reuse it across briefs rather than
  # creating one per session.
  local launch_dir="$REPO_ROOT"
  if [ "${REPO_OS_WORKTREE_ISOLATE:-1}" != "0" ] && [ -n "$_SETUP_BRANCH" ]; then
    local worktree_dir="${REPO_ROOT}/.worktrees/${REPO_OS_SESSION_ID}"
    local _wt_is_group=false
    local _wt_added=false
    if [ -n "$_GWT_GROUP" ] && [ -n "$_GWT_DIR" ]; then
      worktree_dir="$_GWT_DIR"
      _wt_is_group=true
    fi
    # Reuse path (Decision 0054): the worktree already exists on the right
    # branch and has passed the clean-start check, so `git worktree add` is
    # skipped. Everything after this point is shared with the create path —
    # notably the plan-approved mirror, which is per-SESSION and so must be
    # re-written for every brief that reuses the worktree.
    _wt_added=false
    if [ "$_GWT_REUSE" = true ]; then
      _wt_added=true
      echo "Reusing task group worktree $worktree_dir (group: $_GWT_GROUP, branch: $_SETUP_BRANCH)" >&2
    elif [ "$_wt_is_group" != true ] \
         && _standalone_resume_reuse_applicable "$worktree_dir" "$_SETUP_BRANCH"; then
      _wt_added=true
      echo "Reusing standalone worktree $worktree_dir for resumed entry $brief_id (branch: $_SETUP_BRANCH)" >&2
    elif git worktree add "$worktree_dir" "$_SETUP_BRANCH" 2>/dev/null; then
      _wt_added=true
      if [ "$_wt_is_group" = true ]; then
        echo "Created task group worktree $worktree_dir (group: $_GWT_GROUP, branch: $_SETUP_BRANCH)" >&2
      fi
    fi

    if [ "$_wt_added" = true ]; then
      _CURRENT_WORKTREE_DIR="$worktree_dir"
      _CURRENT_WORKTREE_IS_GROUP="$_wt_is_group"
      launch_dir="$worktree_dir"
      # Propagate the operating mode into the worktree. `.claude/repo-mode` is
      # gitignored (Decision 0024 — child repos keep their own mode), so it is
      # NOT carried over by `git worktree add`. Without it the mode guard falls
      # back to its `child` default inside every headless worktree, which in a
      # template repo blocks legitimate writes to `.claude/hooks/` and invites
      # agents to route around write-guard instead. Copying preserves whatever
      # the parent declares rather than hardcoding a mode; this runs in the
      # runner before the session launches, so the immune-path rule in Decision
      # t-0012 §4 (which governs agent tool-call writes) does not apply.
      if [ -f "$REPO_ROOT/.claude/repo-mode" ]; then
        mkdir -p "$worktree_dir/.claude" 2>/dev/null || true
        if ! cp "$REPO_ROOT/.claude/repo-mode" "$worktree_dir/.claude/repo-mode" 2>/dev/null; then
          # Warn loudly — silently continuing reproduces the exact bug this guards.
          echo "WARNING: Failed to copy .claude/repo-mode into $worktree_dir — mode guard will default to 'child' in this session" >&2
        fi
      fi
      # Mirror plan-approved into the worktree state dir.
      # Decision 0028 (Amendment 2026-08-07): hooks inside the worktree session
      # resolve _REPO_OS_ROOT to the worktree root (settings.json uses relative
      # paths, so BASH_SOURCE[0] = worktree CWD). get_session_state_dir() in the
      # agent therefore targets <worktree>/.claude/.state/wt-sessions/{sid}/,
      # not the main repo path written by state_manager_setup above.
      # Mirroring plan-approved closes the two-root divergence without requiring
      # agents to fall back to a different root path.
      local wt_state_dir="$worktree_dir/.claude/.state/wt-sessions/${REPO_OS_SESSION_ID}"
      if mkdir -p "$wt_state_dir" 2>/dev/null; then
        local main_plan_approved="${REPO_ROOT}/.claude/.state/wt-sessions/${REPO_OS_SESSION_ID}/plan-approved"
        if [ -f "$main_plan_approved" ]; then
          if ! cp "$main_plan_approved" "$wt_state_dir/plan-approved" 2>/dev/null; then
            echo "WARNING: Failed to mirror plan-approved into worktree state dir $wt_state_dir — advance_phase(build) may require manual recovery" >&2
          fi
        else
          echo "WARNING: main repo plan-approved not found at $main_plan_approved — state_manager_setup may not have run" >&2
        fi
      else
        echo "WARNING: Failed to create worktree state dir $wt_state_dir — advance_phase(build) will find no plan-approved" >&2
      fi
    else
      echo "ERROR: Failed to create worktree at $worktree_dir for branch $_SETUP_BRANCH" >&2
      _RESULT_OUTCOME="failed:worktree-creation"
      # Release the group lock taken in _resolve_group_worktree — the session
      # never started, so holding it would wedge the group (Decision 0054).
      if [ -n "$_CURRENT_GROUP_NAME" ]; then
        release_group_worktree_lock "$_CURRENT_GROUP_NAME" "$$" "${REPO_OS_SESSION_ID:-}" 2>/dev/null || true
        _CURRENT_GROUP_NAME=""
      fi
      _CURRENT_WORKTREE_IS_GROUP=false
      unset REPO_OS_AUTOMATION_ENTRY
      unset CLAUDE_HEADLESS
      [ -n "$stderr_file" ] && rm -f "$stderr_file" 2>/dev/null || true
      [ -n "$stdout_file" ] && rm -f "$stdout_file" 2>/dev/null || true
      # Clean up state initialized by state_manager_setup before early return
      runner_external_cleanup "$REPO_ROOT" "$brief_id" "close" "$_RESULT_BASELINE" 2>/dev/null || true
      unset REPO_OS_SESSION_ID
      return
    fi
  fi

  # Launch headless session in background to enable FORCE-HALT child kill.
  # SIGTERM deferral: when the daemon receives SIGTERM, the trap sets
  # _SHUTDOWN_REQUESTED=true and `wait` is interrupted (returns 128+signum).
  # The child may still be running — re-wait until it exits naturally.
  # This prevents SIGTERM from killing sessions during close phase output.

  # Session TTL guard (session_max_ttl_seconds: 0 = disabled, default 21600).
  # A background watchdog sends SIGTERM to the child after the TTL expires.
  # The wait-loop check provides belt-and-suspenders enforcement on each
  # SIGTERM-interrupted iteration. Exit code 143 is handled by outcome-detector.
  local _session_max_ttl
  _session_max_ttl=$(_parse_config_field "runner" "session_max_ttl_seconds" 2>/dev/null || echo "21600")
  _session_max_ttl="${_session_max_ttl:-21600}"

  # Turn budget. Was hardcoded `--max-turns 200` at both launch sites, which is
  # what two briefs hit on 2026-10-21 after ~40 minutes each, producing nothing.
  # Tunable without editing code, and it is the documented way out of the
  # `review:turn-budget-exhausted` outcome the detector now raises.
  #
  # Daemon-global on purpose: a per-entry budget would need a queue-entry field,
  # serialisation, the editable-field allowlist and intake validation, and
  # nothing reads one yet.
  local _session_max_turns
  _session_max_turns=$(_parse_config_field "runner" "session_max_turns" 2>/dev/null || echo "400")
  _session_max_turns="${_session_max_turns:-400}"
  # Guard the value: it is interpolated into the CLI invocation, and a
  # non-numeric or absent reading must not produce `--max-turns ''`.
  case "$_session_max_turns" in ''|*[!0-9]*) _session_max_turns=400 ;; esac
  [ "$_session_max_turns" -gt 0 ] || _session_max_turns=400
  local _session_launch_epoch
  _session_launch_epoch=$(date +%s)
  local _ttl_watchdog_pid=""

  # Graceful-stop grace period (stop_grace_seconds: 0 = never escalate,
  # default 120). Backstop for a graceful stop the PreToolUse hook never gets
  # to answer — see _start_stop_watcher.
  local _stop_grace
  _stop_grace=$(_parse_config_field "runner" "stop_grace_seconds" 2>/dev/null || echo "120")
  _stop_grace="${_stop_grace:-120}"
  case "$_stop_grace" in
    ''|*[!0-9]*) _stop_grace=120 ;;
  esac

  # --- Operator session control record (Decision t-0055) ---
  # Written BEFORE launch so an operator (and Massimo's Task details header) can
  # resolve a running entry to its work order, its resumable claude session id,
  # the process running it and the worktree it is running in. control_state is
  # updated again once the child exits. The record and the per-entry control
  # directory both resolve against the MAIN repo root inside the helper, so the
  # launched worktree session reads and writes the same files the runner does.
  local _claude_session_id=""
  local _session_id_flag=""
  if [ "${_RESUME_ENTRY:-false}" = true ]; then
    # Resume continues the recorded session with --resume instead of minting a
    # new one with --session-id. Claude keys transcripts by working directory,
    # so a resume only reaches the real history if it launches from the same
    # directory the stopped session ran in — assert that rather than resume
    # into an empty transcript (Decision t-0055 clause 8).
    if [ -n "$_resume_worktree" ] && [ "$_resume_worktree" != "$launch_dir" ]; then
      echo "WARNING: entry $brief_id was stopped in '$_resume_worktree' but would resume from '$launch_dir' — transcripts are keyed by directory, so a fresh session is started instead" >&2
      _RESUME_ENTRY=false
    else
      _claude_session_id="$_resume_claude_session"
      _session_id_flag="--resume $_claude_session_id"
    fi
  fi
  if [ "${_RESUME_ENTRY:-false}" != true ]; then
    if _claude_session_id=$(_generate_uuid); then
      _session_id_flag="--session-id $_claude_session_id"
    else
      echo "WARNING: could not generate a UUID for --session-id — entry $brief_id will not be resumable by session id" >&2
      _claude_session_id=""
    fi
  fi
  ensure_control_dir "$brief_id" >/dev/null 2>&1 || \
    echo "WARNING: failed to create the control directory for entry $brief_id" >&2
  session_record_set "${REPO_OS_SESSION_ID:-}" \
    "entry_id=$brief_id" \
    "work_order_id=${_QE_WORK_ORDER_ID:-}" \
    "claude_session_id=$_claude_session_id" \
    "worktree=$launch_dir" \
    "control_state=running" 2>/dev/null || \
    echo "WARNING: failed to write the operator control record for entry $brief_id" >&2

  local exit_code=0
  if [ -n "$stderr_file" ]; then
    # shellcheck disable=SC2086 — $model_flag and $_session_id_flag intentionally unquoted (each expands to nothing when empty)
    # `exec` is load-bearing. Without it the subshell FORKS the child, so `$!`
    # is the SUBSHELL's pid and every kill path signals a wrapper while the real
    # process keeps running: FORCE-HALT and the TTL watchdog were both affected. Confirmed on a live run 2026-10-20 — the
    # tracked pid was a `bash runner.sh` subshell whose child was the real
    # process, and terminating the tracked pid left it running.
    #
    # `cd ... && exec` keeps the ordering: a failed cd still never runs the
    # child. The here-string and the two file redirects are established by the
    # subshell BEFORE exec replaces it, so all survive. `wait` now returns the
    # child's own status, including 143 on SIGTERM, which detect_outcome already
    # handles.
    #
    # Output goes straight to files, NOT through `2> >(tee ...)`. The tee that
    # used to sit here was an intermediate process the subshell's exec orphaned
    # and nothing waited on, so the banner — the LAST thing written — could still
    # be in the pipe when detect_outcome read the file (known-issues R26, which
    # materialised on 2026-10-21). With a direct redirect there is no process to
    # outlive the child: when `wait` returns, the files are complete. The cost is
    # that output reaches daemon.log after the session ends rather than live;
    # it is replayed below, before detect_outcome runs. Do not "fix" a missed
    # read with sleep/sync/retry — removing the intermediate process is the fix.
    (cd "$launch_dir" && exec claude -p \
      --permission-mode bypassPermissions \
      --disallowedTools "$disallowed" \
      --max-turns "$_session_max_turns" \
      $model_flag \
      $_session_id_flag \
      <<< "$prompt" \
      >"$stdout_file" 2>"$stderr_file") &
    _CLAUDE_CHILD_PID=$!
    session_record_set "${REPO_OS_SESSION_ID:-}" "child_pid=$_CLAUDE_CHILD_PID" 2>/dev/null || true
    # Start TTL watchdog: kills child directly after TTL seconds
    if [ "$_session_max_ttl" -gt 0 ]; then
      local _child_pid_capture="$_CLAUDE_CHILD_PID"
      ( sleep "$_session_max_ttl"
        if kill -0 "$_child_pid_capture" 2>/dev/null; then
          echo "Session exceeded TTL (${_session_max_ttl}s) — sending SIGTERM to child pid ${_child_pid_capture}" >&2
          kill -TERM "$_child_pid_capture" 2>/dev/null || true
        fi ) &
      _ttl_watchdog_pid=$!
    fi
    # FORCE-HALT must be able to interrupt THIS entry, not just the next one.
    _start_force_halt_watcher "$_CLAUDE_CHILD_PID"
    # Start the operator stop watcher (Decision t-0055 clauses 6-7)
    _start_stop_watcher "$brief_id" "$_CLAUDE_CHILD_PID" "$_stop_grace" "$launch_dir"
    wait "$_CLAUDE_CHILD_PID" || exit_code=$?
    # Re-wait if child is still alive (SIGTERM interrupted wait, not child)
    while [ "$exit_code" -ne 0 ] && kill -0 "$_CLAUDE_CHILD_PID" 2>/dev/null; do
      # TTL belt-and-suspenders: send SIGTERM if elapsed exceeds threshold
      if [ "$_session_max_ttl" -gt 0 ]; then
        local _now_epoch _elapsed
        _now_epoch=$(date +%s)
        _elapsed=$(( _now_epoch - _session_launch_epoch ))
        if [ "$_elapsed" -gt "$_session_max_ttl" ]; then
          echo "Session exceeded TTL (${_session_max_ttl}s, elapsed ${_elapsed}s) — sending SIGTERM to child pid $_CLAUDE_CHILD_PID" >&2
          kill -TERM "$_CLAUDE_CHILD_PID" 2>/dev/null || true
        fi
      fi
      echo "SIGTERM deferred: child pid $_CLAUDE_CHILD_PID still running — re-waiting..." >&2
      exit_code=0
      wait "$_CLAUDE_CHILD_PID" || exit_code=$?
    done
  else
    # shellcheck disable=SC2086 — $model_flag and $_session_id_flag intentionally unquoted (each expands to nothing when empty)
    # `exec` for the same reason as the stderr branch above: the tracked pid must
    # be the real process, not a subshell wrapper, or every kill path signals the
    # wrapper and the child survives.
    (cd "$launch_dir" && exec claude -p \
      --permission-mode bypassPermissions \
      --disallowedTools "$disallowed" \
      --max-turns "$_session_max_turns" \
      $model_flag \
      $_session_id_flag \
      <<< "$prompt") &
    _CLAUDE_CHILD_PID=$!
    session_record_set "${REPO_OS_SESSION_ID:-}" "child_pid=$_CLAUDE_CHILD_PID" 2>/dev/null || true
    # Start TTL watchdog: kills child directly after TTL seconds
    if [ "$_session_max_ttl" -gt 0 ]; then
      local _child_pid_capture="$_CLAUDE_CHILD_PID"
      ( sleep "$_session_max_ttl"
        if kill -0 "$_child_pid_capture" 2>/dev/null; then
          echo "Session exceeded TTL (${_session_max_ttl}s) — sending SIGTERM to child pid ${_child_pid_capture}" >&2
          kill -TERM "$_child_pid_capture" 2>/dev/null || true
        fi ) &
      _ttl_watchdog_pid=$!
    fi
    # FORCE-HALT must be able to interrupt THIS entry, not just the next one.
    _start_force_halt_watcher "$_CLAUDE_CHILD_PID"
    # Start the operator stop watcher (Decision t-0055 clauses 6-7)
    _start_stop_watcher "$brief_id" "$_CLAUDE_CHILD_PID" "$_stop_grace" "$launch_dir"
    wait "$_CLAUDE_CHILD_PID" || exit_code=$?
    # Re-wait if child is still alive (SIGTERM interrupted wait, not child)
    while [ "$exit_code" -ne 0 ] && kill -0 "$_CLAUDE_CHILD_PID" 2>/dev/null; do
      # TTL belt-and-suspenders: send SIGTERM if elapsed exceeds threshold
      if [ "$_session_max_ttl" -gt 0 ]; then
        local _now_epoch _elapsed
        _now_epoch=$(date +%s)
        _elapsed=$(( _now_epoch - _session_launch_epoch ))
        if [ "$_elapsed" -gt "$_session_max_ttl" ]; then
          echo "Session exceeded TTL (${_session_max_ttl}s, elapsed ${_elapsed}s) — sending SIGTERM to child pid $_CLAUDE_CHILD_PID" >&2
          kill -TERM "$_CLAUDE_CHILD_PID" 2>/dev/null || true
        fi
      fi
      echo "SIGTERM deferred: child pid $_CLAUDE_CHILD_PID still running — re-waiting..." >&2
      exit_code=0
      wait "$_CLAUDE_CHILD_PID" || exit_code=$?
    done
  fi
  # Kill TTL watchdog if still running (session completed before TTL fired)
  if [ -n "$_ttl_watchdog_pid" ]; then
    kill "$_ttl_watchdog_pid" 2>/dev/null || true
    wait "$_ttl_watchdog_pid" 2>/dev/null || true
    _ttl_watchdog_pid=""
  fi
  # Same for the FORCE-HALT watcher. Its own loop exits when the child dies, but
  # reaping it here keeps the daemon from accumulating one zombie poller per
  # entry over a long run.
  if [ -n "${_FORCE_HALT_WATCHER_PID:-}" ]; then
    kill "$_FORCE_HALT_WATCHER_PID" 2>/dev/null || true
    wait "$_FORCE_HALT_WATCHER_PID" 2>/dev/null || true
    _FORCE_HALT_WATCHER_PID=""
  fi
  _stop_stop_watcher
  # The child has exited — whether it finished, was stopped or was killed, the
  # entry is no longer running (Decision t-0055). child_pid is cleared so a
  # reader never mistakes a recycled pid for this session's process.
  session_record_set "${REPO_OS_SESSION_ID:-}" \
    "control_state=stopped" \
    "child_pid=" 2>/dev/null || true
  _CLAUDE_CHILD_PID=""

  # Replay the captured output so it still lands in daemon.log (stdout to stdout,
  # stderr to stderr, as before). The child has exited, so both files are
  # complete. This runs BEFORE detect_outcome, which may itself print to stderr.
  if [ -n "$stdout_file" ] && [ -f "$stdout_file" ]; then
    cat "$stdout_file"
  fi
  if [ -n "$stderr_file" ] && [ -f "$stderr_file" ]; then
    cat "$stderr_file" >&2
  fi

  # --- Operator stop detection (Decision t-0055 clauses 6-7) ---
  # Read before outcome detection, because a stop is not an outcome the session
  # produced: the exit code of a stopped child says nothing useful about the
  # work, and detect_outcome would read it as a failure and burn a retry.
  # FORCE wins over STOP — the watcher escalates by writing FORCE alongside it,
  # and the mode the operator ends up with is the one that killed the child.
  local _stopped_mode=""
  local _control_dir=""
  _control_dir=$(get_control_dir "$brief_id" 2>/dev/null) || _control_dir=""
  if [ -n "$_control_dir" ]; then
    if [ -f "$_control_dir/FORCE" ]; then
      _stopped_mode="forced"
    elif [ -f "$_control_dir/STOP" ]; then
      _stopped_mode="graceful"
    fi
  fi

  # Durable resume handle. The session record is deleted by unregister_session()
  # inside runner_external_cleanup below, so the only way a later resume can
  # find the Claude session id is a file that outlives the session.
  if [ -n "$_stopped_mode" ] && [ -n "$_control_dir" ]; then
    if [ -n "$_claude_session_id" ]; then
      {
        printf '# Resume handle for entry %s — written by runner.sh at operator stop (Decision t-0055).\n' "$brief_id"
        printf '# Lowercase name = durable data; the UPPERCASE siblings are flags.\n'
        printf 'claude_session_id: "%s"\n' "$_claude_session_id"
        printf 'worktree: "%s"\n' "$launch_dir"
        printf 'repo_os_session_id: "%s"\n' "${REPO_OS_SESSION_ID:-}"
        printf 'stopped_mode: "%s"\n' "$_stopped_mode"
        printf 'stopped_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      } > "$_control_dir/resume.yaml" 2>/dev/null || \
        echo "WARNING: failed to write the resume handle for entry $brief_id — it will restart from a fresh session" >&2
    else
      echo "WARNING: entry $brief_id was stopped but has no Claude session id — resume will start a fresh session" >&2
    fi
    # Both flags are cleared once the stop has been honoured, so the entry can
    # be resumed (and stopped again) without the stale flag stopping it on its
    # first tool call.
    rm -f "$_control_dir/STOP" "$_control_dir/FORCE" 2>/dev/null || true
  fi

  # Clear automation context (keep REPO_OS_SESSION_ID alive for cleanup)
  unset REPO_OS_AUTOMATION_ENTRY
  unset CLAUDE_HEADLESS

  # Capture solo mode and branch from worktree context BEFORE removal
  # Use _QE_SOLO_MODE global (populated by _load_queue_entry) instead of get_solo()
  # to avoid reading already-cleaned phase-state post-session (Bug fix — solo merge).
  if [ -n "$_CURRENT_WORKTREE_DIR" ] && [ -d "$_CURRENT_WORKTREE_DIR" ]; then
    _RESULT_SOLO_MODE="${_QE_SOLO_MODE:-false}"
    _RESULT_BRANCH=$(git -C "$_CURRENT_WORKTREE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    # Outcome detection from worktree context
    if [ -n "$_stopped_mode" ]; then
      _RESULT_OUTCOME="stopped:$_stopped_mode"
    else
      _RESULT_OUTCOME=$(detect_outcome "$exit_code" "$_RESULT_BASELINE" "$_CURRENT_WORKTREE_DIR" "$brief_id" "$stderr_file" "$stdout_file")
    fi
    _RESULT_PRESERVED_PATCH=""
    if [ "$_CURRENT_WORKTREE_IS_GROUP" = true ]; then
      # Snapshot even though the tree is kept: the next brief may reset it, and
      # the entry's error_log should still lead somewhere (Decision t-0062).
      preserve_uncommitted_work "$_CURRENT_WORKTREE_DIR" "$_RESULT_BASELINE" "$brief_id" "$_RESULT_OUTCOME" || true
      _RESULT_PRESERVED_PATCH="$_PRESERVED_PATCH_PATH"
      # Task group worktree (Decision 0054): keep it for the next brief. The
      # occupancy lock is deliberately NOT released here — it stays held across
      # _solo_merge_if_needed so no other session can claim the worktree in the
      # window where the final brief's merge may be about to remove it. The
      # caller releases it after the merge/seal step.
      echo "Keeping task group worktree $_CURRENT_WORKTREE_DIR for the next brief (group: $_CURRENT_GROUP_NAME)" >&2
    elif [ -n "$_stopped_mode" ]; then
      # An operator stop keeps the worktree: that is where the stopped session's
      # uncommitted work lives, and the resume relaunches from this exact path
      # (transcripts are keyed by directory — Decision t-0055 clause 8).
      echo "Keeping worktree $_CURRENT_WORKTREE_DIR — entry $brief_id was stopped by the operator and stays resumable" >&2
    else
      # Capture uncommitted work, then remove the worktree (Decision t-0062).
      # Never call this inside $(...): the patch path is returned via a global.
      remove_session_worktree "$_CURRENT_WORKTREE_DIR" "$_RESULT_BASELINE" "$brief_id" "$_RESULT_OUTCOME"
      _RESULT_PRESERVED_PATCH="$_PRESERVED_PATCH_PATH"
      _CURRENT_WORKTREE_DIR=""
    fi
  else
    # Legacy path or worktree not created
    if [ -n "$_stopped_mode" ]; then
      _RESULT_OUTCOME="stopped:$_stopped_mode"
    else
      _RESULT_OUTCOME=$(detect_outcome "$exit_code" "$_RESULT_BASELINE" "$REPO_ROOT" "$brief_id" "$stderr_file" "$stdout_file")
    fi
    _RESULT_SOLO_MODE="${_QE_SOLO_MODE:-false}"
    _RESULT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  fi

  # External cleanup (Stop hook doesn't fire in headless mode)
  # With REPO_OS_SESSION_ID set, cleanup routes to the per-session state dir.
  runner_external_cleanup "$REPO_ROOT" "$brief_id" "close" "$_RESULT_BASELINE"

  # Clear the per-brief session ID after cleanup. In daemon mode, restore the
  # daemon's own pinned identity so subsequent daemon-loop get_session_id calls
  # (e.g. the outcome-transition block) stay env-pinned and never write the shared
  # .claude/.session-id; in single brief-id mode there is no daemon id, so unset.
  if [ -n "${_DAEMON_SESSION_ID:-}" ]; then
    export REPO_OS_SESSION_ID="$_DAEMON_SESSION_ID"
  else
    unset REPO_OS_SESSION_ID
  fi

  # Clean up stderr/stdout temp files
  [ -n "$stderr_file" ] && rm -f "$stderr_file" 2>/dev/null || true
  [ -n "$stdout_file" ] && rm -f "$stdout_file" 2>/dev/null || true

  # Output result summary to stderr (informational only — outcome is in globals)
  local outcome="${_RESULT_OUTCOME%%:*}"
  local outcome_detail="${_RESULT_OUTCOME#*:}"
  echo "outcome: $outcome" >&2
  echo "outcome_detail: $outcome_detail" >&2
  echo "exit_code: $exit_code" >&2
  echo "baseline_sha: $_RESULT_BASELINE" >&2
  echo "branch: $_RESULT_BRANCH" >&2
}

# ============================================================
# Close pipeline recorders (Decision t-0057)
# ============================================================
# The close pipeline's state is RECORDED as it happens, not reconstructed
# afterwards by a reader. These two helpers are the only writers in runner.sh.

# --- Resolve the queue entry file to record close steps into ---
# During a session the entry still sits in running/; an operator-initiated
# close (--close-entry) acts on one that has already moved to completed/.
# Resolved per call rather than captured once, because _transition_entry moves
# the file underneath us mid-pipeline.
_close_entry_path() {
  local eid="$1" f
  [ -n "$eid" ] || return 1
  f="$(_queue_dir)/running/${eid}.yaml"
  if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  if type _find_entry_file > /dev/null 2>&1; then
    f=$(_find_entry_file "$eid" 2>/dev/null) || f=""
    if [ -n "$f" ] && [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  fi
  return 1
}

# --- Record one close-pipeline transition. Fail-soft, always rc 0 ---
# close_state is a report ON the pipeline, not a participant IN it: a recorder
# that cannot write must never change whether a branch merges. Every failure
# mode here (entry file already archived, library not loaded, unwritable queue)
# therefore returns success and leaves the merge path untouched.
#
# Beware: queue_close_record calls _load_queue_entry, which overwrites every
# _QE_* global. _solo_merge_if_needed reads none of them, which is why the
# calls below are safe where they are. A future caller that does read _QE_*
# must reload after recording.
_close_record() {
  local eid="$1" state="${2:-}" step="${3:-}" step_status="${4:-}" detail="${5:-}"
  local f
  type queue_close_record > /dev/null 2>&1 || return 0
  f=$(_close_entry_path "$eid") || return 0
  queue_close_record "$f" "$state" "$step" "$step_status" "$detail" || true
  return 0
}

# --- Which close path is this entry on? ---
# Prints `solo` or `pr`, and prints `solo` for an entry that cannot be read.
# That is the fail-safe direction: `solo` is the pre-t-0057 behaviour, so an
# unreadable entry keeps doing exactly what it did before the PR route existed
# rather than pushing a branch to origin on the strength of a failed read.
#
# Beware: _load_queue_entry overwrites every _QE_* global. Call sites in the
# close pipeline read none of them, which is why this is safe where it is used.
_close_entry_close_path() {
  local eid="$1" f
  type queue_close_path > /dev/null 2>&1 || { printf 'solo'; return 0; }
  f=$(_close_entry_path "$eid") || { printf 'solo'; return 0; }
  _load_queue_entry "$f" 2>/dev/null || { printf 'solo'; return 0; }
  printf '%s' "$(queue_close_path)"
}

# --- Is this entry's merge held by the operator? ---
# Returns 0 (held) only on a POSITIVE reading of merge_hold: true. An entry
# that cannot be read is NOT treated as held, which is the fail-open direction
# here on purpose — the opposite choice would silently strand every merge the
# moment the queue file moved, and a missed hold is recoverable (the operator
# sees the merge happened) where a silent universal hold is not.
_close_merge_held() {
  local eid="$1" f
  # An explicit `--close-entry` outranks the hold: the hold stops the runner
  # merging unattended, and the operator running `merge` on a held entry IS the
  # attention it was waiting for. queue_close_merge_allowed admits `held` on the
  # same reasoning, so refusing here would make that admission unreachable.
  [ "${_CLOSE_ENTRY_MODE:-false}" = "true" ] && return 1
  type _load_queue_entry > /dev/null 2>&1 || return 1
  f=$(_close_entry_path "$eid") || return 1
  _load_queue_entry "$f" 2>/dev/null || return 1
  [ "${_QE_MERGE_HOLD:-false}" = "true" ]
}

# --- Record a passing re-verification, only if it actually ran ---
# _reverify_before_merge returns 0 both when it re-verified the rebased branch
# and when it never needed to (main changed nothing this branch changed). Only
# the former sets _RESULT_REVERIFIED=true, so only the former gets a step row —
# a `reverify: done` on a run that never happened is the exact false claim
# close_steps exists to prevent.
_close_record_reverify_pass() {
  [ "${_RESULT_REVERIFIED:-}" = "true" ] || return 0
  _close_record "$1" "" "reverify" "done" "re-verified after rebase onto main"
}

# --- Re-read every open pull request's checks (Decision t-0057 brief 2) ---
# Called once per daemon loop iteration and self-rate-limited to pr.poll_seconds,
# because the loop's own interval is the queue's, not GitHub's: every tick here
# costs one gh round trip per open pull request.
#
# Scans completed/ only. An entry can only reach `pr_open` through the close
# preconditions, whose first clause requires status `completed`, so no other
# directory can hold one — and scanning review/ would re-read the entry whose
# conflict already routed it there.
#
# This sweep REPORTS; it does not transition. pr_refresh records the close state
# and writes the escalation, and a conflict found here leaves the entry where it
# is rather than moving it to review/: queue_escalate only acts on running/, and
# an entry whose session genuinely completed is not fixed by re-running it. The
# close state and the escalation are what the operator reads.
_PR_POLL_LAST=0

_pr_poll_sweep() {
  type pr_refresh > /dev/null 2>&1 || return 0
  local interval now qdir f eid state
  interval=$(_pr_poll_seconds)
  now=$(date +%s)
  [ $((now - _PR_POLL_LAST)) -ge "$interval" ] || return 0
  # Stamped BEFORE the sweep, not after: stamping afterwards would make the
  # interval "poll_seconds plus however long the gh calls took", which drifts
  # further every cycle on a slow network.
  _PR_POLL_LAST="$now"
  # No gh, nothing to read. Silent: the daemon would otherwise log this line
  # every poll_seconds forever on a repo that closes solo, and pr_open already
  # recorded the same reason on the entry that cared.
  pr_gh_available || return 0
  qdir=$(_queue_dir)
  for f in "$qdir/completed"/*.yaml; do
    [ -f "$f" ] || continue
    _load_queue_entry "$f" 2>/dev/null || continue
    eid="${_QE_ID:-}"
    [ "${_QE_PR_NUMBER:-0}" != "0" ] || continue
    [ "$(queue_close_state)" = "pr_open" ] || continue
    pr_refresh "$f" || true
    case "${_PR_OUTCOME:-}" in
      "") ;;
      *) echo "Pull request #${_PR_NUMBER:-?} for entry $eid reported ${_PR_OUTCOME} — see escalation ${_PR_ESCALATION_ID:-unknown}" >&2 ;;
    esac
    # The STATE is reloaded rather than read off _QE_*: every
    # queue_close_record inside pr_refresh rewrites those, so reading them here
    # would be reading whichever write happened to be last. The _PR_* globals
    # below are a different set — pr_refresh's own report, which is exactly
    # what they are for, and which _load_queue_entry does not touch.
    state=""
    if _load_queue_entry "$f" 2>/dev/null; then
      state=$(queue_close_state 2>/dev/null) || state=""
    fi
    if [ "$state" = "merged" ]; then
      echo "Pull request #${_PR_NUMBER:-?} for entry $eid has merged — branch sealed, local main synced" >&2
    fi
  done
}

# ============================================================
# Solo merge + branch seal (extracted from _run_single_entry)
# ============================================================
# Called from daemon loop and single-shot mode AFTER _run_single_entry returns.
# Operates on _RESULT_* globals. Runs in the main shell — no subshell loss risk.
#
# Arguments:
#   $1 — entry_current_branch
#   $2 — push_on_complete ("true"/"false")
#   $3 — brief_id (for escalation context)
#   $4 — work_order_id (optional, for task group seal guard — Decision 0013)
#   $5 — group_name (optional; when set and this is the final brief, the group
#        worktree is removed after a successful seal — Decision 0054)
# Reads: _RESULT_OUTCOME, _RESULT_SOLO_MODE
# May modify: _RESULT_OUTCOME (on merge conflict → review:merge-conflict)
# BEFORE CHANGING THIS FUNCTION OR THE OUTCOME HANDLING AROUND IT, read this.
#
# Several queued briefs written on 2026-10-12 name this function and the runner's
# outcome handling in their scope. Between then and 2026-10-21 this region
# changed substantially, and a brief written against the older shape can rewrite
# it and silently drop one of the following. Nothing would fail; the behaviour
# would just be gone. Each of these was a live defect that cost a session:
#
#   - `exec claude -p` at BOTH launch sites. Without `exec` the subshell forks,
#     so the tracked `$!` is a wrapper and every kill path signals the wrapper
#     while the real process runs on.
#   - the DIRECT redirects (`>"$stdout_file" 2>"$stderr_file"`) at the capturing
#     launch site, replayed with `cat` after the child is reaped. The earlier
#     `2> >(tee ...)` left an orphaned tee that could still hold the banner when
#     detect_outcome read the file, silently restoring the turn-budget defect
#     (R26; it happened on 2026-10-21). Never reintroduce a process substitution
#     on the launch path, and never paper over a missed read with sleep/sync.
#   - the FORCE-HALT watcher call at both launch sites, which is what lets a
#     force-halt interrupt the entry it was raised against rather than the next.
#   - `--max-turns "$_session_max_turns"`, the configurable turn budget. It was
#     hardcoded at 200 and two briefs exhausted it, producing nothing.
#   - the turn-budget outcome branch in `lib/outcome-detector.sh`, which must
#     stay AHEAD of every exit-0 success branch. A session that runs out of turns
#     exits zero, so without it an exhausted brief is recorded `completed` and
#     its queue entry leaves the queue as though the work were done.
#   - the circuit-breaker cooldown and its FORCE-HALT exemption.
#   - the merge-finality gate here: this function merges only for a session the
#     runner considers final. RUNNER-PARITY row 16 records that task-group
#     finality is derived from the entry's `solo_mode` flag, so setting that flag
#     on a non-final group brief makes the runner merge and SEAL the group branch
#     early, stranding the remaining briefs. Checked on 2026-10-21: every
#     task-group entry in the queue had it set, including non-final ones.
#
# RUNNER-PARITY.md is the fuller catalogue of this region; `known-issues.md`
# R25-R30 carry the defect histories.
_solo_merge_if_needed() {
  local entry_current_branch="$1"
  local push_on_complete="${2:-false}"
  local brief_id="${3:-}"
  local work_order_id="${4:-}"
  local group_name="${5:-}"

  local _outcome_type="${_RESULT_OUTCOME%%:*}"

  # --- Non-final task group briefs must not merge (Decision 0013 §7) ---
  # The seal was already gated on finality below, but the MERGE was not, so
  # every completed solo task group brief merged to main as it finished rather
  # than only the final one. `session-close-check.sh` gates its merge on
  # is_final_brief; this is the runner side of that parity contract.
  #
  # The observed damage was not just an early merge: merging brief N made the
  # group branch an ancestor of main, so branch_manager_setup's Case 1 then
  # deleted and recreated the branch before brief N+1 — the shared group branch
  # did not survive between briefs at all.
  #
  # Standalone work is unaffected. _is_final_taskgroup_entry returns 0 (final)
  # when work_order_id is empty, and also for a `type: single` work order whose
  # only entry is this one, so single-entry merges behave exactly as before.
  if [ "$_outcome_type" = "completed" ] && [ "$_RESULT_SOLO_MODE" = "true" ] \
     && [ -n "$entry_current_branch" ] && ! _is_final_taskgroup_entry "$brief_id" "$work_order_id"; then
    echo "Task group brief is not final — skipping merge and seal; branch '$entry_current_branch' stays open for the next brief (Decision 0013 §7)" >&2
    # Close pipeline: this brief hands off rather than closing (t-0057). The two
    # steps recorded are the two things it actually did, each with evidence
    # rather than an assertion — the branch head it committed to, and the group
    # contract file if one is on disk.
    local _ho_sha _ho_contract=""
    _ho_sha=$(git -C "$REPO_ROOT" rev-parse --short "$entry_current_branch" 2>/dev/null || echo "unknown")
    _close_record "$brief_id" "" "commit" "done" "$entry_current_branch at $_ho_sha"
    if [ -n "$group_name" ]; then
      if [ -f "$REPO_ROOT/.claude/local/task-groups/${group_name}.yaml" ]; then
        _ho_contract=".claude/local/task-groups/${group_name}.yaml"
      elif [ -f "$REPO_ROOT/docs/ai/task-groups/${group_name}.yaml" ]; then
        _ho_contract="docs/ai/task-groups/${group_name}.yaml"
      fi
    fi
    if [ -n "$_ho_contract" ]; then
      _close_record "$brief_id" "" "contract" "done" "$_ho_contract"
    else
      _close_record "$brief_id" "" "contract" "skipped" "no group contract found"
    fi
    _close_record "$brief_id" "handed_off" "" "" ""
    if [ -n "$group_name" ]; then
      release_group_worktree_lock "$group_name" "$$" "${REPO_OS_SESSION_ID:-}" || true
      _CURRENT_GROUP_NAME=""
    fi
    return
  fi

  # --- Operator merge hold (t-0057) ---
  # A held entry stops at the gate: verified, mergeable, not merged. The branch
  # is deliberately left unsealed so `queue-cli.sh merge` can still close it
  # after `hold-merge --release`. Checked before the solo merge rather than
  # inside it so the hold applies to the PR path too once brief 2 lands.
  if [ "$_outcome_type" = "completed" ] && [ -n "$entry_current_branch" ] \
     && _close_merge_held "$brief_id"; then
    echo "Merge held by operator — $entry_current_branch not merged, not sealed; release with 'queue-cli.sh hold-merge $brief_id --release'" >&2
    _close_record "$brief_id" "ready" "merge" "skipped" "merge_hold set by operator"
    if [ -n "$group_name" ]; then
      release_group_worktree_lock "$group_name" "$$" "${REPO_OS_SESSION_ID:-}" || true
      _CURRENT_GROUP_NAME=""
    fi
    return
  fi

  if [ "$_outcome_type" = "completed" ] && [ "$_RESULT_SOLO_MODE" = "true" ] && [ -n "$entry_current_branch" ]; then
    case "$entry_current_branch" in
      feature/*|fix/*|hotfix/*)
        local _merge_ok=false
        local _merge_conflict=false
        local _conflict_files=""
        local _pre_merge_sha=""
        # Close-time re-verification (lib/reverify-merge.sh). _reverify_failed
        # is a third outcome alongside ok/conflict: the branch must NOT be
        # sealed, because it has to stay open for the fix and the retry.
        local _reverify_failed=false
        local _reverify_rc=0
        local _reverify_lock_epoch=0
        if is_full_worktree_session; then
          # Worktree merge path (Decision 0030)
          local _main_repo="$REPO_ROOT"
          local _merge_lock="$_main_repo/.claude/.state/.merge-lock"
          if ! _acquire_runner_merge_lock "$_merge_lock"; then
            # Fail-closed (C3): write escalation and skip merge
            local _esc_dir="$REPO_ROOT/.claude/.automation/escalations"
            mkdir -p "$_esc_dir" 2>/dev/null || true
            local _esc_id="esc-merge-lock-$(date +%Y%m%d-%H%M%S)"
            {
              printf 'escalation:\n'
              printf '  id: "%s"\n' "$_esc_id"
              printf '  queue_entry_id: "%s"\n' "$brief_id"
              printf '  type: "gate-failure"\n'
              printf '  severity: "blocking"\n'
              printf '  phase_at_exit: "close"\n'
              printf '  tag_at_exit: "agent"\n'
              printf '  message: "Runner merge lock acquisition failed after 3 attempts — merge blocked (fail-closed)"\n'
              printf '  context: "lock_path: %s, branch: %s"\n' "$_merge_lock" "$entry_current_branch"
              printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
              printf '  resolved: false\n'
              printf '  resolution: ""\n'
            } > "$_esc_dir/${_esc_id}.yaml" 2>/dev/null || true
            echo "ERROR: Runner merge blocked — lock acquisition failed. Escalation: $_esc_id" >&2
            # Stays `ready`, not `conflict`: nothing was attempted against main,
            # so this is retryable with `queue-cli.sh merge <id>` once the lock
            # clears. Recording `conflict` here would refuse that retry.
            _close_record "$brief_id" "ready" "merge" "failed" "merge lock unavailable — escalation $_esc_id"
            _release_runner_merge_lock
            return 0
          fi
          _reverify_lock_epoch=$(date +%s)
          local _main_br
          _main_br=$(git -C "$_main_repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
          if [ "$_main_br" = "main" ]; then
            # Rebase + re-verify, INSIDE the lock and before any merge. A no-op
            # unless main changed a file this branch also changed.
            _reverify_rc=0
            _reverify_before_merge "$_main_repo" "$entry_current_branch" "$brief_id" || _reverify_rc=$?
            case "$_reverify_rc" in
              1) _merge_conflict=true
                 _conflict_files="$_REVERIFY_CONFLICT_FILES" ;;
              2) _reverify_failed=true ;;
            esac
            if [ "$_reverify_rc" -eq 0 ]; then
              _close_record_reverify_pass "$brief_id"
              _close_record "$brief_id" "merging" "merge" "running" "$entry_current_branch into main"
              _pre_merge_sha=$(git -C "$_main_repo" rev-parse HEAD 2>/dev/null || echo "")
              if git -C "$_main_repo" merge --ff-only "$entry_current_branch" 2>/dev/null; then
                _merge_ok=true
              elif git -C "$_main_repo" merge --no-ff -m "Merge $entry_current_branch (auto)" "$entry_current_branch" 2>/dev/null; then
                _merge_ok=true
              else
                _merge_conflict=true
                _conflict_files=$(git -C "$_main_repo" diff --name-only --diff-filter=U 2>/dev/null || echo "unknown")
                git -C "$_main_repo" merge --abort 2>/dev/null || true
              fi
            fi
          else
            echo "WARNING: Main repo on '$_main_br', not 'main' — skipping worktree merge" >&2
          fi
          _release_runner_merge_lock
          _warn_if_merge_lock_held_long "$_reverify_lock_epoch" "$entry_current_branch"
        elif git checkout main 2>/dev/null; then
          # Legacy non-worktree path. It takes no merge lock — that is
          # pre-existing (RUNNER-PARITY row 5) and not changed here — but it
          # gets the same re-verification gate, so the two paths cannot
          # disagree about whether a branch is safe to merge.
          # No _warn_if_merge_lock_held_long call here, deliberately: that
          # warning reports how long THIS holder blocked other merges, and on a
          # path that holds no lock it would block nobody and the warning would
          # be a lie. The gate still runs; only the hold measurement is absent.
          _reverify_rc=0
          _reverify_before_merge "$REPO_ROOT" "$entry_current_branch" "$brief_id" || _reverify_rc=$?
          case "$_reverify_rc" in
            1) _merge_conflict=true
               _conflict_files="$_REVERIFY_CONFLICT_FILES" ;;
            2) _reverify_failed=true ;;
          esac
          if [ "$_reverify_rc" -eq 0 ]; then
            _close_record_reverify_pass "$brief_id"
            _close_record "$brief_id" "merging" "merge" "running" "$entry_current_branch into main"
            _pre_merge_sha=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")
            if git merge --ff-only "$entry_current_branch" 2>/dev/null; then
              _merge_ok=true
            else
              # ff-only failed — try --no-ff merge
              if git merge --no-ff -m "Merge $entry_current_branch (auto)" "$entry_current_branch" 2>/dev/null; then
                _merge_ok=true
              else
                # Merge conflict — capture conflict file list before aborting
                _merge_conflict=true
                _conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null || echo "unknown")
                git merge --abort 2>/dev/null || true
              fi
            fi
          fi
        fi
        if [ "$_merge_ok" = true ]; then
          if _is_final_taskgroup_entry "$brief_id" "$work_order_id"; then
            record_closed_branch "$entry_current_branch"
            delete_merged_session_branch "$entry_current_branch" "${_main_repo:-}"
          fi
          # Detect ref-move anomaly: if main HEAD was unchanged by the merge,
          # a 'git branch -f main' ref-move likely preceded this call. Log loudly.
          local _post_merge_sha
          _post_merge_sha=$(git -C "${_main_repo:-$REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo "")
          if [ -n "$_pre_merge_sha" ] && [ "$_pre_merge_sha" = "$_post_merge_sha" ]; then
            echo "WARNING: Solo merge: 'Already up to date' — main HEAD unchanged by merge of '$entry_current_branch'. Possible prior ref-move by agent. Applying working-tree sync." >&2
          fi
          echo "Solo merge: $entry_current_branch → main (success)" >&2
          _close_record "$brief_id" "merged" "merge" "done" "merged into main at ${_post_merge_sha:0:7}"
          # Post-merge working-tree sync (unconditional — Decision 0030).
          # Syncs the main repo index and working tree to HEAD. Critical when a
          # worktree agent moved the main ref (ref-move): the ref pointer advances
          # but the main working tree's index/content remain frozen at the old state.
          # Uses git -C in all cases (_main_repo set = worktree path; absent = runner
          # is already in REPO_ROOT which IS the main repo — both cases handled).
          local _sync_dir="${_main_repo:-$REPO_ROOT}"
          if ! git -C "$_sync_dir" reset HEAD -- . 2>/dev/null; then
            echo "WARNING: Solo merge: post-merge index reset failed for '$_sync_dir'" >&2
          fi
          if ! git -C "$_sync_dir" checkout HEAD -- . 2>/dev/null; then
            echo "WARNING: Solo merge: post-merge working tree restore failed for '$_sync_dir'" >&2
          fi
          # Stale-tree detection backstop (Decision 0030): after sync, verify main
          # tree matches HEAD. A non-quiet result means sync could not repair the
          # stale content — escalate rather than silently continue.
          if ! git -C "$_sync_dir" diff HEAD --quiet 2>/dev/null; then
            echo "ERROR: Main working tree still stale after post-merge sync — index/tree differ from HEAD. Merged code is committed but absent from disk. Repair: 'git -C $_sync_dir checkout HEAD -- . && git -C $_sync_dir clean -fd'" >&2
            local _esc_dir="$REPO_ROOT/.claude/.automation/escalations"
            mkdir -p "$_esc_dir" 2>/dev/null || true
            local _stale_esc_id="esc-stale-main-$(date +%Y%m%d-%H%M%S)-$$"
            {
              printf 'escalation:\n'
              printf '  id: "%s"\n' "$_stale_esc_id"
              printf '  queue_entry_id: "%s"\n' "$brief_id"
              printf '  type: "gate-failure"\n'
              printf '  severity: "blocking"\n'
              printf '  phase_at_exit: "close"\n'
              printf '  tag_at_exit: "close"\n'
              printf '  message: "Main working tree stale after solo merge sync — index/tree differ from HEAD. Merged code committed but absent from disk (likely caused by prior ref-move from worktree)."\n'
              printf '  context: "sync_dir: %s, branch: %s"\n' "$_sync_dir" "$entry_current_branch"
              printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
              printf '  resolved: false\n'
              printf '  resolution: ""\n'
            } > "$_esc_dir/${_stale_esc_id}.yaml" 2>/dev/null || true
            echo "Escalation written: $_stale_esc_id" >&2
          fi
          # Push to remote — push_on_complete or advisory fallback
          local _repo_mode_file="$REPO_ROOT/.claude/repo-mode"
          local _is_template=false
          [ -f "$_repo_mode_file" ] && grep -q "template" "$_repo_mode_file" 2>/dev/null && _is_template=true
          if [ "$push_on_complete" = "true" ] && git remote get-url origin >/dev/null 2>&1; then
            if git push -u origin main >/dev/null 2>&1; then
              _close_record "$brief_id" "pushed" "push" "done" "origin main"
            else
              echo "WARNING: push_on_complete failed — run 'git push origin main' manually" >&2
              # State stays `merged`: main HAS the work, only origin does not.
              _close_record "$brief_id" "" "push" "failed" "git push -u origin main failed"
            fi
          elif [ "$_is_template" = false ] && git remote get-url origin >/dev/null 2>&1; then
            if git push origin main >/dev/null 2>&1; then
              _close_record "$brief_id" "pushed" "push" "done" "origin main (advisory push)"
            else
              echo "Advisory: push to origin failed — run 'git push origin main' manually" >&2
              _close_record "$brief_id" "" "push" "failed" "advisory push to origin main failed"
            fi
          else
            _close_record "$brief_id" "" "push" "skipped" "no push configured for this repo"
          fi
        elif [ "$_merge_conflict" = true ]; then
          # Merge conflict — write scope-deviation escalation and transition to review
          git checkout "$entry_current_branch" 2>/dev/null || true
          local _esc_dir="$REPO_ROOT/.claude/.automation/escalations"
          mkdir -p "$_esc_dir" 2>/dev/null || true
          local _esc_id="esc-merge-$(date +%Y%m%d-%H%M%S)"
          local _esc_context
          _esc_context=$(printf '%s' "$_conflict_files" | tr '\n' ',' | sed 's/,$//')
          {
            printf 'escalation:\n'
            printf '  id: "%s"\n' "$_esc_id"
            printf '  queue_entry_id: "%s"\n' "$brief_id"
            printf '  type: "scope-deviation"\n'
            printf '  severity: "blocking"\n'
            printf '  phase_at_exit: "close"\n'
            printf '  tag_at_exit: "agent"\n'
            printf '  message: "Merge conflict during solo merge of %s into main"\n' "$entry_current_branch"
            printf '  context: "conflict_files: %s"\n' "$_esc_context"
            printf '  scope_classification: ""\n'
            printf '  risk_gain:\n'
            printf '    risk: "Branch has diverged from main — manual conflict resolution required"\n'
            printf '    gain: ""\n'
            printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '  resolved: false\n'
            printf '  resolution: ""\n'
          } > "$_esc_dir/${_esc_id}.yaml" 2>/dev/null || true
          # Override outcome to review so daemon transitions entry correctly
          _RESULT_OUTCOME="review:merge-conflict"
          # The conflicting files are the detail an operator acts on, so they go
          # in the step row as well as the escalation.
          _close_record "$brief_id" "conflict" "merge" "failed" "conflict_files: $_esc_context"
          echo "Solo merge conflict: $entry_current_branch — escalation $_esc_id written, entry → review" >&2
        elif [ "$_reverify_failed" = true ]; then
          # Re-verification of the rebased branch did not pass. The branch is
          # deliberately NOT sealed and NOT merged: it has to stay open for the
          # fix and the retry, and main must not receive code that failed its
          # own checks. _reverify_before_merge already wrote the esc-reverify
          # escalation naming the failing checks, the overlapping files and the
          # main commit that changed them.
          _RESULT_OUTCOME="review:reverify-failed"
          _close_record "$brief_id" "reverify_failed" "reverify" "failed" "${_REVERIFY_FAIL_REASON:-unknown}"
          echo "Re-verification failed for $entry_current_branch — NOT merged, NOT sealed; escalation ${_REVERIFY_ESCALATION_ID:-unknown} written, entry → review" >&2
          echo "  reason: ${_REVERIFY_FAIL_REASON:-unknown}" >&2
        else
          # Non-conflict failure (e.g., checkout failed) — seal branch (Leak Point 6)
          git merge --abort 2>/dev/null || true
          git checkout "$entry_current_branch" 2>/dev/null || true
          if _is_final_taskgroup_entry "$brief_id" "$work_order_id"; then
            record_closed_branch "$entry_current_branch"
          fi
          echo "WARNING: Solo merge of '$entry_current_branch' into main failed — branch sealed" >&2
          # `ready`, not `conflict`: there were no unmerged paths, so the cause
          # is something like a failed checkout or main not being on main. That
          # is retryable, and `conflict` would refuse the retry. The step row
          # carries the distinction a bare state cannot.
          _close_record "$brief_id" "ready" "merge" "failed" "merge failed without conflict — branch sealed, retry with 'merge'"
        fi
        ;;
      *)
        # Not a solo-mergeable branch type — seal only
        if _is_final_taskgroup_entry "$brief_id" "$work_order_id"; then
          record_closed_branch "$entry_current_branch"
        fi
        _close_record "$brief_id" "ready" "merge" "skipped" "branch '$entry_current_branch' is not a solo-mergeable type"
        ;;
    esac
  elif [ "$_outcome_type" = "completed" ] && [ "$push_on_complete" = "true" ] && [ -n "$entry_current_branch" ] && [ "$entry_current_branch" != "main" ]; then
    # Non-solo completed entry with push_on_complete.
    #
    # On `close_path: pr` this is where the pull request is opened (t-0057 §10,
    # brief 2). The trigger is push_on_complete and NOT close_path alone, even
    # though close_path already defaults to `pr` for every non-solo entry: an
    # entry that never asked to be pushed must not start reaching origin because
    # the close pipeline grew a PR route. Opting in stays a per-entry decision.
    #
    # Gated on finality as well (Decision 0015 §3): a task group closes once, at
    # its last brief. Opening a PR per brief would put the group's partial work
    # in front of a reviewer three times. A non-final brief takes the plain push
    # below, which is what it did before this route existed.
    #
    # Nothing in this arm reads _QE_* after the guard: _close_entry_close_path,
    # _is_final_taskgroup_entry and pr_open each run _load_queue_entry and leave
    # those globals holding whichever entry they looked at last. Everything the
    # arm needs afterwards comes either from locals captured before the guard
    # ($entry_current_branch, $brief_id) or from pr_open's own _PR_* report,
    # which is a separate set _load_queue_entry does not touch.
    local _pr_opened=false
    if [ "$(_close_entry_close_path "$brief_id")" = "pr" ] \
       && _is_final_taskgroup_entry "$brief_id" "$work_order_id"; then
      local _pr_entry_file
      if _pr_entry_file=$(_close_entry_path "$brief_id") \
         && type pr_open > /dev/null 2>&1; then
        # pr_open pushes the branch itself and records every close step it
        # takes, including each documented degrade. It returns 0 for all of
        # them — a missing `gh` is not a failed entry (brief 2 step 5) — so the
        # outcome is read from the state it recorded, not from its exit code.
        pr_open "$_pr_entry_file" || true
        _pr_opened=true
        # pr-manager never decides an entry's outcome — it reports one and the
        # caller routes it. The only outcome it raises here is a conflict seen
        # on a pull request it adopted, which must reach review exactly as a
        # solo merge conflict does.
        if [ -n "${_PR_OUTCOME:-}" ]; then
          _RESULT_OUTCOME="$_PR_OUTCOME"
          echo "Pull request for $entry_current_branch reported ${_PR_OUTCOME} — entry → review" >&2
        fi
        if [ -n "${_PR_NUMBER:-}" ] && [ "${_PR_NUMBER:-0}" != "0" ]; then
          echo "Opened pull request #${_PR_NUMBER} for $entry_current_branch — ${_PR_URL:-no url}" >&2
        else
          echo "PR close path degraded for $entry_current_branch: ${_PR_REASON:-unknown} — entry stays at ready" >&2
        fi
      fi
    fi
    if [ "$_pr_opened" = false ]; then
      if git remote get-url origin >/dev/null 2>&1; then
        if ! git push -u origin "$entry_current_branch" >/dev/null 2>&1; then
          echo "WARNING: push_on_complete failed for $entry_current_branch — push manually" >&2
        fi
      fi
      # Manual-close entry: pushed, but nothing merged. It stops here awaiting
      # an operator `merge` (t-0057).
      _close_record "$brief_id" "ready" "push-branch" "done" "origin $entry_current_branch"
    fi
    if _is_final_taskgroup_entry "$brief_id" "$work_order_id"; then
      # Sealed even with a pull request still open: sealing retires the branch
      # from LOCAL session use (Decision 0013), and everything left to do —
      # checks, update-branch, the merge itself — happens on origin through gh.
      # pr-manager's own seal after a merge lands is what deletes the local
      # branch; record_closed_branch is idempotent, so running here first is
      # not a double-seal.
      record_closed_branch "$entry_current_branch"
    fi
  elif [ -n "$entry_current_branch" ] && [ "$entry_current_branch" != "main" ]; then
    # Non-solo or failed outcome — still seal the branch
    if _is_final_taskgroup_entry "$brief_id" "$work_order_id"; then
      record_closed_branch "$entry_current_branch"
    fi
    # Only a COMPLETED entry is ready to close. A failed or review outcome has
    # no close pipeline to be at the head of, and saying `ready` would offer the
    # operator a merge of work that never passed its checks.
    if [ "$_outcome_type" = "completed" ]; then
      _close_record "$brief_id" "ready" "" "" ""
    fi
  fi

  # --- Task group worktree lifetime (Decision 0054) ---
  # The group worktree outlives individual briefs, so it is removed only once
  # the final brief's branch has actually been sealed. The closed-branches
  # ledger is the primary signal rather than a flag threaded through the five
  # seal sites above: it is the same signal Decision 0013 uses, and it already
  # encodes the case that matters most — a merge conflict deliberately leaves
  # the branch unsealed for retry, so the worktree must survive too.
  # Either way the occupancy lock is released here: it was held across the
  # merge so no other session could claim the worktree mid-merge.
  if [ -n "$group_name" ]; then
    local _gwt_sealed=false
    if [ -n "$entry_current_branch" ] \
       && grep -qxF "$entry_current_branch" "$REPO_ROOT/.claude/local/closed-branches" 2>/dev/null \
       && _is_final_taskgroup_entry "$brief_id" "$work_order_id"; then
      _gwt_sealed=true
    fi
    if [ "$_gwt_sealed" = true ]; then
      remove_group_worktree "$group_name" "$$" "${REPO_OS_SESSION_ID:-}" || true
      echo "Removed task group worktree for '$group_name' — final brief merged and sealed" >&2
      _CURRENT_WORKTREE_DIR=""
      _CURRENT_WORKTREE_IS_GROUP=false
    else
      release_group_worktree_lock "$group_name" "$$" "${REPO_OS_SESSION_ID:-}" || true
    fi
    _CURRENT_GROUP_NAME=""
  fi
}

# ============================================================
# Close-only mode (Decision t-0057)
# ============================================================
# Runs the close pipeline for ONE already-completed entry and exits. No session
# is launched, no outcome is detected, no queue status transition happens — this
# is the operator saying "close that one now", and the only thing it adds to the
# normal flow is the timing.
#
# It exists so `queue-cli.sh merge` reaches the real pipeline. queue-cli.sh
# cannot source this file (argv parsing and a daemon loop run at load), and a
# second copy of _solo_merge_if_needed would be a second merge gate free to
# disagree with this one about when a branch is safe to merge.

if [ -n "$CLOSE_ENTRY_ID" ]; then
  _ce_file=$(_find_entry_file "$CLOSE_ENTRY_ID" 2>/dev/null) || _ce_file=""
  if [ -z "$_ce_file" ] || [ ! -f "$_ce_file" ]; then
    echo "ERROR: entry not found: $CLOSE_ENTRY_ID" >&2
    exit 1
  fi

  # Fail-closed precondition. The same check queue-cli.sh ran before invoking
  # us, repeated here because this mode is reachable directly and the queue can
  # have moved on in between.
  _ce_refusal=$(queue_close_merge_allowed "$_ce_file") || {
    echo "REFUSED: $_ce_refusal" >&2
    exit 1
  }

  _load_queue_entry "$_ce_file"
  _ce_branch="$_QE_BRANCH"
  _ce_push="${_QE_PUSH_ON_COMPLETE:-false}"
  _ce_wo="${_QE_WORK_ORDER_ID:-}"

  if [ -z "$_ce_branch" ]; then
    echo "ERROR: entry $CLOSE_ENTRY_ID has no branch recorded — nothing to merge" >&2
    exit 1
  fi

  # The operator is acting now, and queue_close_merge_allowed has already let
  # `held` through on that basis (the hold stops the RUNNER merging unattended,
  # not its owner merging deliberately). This flag is what tells the hold check
  # inside _solo_merge_if_needed that it is looking at the deliberate case.
  _CLOSE_ENTRY_MODE=true

  # _solo_merge_if_needed is driven entirely by the _RESULT_* globals a session
  # would have left behind. A manual-close entry is exactly a completed one
  # whose solo merge was deferred, so that is what it is told.
  _RESULT_OUTCOME="completed"
  _RESULT_SOLO_MODE="true"
  _RESULT_REVERIFIED=""
  _RESULT_OVERLAP_FILES=""

  # The group name is deliberately NOT passed. Its only effects in there are
  # releasing a group worktree occupancy lock and removing the worktree — both
  # keyed to the session that holds them, and this process holds neither. The
  # worktree outliving an operator close is untidy; releasing another process's
  # lock would be a correctness bug.
  #
  # The merge lock is acquired here only on the path where
  # _solo_merge_if_needed does NOT acquire it itself (the legacy checkout path,
  # RUNNER-PARITY row 5). Same predicate, so there is never a second
  # acquisition — _acquire_runner_merge_lock is not reentrant and would
  # fail-closed on one.
  _ce_took_lock=false
  if ! is_full_worktree_session; then
    if ! _acquire_runner_merge_lock "$REPO_ROOT/.claude/.state/.merge-lock"; then
      echo "REFUSED: runner merge lock unavailable — another merge is in flight" >&2
      _release_runner_merge_lock
      exit 1
    fi
    _ce_took_lock=true
  fi

  _solo_merge_if_needed "$_ce_branch" "$_ce_push" "$CLOSE_ENTRY_ID" "$_ce_wo" ""

  if [ "$_ce_took_lock" = true ]; then
    _release_runner_merge_lock
  fi

  # Same write-back the daemon does after its own merge: both fields stay at
  # their defaults when the gate did not run, which is how the entry says "no
  # overlap" rather than "passed".
  _ce_file=$(_find_entry_file "$CLOSE_ENTRY_ID" 2>/dev/null) || _ce_file=""
  if [ -n "$_ce_file" ] && [ -f "$_ce_file" ] \
     && { [ -n "$_RESULT_REVERIFIED" ] || [ -n "$_RESULT_OVERLAP_FILES" ]; }; then
    _load_queue_entry "$_ce_file"
    _QE_REVERIFIED="$_RESULT_REVERIFIED"
    _QE_OVERLAP_FILES=$(queue_yaml_flow_seq "$_RESULT_OVERLAP_FILES")
    _write_queue_entry "$_ce_file"
  fi

  # Report the recorded state rather than inferring success from the absence of
  # errors. The entry's queue status is left alone on purpose: a conflict here
  # is a close-pipeline failure on an entry whose work is finished, and moving a
  # completed entry back to review/ is a transition nobody asked for. The
  # escalation _solo_merge_if_needed wrote is the operator's signal.
  _ce_state="unknown"
  if [ -n "$_ce_file" ] && [ -f "$_ce_file" ]; then
    _load_queue_entry "$_ce_file"
    _ce_state=$(queue_close_state)
  fi
  echo "Close pipeline finished for $CLOSE_ENTRY_ID — close_state: $_ce_state" >&2
  case "$_ce_state" in
    merged|pushed) exit 0 ;;
    *) exit 1 ;;
  esac
fi

# ============================================================
# Single-shot mode (backward compatible with Brief 2)
# ============================================================

if [ "$DAEMON_MODE" = false ]; then
  # Validate session type
  VALID_PHASES=$(get_phases_for_type "$SESSION_TYPE")
  if [ -z "$VALID_PHASES" ]; then
    echo "ERROR: Unknown session type: $SESSION_TYPE" >&2
    exit 1
  fi

  # Config enabled check
  RUNNER_ENABLED=$(_parse_config_field "runner" "enabled")
  if [ -z "$RUNNER_ENABLED" ]; then
    echo "ERROR: Could not parse runner.enabled from config" >&2
    exit 1
  fi
  if [ "$RUNNER_ENABLED" != "true" ]; then
    echo "Runner disabled (enabled: $RUNNER_ENABLED). Exiting." >&2
    exit 0
  fi

  # HALT file check
  if [ -f "$AUTOMATION_DIR/HALT" ]; then
    echo "HALT file present. Runner stopped." >&2
    exit 0
  fi

  # Build prompt (single-shot uses a minimal prompt)
  PROMPT="You are working on brief: $BRIEF_ID. Read the task brief and execute it."

  # Log entry-started event
  review_log_append "entry-started" "" "$BRIEF_ID" \
    "Entry $BRIEF_ID started (single-shot)" 2>/dev/null || true

  # Execute (direct call — no subshell, outcome in globals)
  # Single-shot mode builds a minimal prompt and has no brief path, so the
  # Decision 0054 group-worktree path does not engage here — the entry falls
  # back to a per-session worktree (Decision 0033).
  _run_single_entry "$BRIEF_ID" "$PROMPT" "$SESSION_TYPE" "$EXISTING_BRANCH" "${_QE_PERMISSION_PROFILE:-build}" "false" "${_QE_BRIEF_PATH:-}" ""

  # Solo merge + branch seal (Phase 2: extracted from _run_single_entry)
  _solo_merge_if_needed "$_RESULT_BRANCH" "false" "$BRIEF_ID" "" "$_CURRENT_GROUP_NAME"

  # Belt-and-suspenders: check globals are populated
  if [ -z "$_RESULT_OUTCOME" ]; then
    echo "WARNING: Empty outcome from _run_single_entry — treating as failure" >&2
    exit 1
  fi

  OUTCOME="${_RESULT_OUTCOME%%:*}"

  case "$OUTCOME" in
    completed) exit 0 ;;
    review)    exit 2 ;;
    stopped)   exit 4 ;;  # operator stop — not a failure (Decision t-0055)
    failed)    exit 1 ;;
    *)         exit 1 ;;
  esac
fi

# ============================================================
# Daemon mode — queue-driven loop
# ============================================================

# --- PID file guard (flock-based atomic guard) ---
PID_FILE="$AUTOMATION_DIR/runner.pid"
DAEMON_LOCK_FILE="$AUTOMATION_DIR/.daemon-lock"

_cleanup_pid_file() {
  rm -f "$PID_FILE" 2>/dev/null || true
}

# Acquire exclusive daemon lock (flock on macOS/Linux, mkdir fallback)
_DAEMON_LOCK_FD=""
if command -v flock > /dev/null 2>&1; then
  # flock available — use file descriptor lock (held for daemon lifetime)
  exec 9>"$DAEMON_LOCK_FILE"
  if ! flock -n 9; then
    # Another daemon holds the lock — check PID file for diagnostics
    EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null || echo "unknown")
    echo "Daemon already running (pid $EXISTING_PID, lock held)" >&2
    exit 0
  fi
  _DAEMON_LOCK_FD=9
else
  # flock unavailable (some macOS) — fall back to mkdir-based atomic lock
  if ! mkdir "$DAEMON_LOCK_FILE.d" 2>/dev/null; then
    # Lock dir exists — check if holder is still alive via PID file
    EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
      echo "Daemon already running (pid $EXISTING_PID)" >&2
      exit 0
    else
      # Stale lock — reclaim (rm -rf: dir may be non-empty with pid file)
      echo "Removing stale daemon lock (pid $EXISTING_PID not running)" >&2
      rm -rf "$DAEMON_LOCK_FILE.d" 2>/dev/null || true
      if ! mkdir "$DAEMON_LOCK_FILE.d" 2>/dev/null; then
        echo "ERROR: Cannot acquire daemon lock" >&2
        exit 1
      fi
      # Write our PID immediately after acquiring the lock dir so the
      # secondary liveness check below reads fresh data (not stale PID).
      printf '%s' "$$" > "$PID_FILE" 2>/dev/null || true
      # Secondary liveness check (C10 TOCTOU patch): another process may have
      # raced us — if PID file was overwritten by a different daemon, yield.
      _post_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
      if [ -n "$_post_pid" ] && [ "$_post_pid" != "$$" ] && kill -0 "$_post_pid" 2>/dev/null; then
        echo "Race detected: daemon pid $_post_pid overwrote our PID — yielding" >&2
        rm -rf "$DAEMON_LOCK_FILE.d" 2>/dev/null || true
        exit 0
      fi
    fi
  fi
fi

# Write PID file (under lock — no race)
printf '%s' "$$" > "$PID_FILE"

_cleanup_daemon_lock() {
  rm -f "$PID_FILE" 2>/dev/null || true
  if [ -n "$_DAEMON_LOCK_FD" ]; then
    # flock released automatically on fd close
    eval "exec ${_DAEMON_LOCK_FD}>&-" 2>/dev/null || true
  else
    rm -rf "$DAEMON_LOCK_FILE.d" 2>/dev/null || true
  fi
}
_graceful_shutdown() {
  _SHUTDOWN_REQUESTED=true
  # SIGTERM source diagnostics — helps identify whether signal comes from
  # launchd, another runner instance, or macOS process management.
  local _sig_ts _sig_ppid _sig_parent_cmd
  _sig_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
  _sig_ppid=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ' || echo "unknown")
  _sig_parent_cmd=$(ps -o comm= -p "$_sig_ppid" 2>/dev/null || echo "unknown")
  echo "Shutdown requested at $_sig_ts — daemon pid $$, ppid $_sig_ppid ($_sig_parent_cmd), child_active=${_CLAUDE_CHILD_PID:+yes}${_CLAUDE_CHILD_PID:-no}" >&2
  echo "Deferring shutdown until active session completes and queue transition finishes..." >&2
}
trap '_graceful_shutdown' TERM INT
trap '_stop_heartbeat || true; _runner_crash_cleanup || true; _write_health "stopped" || true; _cleanup_daemon_lock || true' EXIT

echo "Runner daemon starting (pid $$)..." >&2

_ensure_queue_dirs

# Pre-flight: same-filesystem check (one-time at startup)
_check_same_filesystem

_DAEMON_START_EPOCH=$(date +%s)

# --- Pin a stable daemon-level identity (per-process session identity) ---
# The daemon's own loop calls get_session_id/get_session_state_dir (startup
# sweeps, review-item scoring, cleanup). Without REPO_OS_SESSION_ID those hit
# get_session_id's no-stdin fallback and write a SHARED flat .claude/.session-id,
# which an interactive window can then ADOPT (no sidecar exists to trigger a mint)
# — re-aliasing the very thing the per-process identity scheme fixes. Pinning an
# env id here makes the daemon's get_session_id return it and write neither the
# flat file nor a sidecar. Per-brief processing overrides this with its own
# isolated daemon-<ts> id (+ worktree); the loop re-asserts this id each iteration.
_DAEMON_SESSION_ID="daemon-main-${_DAEMON_START_EPOCH}-$$"
export REPO_OS_SESSION_ID="$_DAEMON_SESSION_ID"

# --- Startup crash recovery ---
_startup_crash_recovery

# --- Startup review-items sweep ---
# Remove stale review-items/ subdirectories older than 7 days.
# Follows the same startup-sweep pattern as sweep_stale_sessions above.
_ri_count=$(sweep_stale_review_items 2>/dev/null || echo "0")
[ "$_ri_count" -gt 0 ] && echo "startup: removed $_ri_count stale review-items directories (>7d)" >&2
unset _ri_count

# Cleanup tracking — run cleanup every N idle cycles
_IDLE_CYCLE_COUNT=0
_CLEANUP_INTERVAL=10  # Run cleanup every 10 idle cycles

while true; do
  # Re-assert the daemon's own identity. Per-brief processing overrides
  # REPO_OS_SESSION_ID with an isolated daemon-<ts> id (and uses it for post-brief
  # cleanup); restoring it here keeps the daemon loop's own get_session_id calls
  # env-pinned so they never touch the shared .claude/.session-id.
  export REPO_OS_SESSION_ID="$_DAEMON_SESSION_ID"

  # --- Shutdown check ---
  if [ "$_SHUTDOWN_REQUESTED" = true ]; then
    echo "Shutdown: exiting daemon loop (graceful)" >&2
    break
  fi

  # --- HALT file check ---
  if [ -f "$AUTOMATION_DIR/HALT" ]; then
    echo "HALT file present. Runner stopped." >&2
    break
  fi

  # --- FORCE-HALT file check (immediate — kill active session) ---
  if [ -f "$AUTOMATION_DIR/FORCE-HALT" ]; then
    echo "FORCE-HALT file present. Killing active session if any..." >&2
    if [ -n "$_CLAUDE_CHILD_PID" ] && kill -0 "$_CLAUDE_CHILD_PID" 2>/dev/null; then
      kill -TERM "$_CLAUDE_CHILD_PID" 2>/dev/null || true
      # Wait up to 10 seconds for graceful exit
      _fh_wait=0
      while [ "$_fh_wait" -lt 10 ] && kill -0 "$_CLAUDE_CHILD_PID" 2>/dev/null; do
        sleep 1
        _fh_wait=$((_fh_wait + 1))
      done
      # SIGKILL if still alive
      if kill -0 "$_CLAUDE_CHILD_PID" 2>/dev/null; then
        echo "FORCE-HALT: child still alive after 10s — sending SIGKILL" >&2
        kill -KILL "$_CLAUDE_CHILD_PID" 2>/dev/null || true
        wait "$_CLAUDE_CHILD_PID" 2>/dev/null || true
      fi
    fi
    # --- Clean up worktree if one was created (Decision 0033) ---
    # Task group worktrees survive a force-halt (Decision 0054): the group is
    # mid-flight and its working state is what the operator will want on
    # restart. Only the occupancy lock is released.
    # Release the lock on _CURRENT_GROUP_NAME alone, for the same reason as
    # _runner_crash_cleanup: the lock is taken before _CURRENT_WORKTREE_IS_GROUP
    # is set, so gating the release on that flag would miss the window.
    if [ -n "$_CURRENT_GROUP_NAME" ]; then
      release_group_worktree_lock "$_CURRENT_GROUP_NAME" "$$" "${REPO_OS_SESSION_ID:-}" 2>/dev/null || true
      _CURRENT_GROUP_NAME=""
    fi
    _fh_patch=""
    if [ "$_CURRENT_WORKTREE_IS_GROUP" = true ]; then
      if [ -n "$_CURRENT_WORKTREE_DIR" ]; then
        echo "FORCE-HALT: task group worktree '$_CURRENT_WORKTREE_DIR' left in place (Decision 0054)" >&2
      fi
      _CURRENT_WORKTREE_DIR=""
      _CURRENT_WORKTREE_IS_GROUP=false
    elif [ -n "$_CURRENT_WORKTREE_DIR" ] && [ -d "$_CURRENT_WORKTREE_DIR" ]; then
      remove_session_worktree "$_CURRENT_WORKTREE_DIR" "${_RESULT_BASELINE:-}" "${_CURRENT_ENTRY_ID:-}" "failed:force-halt"
      _fh_patch="$_PRESERVED_PATCH_PATH"
      _CURRENT_WORKTREE_DIR=""
    fi
    _fh_note=$(preserved_work_note "$_fh_patch" "$REPO_ROOT")
    # --- Transition running entry to failed/ ---
    if [ -n "$_CURRENT_ENTRY_ID" ]; then
      _fh_qdir=$(_queue_dir)
      _fh_entry_file="$_fh_qdir/running/${_CURRENT_ENTRY_ID}.yaml"
      if [ -f "$_fh_entry_file" ]; then
        if acquire_queue_lock; then
          _load_queue_entry "$_fh_entry_file"
          _QE_STATUS="failed"
          _QE_ERROR_LOG="force-halted${_fh_note:+; ${_fh_note}}"
          _QE_COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          _QE_UPDATED_AT="$_QE_COMPLETED_AT"
          _write_queue_entry "$_fh_qdir/failed/${_CURRENT_ENTRY_ID}.yaml"
          rm -f "$_fh_entry_file"
          rm -f "$_fh_qdir/running/${_CURRENT_ENTRY_ID}.heartbeat" 2>/dev/null || true
          _rebuild_queue_index || true
          # Propagate failure to work order if entry belongs to one
          if [ -n "$_QE_WORK_ORDER_ID" ]; then
            _fh_wo_status=$(wo_check_completion "$_QE_WORK_ORDER_ID" 2>/dev/null) || {
              echo "WARNING: wo_check_completion failed for work order $_QE_WORK_ORDER_ID after force-halt of entry $_CURRENT_ENTRY_ID" >&2
            }
            case "$_fh_wo_status" in
              failed)
                review_log_append "work-order-failed" "$_QE_WORK_ORDER_ID" "" \
                  "Work order $_QE_WORK_ORDER_ID failed — entry $_CURRENT_ENTRY_ID force-halted. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                ;;
              escalated)
                review_log_append "work-order-escalated" "$_QE_WORK_ORDER_ID" "" \
                  "Work order $_QE_WORK_ORDER_ID escalated — entry $_CURRENT_ENTRY_ID force-halted. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                ;;
              completed)
                review_log_append "work-order-completed" "$_QE_WORK_ORDER_ID" "" \
                  "Work order $_QE_WORK_ORDER_ID completed — all children terminal after force-halt of $_CURRENT_ENTRY_ID" 2>/dev/null || true
                ;;
              "")
                echo "WARNING: wo_check_completion returned empty status for work order $_QE_WORK_ORDER_ID (force-halt, entry $_CURRENT_ENTRY_ID)" >&2
                ;;
            esac
          fi
          release_queue_lock
          echo "FORCE-HALT: entry $_CURRENT_ENTRY_ID transitioned to failed/" >&2
        else
          echo "WARNING: FORCE-HALT could not acquire lock — entry $_CURRENT_ENTRY_ID may be orphaned in running/" >&2
        fi
      fi
      # Write escalation file
      _fh_esc_dir="$REPO_ROOT/.claude/.automation/escalations"
      mkdir -p "$_fh_esc_dir" 2>/dev/null || true
      _fh_esc_id="esc-${_CURRENT_ENTRY_ID}-$(date +%Y%m%d-%H%M%S)"
      {
        printf 'escalation:\n'
        printf '  id: "%s"\n' "$_fh_esc_id"
        printf '  queue_entry_id: "%s"\n' "$_CURRENT_ENTRY_ID"
        printf '  type: "gate-failure"\n'
        printf '  severity: "blocking"\n'
        printf '  phase_at_exit: "unknown"\n'
        printf '  tag_at_exit: "agent"\n'
        printf '  message: "FORCE-HALT — entry terminated by operator"\n'
        printf '  context: "Daemon received FORCE-HALT file while entry was running%s"\n' "$(printf '%s' "${_fh_note:+; ${_fh_note}}" | tr -d '"\\')"
        printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  resolved: false\n'
        printf '  resolution: ""\n'
      } > "$_fh_esc_dir/${_fh_esc_id}.yaml" 2>/dev/null || true
      _stop_heartbeat
      _CURRENT_ENTRY_ID=""
    fi
    rm -f "$AUTOMATION_DIR/FORCE-HALT" 2>/dev/null || true
    echo "FORCE-HALT: daemon exiting." >&2
    break
  fi

  # --- Config reload (live toggle support) ---
  RUNNER_ENABLED=$(_parse_config_field "runner" "enabled")
  if [ "$RUNNER_ENABLED" != "true" ]; then
    _write_health "disabled"
    echo "Runner disabled. Sleeping 30s..." >&2
    sleep 30
    continue
  fi

  # --- Stale lock check ---
  if ! _check_stale_locks; then
    echo "Stale lock detected. Breaking loop for investigation." >&2
    break
  fi

  # --- Circuit breaker check ---
  if _circuit_breaker_tripped; then
    _write_health "circuit-breaker"
    # Message stays general: the count can be 4+ after a failed probe, and the
    # fail-closed arm trips with no readable count at all. Naming the cooldown
    # here matters because this is the line an operator watches while waiting a
    # window out — it was previously the only breaker message that never
    # mentioned there was a way out.
    echo "Circuit breaker tripped. Sleeping 60s... (see 'queue-cli.sh status' for the failure count; it self-expires for one probe entry after runner.circuit_breaker_cooldown_seconds, or clear it with 'queue-cli.sh reset-breaker')" >&2
    sleep 60
    continue
  fi

  # --- Re-read open pull requests (Decision t-0057 brief 2) ---
  # Before the dequeue, not inside the idle branch: a repo whose queue is never
  # empty would otherwise never notice that a pull request merged. Takes no
  # queue lock — it only rewrites close fields on completed entries, which the
  # dequeue below does not read.
  _pr_poll_sweep || true

  # --- Dequeue oldest approved entry (locked) ---
  ENTRY_FILE=""
  if acquire_queue_lock; then
    ENTRY_FILE=$(queue_dequeue) || true
    release_queue_lock
  else
    echo "WARNING: Queue lock unavailable, retrying next cycle" >&2
    sleep 5
    continue
  fi
  if [ -z "$ENTRY_FILE" ]; then
    # Idle cycle — periodic cleanup + stale-running recovery
    _IDLE_CYCLE_COUNT=$((_IDLE_CYCLE_COUNT + 1))
    if [ "$_IDLE_CYCLE_COUNT" -ge "$_CLEANUP_INTERVAL" ]; then
      run_cleanup
      # Stale-running recovery: scan for entries with no heartbeat, stranded > 1 hour
      # Previous threshold (interval * 2 = 60s) caused false-positive recovery —
      # Claude sessions routinely run 10–20 minutes.
      _sr_qdir=$(_queue_dir)
      _sr_interval=$(_parse_config_field "runner" "heartbeat_interval")
      _sr_interval="${_sr_interval:-30}"
      _sr_threshold=$((_sr_interval * 120))
      _sr_now=$(date +%s)
      for _sr_entry_file in "$_sr_qdir/running"/*.yaml; do
        [ -f "$_sr_entry_file" ] || continue
        _sr_entry_id=$(basename "$_sr_entry_file" .yaml)
        _sr_hb_file="$_sr_qdir/running/${_sr_entry_id}.heartbeat"
        # Skip entries that have an active heartbeat (another runner is processing)
        if [ -f "$_sr_hb_file" ]; then
          _sr_hb_ts=$(cat "$_sr_hb_file" 2>/dev/null || true)
          if [ -n "$_sr_hb_ts" ]; then
            _sr_hb_epoch=$(_iso_to_epoch "$_sr_hb_ts" 2>/dev/null || echo "0")
            _sr_age=$((_sr_now - _sr_hb_epoch))
            if [ "$_sr_age" -lt "$_sr_threshold" ]; then
              continue  # Heartbeat is fresh — entry is legitimately running
            fi
          fi
          # Heartbeat exists but is stale — fall through to recovery
        fi
        # No heartbeat or stale heartbeat — check entry age via updated_at
        _load_queue_entry "$_sr_entry_file"
        _sr_entry_epoch=$(_iso_to_epoch "$_QE_UPDATED_AT" 2>/dev/null || echo "0")
        _sr_entry_age=$((_sr_now - _sr_entry_epoch))
        if [ "$_sr_entry_age" -gt "$_sr_threshold" ]; then
          echo "WARNING: Recovering stale entry $_sr_entry_id (no active heartbeat, age ${_sr_entry_age}s > ${_sr_threshold}s)" >&2
          if acquire_queue_lock; then
            _QE_STATUS="failed"
            _QE_ERROR_LOG="stranded entry — no heartbeat (recovered by daemon idle scan)"
            _QE_COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            _QE_UPDATED_AT="$_QE_COMPLETED_AT"
            _write_queue_entry "$_sr_qdir/failed/${_sr_entry_id}.yaml"
            rm -f "$_sr_entry_file"
            rm -f "$_sr_hb_file" 2>/dev/null || true
            # Propagate failure to work order if entry belongs to one
            if [ -n "$_QE_WORK_ORDER_ID" ]; then
              _sr_wo_status=$(wo_check_completion "$_QE_WORK_ORDER_ID" 2>/dev/null) || {
                echo "WARNING: wo_check_completion failed for work order $_QE_WORK_ORDER_ID after idle-scan recovery of entry $_sr_entry_id" >&2
              }
              case "$_sr_wo_status" in
                failed)
                  review_log_append "work-order-failed" "$_QE_WORK_ORDER_ID" "" \
                    "Work order $_QE_WORK_ORDER_ID failed — stranded entry $_sr_entry_id recovered by idle scan. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                  ;;
                escalated)
                  review_log_append "work-order-escalated" "$_QE_WORK_ORDER_ID" "" \
                    "Work order $_QE_WORK_ORDER_ID escalated — stranded entry $_sr_entry_id recovered by idle scan. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                  ;;
                completed)
                  review_log_append "work-order-completed" "$_QE_WORK_ORDER_ID" "" \
                    "Work order $_QE_WORK_ORDER_ID completed — all children terminal after idle-scan recovery of $_sr_entry_id" 2>/dev/null || true
                  ;;
                "")
                  echo "WARNING: wo_check_completion returned empty status for work order $_QE_WORK_ORDER_ID (idle-scan recovery, entry $_sr_entry_id)" >&2
                  ;;
              esac
            fi
            _rebuild_queue_index || true
            release_queue_lock
          else
            echo "WARNING: Could not acquire lock for stale entry recovery ($_sr_entry_id)" >&2
          fi
        fi
      done

      # --- Work order reconciliation pass (level-triggered safety net) ---
      # Catches any WO left non-terminal by the event-driven path due to daemon
      # crashes, partial writes, or missed transitions. Runs inside queue lock.
      _wo_dir_path=$(_queue_dir)/work-orders
      if [ -d "$_wo_dir_path" ]; then
        for _rec_wo_file in "$_wo_dir_path"/*.yaml; do
          [ -f "$_rec_wo_file" ] || continue
          _load_work_order "$_rec_wo_file"
          # Skip already-terminal WOs
          case "$_WO_STATUS" in
            completed) continue ;;
          esac
          # Non-terminal WO — attempt reconciliation under queue lock
          _rec_wo_id="$_WO_ID"
          if acquire_queue_lock; then
            _rec_new_status=$(wo_reconcile "$_rec_wo_id" 2>/dev/null) || {
              echo "WARNING: wo_reconcile failed for work order $_rec_wo_id (idle-scan reconciliation pass)" >&2
            }
            _rebuild_queue_index || true
            release_queue_lock
            if [ -n "$_rec_new_status" ] && [ "$_rec_new_status" != "$_WO_STATUS" ]; then
              review_log_append "work-order-reconciled" "$_rec_wo_id" "" \
                "Work order $_rec_wo_id reconciled: $_WO_STATUS → $_rec_new_status (idle-scan safety net)" 2>/dev/null || true
              echo "INFO: Work order $_rec_wo_id reconciled: $_WO_STATUS → $_rec_new_status" >&2
            fi
          else
            echo "WARNING: Could not acquire lock for WO reconciliation of $_rec_wo_id" >&2
          fi
        done
      fi

      _IDLE_CYCLE_COUNT=0
    fi
    _CONSECUTIVE_SESSION_COUNT=0
    _write_health "idle"
    _poll_interval=$(_parse_config_field "runner" "poll_interval")
    _poll_interval="${_poll_interval:-60}"
    sleep "$_poll_interval"
    continue
  fi

  # Reset idle counter on activity
  _IDLE_CYCLE_COUNT=0

  # Load entry metadata
  _load_queue_entry "$ENTRY_FILE"
  ENTRY_ID="$_QE_ID"
  ENTRY_SESSION_TYPE="$_QE_SESSION_TYPE"
  ENTRY_BRANCH="$_QE_BRANCH"
  ENTRY_BRIEF_PATH="$_QE_BRIEF_PATH"
  ENTRY_WORK_ORDER_ID="$_QE_WORK_ORDER_ID"
  ENTRY_PUSH="${_QE_PUSH_ON_COMPLETE:-false}"
  ENTRY_PERMISSION_PROFILE="${_QE_PERMISSION_PROFILE:-build}"
  ENTRY_MODEL="${_QE_MODEL:-}"
  # Operator resume (Decision t-0055 clause 8). `resume: true` is set by
  # queue_resume and consumed here — it is a one-shot instruction, so it is
  # cleared on the running copy before the session launches and a crash
  # mid-session cannot leave the entry permanently flagged for resume.
  ENTRY_RESUME="${_QE_RESUME:-false}"
  ENTRY_STOPPED_MODE="${_QE_STOPPED_MODE:-}"
  # t-0055 clause 14. Captured here with the rest, because the Parent task
  # section is built after several helpers that clobber _QE_*.
  ENTRY_FOLLOW_UP_OF="${_QE_FOLLOW_UP_OF:-}"
  if [ "$ENTRY_RESUME" = true ]; then
    _QE_RESUME="false"
    _write_queue_entry "$ENTRY_FILE" 2>/dev/null || \
      echo "WARNING: could not clear the resume flag on entry $ENTRY_ID" >&2
  fi

  echo "Processing entry: $ENTRY_ID (type: $ENTRY_SESSION_TYPE)" >&2

  # --- Merge-idempotency check (Phase 4: skip re-execution if already merged) ---
  # Skipped on a resume: the entry is mid-flight by definition, its branch is
  # checked out in the worktree it was stopped in, and the branch-deletion arm
  # below would either fail against that checkout or discard live work.
  _retry_count="${_QE_RETRY_COUNT:-0}"
  if [ "$ENTRY_RESUME" != true ] && [ "$_retry_count" -gt 0 ] && [ -n "$ENTRY_BRANCH" ]; then
    # Prior attempt created a branch — determine merge state
    _merge_skip=false
    if git rev-parse --verify "$ENTRY_BRANCH" >/dev/null 2>&1; then
      # Branch exists — count commits ahead of main
      _commits_ahead=$(git rev-list --count "main..$ENTRY_BRANCH" 2>/dev/null) || _commits_ahead=""
      if [ -z "$_commits_ahead" ] || [ "$_commits_ahead" -eq 0 ] 2>/dev/null; then
        # Zero commits ahead — branch was created but session crashed before committing.
        # Delete the stale branch so the retry can create a fresh one.
        echo "Entry $ENTRY_ID: branch $ENTRY_BRANCH has 0 commits ahead of main — stale branch from crashed session, deleting for retry" >&2
        git branch -D "$ENTRY_BRANCH" 2>/dev/null || true
        # Fall through to normal retry execution
      elif git merge-base --is-ancestor "$ENTRY_BRANCH" main 2>/dev/null; then
        # Commits ahead AND all reachable from main — genuinely merged
        echo "Entry $ENTRY_ID: branch $ENTRY_BRANCH has $_commits_ahead commit(s) ahead and is merged to main — skipping re-execution" >&2
        _merge_skip=true
      else
        # Commits ahead but NOT merged — unmerged work from prior attempt, retry
        # (message-only distinction: a non-final sequential group brief is expected
        # to have an unmerged branch — see _unmerged_branch_message)
        _unmerged_branch_message "$ENTRY_ID" "$ENTRY_BRANCH" "$_commits_ahead" "$ENTRY_BRIEF_PATH" "$ENTRY_WORK_ORDER_ID" >&2 || true
        # Fall through to normal retry execution
      fi
    else
      # Branch does not exist — fresh start, proceed normally
      echo "Entry $ENTRY_ID: branch $ENTRY_BRANCH does not exist — proceeding with fresh session" >&2
    fi

    if [ "$_merge_skip" = true ]; then
      # Transition directly to completed (locked)
      _skip_lock_attempts=0
      while ! acquire_queue_lock; do
        _skip_lock_attempts=$((_skip_lock_attempts + 1))
        if [ "$_skip_lock_attempts" -ge 3 ]; then
          echo "ERROR: Lock unavailable for idempotent completion ($ENTRY_ID)" >&2
          continue 2
        fi
        sleep 1
      done
      queue_complete "$ENTRY_ID"
      release_queue_lock
      _circuit_breaker_reset
      # Review log + work order lifecycle
      if [ -n "$ENTRY_WORK_ORDER_ID" ]; then
        review_log_append "entry-completed" "$ENTRY_WORK_ORDER_ID" "$ENTRY_ID" \
          "Entry $ENTRY_ID completed (idempotent — already merged)" 2>/dev/null || true
        _wo_new_status=$(wo_check_completion "$ENTRY_WORK_ORDER_ID" 2>/dev/null) || {
          echo "WARNING: wo_check_completion failed for work order $ENTRY_WORK_ORDER_ID after idempotent completion of entry $ENTRY_ID" >&2
        }
        case "$_wo_new_status" in
          completed)
            review_log_append "work-order-completed" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID completed — all children done" 2>/dev/null || true
            ;;
          failed)
            review_log_append "work-order-failed" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID failed — sibling entry failed. Recovery: queue-cli.sh reopen-wo $ENTRY_WORK_ORDER_ID" 2>/dev/null || true
            ;;
          escalated)
            review_log_append "work-order-escalated" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID escalated — child failure detected. Recovery: queue-cli.sh reopen-wo $ENTRY_WORK_ORDER_ID" 2>/dev/null || true
            ;;
          "")
            echo "WARNING: wo_check_completion returned empty status for work order $ENTRY_WORK_ORDER_ID (idempotent completion, entry $ENTRY_ID)" >&2
            ;;
        esac
      fi
      sleep 2
      continue
    fi
  fi

  # --- Work-order deferral guard (skip entry if sibling is escalated or failed) ---
  # When an entry belongs to an escalated or failed work order, defer it back to
  # approved/ without incrementing retry_count. The entry resumes when the work
  # order is reopened. Failed work orders block siblings just like escalated ones.
  if [ -n "$ENTRY_WORK_ORDER_ID" ]; then
    _wo_defer_reason=""
    if wo_is_escalated "$ENTRY_WORK_ORDER_ID"; then
      _wo_defer_reason="escalated"
    elif wo_is_failed "$ENTRY_WORK_ORDER_ID"; then
      _wo_defer_reason="failed"
    fi
    if [ -n "$_wo_defer_reason" ]; then
      echo "Entry $ENTRY_ID: work order $ENTRY_WORK_ORDER_ID is $_wo_defer_reason — deferring" >&2
      # Never fatal: at the cap the entry and its siblings are blocked with an
      # escalation (see _handle_wo_deferral) and the daemon moves on.
      _handle_wo_deferral "$ENTRY_ID" "$ENTRY_WORK_ORDER_ID" "$_wo_defer_reason" || true
      sleep 2
      continue
    fi
  fi

  # Re-source phase helper to pick up session types added after daemon start.
  # Fixes: new session types registered in _phase-helper.sh after daemon launch are
  # not recognized without daemon restart. Re-sourcing is safe — all functions are
  # pure lookups with no state side effects.
  # shellcheck disable=SC1090
  source "$REPO_ROOT/.claude/hooks/_phase-helper.sh" 2>/dev/null || true

  # Validate session type
  if [ -z "$(get_phases_for_type "$ENTRY_SESSION_TYPE" 2>/dev/null)" ]; then
    echo "ERROR: Invalid session type '$ENTRY_SESSION_TYPE' for entry $ENTRY_ID" >&2
    _block_lock_attempts=0
    while ! acquire_queue_lock; do
      _block_lock_attempts=$((_block_lock_attempts + 1))
      if [ "$_block_lock_attempts" -ge 3 ]; then
        echo "ERROR: Lock unavailable for queue_block — skipping transition" >&2
        continue 2  # skip to next daemon cycle
      fi
      sleep 1
    done
    queue_block "$ENTRY_ID" "Invalid session type: $ENTRY_SESSION_TYPE"
    release_queue_lock
    continue
  fi

  # --- Dirty-tree guard (Phase 3: clean working tree between entries) ---
  # Prevents cascading dirty state from a prior failed entry.
  _dirty_check=$(git status --porcelain 2>/dev/null || true)
  if [ -n "$_dirty_check" ]; then
    echo "WARNING: Dirty working tree detected before entry $ENTRY_ID — cleaning" >&2
    git checkout -- . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
  fi

  # --- Assemble prompt (lazy generation at dequeue time) ---
  if [ "$ENTRY_RESUME" = true ]; then
    # A resume continues an existing transcript, so the whole brief is already
    # in the child's context — re-sending it would duplicate it. The message is
    # the operator's instruction to carry on. The phase chain, unlike the
    # transcript, does NOT survive the stop (cleanup_session_files removes
    # phase-state at close and state_manager_setup re-inits at `init`), so the
    # message says so rather than letting the agent assume otherwise.
    PROMPT="Resumed by operator."
    if [ "$ENTRY_STOPPED_MODE" = "forced" ]; then
      PROMPT="$PROMPT The previous session was force-stopped; check the working tree before continuing."
    fi
    PROMPT="$PROMPT Session state was reset to the init phase at the stop, so re-advance the phases from where your work actually stands."
  else
    PROMPT=$(assemble_prompt "$ENTRY_FILE")
  fi

  # A follow-up's parent context (t-0055 clause 14), appended before the notes
  # so the ordering reads brief → background → operator amendment. Skipped on a
  # resume: the resumed transcript already contains the section from the
  # session's first launch, and re-sending it would compete with the operator's
  # actual instruction to carry on.
  if [ "$ENTRY_RESUME" != true ] && [ -n "$ENTRY_FOLLOW_UP_OF" ]; then
    _ENTRY_PARENT=$(_build_parent_task_section "$ENTRY_ID" "$ENTRY_FOLLOW_UP_OF") || _ENTRY_PARENT=""
    if [ -n "$_ENTRY_PARENT" ]; then
      PROMPT="$PROMPT

$_ENTRY_PARENT"
      review_log_append "entry-parent-context" "$ENTRY_WORK_ORDER_ID" "$ENTRY_ID" \
        "Entry $ENTRY_ID is a follow-up of $ENTRY_FOLLOW_UP_OF — parent context added to its prompt" 2>/dev/null || true
    fi
  fi

  # Operator notes written while this entry was queued or stopped ride in with
  # the prompt — the one moment before the session starts where context can
  # still be added (t-0055 clause 13). Appended after the brief in both cases,
  # so the note reads as an amendment to the brief rather than a replacement.
  _ENTRY_NOTES=$(_drain_operator_notes "$ENTRY_ID") || _ENTRY_NOTES=""
  if [ -n "$_ENTRY_NOTES" ]; then
    PROMPT="$PROMPT

$_ENTRY_NOTES"
    review_log_append "entry-notes-delivered" "$ENTRY_WORK_ORDER_ID" "$ENTRY_ID" \
      "Operator notes delivered to entry $ENTRY_ID in its $([ "$ENTRY_RESUME" = true ] && echo "resume message" || echo "prompt")" 2>/dev/null || true
  fi

  # --- Re-check HALT / FORCE-HALT (last stop before the session starts) ---
  # The loop-top check is stale by now. Deliberately placed as late as the loop
  # allows, directly before the heartbeat and launch. Do not move it earlier
  # and do not remove it: it is what makes "once the flag exists, no new entry
  # starts" true. `continue` hands the flag to the loop-top handler.
  if _return_entry_if_halted "$ENTRY_ID"; then
    continue
  fi

  # --- Start heartbeat ---
  _start_heartbeat "$ENTRY_ID"

  # --- Log entry-started event ---
  review_log_append "entry-started" "$ENTRY_WORK_ORDER_ID" "$ENTRY_ID" \
    "Entry $ENTRY_ID started — work order $ENTRY_WORK_ORDER_ID" 2>/dev/null || true

  # --- Execute (direct call — no subshell, outcome in globals) ---
  _CURRENT_ENTRY_ID="$ENTRY_ID"
  _write_health "running"
  _RESUME_ENTRY="$ENTRY_RESUME"
  _run_single_entry "$ENTRY_ID" "$PROMPT" "$ENTRY_SESSION_TYPE" "$ENTRY_BRANCH" "$ENTRY_PERMISSION_PROFILE" "$ENTRY_PUSH" "$ENTRY_BRIEF_PATH" "$ENTRY_MODEL"
  _RESUME_ENTRY=false
  _RESUME_WORKTREE_EXEMPT=false

  # --- Stop heartbeat ---
  _stop_heartbeat
  # Clean up heartbeat file
  rm -f "$(_queue_dir)/running/${ENTRY_ID}.heartbeat" 2>/dev/null || true
  _CURRENT_ENTRY_ID=""

  # --- Write branch name back to entry YAML (Phase 4: enables merge-idempotency on retry) ---
  if [ -n "$_RESULT_BRANCH" ] && [ "$_RESULT_BRANCH" != "main" ]; then
    _running_entry="$(_queue_dir)/running/${ENTRY_ID}.yaml"
    if [ -f "$_running_entry" ]; then
      _load_queue_entry "$_running_entry"
      if [ "$_QE_BRANCH" != "$_RESULT_BRANCH" ]; then
        _QE_BRANCH="$_RESULT_BRANCH"
        _write_queue_entry "$_running_entry"
      fi
    fi
  fi

  # --- Solo merge + branch seal (Phase 2: runs in main shell, not subshell) ---
  # _CURRENT_GROUP_NAME is set by _resolve_group_worktree for sequential task
  # group entries (Decision 0054) and empty for every other entry type; passing
  # it makes the group worktree removal/lock release part of the same step that
  # seals the branch.
  _GWT_ENTRY_GROUP="$_CURRENT_GROUP_NAME"
  _solo_merge_if_needed "$_RESULT_BRANCH" "$ENTRY_PUSH" "$ENTRY_ID" "$ENTRY_WORK_ORDER_ID" "$_GWT_ENTRY_GROUP"

  # --- Record the re-verification result on the entry ---
  # Written here, while the entry is still in running/, because the transition
  # below moves the file and queue_complete() round-trips it through
  # _load_queue_entry/_write_queue_entry — so a field set now survives into
  # completed/, and one set afterwards would be written to a path that no
  # longer exists. Both fields stay at their defaults ("" / []) when the gate
  # did not run, which is how the entry says "no overlap" rather than "passed".
  if [ -n "$_RESULT_REVERIFIED" ] || [ -n "$_RESULT_OVERLAP_FILES" ]; then
    _running_entry="$(_queue_dir)/running/${ENTRY_ID}.yaml"
    if [ -f "$_running_entry" ]; then
      _load_queue_entry "$_running_entry"
      _QE_REVERIFIED="$_RESULT_REVERIFIED"
      _QE_OVERLAP_FILES=$(queue_yaml_flow_seq "$_RESULT_OVERLAP_FILES")
      _write_queue_entry "$_running_entry"
    fi
  fi

  # --- Handle empty outcome (belt-and-suspenders guard on globals) ---
  if [ -z "$_RESULT_OUTCOME" ]; then
    echo "WARNING: Empty outcome from _run_single_entry for $ENTRY_ID — treating as infrastructure failure" >&2
    OUTCOME_RAW="failed:empty-result"
    BASELINE_SHA=""
  else
    OUTCOME_RAW="$_RESULT_OUTCOME"
    BASELINE_SHA="$_RESULT_BASELINE"
  fi

  # --- Parse outcome ---
  OUTCOME="${OUTCOME_RAW%%:*}"
  echo "Entry $ENTRY_ID outcome: $OUTCOME_RAW" >&2

  # --- Queue state transition based on outcome ---
  # Lock with retry (3 attempts, 1s backoff). Entry must transition out of running/.
  _lock_acquired=false
  _lock_attempt=0
  while [ "$_lock_attempt" -lt 3 ]; do
    if acquire_queue_lock; then
      _lock_acquired=true
      break
    fi
    _lock_attempt=$((_lock_attempt + 1))
    echo "WARNING: Lock attempt $_lock_attempt/3 failed for outcome transition ($ENTRY_ID)" >&2
    sleep 1
  done
  if [ "$_lock_acquired" = false ]; then
    # Escalation is written, but transitions proceed unlocked below (intentional).
    # Unlike the dequeue path (which skips via `continue`), outcome transitions must
    # complete to avoid orphaning the entry in running/. Stale-running scanner is the
    # secondary safety net if even unlocked transition fails.
    echo "ERROR: Lock acquisition failed after 3 attempts for $ENTRY_ID — writing escalation" >&2
    _esc_dir="$REPO_ROOT/.claude/.automation/escalations"
    mkdir -p "$_esc_dir" 2>/dev/null || true
    _esc_id="esc-lock-$(date +%Y%m%d-%H%M%S)"
    {
      printf 'escalation:\n'
      printf '  id: "%s"\n' "$_esc_id"
      printf '  queue_entry_id: "%s"\n' "$ENTRY_ID"
      printf '  type: "gate-failure"\n'
      printf '  severity: "blocking"\n'
      printf '  phase_at_exit: "close"\n'
      printf '  tag_at_exit: "agent"\n'
      printf '  message: "Lock acquisition failed after 3 attempts during outcome transition"\n'
      printf '  context: "outcome: %s, entry: %s"\n' "$OUTCOME_RAW" "$ENTRY_ID"
      printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '  resolved: false\n'
      printf '  resolution: ""\n'
    } > "$_esc_dir/${_esc_id}.yaml" 2>/dev/null || true
  fi

  # Transition call with return-code checks
  _transition_ok=true
  # A preserved-work patch must be findable from the entry whatever the outcome:
  # untracked-only work classifies as completed:clean-noop, so every transition
  # below carries the note. Empty when nothing was preserved (error_log unchanged).
  _pw_note=$(preserved_work_note "$_RESULT_PRESERVED_PATCH" "$REPO_ROOT")
  case "$OUTCOME" in
    completed)
      if ! queue_complete "$ENTRY_ID" "${_pw_note:+${OUTCOME_RAW}; ${_pw_note}}"; then
        echo "ERROR: queue_complete failed for $ENTRY_ID" >&2
        _transition_ok=false
      fi
      ;;
    review)
      case "$OUTCOME_RAW" in
        review:incomplete-deliverable)
          # Completeness veto: route to review/ and write escalation file with criteria detail
          _ri_score=$(grep '^COMPLETENESS: ' "$(get_session_state_dir)/cohesion-reviewed" 2>/dev/null | sed 's/^COMPLETENESS: *//' | head -1 || true)
          if ! queue_incomplete "$ENTRY_ID" "${_ri_score:-COMPLETENESS_GATE: NEEDS_WORK}" "${_pw_note:+${OUTCOME_RAW}; ${_pw_note}}"; then
            echo "ERROR: queue_incomplete failed for $ENTRY_ID" >&2
            _transition_ok=false
          fi
          ;;
        *)
          if ! queue_escalate "$ENTRY_ID" "${_pw_note:+${OUTCOME_RAW}; ${_pw_note}}"; then
            echo "ERROR: queue_escalate failed for $ENTRY_ID" >&2
            _transition_ok=false
          fi
          ;;
      esac
      ;;
    stopped)
      # Operator stop (Decision t-0055): the entry goes to stopped/, keeping its
      # worktree, its Claude session and its retry budget. Not a failure, so no
      # retry is consumed and the circuit breaker is left alone.
      if ! queue_stop "$ENTRY_ID" "${OUTCOME_RAW#*:}"; then
        echo "ERROR: queue_stop failed for $ENTRY_ID" >&2
        _transition_ok=false
      fi
      ;;
    failed)
      # Infrastructure failures (empty-result) are non-retriable — go directly to
      # terminal failed/ without incrementing retry_count. Retriable failures use
      # queue_fail which respects max_retries.
      case "$OUTCOME_RAW" in
        failed:empty-result|failed:group-worktree-rebase-conflict|failed:branch-rebase-conflict)
          # A rebase conflict cannot be fixed by retrying: the group is blocked until
          # the operator rebases by hand (or reset-group-worktree) and runs reopen-wo.
          if ! queue_fail_terminal "$ENTRY_ID" "${OUTCOME_RAW#failed:}: terminal, operator action required (see escalation)${_pw_note:+; ${_pw_note}}"; then
            echo "ERROR: queue_fail_terminal failed for $ENTRY_ID" >&2
            _transition_ok=false
          fi
          ;;
        *)
          if ! queue_fail "$ENTRY_ID" "${OUTCOME_RAW}${_pw_note:+; ${_pw_note}}"; then
            echo "ERROR: queue_fail failed for $ENTRY_ID" >&2
            _transition_ok=false
          fi
          ;;
      esac
      ;;
    *)
      if ! queue_fail "$ENTRY_ID" "${OUTCOME_RAW}${_pw_note:+; ${_pw_note}}"; then
        echo "ERROR: queue_fail failed for $ENTRY_ID (wildcard outcome: $OUTCOME_RAW)" >&2
        _transition_ok=false
      fi
      ;;
  esac

  if [ "$_transition_ok" = false ]; then
    echo "WARNING: State transition failed for $ENTRY_ID — entry may be orphaned in running/" >&2
    review_log_append "transition-failed" "${ENTRY_WORK_ORDER_ID:-}" "$ENTRY_ID" \
      "State transition failed for $ENTRY_ID (outcome: $OUTCOME_RAW) — entry may be orphaned in running/" 2>/dev/null || true
  fi
  # Only release lock if we actually acquired it (Phase 6: prevents releasing another section's lock)
  if [ "$_lock_acquired" = true ]; then
    release_queue_lock
  fi

  # --- Post-transition actions (outside lock scope) ---
  # Reset work order status tracker (top-level code — no `local`)
  _wo_new_status=""

  case "$OUTCOME" in
    completed)
      _circuit_breaker_reset
      _SESSIONS_COMPLETED=$((_SESSIONS_COMPLETED + 1))
      _LAST_SESSION_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      _CONSECUTIVE_SESSION_COUNT=$((_CONSECUTIVE_SESSION_COUNT + 1))

      # Review log + work order lifecycle
      if [ -n "$ENTRY_WORK_ORDER_ID" ]; then
        review_log_append "entry-completed" "$ENTRY_WORK_ORDER_ID" "$ENTRY_ID" \
          "Entry $ENTRY_ID completed ($ENTRY_SESSION_TYPE)" 2>/dev/null || true
        _wo_new_status=$(wo_check_completion "$ENTRY_WORK_ORDER_ID" 2>/dev/null) || {
          echo "WARNING: wo_check_completion failed for work order $ENTRY_WORK_ORDER_ID after completion of entry $ENTRY_ID" >&2
        }
        case "$_wo_new_status" in
          completed)
            review_log_append "work-order-completed" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID completed — all children done" 2>/dev/null || true
            ;;
          failed)
            review_log_append "work-order-failed" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID failed — sibling entry failed. Recovery: queue-cli.sh reopen-wo $ENTRY_WORK_ORDER_ID" 2>/dev/null || true
            ;;
          escalated)
            review_log_append "work-order-escalated" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID escalated — child failure detected. Recovery: queue-cli.sh reopen-wo $ENTRY_WORK_ORDER_ID" 2>/dev/null || true
            ;;
          "")
            echo "WARNING: wo_check_completion returned empty status for work order $ENTRY_WORK_ORDER_ID (entry $ENTRY_ID completed)" >&2
            ;;
        esac
      fi

      # Cohesion triggers (all session types)
      check_cohesion_triggers "$ENTRY_ID" "$ENTRY_SESSION_TYPE" \
        "$BASELINE_SHA" "$ENTRY_BRIEF_PATH" "$ENTRY_BRANCH" \
        "$ENTRY_WORK_ORDER_ID" || true

      # Remediation trigger (audit sessions only)
      check_remediation_trigger "$ENTRY_ID" "$ENTRY_SESSION_TYPE" \
        "$ENTRY_BRIEF_PATH" "$ENTRY_BRANCH" \
        "$ENTRY_WORK_ORDER_ID" || true

      # Drift detection (task group sessions only)
      if [ "$ENTRY_SESSION_TYPE" = "taskgroup" ]; then
        _drift_group=""
        if [ -n "$ENTRY_BRIEF_PATH" ]; then
          _drift_group=$(_extract_group_name "$ENTRY_BRIEF_PATH") || true
        fi
        run_drift_detection "$ENTRY_ID" "$PROMPT" "$BASELINE_SHA" "$_drift_group" "" || true
      fi
      ;;
    review)
      # Escalations are operator-directed — do not count as failures
      _LAST_SESSION_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      _CONSECUTIVE_SESSION_COUNT=$((_CONSECUTIVE_SESSION_COUNT + 1))
      # Review log + work order lifecycle
      if [ -n "$ENTRY_WORK_ORDER_ID" ]; then
        review_log_append "entry-escalated" "$ENTRY_WORK_ORDER_ID" "$ENTRY_ID" \
          "Entry $ENTRY_ID escalated ($ENTRY_SESSION_TYPE)" 2>/dev/null || true
        _wo_new_status=$(wo_check_completion "$ENTRY_WORK_ORDER_ID" 2>/dev/null) || {
          echo "WARNING: wo_check_completion failed for work order $ENTRY_WORK_ORDER_ID after escalation of entry $ENTRY_ID" >&2
        }
        case "$_wo_new_status" in
          failed)
            review_log_append "work-order-failed" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID failed — sibling entry failed. Recovery: queue-cli.sh reopen-wo $ENTRY_WORK_ORDER_ID" 2>/dev/null || true
            ;;
          escalated)
            review_log_append "work-order-escalated" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID escalated — entry requires review" 2>/dev/null || true
            ;;
          "")
            echo "WARNING: wo_check_completion returned empty status for work order $ENTRY_WORK_ORDER_ID (entry $ENTRY_ID escalated)" >&2
            ;;
        esac
      fi
      ;;
    stopped)
      # Operator-directed, like review — not a failure, so the circuit breaker
      # and the failure counter are both left alone. The work order stays open
      # by construction (the entry is non-terminal in stopped/), so there is no
      # wo_check_completion call to make here.
      _LAST_SESSION_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      _CONSECUTIVE_SESSION_COUNT=$((_CONSECUTIVE_SESSION_COUNT + 1))
      review_log_append "entry-stopped" "${ENTRY_WORK_ORDER_ID:-}" "$ENTRY_ID" \
        "Entry $ENTRY_ID stopped by operator (${OUTCOME_RAW#*:}) — worktree and Claude session kept. Resume with: queue-cli.sh resume-entry $ENTRY_ID" 2>/dev/null || true
      ;;
    failed|*)
      # An operator force-halt is not a repo failure. Since the in-session
      # watcher actually kills the child, a force-halted session now returns 143
      # and lands here, where it previously could not reach outcome detection at
      # all. Counting it would mean three operator force-halts trip the breaker
      # and block the next start for a full cooldown window — a failure the
      # operator did not earn. The flag is still present at this point because
      # the watcher deliberately leaves it: the loop-top handler needs it to
      # stop the daemon and to sweep the worktree. Note it does NOT re-handle
      # the entry — `_CURRENT_ENTRY_ID` is cleared before this arm runs, and the
      # entry has already been through `queue_fail` on the normal failure path.
      # Two consequences, both pre-existing and recorded rather than fixed here:
      # a force-halted entry gets no escalation artifact, and the halt consumes
      # one of its retries.
      if [ -f "$AUTOMATION_DIR/FORCE-HALT" ]; then
        echo "Session terminated by FORCE-HALT — not counted against the circuit breaker." >&2
      elif [ "$OUTCOME_RAW" = "failed:group-worktree-rebase-conflict" ] || [ "$OUTCOME_RAW" = "failed:branch-rebase-conflict" ]; then
        # No session ran; the conflict is a repo-content problem the operator must
        # resolve. Counting it would let one conflicted group trip the breaker
        # and stall every unrelated queue entry.
        echo "Rebase conflict — not counted against the circuit breaker." >&2
      else
        _circuit_breaker_increment
      fi
      _SESSIONS_FAILED=$((_SESSIONS_FAILED + 1))
      _LAST_SESSION_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      _CONSECUTIVE_SESSION_COUNT=$((_CONSECUTIVE_SESSION_COUNT + 1))

      # Review log + work order lifecycle (only on terminal failure — retries exhausted)
      # Detect terminal failure by checking if queue_fail moved the entry to failed/
      if [ -n "$ENTRY_WORK_ORDER_ID" ]; then
        if [ -f "$(_queue_dir)/failed/${ENTRY_ID}.yaml" ]; then
          review_log_append "entry-failed" "$ENTRY_WORK_ORDER_ID" "$ENTRY_ID" \
            "Entry $ENTRY_ID failed — retries exhausted ($ENTRY_SESSION_TYPE)" 2>/dev/null || true
          _wo_new_status=$(wo_check_completion "$ENTRY_WORK_ORDER_ID" 2>/dev/null) || {
            echo "WARNING: wo_check_completion failed for work order $ENTRY_WORK_ORDER_ID after terminal failure of entry $ENTRY_ID" >&2
          }
          case "$_wo_new_status" in
            failed)
              review_log_append "work-order-failed" "$ENTRY_WORK_ORDER_ID" "" \
                "Work order $ENTRY_WORK_ORDER_ID failed — entry $ENTRY_ID failed. Recovery: queue-cli.sh reopen-wo $ENTRY_WORK_ORDER_ID" 2>/dev/null || true
              ;;
            escalated)
              review_log_append "work-order-escalated" "$ENTRY_WORK_ORDER_ID" "" \
                "Work order $ENTRY_WORK_ORDER_ID escalated — entry failed" 2>/dev/null || true
              ;;
            "")
              echo "WARNING: wo_check_completion returned empty status for work order $ENTRY_WORK_ORDER_ID (terminal failure, entry $ENTRY_ID)" >&2
              ;;
          esac
        fi
      fi
      ;;
  esac

# --- Task group worktree lifetime: group failure (Decision 0054) ---
# A group worktree survives an individual brief's failure — the restart reuses
# it, and its working state is what the operator inspects. It does NOT survive
# the failure of the whole work order: at that point no further brief will run,
# and the tree is only debris holding a branch checked out. Placed after the
# outcome `case` rather than inside its three `failed)` arms so there is one
# removal site keyed on the work order's actual terminal status, not on which
# arm happened to run.
# Abandonment reaches the same end by a different route: queue-cli.sh moves the
# work order to a terminal status, and the next cleanup sweep removes any group
# worktree whose branch is sealed or stale (group-worktree-sweep.sh).
if [ -n "${_GWT_ENTRY_GROUP:-}" ] && [ -n "$ENTRY_WORK_ORDER_ID" ]; then
  if wo_is_failed "$ENTRY_WORK_ORDER_ID" 2>/dev/null; then
    remove_group_worktree "$_GWT_ENTRY_GROUP" "$$" "" 2>/dev/null || true
    echo "Removed task group worktree for '$_GWT_ENTRY_GROUP' — work order $ENTRY_WORK_ORDER_ID failed" >&2
  fi
fi
_GWT_ENTRY_GROUP=""

  # Configurable cooldown between sessions
  _cooldown=$(_parse_config_field "runner" "cooldown_between_sessions")
  _cooldown="${_cooldown:-5}"
  sleep "$_cooldown"

  # Max consecutive sessions check
  _max_sessions=$(_parse_config_field "runner" "max_consecutive_sessions")
  _max_sessions="${_max_sessions:-0}"
  if [ "$_max_sessions" -gt 0 ] && [ "$_CONSECUTIVE_SESSION_COUNT" -ge "$_max_sessions" ]; then
    echo "Max consecutive sessions reached ($_max_sessions). Exiting daemon." >&2
    break
  fi
done

# Post-loop: daemon exiting
echo "Runner daemon stopped (pid $$)." >&2
exit 0
