#!/usr/bin/env bash
# Work preserver — a dying session's uncommitted work must survive worktree
# removal (Decision t-0062).
#
# The defect: on 2026-10-21 a brief ended `review:dirty-noop` and the runner then
# `git worktree remove --force`d its tree. Four modified files were gone.
#
# Real git repos and real worktrees under /tmp. The real repo, the real queue and
# .claude/.state are never touched: every path is derived from $T below.
#
# Overrides, used to prove each case FAILS against the pre-fix code:
#   WP_LIB     work-preserver.sh to test        (default: ../lib/work-preserver.sh;
#              also accepted as the first argument)
#   WP_RUNNER  runner.sh for structural checks  (default: ../runner.sh)
#   WP_QM      queue-manager.sh                 (default: ../lib/queue-manager.sh)
#   WP_CLEANUP cleanup.sh                       (default: ../lib/cleanup.sh)
#
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
WP_LIB="${1:-${WP_LIB:-$LIB_DIR/work-preserver.sh}}"   # $1 = lib path (headless shells cannot set env prefixes)
WP_RUNNER="${WP_RUNNER:-$SCRIPT_DIR/../runner.sh}"
WP_QM="${WP_QM:-$LIB_DIR/queue-manager.sh}"
WP_CLEANUP="${WP_CLEANUP:-$LIB_DIR/cleanup.sh}"
WP_REPORTER="${WP_REPORTER:-$LIB_DIR/queue-reporter.sh}"
LOCK_LIB="$LIB_DIR/file-lock.sh"
BRANCH_LIB="$LIB_DIR/branch-manager.sh"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() {
  _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1))
  printf "not ok %d - %s\n" "$_TAP_NUM" "$1"
  if [ -n "${2:-}" ]; then printf "  # %s\n" "$2"; fi
  _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"
}
_tap_ok()  { if [ "$1" = true ]; then _tap_pass "$2"; else _tap_fail "$2" "${3:-}"; fi; }

printf "# === Work Preserver (Decision t-0062) ===\n"

# /tmp explicitly: the repo's test-seam guards want sandboxes under /tmp.
T=$(mktemp -d /tmp/repo-os-wp-XXXXXX)
trap 'rm -rf "$T"' EXIT
REPO="$T/repo"
AUTO="$T/auto"
mkdir -p "$REPO" "$AUTO/reports"

git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false
printf 'ignored.log\n' > "$REPO/.gitignore"
printf 'original\n' > "$REPO/a.txt"
printf 'to-delete\n' > "$REPO/gone.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m base

# Functions under test run `git worktree remove` against the cwd repo, as the
# runner does from the main checkout.
cd "$REPO"
export AUTOMATION_DIR="$AUTO"
export REPO_ROOT="$REPO"

# shellcheck disable=SC1090
source "$WP_LIB"

WT=""; BASE=""
_mkwt() {
  WT="$T/wt-$1"
  git -C "$REPO" worktree add -q -b "br-$1" "$WT" HEAD
  BASE=$(git -C "$WT" rev-parse HEAD)
}
_dirty() {
  printf 'changed\n' > "$WT/a.txt"
  printf 'brand new\n' > "$WT/new.txt"
  mkdir -p "$WT/sub/dir"
  printf 'nested\n' > "$WT/sub/dir/deep.txt"
  printf 'noise\n' > "$WT/ignored.log"
  rm -f "$WT/gone.txt"
  printf '\000\001\002BIN' > "$WT/blob.bin"
}
_listed() { git -C "$REPO" worktree list --porcelain | grep -c "^worktree $1\$" || true; }

# ---------------------------------------------------------------- 1, 3, 6
_mkwt dirty
_dirty
_PRESERVED_PATCH_PATH=""
remove_session_worktree "$WT" "$BASE" "entry-dirty" "review:dirty-noop" 2>/dev/null
P1="$_PRESERVED_PATCH_PATH"

_ok=false; [ -n "$P1" ] && [ -f "$P1" ] && _ok=true
_tap_ok "$_ok" "1a dirty no-commit session leaves a patch file" "path='$P1'"

_ok=false; case "$P1" in "$AUTO/reports/"*preserved-work-entry-dirty-*.patch) _ok=true ;; esac
_tap_ok "$_ok" "1b patch lives under reports/ and is named after the entry id" "path='$P1'"

_ok=false
if [ -f "$P1" ] && grep -q '^+++ b/a.txt' "$P1" && grep -q '^+changed' "$P1"; then _ok=true; fi
_tap_ok "$_ok" "1c patch contains the tracked modification"

_ok=false
if [ -f "$P1" ] && grep -q '^+++ b/new.txt' "$P1" && grep -q '^+brand new' "$P1" \
   && grep -q '^+++ b/sub/dir/deep.txt' "$P1"; then _ok=true; fi
_tap_ok "$_ok" "1d patch contains untracked files (git diff HEAD would omit them)"

_ok=false
if [ -f "$P1" ] && grep -q '^deleted file mode' "$P1" && grep -q 'GIT binary patch' "$P1"; then _ok=true; fi
_tap_ok "$_ok" "1e patch contains a deletion and a binary file"

_ok=false
if [ -f "$P1" ] && ! grep -q 'ignored.log' <(grep -v '^#' "$P1") ; then _ok=true; fi
_tap_ok "$_ok" "1f gitignored files are not captured"

_ok=false
if [ -f "$P1" ] && grep -q '^#   ?? new.txt' "$P1" && grep -q '^# outcome:     review:dirty-noop' "$P1"; then _ok=true; fi
_tap_ok "$_ok" "1g header records git status --short and the outcome"

_ok=false; [ ! -d "$WT" ] && [ "$(_listed "$WT")" = 0 ] && _ok=true
_tap_ok "$_ok" "3  worktree is still removed after capture"

_ok=false; git -C "$REPO" rev-parse --verify -q "br-dirty" >/dev/null && _ok=true
_tap_ok "$_ok" "3b the session branch is left alone"

# 6: apply against the merge base
git -C "$REPO" worktree add -q --detach "$T/check" "$BASE"
_ok=false
if [ -f "$P1" ] && git -C "$T/check" apply --check "$P1" 2>/dev/null; then _ok=true; fi
_tap_ok "$_ok" "6a git apply --check succeeds against the baseline"
if [ -f "$P1" ] && git -C "$T/check" apply "$P1" 2>/dev/null; then
  _ok=false
  if [ "$(cat "$T/check/a.txt")" = "changed" ] && [ "$(cat "$T/check/new.txt")" = "brand new" ] \
     && [ ! -e "$T/check/gone.txt" ] && [ "$(wc -c < "$T/check/blob.bin" | tr -d ' ')" = 6 ]; then _ok=true; fi
  _tap_ok "$_ok" "6b applying the patch reproduces the session's tree"
else
  _tap_fail "6b applying the patch reproduces the session's tree" "apply failed or no patch"
fi
git -C "$REPO" worktree remove --force "$T/check" 2>/dev/null || true

# ---------------------------------------------------------------- real index untouched
_mkwt idx
printf 'x\n' > "$WT/untracked-only.txt"
_before=$(git -C "$WT" status --short)
preserve_uncommitted_work "$WT" "$BASE" "entry-idx" "review:dirty-noop" 2>/dev/null
_after=$(git -C "$WT" status --short)
_ok=false; [ "$_before" = "$_after" ] && [ -n "$_PRESERVED_PATCH_PATH" ] && _ok=true
_tap_ok "$_ok" "1h capture alone leaves the worktree's real index untouched; untracked-only work is preserved"
git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true

# ---------------------------------------------------------------- 4
_mkwt committed
printf 'committed work\n' > "$WT/c.txt"
git -C "$WT" add c.txt
git -C "$WT" commit -q -m "session work"
_PRESERVED_PATCH_PATH="stale"
_n_before=$(ls "$AUTO/reports" | wc -l | tr -d ' ')
remove_session_worktree "$WT" "$BASE" "entry-committed" "completed:clean" 2>/dev/null
_n_after=$(ls "$AUTO/reports" | wc -l | tr -d ' ')
_ok=false; [ -z "$_PRESERVED_PATCH_PATH" ] && [ "$_n_before" = "$_n_after" ] && _ok=true
_tap_ok "$_ok" "4  a session that committed produces no patch" "before=$_n_before after=$_n_after path='$_PRESERVED_PATCH_PATH'"
_ok=false; [ ! -d "$WT" ] && _ok=true
_tap_ok "$_ok" "4b ...and its worktree is still removed"

# ---------------------------------------------------------------- 5
_mkwt clean
_n_before=$(ls "$AUTO/reports" | wc -l | tr -d ' ')
remove_session_worktree "$WT" "$BASE" "entry-clean" "completed:clean-noop" 2>/dev/null
_n_after=$(ls "$AUTO/reports" | wc -l | tr -d ' ')
_ok=false; [ -z "$_PRESERVED_PATCH_PATH" ] && [ "$_n_before" = "$_n_after" ] && _ok=true
_tap_ok "$_ok" "5  a clean-tree no-op produces no patch"
_ok=false; [ ! -d "$WT" ] && _ok=true
_tap_ok "$_ok" "5b ...and its worktree is still removed"

# ---------------------------------------------------------------- missing baseline
_mkwt nobase
_dirty
remove_session_worktree "$WT" "" "entry-nobase" "failed:runner-crash" 2>/dev/null
_ok=false; [ -n "$_PRESERVED_PATCH_PATH" ] && [ -f "$_PRESERVED_PATCH_PATH" ] && _ok=true
_tap_ok "$_ok" "1i an unknown baseline errs toward capturing, not toward losing work"

# ---------------------------------------------------------------- 7: must never fail the close
_mkwt nodisk
_dirty
printf 'not a directory\n' > "$T/afile"
_rc=0
( AUTOMATION_DIR="$T/afile"; remove_session_worktree "$WT" "$BASE" "entry-nodisk" "review:dirty-noop" ) 2>"$T/nodisk.err" || _rc=$?
_ok=false; [ "$_rc" = 0 ] && _ok=true
_tap_ok "$_ok" "7a an unwritable reports dir does not fail the close" "rc=$_rc"
_ok=false; [ ! -d "$WT" ] && _ok=true
_tap_ok "$_ok" "7b ...and the worktree is still removed"
_ok=false; grep -q 'NOT preserved' "$T/nodisk.err" && _ok=true
_tap_ok "$_ok" "7c ...and the loss is announced on stderr"

# non-directory / missing worktree argument
_rc=0; preserve_uncommitted_work "$T/does-not-exist" "$BASE" "x" "y" 2>/dev/null || _rc=$?
_ok=false; [ "$_rc" = 0 ] && [ -z "$_PRESERVED_PATCH_PATH" ] && _ok=true
_tap_ok "$_ok" "7d a missing worktree is a quiet no-op"

# ---------------------------------------------------------------- 2: discoverable from the queue entry
_mkwt q
_dirty
remove_session_worktree "$WT" "$BASE" "entry-q" "review:dirty-noop" 2>/dev/null
PQ="$_PRESERVED_PATCH_PATH"
NOTE=$(preserved_work_note "$PQ" "$REPO")

(
  export CONFIG_FILE="$AUTO/config.yaml"
  # shellcheck disable=SC1090
  source "$LOCK_LIB"
  # shellcheck disable=SC1090
  source "$BRANCH_LIB" 2>/dev/null || true
  # shellcheck disable=SC1090
  source "$WP_QM"
  _ensure_queue_dirs
  _mk_running() {
    printf 'entry:\n  id: "%s"\n  status: "running"\n  priority: "0"\n  session_type: "standard"\n  branch: "feature/x"\n  brief_path: "b.md"\n  created_at: "2026-10-22T00:00:00Z"\n  updated_at: "2026-10-22T00:00:00Z"\n' \
      "$1" > "$AUTO/queue/running/$1.yaml"
  }

  # review path (queue_escalate)
  _mk_running entry-q
  queue_escalate entry-q "review:dirty-noop; ${NOTE}" 2>/dev/null || true
  _el=$(grep '^  error_log:' "$AUTO/queue/review/entry-q.yaml" 2>/dev/null || true)
  _rel="${PQ#"$REPO"/}"
  case "$_el" in *"$_rel"*) echo "REVIEW_OK" ;; *) echo "REVIEW_MISSING: $_el" ;; esac

  # `queue-cli.sh review` reads review_items rows with IFS='|'. A '|' in error_log
  # would cut the path off and spill the rest into work_order_id.
  # shellcheck disable=SC1090
  source "$WP_REPORTER"
  _row=$(review_items 2>/dev/null | grep '^entry-q|' || true)
  IFS='|' read -r _r_id _r_st _r_ty _r_err _r_wo <<EOF_ROW
$_row
EOF_ROW
  case "$_r_err" in *"$_rel"*) echo "ROW_PATH_OK" ;; *) echo "ROW_PATH_MISSING: $_r_err" ;; esac
  if [ -z "$_r_wo" ]; then echo "ROW_WO_OK"; else echo "ROW_WO_CORRUPT: $_r_wo"; fi

  # failed path (queue_fail)
  _mk_running entry-f
  queue_fail entry-f "failed:crash; ${NOTE}" 2>/dev/null || true
  _ef=$(grep -h '^  error_log:' "$AUTO/queue/failed/entry-f.yaml" "$AUTO/queue/pending-review/entry-f.yaml" "$AUTO/queue/approved/entry-f.yaml" 2>/dev/null || true)
  case "$_ef" in *"$_rel"*) echo "FAIL_OK" ;; *) echo "FAIL_MISSING: $_ef" ;; esac

  # completed path (queue_complete): untracked-only work classifies as
  # completed:clean-noop, so a completed entry must carry the path too.
  _mk_running entry-c
  queue_complete entry-c "completed:clean-noop; ${NOTE}" 2>/dev/null || true
  _ec=$(grep '^  error_log:' "$AUTO/queue/completed/entry-c.yaml" 2>/dev/null || true)
  case "$_ec" in *"$_rel"*) echo "COMPLETE_OK" ;; *) echo "COMPLETE_MISSING: $_ec" ;; esac

  # incomplete-deliverable path (queue_incomplete → queue_escalate)
  _mk_running entry-i
  queue_incomplete entry-i "COMPLETENESS_GATE: NEEDS_WORK" "review:incomplete-deliverable; ${NOTE}" 2>/dev/null || true
  _ei=$(grep '^  error_log:' "$AUTO/queue/review/entry-i.yaml" 2>/dev/null || true)
  case "$_ei" in *"$_rel"*) echo "INCOMPLETE_OK" ;; *) echo "INCOMPLETE_MISSING: $_ei" ;; esac

  # no note → completed entry's error_log untouched
  _mk_running entry-cplain
  queue_complete entry-cplain 2>/dev/null || true
  _ecp=$(grep '^  error_log:' "$AUTO/queue/completed/entry-cplain.yaml" 2>/dev/null || true)
  case "$_ecp" in ''|*'error_log: ""'*) echo "CPLAIN_OK" ;; *) echo "CPLAIN_CHANGED: $_ecp" ;; esac

  # no reason → error_log untouched (no behaviour change for plain escalations)
  _mk_running entry-plain
  queue_escalate entry-plain 2>/dev/null || true
  _ep=$(grep '^  error_log:' "$AUTO/queue/review/entry-plain.yaml" 2>/dev/null || true)
  case "$_ep" in ''|*'error_log: ""'*) echo "PLAIN_OK" ;; *) echo "PLAIN_CHANGED: $_ep" ;; esac
) > "$T/q.out" 2>"$T/q.err" || true

_ok=false; grep -q '^REVIEW_OK' "$T/q.out" && _ok=true
_tap_ok "$_ok" "2a queue_escalate records the patch path where 'queue-cli.sh show' reads it" "$(grep REVIEW "$T/q.out" || true)"
_ok=false; grep -q '^FAIL_OK' "$T/q.out" && _ok=true
_tap_ok "$_ok" "2b queue_fail records the patch path in error_log" "$(grep FAIL "$T/q.out" || true)"
_ok=false; grep -q '^PLAIN_OK' "$T/q.out" && _ok=true
_tap_ok "$_ok" "2c queue_escalate without a reason leaves error_log alone" "$(grep PLAIN "$T/q.out" || true)"
_ok=false; [ -z "$(preserved_work_note "" "$REPO")" ] && _ok=true
_tap_ok "$_ok" "2d no patch → no note (error_log stays exactly the outcome string)"
_ok=false; grep -q '^ROW_PATH_OK' "$T/q.out" && _ok=true
_tap_ok "$_ok" "2e 'queue-cli.sh review' row still carries the patch path" "$(grep ROW_PATH "$T/q.out" || true)"
_ok=false; grep -q '^ROW_WO_OK' "$T/q.out" && _ok=true
_tap_ok "$_ok" "2f ...and the note does not spill into work_order_id" "$(grep ROW_WO "$T/q.out" || true)"
case "$NOTE" in *'|'*) _ok=false ;; *) _ok=true ;; esac
_tap_ok "$_ok" "2g the note contains no '|' (the review rows are pipe-delimited)"
_ok=false; grep -q '^COMPLETE_OK' "$T/q.out" && _ok=true
_tap_ok "$_ok" "2h queue_complete records the patch path (untracked-only work completes)" "$(grep COMPLETE "$T/q.out" || true)"
_ok=false; grep -q '^INCOMPLETE_OK' "$T/q.out" && _ok=true
_tap_ok "$_ok" "2i queue_incomplete records the patch path" "$(grep INCOMPLETE "$T/q.out" || true)"
_ok=false; grep -q '^CPLAIN_OK' "$T/q.out" && _ok=true
_tap_ok "$_ok" "2j queue_complete without a note leaves error_log alone" "$(grep CPLAIN "$T/q.out" || true)"

# ---------------------------------------------------------------- runner wiring (structural)
# runner.sh cannot be sourced (argv parsing + daemon loop at load), so check the
# call sites textually. A bare removal of the session worktree is the regression.
_codef="$T/runner.code"
grep -v '^[[:space:]]*#' "$WP_RUNNER" > "$_codef" || true
_bare=$(grep -c 'git worktree remove --force "\$_CURRENT_WORKTREE_DIR"' "$_codef" || true)
_ok=false; [ "$_bare" = 0 ] && _ok=true
_tap_ok "$_ok" "8a runner.sh has no bare 'git worktree remove --force \$_CURRENT_WORKTREE_DIR'" "found $_bare"

_ok=false; grep -q 'source "\$LIB_DIR/work-preserver.sh"' "$_codef" && _ok=true
_tap_ok "$_ok" "8b runner.sh sources lib/work-preserver.sh"

for _o in 'failed:runner-crash' 'failed:force-halt'; do
  _ok=false; grep -q "remove_session_worktree .*\"$_o\"" "$_codef" && _ok=true
  _tap_ok "$_ok" "8c runner.sh captures before removal on $_o"
done
_ok=false; grep -q 'remove_session_worktree "\$_CURRENT_WORKTREE_DIR" "\$_RESULT_BASELINE" "\$brief_id" "\$_RESULT_OUTCOME"' "$_codef" && _ok=true
_tap_ok "$_ok" "8d runner.sh captures before removal on the normal post-session path"

_ok=false; grep -q '_pw_note=\$(preserved_work_note' "$_codef" && _ok=true
_tap_ok "$_ok" "8e runner.sh builds the note once, before the outcome transitions"
# Every outcome transition must carry it: a patch recorded on only some of them is
# a patch nobody can find for the rest (untracked-only work completes).
for _fn in queue_complete queue_incomplete queue_escalate queue_fail_terminal; do
  _n=$(grep "$_fn \"\$ENTRY_ID\"" "$_codef" | grep -c '_pw_note' || true)
  _ok=false; [ "$_n" -ge 1 ] && _ok=true
  _tap_ok "$_ok" "8f runner.sh passes the note to $_fn" "sites=$_n"
done
_n=$(grep 'queue_fail "\$ENTRY_ID"' "$_codef" | grep -c '_pw_note' || true)
_ok=false; [ "$_n" -ge 2 ] && _ok=true
_tap_ok "$_ok" "8g runner.sh passes the note to both queue_fail sites (failed, wildcard)" "sites=$_n"
_ok=false; grep -q 'preserved_work_note "\$_fh_patch"' "$_codef" && _ok=true
_tap_ok "$_ok" "8h runner.sh threads the note through the FORCE-HALT handler"

# ---------------------------------------------------------------- retention
mkdir -p "$AUTO/reports"
printf 'old\n' > "$AUTO/reports/preserved-work-old-20200101-000000.patch"
touch -t 202001010000 "$AUTO/reports/preserved-work-old-20200101-000000.patch"
printf 'new\n' > "$AUTO/reports/preserved-work-new-20991231-000000.patch"
(
  # shellcheck disable=SC1090
  source "$WP_CLEANUP"
  _clean_reports 30 >/dev/null
) 2>/dev/null || true
_ok=false
if [ ! -e "$AUTO/reports/preserved-work-old-20200101-000000.patch" ] && [ -e "$AUTO/reports/preserved-work-new-20991231-000000.patch" ]; then _ok=true; fi
_tap_ok "$_ok" "9  cleanup reaps expired preserved-work patches and keeps fresh ones"

printf "\n1..%d\n# Tests: %d  Pass: %d  Fail: %d\n" "$_TAP_NUM" "$_TAP_NUM" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then
  printf "# Failures:\n%b" "$_TAP_FAILURES"
  exit 1
fi
exit 0
