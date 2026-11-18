#!/usr/bin/env bash
# Pushing main to origin is opt-in (Decision t-0066, child GT-3).
#
# Before t-0066 the SessionEnd hook pushed main after every merge outside
# template mode, and the runner fell back to its own push when an entry had
# no push_on_complete, so `--push` could not stop a push. Each function below
# is extracted from its file and run against a local bare origin; a
# post-receive hook on the origin counts ref updates, so "not pushed" and
# "pushed exactly once" are observed on the remote, not inferred from output.
# Cases marked "guard" also pass on the pre-t-0066 code.
#
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test-helpers.sh"

CLOSE_CHECK="$HOOKS_DIR/session-close-check.sh"
RUNNER="$REPO_DIR/.claude/.automation/runner.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/push-opt-in.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Load one top-level function from a file. A missing function loads nothing,
# so a case calling it fails rather than aborting the suite.
_load_fn() { # file name
  local f="$WORK/fn-$2.sh"
  sed -n "/^$2() {/,/^}/p" "$1" > "$f"
  # shellcheck disable=SC1090
  . "$f"
}

# Stubs for what the extracted functions call. Each records its arguments.
log_hook_event() { echo "$6" >> "$WORK/events"; }
_close_record() { echo "$4|$5" >> "$WORK/close"; }
get_main_repo_root() { echo "${MAIN_ROOT:-$CLONE}"; }
START_MS=0

# A clone with a bare origin. The origin counts every received push.
_fresh_repo() {
  rm -rf "$WORK/origin.git" "$WORK/clone" "$WORK/events" "$WORK/close" "$WORK/pushes"
  : > "$WORK/events"; : > "$WORK/close"; : > "$WORK/pushes"
  git init -q --bare "$WORK/origin.git"
  printf '#!/bin/sh\necho push >> "%s"\n' "$WORK/pushes" > "$WORK/origin.git/hooks/post-receive"
  chmod +x "$WORK/origin.git/hooks/post-receive"
  git init -q "$WORK/clone"
  CLONE="$WORK/clone"
  (
    cd "$CLONE"
    git config user.email t@example.com; git config user.name t
    git checkout -q -b main
    echo a > a; git add a; git commit -q -m a
    git remote add origin "$WORK/origin.git"
    git push -q origin main 2>/dev/null
    echo b > b; git add b; git commit -q -m b
  )
  : > "$WORK/pushes"
  mkdir -p "$CLONE/.claude/.automation"
}

_origin_main() { git --git-dir="$WORK/origin.git" rev-parse main 2>/dev/null; }
_local_main() { git -C "$CLONE" rev-parse main; }
_push_count() { wc -l < "$WORK/pushes" | tr -d ' '; }

_setting() { # file value
  printf 'runner:\n  enabled: false\n  push_main_on_session_end: %s\n' "$2" > "$CLONE/.claude/.automation/$1"
}

# Run the hook's push in the clone, as SessionEnd does after a merge.
_hook_push() {
  ( cd "$CLONE"; REPO_ROOT="$CLONE"; advisory_push_to_remote ) 2> "$WORK/stderr" || true
}

_load_fn "$CLOSE_CHECK" advisory_push_to_remote
_load_fn "$RUNNER" _push_main_after_merge
unset REPO_OS_SESSION_ID 2>/dev/null || true

# ============================================================
tap_section "P: the SessionEnd hook pushes main only when an interactive operator opted in"
# ============================================================
_fresh_repo
IS_TEMPLATE=false
_hook_push
assert_eq "$(_push_count)" "0" "P1 interactive with no setting: origin receives nothing"
assert_eq "$(grep -c 'push_skipped_no_opt_in' "$WORK/events" || true)" "1" "P1 the skip is logged as push_skipped_no_opt_in"
assert_contains "$(cat "$WORK/stderr")" "git push origin main" "P1 the notice names the command to run"

_fresh_repo
_setting config.yaml true
_hook_push
assert_eq "$(_origin_main)" "$(_local_main)" "P2 interactive with push_main_on_session_end true: main is pushed"

_fresh_repo
_setting config.yaml true
_setting config.local.yaml false
_hook_push
assert_eq "$(_push_count)" "0" "P3 config.local.yaml false overrides config.yaml true"

_fresh_repo
_setting config.yaml true
printf 'runner:\n  enabled: false\n' > "$CLONE/.claude/.automation/config.local.yaml"
_hook_push
assert_eq "$(_push_count)" "1" "P3b config.local.yaml without the key falls through to config.yaml"

_fresh_repo
printf "runner:\n  push_main_on_session_end: 'true'   # opted in\n" > "$CLONE/.claude/.automation/config.yaml"
_hook_push
assert_eq "$(_push_count)" "1" "P3c a quoted value with a trailing comment reads as true"

# A worktree session: REPO_ROOT is the worktree, which has no copy of the
# gitignored config.local.yaml. The setting is read from the main root.
_fresh_repo
_setting config.yaml false
MAIN_ROOT="$WORK/main-root"
mkdir -p "$MAIN_ROOT/.claude/.automation"
printf 'runner:\n  push_main_on_session_end: true\n' > "$MAIN_ROOT/.claude/.automation/config.local.yaml"
_hook_push
unset MAIN_ROOT
rm -rf "$WORK/main-root"
assert_eq "$(_push_count)" "1" "P3d the setting is read from the main repo root, not the worktree"

_fresh_repo
_setting config.yaml true
export REPO_OS_SESSION_ID="brief-p4"
_hook_push
unset REPO_OS_SESSION_ID
assert_eq "$(_push_count)" "0" "P4 headless never pushes, even with the setting true"
assert_eq "$(grep -c 'push_skipped_headless' "$WORK/events" || true)" "1" "P4 the skip is logged as push_skipped_headless"

_fresh_repo
_setting config.yaml true
IS_TEMPLATE=true
_hook_push
IS_TEMPLATE=false
assert_eq "$(_push_count)" "0" "P5 template mode does not push (guard)"

_fresh_repo
_setting config.yaml true
git -C "$CLONE" remote remove origin
_hook_push
assert_eq "$(_push_count)" "0" "P6 no origin remote: nothing pushed (guard)"

# ============================================================
tap_section "R: the runner pushes main after a merge only with push_on_complete"
# ============================================================
_fresh_repo
( cd "$CLONE"; _push_main_after_merge "brief-r1" "false" ) 2>/dev/null || true
assert_eq "$(_push_count)" "0" "R1 push_on_complete false: origin receives nothing"
assert_contains "$(cat "$WORK/close")" "skipped|push_on_complete false" "R1 the close step is recorded as skipped"

_fresh_repo
( cd "$CLONE"; _push_main_after_merge "brief-r2" "true" ) 2>/dev/null || true
assert_eq "$(_push_count)" "1" "R2 push_on_complete true: main is pushed exactly once"
assert_eq "$(_origin_main)" "$(_local_main)" "R2 origin main matches local main"

# ============================================================
tap_section "S: no other place in either file pushes main"
# ============================================================
# Comment lines are dropped. A line runs a push when, with its quoted strings
# removed (so an echoed "run 'git push origin main'" hint does not count), it
# still has `git [-C dir] push` anywhere: after &&, inside $(...), or bare. It
# pushes main when the original line names main (also HEAD:main). Each such
# line must sit inside its one function.
_pushers() { # file -> the enclosing function of each push of main
  awk '
    /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { fn = $1; sub(/\(\).*/, "", fn) }
    /^}/ { fn = "" }
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    line ~ /^#/ { next }
    { cmd = line; gsub(/"[^"]*"/, "", cmd); gsub(/\047[^\047]*\047/, "", cmd) }
    cmd ~ /git([[:space:]]+-C([[:space:]]+[^[:space:]]+)?)?[[:space:]]+push/ && line ~ /[[:space:]:"]main([[:space:]>;")]|$)/ { print (fn == "" ? "<top-level>" : fn) }
  ' "$1" | sort -u | tr '\n' ' ' | sed 's/ $//'
}
assert_eq "$(_pushers "$CLOSE_CHECK")" "advisory_push_to_remote" "S1 session-close-check.sh pushes main only in advisory_push_to_remote"
assert_eq "$(_pushers "$RUNNER")" "_push_main_after_merge" "S2 runner.sh pushes main only in _push_main_after_merge"

finish_tests
