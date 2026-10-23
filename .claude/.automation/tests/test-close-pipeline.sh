#!/usr/bin/env bash
# Close pipeline tests — Decision t-0057.
# Exercises the close-state machine, the step recorder, the fail-closed merge
# preconditions, and the schema round-trip. Bash 3.2 compatible.
#
# Cases:
#   CP.1  every changed file parses (bash -n)
#   CP.2  no Bash 4 constructs in the changed files
#   CP.3  a pre-v1.10.0 entry loads, and close_state is derived from status
#   CP.4  close_path defaults from solo_mode and is pinned on first transition
#   CP.5  close_steps appends in order and survives a write/load round-trip
#   CP.6  a step detail with newlines/tabs stays on one line
#   CP.7  merge_hold renders close_state: held, but never over a finished state
#   CP.8  merge is ALLOWED from ready and from held
#   CP.9  merge is REFUSED when the entry is not completed
#   CP.10 merge is REFUSED when close-time re-verification did not pass
#   CP.11 merge is REFUSED from conflict, merging and every other state
#   CP.12 merge is REFUSED on the pr close path
#   CP.13 merge is REFUSED on a non-final task group brief
#   CP.14 hold-merge, set-close, merge and close-status are wired into queue-cli
#   CP.15 --close-entry is a runner mode, and the solo path records each state
#   CP.16 the conflict-resolve gate admits conflict only, and only when final
#   CP.17 conflict_resolution stores operator intent and round-trips
#   CP.18 the re-arm returns a conflicted entry to completed/ at ready
#   CP.19 the stored strategy inverts for git's rebase, once, then clears
#   CP.20 resolve-conflict is wired into queue-cli.sh and delegates
#
# WHAT THIS SUITE DOES NOT COVER, and why: a live `queue-cli.sh merge` end to
# end — rebase, re-verification session, real merge, real push — needs a running
# runner.sh, and runner.sh parses argv and runs a daemon loop at load, so it
# cannot be sourced into a test. There is no runner subprocess harness in this
# directory to extend either. CP.15 therefore asserts the WIRING structurally
# (the mode exists, each state is recorded at the right site) and the behaviour
# of everything reachable without the runner is tested for real above. The
# rebase/re-verify half of that pipeline is covered for real by
# test-reverify-merge.sh, which has the git fixture and the stub `claude`.
#
# The same boundary falls across `resolve-conflict --agent`: its round trip ends
# in a `queue-cli.sh follow-up-entry` SUBPROCESS, and queue-cli.sh dispatches on
# "$1" at load, so it cannot be sourced to exercise that path in-process. CP.16
# to CP.19 therefore test the two library halves for real (the gate, the store,
# the re-arm, the inversion) and CP.20 tests the CLI half structurally — that it
# checks the gate, delegates the enqueue, and carries no resolution logic of its
# own.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
AUTO_DIR="$SCRIPT_DIR/.."
RUNNER_SH="$AUTO_DIR/runner.sh"
CLI_SH="$AUTO_DIR/queue-cli.sh"

# --- TAP counters ---
# No case body runs in a subshell: the functions under test report through
# _QE_* globals, which a subshell would discard.
_TAP_TEST_NUM=0
_TAP_PASS=0
_TAP_FAIL=0

_tap_pass() {
  _TAP_TEST_NUM=$((_TAP_TEST_NUM + 1))
  _TAP_PASS=$((_TAP_PASS + 1))
  printf "ok %d - %s\n" "$_TAP_TEST_NUM" "$1"
}

_tap_fail() {
  _TAP_TEST_NUM=$((_TAP_TEST_NUM + 1))
  _TAP_FAIL=$((_TAP_FAIL + 1))
  printf "not ok %d - %s\n" "$_TAP_TEST_NUM" "$1"
  if [ -n "${2:-}" ]; then
    printf "  # %s\n" "$2"
  fi
}

assert_eq() {
  if [ "$1" = "$2" ]; then
    _tap_pass "$3"
  else
    _tap_fail "$3" "expected '$2', got '$1'"
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) _tap_pass "$3" ;;
    *)      _tap_fail "$3" "'$2' not found in: $1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) _tap_fail "$3" "'$2' unexpectedly present in: $1" ;;
    *)      _tap_pass "$3" ;;
  esac
}

# --- Files this brief changed ---
SHIPPED_FILES="
$AUTO_DIR/runner.sh
$AUTO_DIR/queue-cli.sh
$LIB_DIR/queue-manager.sh
$LIB_DIR/reverify-merge.sh
"
CHANGED_FILES="$SHIPPED_FILES
$SCRIPT_DIR/test-close-pipeline.sh
"

# ========================================================================
# CP.1 — syntax
# ========================================================================
for _f in $CHANGED_FILES; do
  [ -f "$_f" ] || { _tap_fail "[CRITICAL] CP.1 $(basename "$_f") exists" "not found: $_f"; continue; }
  _out=""
  if _out=$(bash -n "$_f" 2>&1); then
    _tap_pass "CP.1 $(basename "$_f") parses"
  else
    _tap_fail "[CRITICAL] CP.1 $(basename "$_f") parses" "$_out"
  fi
done

# ========================================================================
# CP.2 — Bash 3.2 floor (AI.md). macOS /bin/bash is 3.2; these five
# constructs are the ones that fail there silently or loudly.
#
# Comment lines are stripped first: the libraries document the floor by naming
# the constructs they avoid, and this file carries the detector pattern itself,
# so a raw scan reports its own prose. Scanned over the shipped files only for
# the same reason.
# ========================================================================
for _f in $SHIPPED_FILES; do
  [ -f "$_f" ] || continue
  # Filtered on the -n output, not on the file, so the reported line numbers
  # are still the real ones.
  _bad=$(grep -nE 'declare -A|local -A|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^|\$\{[A-Za-z_][A-Za-z0-9_]*,,|\bmapfile\b|\breadarray\b|\$BASHPID|\$\{BASHPID' "$_f" \
    | grep -vE '^[0-9]+:[[:space:]]*#') || _bad=""
  if [ -z "$_bad" ]; then
    _tap_pass "CP.2 $(basename "$_f") has no Bash 4 constructs"
  else
    _tap_fail "[HIGH] CP.2 $(basename "$_f") has no Bash 4 constructs" "$(printf '%s' "$_bad" | tr '\n' ' ')"
  fi
done

# --- Fixture -------------------------------------------------------------
_FIX=""

_fixture_destroy() {
  # Capture first, re-assert last: on bash 3.2 the status of the last command
  # in an EXIT trap becomes the shell's exit status, so a guarded `rm ... ||
  # true` would rewrite every failure — including a set -e abort — to 0.
  local _rc=$?
  if [ -n "$_FIX" ] && [ -d "$_FIX" ]; then
    rm -rf "$_FIX" 2>/dev/null || true
  fi
  exit "$_rc"
}
trap _fixture_destroy EXIT

_FIX=$(mktemp -d "${TMPDIR:-/tmp}/repo-os-closepipe-XXXXXX")
mkdir -p "$_FIX/.claude/.automation/queue/completed" \
         "$_FIX/.claude/.automation/queue/running" \
         "$_FIX/.claude/.automation/queue/approved" \
         "$_FIX/.claude/.automation/queue/work-orders" \
         "$_FIX/.claude/.state"
cat > "$_FIX/.claude/.automation/config.yaml" <<'CFG'
runner:
  session_max_turns: 10
CFG

REPO_ROOT="$_FIX"
AUTOMATION_DIR="$_FIX/.claude/.automation"
CONFIG_FILE="$AUTOMATION_DIR/config.yaml"
CONFIG_LOCAL_FILE=""
export REPO_ROOT AUTOMATION_DIR CONFIG_FILE CONFIG_LOCAL_FILE

# shellcheck disable=SC1091
source "$LIB_DIR/file-lock.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/queue-manager.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/work-order-manager.sh"

QDIR="$AUTOMATION_DIR/queue"

# A pre-v1.10.0 entry: every field the old schema had, and NONE of the four
# this brief adds. Written by hand rather than by queue_enqueue precisely so it
# cannot acquire the new fields by accident.
_write_old_entry() {
  local id="$1" status="$2" solo="$3" reverified="${4:-}" wo="${5:-}"
  local dir="$QDIR/$status"
  mkdir -p "$dir"
  cat > "$dir/${id}.yaml" <<ENTRY
entry:
  id: "$id"
  status: "$status"
  priority: "0"
  session_type: "standard"
  branch: "feature/${id}"
  brief_path: ""
  prompt: ""
  last_prompt: ""
  auto_mode: "false"
  solo_mode: "$solo"
  retry_count: "0"
  max_retries: "3"
  error_log: ""
  work_order_id: "$wo"
  push_on_complete: "false"
  created_at: "2026-10-01T00:00:00Z"
  updated_at: "2026-10-01T00:00:00Z"
  completed_at: "2026-10-02T00:00:00Z"
  permission_profile: "build"
  reverified: "$reverified"
  overlap_files: []
ENTRY
  printf '%s' "$dir/${id}.yaml"
}

# ========================================================================
# CP.3 — a pre-v1.10.0 entry loads, close_state derived from status
# ========================================================================
_E_OLD_MANUAL=$(_write_old_entry "old-manual" "completed" "false")
_load_queue_entry "$_E_OLD_MANUAL"
assert_eq "$_QE_ID" "old-manual" "CP.3 old entry loads its own fields"
assert_eq "${_QE_CLOSE_STATE:-}" "" "CP.3 old entry has no stored close_state"
assert_eq "${_QE_CLOSE_STEPS:-}" "" "CP.3 old entry has no stored close_steps"
assert_eq "$(queue_close_state)" "ready" \
  "CP.3 completed non-solo entry derives close_state: ready"

_E_OLD_SOLO=$(_write_old_entry "old-solo" "completed" "true")
_load_queue_entry "$_E_OLD_SOLO"
assert_eq "$(queue_close_state)" "merged" \
  "CP.3 completed solo entry derives close_state: merged"

_E_OLD_FAILED=$(_write_old_entry "old-failed" "failed" "false")
_load_queue_entry "$_E_OLD_FAILED"
assert_eq "$(queue_close_state)" "waiting" \
  "CP.3 a failed entry derives close_state: waiting, never ready"

_E_OLD_REVIEW=$(_write_old_entry "old-review" "review" "true")
_load_queue_entry "$_E_OLD_REVIEW"
assert_eq "$(queue_close_state)" "waiting" \
  "CP.3 an entry in review derives close_state: waiting"

# ========================================================================
# CP.4 — close_path defaults from solo_mode, pinned on first transition
# ========================================================================
_load_queue_entry "$_E_OLD_MANUAL"
assert_eq "$(queue_close_path)" "pr" "CP.4 solo_mode false defaults close_path to pr"
_load_queue_entry "$_E_OLD_SOLO"
assert_eq "$(queue_close_path)" "solo" "CP.4 solo_mode true defaults close_path to solo"

queue_close_record "$_E_OLD_SOLO" "merging" "merge" "running" "feature/old-solo into main"
_load_queue_entry "$_E_OLD_SOLO"
assert_eq "${_QE_CLOSE_PATH:-}" "solo" \
  "CP.4 the first transition pins close_path on the entry"
assert_eq "${_QE_CLOSE_STATE:-}" "merging" "CP.4 the first transition records close_state"

# ========================================================================
# CP.5 — close_steps appends in order and round-trips
# ========================================================================
_E_STEPS=$(_write_old_entry "steps" "completed" "true")
queue_close_record "$_E_STEPS" "rebasing" "rebase" "running" "onto main"
queue_close_record "$_E_STEPS" "reverifying" "rebase" "done" "clean"
queue_close_record "$_E_STEPS" "merged" "merge" "done" "abc1234"
_load_queue_entry "$_E_STEPS"
_S="${_QE_CLOSE_STEPS:-}"
assert_eq "$(printf '%s' "$_S" | grep -c '{"step"')" "1" \
  "CP.5 close_steps is stored on a SINGLE line"
assert_eq "$(printf '%s' "$_S" | grep -o '"step":"' | grep -c .)" "3" \
  "CP.5 three steps recorded"
# Order is the thing a pipeline report depends on, so assert the whole shape
# rather than mere membership.
case "$_S" in
  '[{"step":"rebase","status":"running"'*'{"step":"rebase","status":"done"'*'{"step":"merge","status":"done"'*']')
    _tap_pass "CP.5 steps are in the order they ran" ;;
  *)
    _tap_fail "CP.5 steps are in the order they ran" "$_S" ;;
esac
assert_eq "${_QE_CLOSE_STATE:-}" "merged" "CP.5 the last state recorded wins"

# The stored text must be valid YAML *and* valid JSON. There is no YAML reader
# here, so this asserts the JSON half plus the single-line property above,
# which together are what the schema promises.
if printf '%s\n' "$_S" | grep -qE '^\[\{.*\}\]$'; then
  _tap_pass "CP.5 stored close_steps is a well-formed flow sequence"
else
  _tap_fail "[HIGH] CP.5 stored close_steps is a well-formed flow sequence" "$_S"
fi

# ========================================================================
# CP.6 — a multi-line detail cannot break the record
# ========================================================================
_E_FOLD=$(_write_old_entry "fold" "completed" "true")
queue_close_record "$_E_FOLD" "conflict" "merge" "failed" "$(printf 'a.txt\nb.txt\tc.txt')"
_load_queue_entry "$_E_FOLD"
_F="${_QE_CLOSE_STEPS:-}"
assert_eq "$(printf '%s' "$_F" | grep -c '{"step"')" "1" \
  "CP.6 a newline-bearing detail stays on one line"
assert_contains "$_F" "a.txt b.txt c.txt" "CP.6 the detail is folded to spaces, not dropped"
assert_eq "$(queue_close_state)" "conflict" "CP.6 the conflict state is recorded"

# A detail carrying a double quote would break the JSON if it were not escaped.
_E_QUOTE=$(_write_old_entry "quote" "completed" "true")
queue_close_record "$_E_QUOTE" "" "merge" "failed" 'said "no" to it'
_load_queue_entry "$_E_QUOTE"
if printf '%s\n' "${_QE_CLOSE_STEPS:-}" | grep -qE '^\[\{.*\}\]$'; then
  _tap_pass "CP.6 a quote in the detail does not break the sequence"
else
  _tap_fail "[HIGH] CP.6 a quote in the detail does not break the sequence" "${_QE_CLOSE_STEPS:-}"
fi

# ========================================================================
# CP.7 — merge_hold renders held, but never over a finished or refusing state
# ========================================================================
_E_HOLD=$(_write_old_entry "hold" "completed" "false")
queue_close_record "$_E_HOLD" "ready" "" "" ""
_load_queue_entry "$_E_HOLD"
assert_eq "$(queue_close_state)" "ready" "CP.7 unheld entry reports its stored state"

queue_set_merge_hold "$_E_HOLD" "true"
_load_queue_entry "$_E_HOLD"
assert_eq "${_QE_MERGE_HOLD:-}" "true" "CP.7 merge_hold is stored"
assert_eq "${_QE_CLOSE_STATE:-}" "ready" \
  "CP.7 held is NOT written into close_state — merge_hold is the one source"
assert_eq "$(queue_close_state)" "held" "CP.7 a hold renders close_state: held"

queue_set_merge_hold "$_E_HOLD" "false"
_load_queue_entry "$_E_HOLD"
assert_eq "$(queue_close_state)" "ready" \
  "CP.7 --release restores ready with nothing to restore from"

_E_HOLD_DONE=$(_write_old_entry "hold-done" "completed" "true")
queue_close_record "$_E_HOLD_DONE" "merged" "merge" "done" "already in main"
queue_set_merge_hold "$_E_HOLD_DONE" "true"
_load_queue_entry "$_E_HOLD_DONE"
assert_eq "$(queue_close_state)" "merged" \
  "CP.7 a hold does not relabel an entry that already merged"

# A hold must not relabel a state the merge gate REFUSES either. CP.8 admits
# `held` on the solo path, so if a hold rendered over `conflict` then placing a
# hold would be a way of PASSING the gate `conflict` exists to fail.
_E_HOLD_CONFLICT=$(_write_old_entry "hold-conflict" "completed" "true")
queue_close_record "$_E_HOLD_CONFLICT" "conflict" "merge" "failed" "rebase conflict"
queue_set_merge_hold "$_E_HOLD_CONFLICT" "true"
_load_queue_entry "$_E_HOLD_CONFLICT"
assert_eq "${_QE_MERGE_HOLD:-}" "true" "CP.7 the hold on a conflicted entry is stored"
assert_eq "$(queue_close_state)" "conflict" \
  "CP.7 a hold does NOT render over conflict — the refusal outranks the hold"
_R=""
if _R=$(queue_close_merge_allowed "$_E_HOLD_CONFLICT" 2>&1); then
  _tap_fail "[CRITICAL] CP.7 a hold must not let a conflicted entry pass the merge gate" "$_R"
else
  _tap_pass "CP.7 a held conflicted entry is still refused by the merge gate"
fi

_E_HOLD_RVF=$(_write_old_entry "hold-rvf" "completed" "true")
queue_close_record "$_E_HOLD_RVF" "reverify_failed" "reverify" "failed" "tests failed"
queue_set_merge_hold "$_E_HOLD_RVF" "true"
_load_queue_entry "$_E_HOLD_RVF"
assert_eq "$(queue_close_state)" "reverify_failed" \
  "CP.7 a hold does NOT render over reverify_failed either"

# ========================================================================
# CP.8 — merge allowed from ready and from held
# ========================================================================
# solo_mode true: the solo path is the one `merge` runs. A pr-path entry is
# refused on purpose, and CP.12 covers that.
_E_READY=$(_write_old_entry "ready-ok" "completed" "true")
queue_close_record "$_E_READY" "ready" "" "" ""
_R=""
if _R=$(queue_close_merge_allowed "$_E_READY"); then
  _tap_pass "CP.8 merge is allowed from ready"
else
  _tap_fail "[HIGH] CP.8 merge is allowed from ready" "$_R"
fi

queue_set_merge_hold "$_E_READY" "true"
if _R=$(queue_close_merge_allowed "$_E_READY"); then
  _tap_pass "CP.8 merge is allowed from held — the operator overrides their own hold"
else
  _tap_fail "[HIGH] CP.8 merge is allowed from held" "$_R"
fi
queue_set_merge_hold "$_E_READY" "false"

# ========================================================================
# CP.9 — refused when the entry is not completed
# ========================================================================
_E_RUNNING=$(_write_old_entry "still-running" "running" "false")
queue_close_record "$_E_RUNNING" "ready" "" "" ""
if _R=$(queue_close_merge_allowed "$_E_RUNNING"); then
  _tap_fail "[CRITICAL] CP.9 merge is refused when the entry is not completed" \
    "allowed a running entry to merge"
else
  assert_contains "$_R" "not completed" \
    "CP.9 merge is refused when the entry is not completed"
fi

# ========================================================================
# CP.10 — refused when close-time re-verification did not pass
# ========================================================================
_E_RVF=$(_write_old_entry "reverify-no" "completed" "false" "false")
queue_close_record "$_E_RVF" "ready" "" "" ""
if _R=$(queue_close_merge_allowed "$_E_RVF"); then
  _tap_fail "[CRITICAL] CP.10 merge is refused after a failed re-verification" \
    "allowed a reverified:false entry to merge"
else
  assert_contains "$_R" "re-verification" \
    "CP.10 merge is refused after a failed re-verification"
fi

# "" means it never ran, which is not a failure.
_E_RVE=$(_write_old_entry "reverify-empty" "completed" "true" "")
queue_close_record "$_E_RVE" "ready" "" "" ""
if _R=$(queue_close_merge_allowed "$_E_RVE"); then
  _tap_pass "CP.10 an empty reverified is 'did not run', not a refusal"
else
  _tap_fail "[HIGH] CP.10 an empty reverified is 'did not run', not a refusal" "$_R"
fi

# ========================================================================
# CP.11 — refused from every state but ready and held
# ========================================================================
for _st in conflict merging rebasing reverifying reverify_failed waiting handed_off pushed merged pr_open; do
  _E_ST=$(_write_old_entry "state-$_st" "completed" "false")
  queue_close_record "$_E_ST" "$_st" "" "" ""
  if _R=$(queue_close_merge_allowed "$_E_ST"); then
    _tap_fail "[CRITICAL] CP.11 merge is refused from $_st" "allowed a merge from $_st"
  else
    assert_contains "$_R" "close_state is $_st" "CP.11 merge is refused from $_st"
  fi
done

# ========================================================================
# CP.12 — refused on the pr close path
# ========================================================================
_E_PR=$(_write_old_entry "pr-path" "completed" "false")
queue_close_record "$_E_PR" "ready" "" "" ""
queue_set_close_path "$_E_PR" "pr"
if _R=$(queue_close_merge_allowed "$_E_PR"); then
  _tap_fail "[HIGH] CP.12 merge is refused on the pr path" "allowed a solo merge of a pr-path entry"
else
  assert_contains "$_R" "close_path is pr" "CP.12 merge is refused on the pr path"
fi
queue_set_close_path "$_E_PR" "solo"
if _R=$(queue_close_merge_allowed "$_E_PR"); then
  _tap_pass "CP.12 switching the path back to solo makes merge available"
else
  _tap_fail "[HIGH] CP.12 switching the path back to solo makes merge available" "$_R"
fi

# ========================================================================
# CP.13 — refused on a non-final task group brief (Decision 0015 §3)
# ========================================================================
# Real work-order format: unquoted scalars, and entry_ids as a block list —
# _load_work_order joins it into the comma-separated _WO_ENTRY_IDS.
cat > "$QDIR/work-orders/wo-group.yaml" <<'WO'
work_order:
  id: wo-group
  label: close-pipeline-group
  type: taskgroup
  status: in_progress
  entry_ids:
  - tg-b1
  - tg-b2
  created_at: 2026-10-01T00:00:00Z
  updated_at: 2026-10-01T00:00:00Z
WO
_E_B1=$(_write_old_entry "tg-b1" "completed" "true" "" "wo-group")
_E_B2=$(_write_old_entry "tg-b2" "approved" "true" "" "wo-group")
queue_close_record "$_E_B1" "ready" "" "" ""

if queue_is_final_taskgroup_entry "tg-b1" "wo-group"; then
  _tap_fail "[CRITICAL] CP.13 brief 1 is not final while brief 2 is approved" \
    "the finality predicate called brief 1 final"
else
  _tap_pass "CP.13 brief 1 is not final while brief 2 is approved"
fi
if _R=$(queue_close_merge_allowed "$_E_B1"); then
  _tap_fail "[CRITICAL] CP.13 merge is refused on a non-final group brief" \
    "allowed a merge of a non-final group brief"
else
  assert_contains "$_R" "not the final brief" \
    "CP.13 merge is refused on a non-final group brief"
fi

# Finish brief 2 and brief 1 becomes closable — the group closes once, at the end.
rm -f "$_E_B2"
_write_old_entry "tg-b2" "completed" "true" "" "wo-group" > /dev/null
if _R=$(queue_close_merge_allowed "$_E_B1"); then
  _tap_pass "CP.13 with no unfinished siblings the group brief can close"
else
  _tap_fail "[HIGH] CP.13 with no unfinished siblings the group brief can close" "$_R"
fi

# The runner's wrapper and the CLI's predicate must be the SAME code, or the
# seal gate and the merge gate can disagree about when a branch reaches main.
if grep -q 'queue_is_final_taskgroup_entry "\$1" "\${2:-}"' "$RUNNER_SH"; then
  _tap_pass "CP.13 runner.sh _is_final_taskgroup_entry delegates, it does not copy"
else
  _tap_fail "[HIGH] CP.13 runner.sh _is_final_taskgroup_entry delegates, it does not copy" \
    "no delegation found — a second finality gate may have been reintroduced"
fi

# ========================================================================
# CP.14 — the four subcommands are wired into queue-cli.sh
# ========================================================================
for _sub in "close-status)" "merge)" "hold-merge)" "set-close)"; do
  if grep -qF "  $_sub" "$CLI_SH"; then
    _tap_pass "CP.14 queue-cli.sh dispatches $_sub"
  else
    _tap_fail "[HIGH] CP.14 queue-cli.sh dispatches $_sub" "no dispatch arm found"
  fi
done
for _sub in close-status merge hold-merge set-close; do
  if grep -qE "^  $_sub " "$CLI_SH"; then
    _tap_pass "CP.14 $_sub is in the usage block"
  else
    _tap_fail "CP.14 $_sub is in the usage block" "missing from _usage"
  fi
done
# Every new subcommand supports --json (contract convention, Decision t-0061).
_CLI_MERGE_BLOCK=$(sed -n '/^  merge)$/,/^    ;;$/p' "$CLI_SH")
assert_contains "$_CLI_MERGE_BLOCK" 'JSON_OUTPUT' "CP.14 merge supports --json"
assert_contains "$_CLI_MERGE_BLOCK" 'queue_close_merge_allowed' \
  "CP.14 merge checks the fail-closed precondition before acting"
assert_contains "$_CLI_MERGE_BLOCK" 'runner.sh" --close-entry' \
  "CP.14 merge hands off to the runner rather than re-implementing the merge"
assert_not_contains "$_CLI_MERGE_BLOCK" 'git merge' \
  "CP.14 merge contains no merge implementation of its own"

# ========================================================================
# CP.15 — the runner side: the mode exists and each state is recorded
# ========================================================================
if grep -q -- '--close-entry)' "$RUNNER_SH"; then
  _tap_pass "CP.15 runner.sh parses --close-entry"
else
  _tap_fail "[HIGH] CP.15 runner.sh parses --close-entry" "argv arm not found"
fi
if grep -q -- '--close-entry cannot be combined with --daemon or --brief-id' "$RUNNER_SH"; then
  _tap_pass "CP.15 the three runner modes are mutually exclusive"
else
  _tap_fail "[HIGH] CP.15 the three runner modes are mutually exclusive" "no validation found"
fi

# Every close_state the solo path can reach must have a recorder at its site.
# A state nothing writes is a dead enum value that a report would never show.
for _state in handed_off ready merging merged pushed conflict reverify_failed; do
  if grep -qF "_close_record \"\$brief_id\" \"$_state\"" "$RUNNER_SH"; then
    _tap_pass "CP.15 runner.sh records close_state: $_state"
  else
    _tap_fail "[HIGH] CP.15 runner.sh records close_state: $_state" \
      "no _close_record call writes $_state"
  fi
done
# rebasing and reverifying are only distinguishable from inside the gate.
for _state in rebasing reverifying; do
  if grep -qF "_close_record \"\$brief_id\" \"$_state\"" "$LIB_DIR/reverify-merge.sh"; then
    _tap_pass "CP.15 reverify-merge.sh records close_state: $_state"
  else
    _tap_fail "[HIGH] CP.15 reverify-merge.sh records close_state: $_state" \
      "no _close_record call writes $_state"
  fi
done
# The recorder must be fail-soft: a report on the pipeline must not be able to
# change whether a branch merges.
_RUNNER_REC=$(sed -n '/^_close_record() {/,/^}/p' "$RUNNER_SH")
assert_contains "$_RUNNER_REC" "return 0" "CP.15 _close_record always returns success"
assert_contains "$_RUNNER_REC" "|| true" "CP.15 _close_record swallows a recorder failure"
# The hold must be checked before the merge, not after it.
if grep -q '_close_merge_held "\$brief_id"' "$RUNNER_SH"; then
  _tap_pass "CP.15 the solo path checks the merge hold"
else
  _tap_fail "[CRITICAL] CP.15 the solo path checks the merge hold" "no hold check found"
fi
_HELD_LINE=$(grep -n '_close_merge_held "\$brief_id"' "$RUNNER_SH" | head -1 | cut -d: -f1)
_MERGE_LINE=$(grep -n 'merge --ff-only "\$entry_current_branch"' "$RUNNER_SH" | head -1 | cut -d: -f1)
if [ -n "$_HELD_LINE" ] && [ -n "$_MERGE_LINE" ] && [ "$_HELD_LINE" -lt "$_MERGE_LINE" ]; then
  _tap_pass "CP.15 the hold is checked BEFORE the merge runs"
else
  _tap_fail "[CRITICAL] CP.15 the hold is checked BEFORE the merge runs" \
    "hold at line ${_HELD_LINE:-?}, merge at line ${_MERGE_LINE:-?}"
fi

# ========================================================================
# CP.16 — the conflict-resolve gate: conflict only, and only when final
# ========================================================================
# A conflicted entry sits in review/, which is why this gate cannot be
# _queue_close_preconditions: that one demands `completed`.
_E_CONF=$(_write_old_entry "conflicted" "review" "true")
queue_close_record "$_E_CONF" "conflict" "merge" "failed" "lib/a.sh,lib/b.sh"
_R="unset"
if _R=$(queue_conflict_resolve_allowed "$_E_CONF"); then
  assert_eq "$_R" "" "CP.16 the gate prints nothing when it allows"
else
  _tap_fail "[CRITICAL] CP.16 resolve is allowed from close_state conflict" "$_R"
fi

# review/ is not evidence of a conflict. An entry reaches it for a dozen
# reasons; only a recorded `conflict` is a conflict.
_E_REV_ONLY=$(_write_old_entry "review-only" "review" "true")
if _R=$(queue_conflict_resolve_allowed "$_E_REV_ONLY"); then
  _tap_fail "[CRITICAL] CP.16 resolve is refused for an entry in review with no conflict" \
    "allowed a resolve on an entry that never conflicted"
else
  assert_contains "$_R" "not conflict" \
    "CP.16 resolve is refused for an entry in review with no conflict"
fi

# And not from a state the pipeline is still moving through, or has finished.
for _st in ready merging merged rebasing reverify_failed; do
  _E_CS=$(_write_old_entry "conf-state-$_st" "review" "true")
  queue_close_record "$_E_CS" "$_st" "" "" ""
  if _R=$(queue_conflict_resolve_allowed "$_E_CS"); then
    _tap_fail "[HIGH] CP.16 resolve is refused from $_st" "allowed a resolve from $_st"
  else
    assert_contains "$_R" "close_state is $_st" "CP.16 resolve is refused from $_st"
  fi
done

# Finality is enforced here for a reason beyond symmetry: the re-arm reopens the
# parent work order, and reopening a group mid-group un-gates siblings the
# deferral guard is correctly holding.
cat > "$QDIR/work-orders/wo-conf.yaml" <<'WO'
work_order:
  id: wo-conf
  label: conflict-group
  type: taskgroup
  status: escalated
  entry_ids:
  - cg-b1
  - cg-b2
  created_at: 2026-10-01T00:00:00Z
  updated_at: 2026-10-01T00:00:00Z
WO
_E_CG1=$(_write_old_entry "cg-b1" "review" "true" "" "wo-conf")
_write_old_entry "cg-b2" "approved" "true" "" "wo-conf" > /dev/null
queue_close_record "$_E_CG1" "conflict" "merge" "failed" "lib/a.sh"
if _R=$(queue_conflict_resolve_allowed "$_E_CG1"); then
  _tap_fail "[CRITICAL] CP.16 resolve is refused on a non-final group brief" \
    "allowed a resolve that would reopen a group with an unfinished sibling"
else
  assert_contains "$_R" "not the final brief" \
    "CP.16 resolve is refused on a non-final group brief"
fi

if _R=$(queue_conflict_resolve_allowed "$QDIR/review/nope.yaml"); then
  _tap_fail "[HIGH] CP.16 resolve is refused when the entry file is missing" "allowed"
else
  assert_contains "$_R" "not found" "CP.16 resolve is refused when the entry file is missing"
fi

# ========================================================================
# CP.17 — conflict_resolution stores operator intent and round-trips
# ========================================================================
_E_CR=$(_write_old_entry "cres" "review" "true")
_load_queue_entry "$_E_CR"
assert_eq "${_QE_CONFLICT_RESOLUTION:-}" "" \
  "CP.17 a pre-v1.12.0 entry loads with no conflict_resolution"

queue_set_conflict_resolution "$_E_CR" "ours"
_load_queue_entry "$_E_CR"
assert_eq "${_QE_CONFLICT_RESOLUTION:-}" "ours" \
  "CP.17 ours is stored in the OPERATOR's vocabulary, un-inverted"
queue_set_conflict_resolution "$_E_CR" "theirs"
_load_queue_entry "$_E_CR"
assert_eq "${_QE_CONFLICT_RESOLUTION:-}" "theirs" "CP.17 theirs round-trips"
queue_set_conflict_resolution "$_E_CR" ""
_load_queue_entry "$_E_CR"
assert_eq "${_QE_CONFLICT_RESOLUTION:-}" "" "CP.17 the empty value clears it"

# The value is spliced into a git argument list, so anything outside the closed
# set is refused on the way in...
if queue_set_conflict_resolution "$_E_CR" "--upload-pack=sh" 2>/dev/null; then
  _tap_fail "[CRITICAL] CP.17 an out-of-set strategy is refused" "stored an arbitrary value"
else
  _tap_pass "CP.17 an out-of-set strategy is refused"
fi
_load_queue_entry "$_E_CR"
assert_eq "${_QE_CONFLICT_RESOLUTION:-}" "" \
  "CP.17 a refused write leaves the stored value untouched"

# ...and normalised on the way out, so a hand-edited file cannot reach git either.
printf '  conflict_resolution: "--exec=rm"\n' >> "$_E_CR"
_load_queue_entry "$_E_CR"
assert_eq "${_QE_CONFLICT_RESOLUTION:-}" "" \
  "CP.17 a hand-edited out-of-set value normalises to empty on load"

# It steers a merge, so it is not the operator's to set by hand through `edit`.
if queue_edit "cres" "conflict_resolution" "ours" 2>/dev/null; then
  _tap_fail "[HIGH] CP.17 conflict_resolution is not in queue_edit's allowlist" \
    "edit accepted a field that steers a merge"
else
  _tap_pass "CP.17 conflict_resolution is not in queue_edit's allowlist"
fi

# ========================================================================
# CP.18 — the re-arm returns a conflicted entry to completed/ at ready
# ========================================================================
# The full starting state of a solo-path conflict: review/, reverified false,
# an error_log pointing at the escalation, and an escalated work order.
cat > "$QDIR/work-orders/wo-rearm.yaml" <<'WO'
work_order:
  id: wo-rearm
  label: rearm-group
  type: taskgroup
  status: escalated
  entry_ids:
  - rearm-me
  created_at: 2026-10-01T00:00:00Z
  updated_at: 2026-10-01T00:00:00Z
WO
_E_RA=$(_write_old_entry "rearm-me" "review" "true" "false" "wo-rearm")
_load_queue_entry "$_E_RA"
_QE_ERROR_LOG=".claude/.automation/escalations/esc-merge-20261023-conflict.yaml"
_write_queue_entry "$_E_RA"
queue_close_record "$_E_RA" "conflict" "merge" "failed" "lib/a.sh"

_RA_NEW=$(queue_close_rearm "$_E_RA" "agent" "keep both intents")
assert_eq "$_RA_NEW" "$QDIR/completed/rearm-me.yaml" \
  "CP.18 the re-arm returns the new path in completed/"
if [ -f "$_E_RA" ]; then
  _tap_fail "[HIGH] CP.18 the old review/ file is removed" "two files now describe one entry"
else
  _tap_pass "CP.18 the old review/ file is removed"
fi

_load_queue_entry "$_RA_NEW"
# All three of these are load-bearing against a separate close precondition:
# status for clause (1), close_state for clause (4), reverified for clause (2).
assert_eq "$_QE_STATUS" "completed" "CP.18 status returns to completed"
assert_eq "${_QE_CLOSE_STATE:-}" "ready" "CP.18 close_state returns to ready"
assert_eq "${_QE_REVERIFIED:-}" "" \
  "CP.18 reverified is cleared — false is a STANDING refusal, not a record"
assert_eq "${_QE_ERROR_LOG:-}" "" "CP.18 error_log is cleared"
assert_eq "$_QE_COMPLETED_AT" "2026-10-02T00:00:00Z" \
  "CP.18 completed_at is preserved — a re-arm is not a second completion"

# The step row is the pipeline's account of why this entry is mergeable again.
assert_contains "${_QE_CLOSE_STEPS:-}" '{"step":"resolve","status":"done"' \
  "CP.18 a resolve step is recorded"
assert_contains "${_QE_CLOSE_STEPS:-}" "mode: agent" "CP.18 the step row carries the mode"
assert_contains "${_QE_CLOSE_STEPS:-}" "keep both intents" \
  "CP.18 the step row carries the operator note"
assert_contains "${_QE_CLOSE_STEPS:-}" '{"step":"merge","status":"failed"' \
  "CP.18 the conflict that preceded it is still on the record"

# Without the reopen the fix brief would be queued and walked into blocked/ by
# the runner's escalated-work-order guard.
_load_work_order "$QDIR/work-orders/wo-rearm.yaml"
assert_eq "$_WO_STATUS" "open" "CP.18 the escalated parent work order is reopened"

# And the re-armed entry must actually pass the gate it was re-armed for,
# which is the only thing that makes the whole command worth running.
if _R=$(queue_close_merge_allowed "$_RA_NEW"); then
  _tap_pass "CP.18 the re-armed entry passes the merge gate"
else
  _tap_fail "[CRITICAL] CP.18 the re-armed entry passes the merge gate" "$_R"
fi

# A work order that is neither escalated nor failed is left alone.
cat > "$QDIR/work-orders/wo-open.yaml" <<'WO'
work_order:
  id: wo-open
  label: open-group
  type: taskgroup
  status: in_progress
  entry_ids:
  - rearm-open
  created_at: 2026-10-01T00:00:00Z
  updated_at: 2026-10-01T00:00:00Z
WO
_E_RA2=$(_write_old_entry "rearm-open" "review" "true" "" "wo-open")
queue_close_record "$_E_RA2" "conflict" "merge" "failed" ""
queue_close_rearm "$_E_RA2" "manual" "" > /dev/null
_load_work_order "$QDIR/work-orders/wo-open.yaml"
assert_eq "$_WO_STATUS" "in_progress" \
  "CP.18 a work order that is not escalated is not touched"

# ========================================================================
# CP.19 — the stored strategy inverts for git's rebase, once, then clears
# ========================================================================
# reverify-merge.sh is a pure library (functions plus three sentinels), so it
# can be sourced; the rebase it guards is covered by test-reverify-merge.sh.
# shellcheck disable=SC1091
source "$LIB_DIR/reverify-merge.sh"

_E_INV=$(_write_old_entry "invert" "completed" "true")
assert_eq "$(_reverify_take_conflict_strategy "invert")" "" \
  "CP.19 no stored strategy means no rebase argument"

# THE INVERSION. During `git rebase main` the branch is replayed ONTO main, so
# git's "ours" is main and "theirs" is the branch. The operator's --ours means
# "keep my branch's version", which is git's -Xtheirs. Swapping these silently
# discards the branch's work on every conflicting hunk.
queue_set_conflict_resolution "$_E_INV" "ours"
assert_eq "$(_reverify_take_conflict_strategy "invert")" "-Xtheirs" \
  "CP.19 the operator's --ours becomes git's -Xtheirs on a rebase"
_load_queue_entry "$_E_INV"
assert_eq "${_QE_CONFLICT_RESOLUTION:-}" "" \
  "CP.19 the strategy is cleared as it is read — it applies to ONE rebase"
assert_eq "$(_reverify_take_conflict_strategy "invert")" "" \
  "CP.19 a second read yields nothing, so a later close is not steered"

queue_set_conflict_resolution "$_E_INV" "theirs"
assert_eq "$(_reverify_take_conflict_strategy "invert")" "-Xours" \
  "CP.19 the operator's --theirs becomes git's -Xours on a rebase"

# Fail-soft on the way in: an unknown id must not abort a close.
_RC_IRC=0
_R=$(_reverify_take_conflict_strategy "no-such-entry") || _RC_IRC=$?
assert_eq "$_RC_IRC" "0" "CP.19 an unknown entry returns success, not a failure"
assert_eq "$_R" "" "CP.19 an unknown entry yields no rebase argument"

# ========================================================================
# CP.20 — resolve-conflict is wired into queue-cli.sh and delegates
# ========================================================================
if grep -qF "  resolve-conflict)" "$CLI_SH"; then
  _tap_pass "CP.20 queue-cli.sh dispatches resolve-conflict)"
else
  _tap_fail "[HIGH] CP.20 queue-cli.sh dispatches resolve-conflict)" "no dispatch arm found"
fi
if grep -qE "^  resolve-conflict " "$CLI_SH"; then
  _tap_pass "CP.20 resolve-conflict is in the usage block"
else
  _tap_fail "CP.20 resolve-conflict is in the usage block" "missing from _usage"
fi

_CLI_RC_BLOCK=$(sed -n '/^  resolve-conflict)$/,/^    ;;$/p' "$CLI_SH")
assert_contains "$_CLI_RC_BLOCK" 'JSON_OUTPUT' "CP.20 resolve-conflict supports --json"
assert_contains "$_CLI_RC_BLOCK" 'queue_conflict_resolve_allowed' \
  "CP.20 resolve-conflict checks the fail-closed precondition before acting"
for _flag in agent ours theirs manual; do
  assert_contains "$_CLI_RC_BLOCK" "--$_flag" "CP.20 resolve-conflict accepts --$_flag"
done
assert_contains "$_CLI_RC_BLOCK" 'requires one of --agent' \
  "CP.20 there is no default mode — the strategy is never guessed"

# --agent must delegate the enqueue to the one command that owns the t-0055
# clause 14 linkage. A second enqueue path would be free to drift from it.
assert_contains "$_CLI_RC_BLOCK" 'queue-cli.sh" follow-up-entry' \
  "CP.20 --agent delegates to follow-up-entry rather than enqueuing itself"
assert_not_contains "$_CLI_RC_BLOCK" 'queue_enqueue' \
  "CP.20 resolve-conflict contains no enqueue of its own"

# The strategy is stored, not applied: resolving locally would empty
# overlap_report.main_changed, the one trigger for the t-0056 re-verification,
# so the next close would skip it and report success.
assert_contains "$_CLI_RC_BLOCK" 'queue_set_conflict_resolution' \
  "CP.20 --ours/--theirs are stored through the one setter"
assert_not_contains "$_CLI_RC_BLOCK" '-Xtheirs' \
  "CP.20 the git inversion lives at the rebase, not at the CLI"
# The command must touch no working tree. Counted rather than grepped for a
# forbidden word because the generated brief TEXT tells the fix session to run
# `git rebase main` — the prohibition is on what this command executes, so the
# assertion is that every git call it makes is the read it needs for the SHAs.
_RC_GIT_CALLS=$(printf '%s\n' "$_CLI_RC_BLOCK" | grep -c 'git -C' || true)
_RC_GIT_READS=$(printf '%s\n' "$_CLI_RC_BLOCK" | grep -c 'git -C "$REPO_ROOT" rev-parse' || true)
assert_eq "$_RC_GIT_CALLS" "$_RC_GIT_READS" \
  "CP.20 every git call is a rev-parse — resolve-conflict rebases and merges nothing"

# --ours/--theirs reach git only through the solo path's rebase, so the pr path
# must refuse them rather than store a value nothing reads.
assert_contains "$_CLI_RC_BLOCK" 'local rebase strategy' \
  "CP.20 --ours/--theirs are refused on the pr close path"
assert_contains "$_CLI_RC_BLOCK" 'set-close' \
  "CP.20 the pr-path refusal names the way out"

# The re-arm is last: everything before it can refuse, and once the entry reads
# ready the conflict is no longer visible as one.
_RC_SET_LINE=$(printf '%s\n' "$_CLI_RC_BLOCK" | grep -n 'queue_set_conflict_resolution' | head -1 | cut -d: -f1)
_RC_FU_LINE=$(printf '%s\n' "$_CLI_RC_BLOCK" | grep -n 'queue-cli.sh" follow-up-entry' | head -1 | cut -d: -f1)
_RC_ARM_LINE=$(printf '%s\n' "$_CLI_RC_BLOCK" | grep -n 'queue_close_rearm' | head -1 | cut -d: -f1)
if [ -n "$_RC_ARM_LINE" ] && [ -n "$_RC_SET_LINE" ] && [ -n "$_RC_FU_LINE" ] \
   && [ "$_RC_SET_LINE" -lt "$_RC_ARM_LINE" ] && [ "$_RC_FU_LINE" -lt "$_RC_ARM_LINE" ]; then
  _tap_pass "CP.20 the re-arm runs LAST, after everything that can refuse"
else
  _tap_fail "[CRITICAL] CP.20 the re-arm runs LAST, after everything that can refuse" \
    "set at ${_RC_SET_LINE:-?}, follow-up at ${_RC_FU_LINE:-?}, re-arm at ${_RC_ARM_LINE:-?}"
fi

# --- Summary ------------------------------------------------------------
printf "\n1..%d\n" "$_TAP_TEST_NUM"
printf "# pass %d, fail %d\n" "$_TAP_PASS" "$_TAP_FAIL"
[ "$_TAP_FAIL" -eq 0 ]
