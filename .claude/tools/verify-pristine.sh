#!/usr/bin/env bash
# verify-pristine.sh — check a change to the enforcement mechanism from OUTSIDE itself
# (Decision t-0063).
#
# The problem: a change to hooks / runner / queue libs / their tests is verified by the
# harness it just modified. A test helper edited to say "ok" turns every suite green
# and the commit gate, running the same helper, agrees. This tool:
#
#   1. resolves the merge base of HEAD and --base (default: main);
#   2. makes a throwaway clone of the repository's object store, checked out at the
#      merge base, with a `main` ref and no remote;
#   3. copies in ONLY the change's added/modified TEST files (never harness files:
#      test-helpers.sh, test-fixtures.sh, run-*.sh) — so a suite that passes only
#      because the harness was edited fails here;
#   4. runs the named suites there under a scrubbed environment, with a watchdog;
#   5. reports pass/fail counts, optionally writes hash-bound evidence, cleans up.
#
# A pristine run measures the change's tests against the code BEFORE the change. New
# tests that exercise new behaviour are therefore EXPECTED to fail here ("fail first");
# what the run proves is that the harness cannot be what makes them pass. The commit
# gate demands that this run happened and is fresh, not that it was green.
#
# Isolation is by construction: a `git clone`, not a linked worktree (which shares the
# common dir with the real repository), a temp dir under /tmp, an `env -i` environment
# and a trap that removes the temp dir. Nothing is written inside the real repository
# except the file named by --out.
#
# Usage:
#   verify-pristine.sh [--repo=DIR] [--base=REF] [--suite=PATH]... [--out=FILE]
#                      [--timeout=SECS] [--classify]
#   --repo      repository (or linked checkout) to verify; default: current toplevel
#   --base      ref to take the merge base against; default: main
#   --suite     a suite path relative to the repo root; repeatable. Default: every
#               test file this change adds or modifies.
#   --out       write evidence (YAML) to FILE, relative to the repo root
#   --timeout   per-suite watchdog in seconds; default 600
#   --classify  do not run anything: print `mechanism-change: yes|no` and the files
#
# Stdout is `key: value` lines. Exit 0 when the run happened (failing tests are data),
# 1 on tool_error (unresolvable base, missing suite, clone failure, timeout), 64 on
# bad usage. Bash 3.2 compatible; no GNU timeout (macOS lacks it).

set -uo pipefail

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX GIT_OBJECT_DIRECTORY

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$TOOL_DIR/../hooks/_mechanism-helper.sh"

usage() {
  cat <<'USAGE'
usage: verify-pristine.sh [--repo=DIR] [--base=REF] [--suite=PATH]... [--out=FILE] [--timeout=SECS] [--classify]
USAGE
}

REPO=""; BASE="main"; SUITES=""; OUT=""; TIMEOUT=600; CLASSIFY=0
for _a in "$@"; do
  case "$_a" in
    --repo=*)    REPO="${_a#--repo=}" ;;
    --base=*)    BASE="${_a#--base=}" ;;
    --suite=*)   SUITES="${SUITES}${_a#--suite=}"$'\n' ;;
    --out=*)     OUT="${_a#--out=}" ;;
    --timeout=*) TIMEOUT="${_a#--timeout=}" ;;
    --classify)  CLASSIFY=1 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unknown argument: $_a" >&2; usage >&2; exit 64 ;;
  esac
done
case "$TIMEOUT" in ''|*[!0-9]*|0) echo "--timeout must be a whole number of seconds, at least 1" >&2; exit 64 ;; esac

if [ -z "$REPO" ]; then
  REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "outcome: tool_error"; echo "error: not inside a git repository"; exit 1; }
else
  REPO=$(cd "$REPO" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || { echo "outcome: tool_error"; echo "error: --repo is not a git repository"; exit 1; }
fi

WORK=""
cleanup() { if [ -n "$WORK" ]; then rm -rf "$WORK"; fi; }
trap cleanup EXIT
trap 'exit 130' INT TERM

G() { git -C "$REPO" "$@"; }

MB=""
OUTCOME="tool_error"
TOTAL_PASS=0
TOTAL_FAIL=0
SUITE_LIST=""

write_evidence() {
  [ -n "$OUT" ] || return 0
  [ -n "$MB" ] || return 0
  local dest="$OUT" staged hash
  case "$dest" in /*) ;; *) dest="$REPO/$dest" ;; esac
  staged=$(cd "$REPO" && mech_filter "$(git diff --cached --name-only --no-renames --diff-filter=ACMDT 2>/dev/null)")
  hash=$(cd "$REPO" && mech_change_hash "$staged")
  if [ -z "$hash" ]; then
    echo "warning: no mechanism file is staged; the evidence is bound to an empty change and will not satisfy the gate" >&2
  fi
  mkdir -p "$(dirname "$dest")" 2>/dev/null || true
  {
    printf 'merge_base: %s\n' "$MB"
    printf 'change_hash: %s\n' "$hash"
    printf 'outcome: %s\n' "$OUTCOME"
    printf 'pass: %s\n' "$TOTAL_PASS"
    printf 'fail: %s\n' "$TOTAL_FAIL"
    printf 'suites: %s\n' "$(printf '%s' "$SUITE_LIST" | tr '\n' ' ' | sed 's/ *$//')"
    printf 'tool: verify-pristine.sh\n'
    printf 'generated_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$dest" || echo "warning: could not write evidence to $dest" >&2
}

fail_tool() {
  OUTCOME="tool_error"
  echo "outcome: tool_error"
  echo "error: $1"
  write_evidence
  exit 1
}

# --- 1. merge base -----------------------------------------------------------------
if ! G rev-parse --verify -q "${BASE}^{commit}" >/dev/null 2>&1; then
  fail_tool "base ref '$BASE' does not resolve to a commit"
fi
MB=$(G merge-base HEAD "$BASE" 2>/dev/null) || MB=""
[ -n "$MB" ] || fail_tool "no merge base between HEAD and '$BASE'"
echo "merge_base: $MB"

changed_files() {
  { G diff --name-only --no-renames --diff-filter=ACMDT "$MB" -- 2>/dev/null; G ls-files --others --exclude-standard 2>/dev/null; } | LC_ALL=C sort -u
}

CHANGED=$(changed_files)
MECH_CHANGED=$(mech_filter "$CHANGED")

if [ "$CLASSIFY" = 1 ]; then
  if [ -n "$MECH_CHANGED" ]; then echo "mechanism-change: yes"; else echo "mechanism-change: no"; fi
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    echo "file: $_f"
  done <<EOF
$MECH_CHANGED
EOF
  exit 0
fi

# --- 2. what is copied in, what is not -----------------------------------------------
COPY_SET=""; HARNESS_CHANGED=""; CODE_CHANGED=""; DELETED=""
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  if [ ! -e "$REPO/$_f" ]; then
    DELETED="${DELETED}${_f} "
  elif mech_is_test_path "$_f"; then
    COPY_SET="${COPY_SET}${_f}"$'\n'
  else
    case "$_f" in
      */tests/*|.claude/tools/*conformance*.sh) HARNESS_CHANGED="${HARNESS_CHANGED}${_f} " ;;
      *)         CODE_CHANGED="${CODE_CHANGED}${_f} " ;;
    esac
  fi
done <<EOF
$MECH_CHANGED
EOF

if [ -z "$SUITES" ]; then SUITES="$COPY_SET"; fi
SUITE_LIST="$SUITES"

join() { printf '%s' "$1" | tr '\n' ' ' | sed 's/ *$//'; }
_v=$(join "$COPY_SET");        echo "copied: ${_v:-none}"
_v=$(join "$HARNESS_CHANGED"); echo "harness_changed: ${_v:-none}"
_v=$(join "$CODE_CHANGED");    echo "code_changed: ${_v:-none}"
_v=$(join "$DELETED");         echo "deleted: ${_v:-none}"

# Evidence binds the STAGED content; flag edits the index does not hold.
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  [ -e "$REPO/$_f" ] || continue
  if ! G diff --quiet -- "$_f" 2>/dev/null; then
    echo "warning: $_f has unstaged edits; the evidence binds the staged content, so stage it (tests are copied from the index when staged)" >&2
  fi
done <<EOF
$MECH_CHANGED
EOF

# --- 3. throwaway checkout ------------------------------------------------------------
WORK=$(mktemp -d /tmp/verify-pristine.XXXXXX) || fail_tool "cannot create a temp directory under /tmp"
CHK="$WORK/checkout"
mkdir -p "$WORK/home" "$WORK/tmp"
printf '[user]\n\tname = verify-pristine\n\temail = verify-pristine@localhost\n[commit]\n\tgpgsign = false\n' > "$WORK/home/.gitconfig"

COMMON=$(G rev-parse --git-common-dir 2>/dev/null) || fail_tool "cannot locate the git common dir"
case "$COMMON" in /*) ;; *) COMMON="$REPO/$COMMON" ;; esac

if ! git -c core.hooksPath=/dev/null clone -q --local --no-checkout "$COMMON" "$CHK" >"$WORK/clone.log" 2>&1; then
  fail_tool "clone failed: $(head -1 "$WORK/clone.log")"
fi
CK() { git -C "$CHK" -c core.hooksPath=/dev/null "$@"; }
CK checkout -q --detach "$MB" >"$WORK/co.log" 2>&1 || fail_tool "checkout of the merge base failed: $(head -1 "$WORK/co.log")"
CK checkout -q -B main "$MB" >"$WORK/co.log" 2>&1 || fail_tool "creating the main ref failed: $(head -1 "$WORK/co.log")"
CK remote remove origin >/dev/null 2>&1 || true

while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  mkdir -p "$(dirname "$CHK/$_f")"
  if G ls-files --error-unmatch -- "$_f" >/dev/null 2>&1; then
    G show ":$_f" > "$CHK/$_f" 2>/dev/null || fail_tool "cannot copy $_f (from the index) into the pristine checkout"
  else
    cp -p "$REPO/$_f" "$CHK/$_f" || fail_tool "cannot copy $_f into the pristine checkout"
  fi
done <<EOF
$COPY_SET
EOF

while IFS= read -r _s; do
  [ -n "$_s" ] || continue
  [ -f "$CHK/$_s" ] || fail_tool "suite not found in the pristine checkout: $_s"
done <<EOF
$SUITES
EOF

# --- 4. run ------------------------------------------------------------------------------
kill_tree() {
  local p="$1" c
  for c in $(pgrep -P "$p" 2>/dev/null); do kill_tree "$c"; done
  kill -9 "$p" 2>/dev/null || true
}

run_suite() {
  local suite="$1" log="$WORK/suite.log" pid ticks=0 limit=$((TIMEOUT * 5))
  : > "$log"
  ( cd "$CHK" && exec env -i PATH="$PATH" HOME="$WORK/home" TMPDIR="$WORK/tmp" LC_ALL=C GIT_CONFIG_NOSYSTEM=1 bash "$suite" ) >"$log" 2>&1 </dev/null &
  pid=$!
  S_TIMEOUT=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$limit" ]; then S_TIMEOUT=1; kill_tree "$pid"; break; fi
    sleep 0.2
    ticks=$((ticks + 1))
  done
  S_RC=0
  wait "$pid" 2>/dev/null || S_RC=$?
  S_PASS=$(grep -c '^ok ' "$log" || true)
  S_FAIL=$(grep -c '^not ok ' "$log" || true)
}

TIMED_OUT_SUITE=""
while IFS= read -r _s; do
  [ -n "$_s" ] || continue
  run_suite "$_s"
  _note=""
  if [ "$S_TIMEOUT" = 1 ]; then _note=" timed_out"; TIMED_OUT_SUITE="$_s"; fi
  if [ "$S_PASS" = 0 ] && [ "$S_FAIL" = 0 ]; then _note="$_note tap=none"; fi
  # A suite that exits non-zero without reporting a single failure crashed (or speaks
  # a dialect this counter does not read). Count that as a failure, never as silence.
  if [ "$S_RC" != 0 ] && [ "$S_FAIL" = 0 ] && [ "$S_TIMEOUT" != 1 ]; then
    S_FAIL=1; _note="$_note exit_nonzero_counted_as_fail"
  fi
  echo "suite: $_s rc=$S_RC pass=$S_PASS fail=$S_FAIL$_note"
  TOTAL_PASS=$((TOTAL_PASS + S_PASS))
  TOTAL_FAIL=$((TOTAL_FAIL + S_FAIL))
  [ -z "$TIMED_OUT_SUITE" ] || break
done <<EOF
$SUITES
EOF

echo "total: pass=$TOTAL_PASS fail=$TOTAL_FAIL"
if [ -n "$TIMED_OUT_SUITE" ]; then
  fail_tool "suite timed_out after ${TIMEOUT}s: $TIMED_OUT_SUITE"
fi
if [ -z "$SUITES" ]; then
  echo "note: this change adds or modifies no test files and no --suite was named; nothing was run — the commit gate will treat this evidence as 'empty'. Name an existing suite that exercises the change with --suite=PATH."
elif [ "$((TOTAL_PASS + TOTAL_FAIL))" = 0 ]; then
  echo "note: the named suites reported no results; the commit gate will treat this evidence as 'empty'"
fi

OUTCOME="ran"
echo "outcome: ran"
write_evidence
exit 0
