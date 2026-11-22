#!/usr/bin/env bash
# Review findings as a file — Decision t-0082 (Massimo R5)
#
# Prompt A writes its advisory review findings with .claude/tools/review-findings.sh
# to docs/spec/review-findings/<version>.yaml; the operator's decisions are
# recorded with `set`; `check` passes only when every Blocking finding is applied
# or dismissed with a reason. Each case runs the real tool against a scratch repo.
#
# Run against the code before t-0082 (verify-pristine) every case fails: the
# tool does not exist.
# Bash 3.2 compatible.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TOOL="$REAL_REPO/.claude/tools/review-findings.sh"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"; }
_tap_eq() { if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi; }
_tap_contains() { case "$1" in *"$2"*) _tap_pass "$3" ;; *) _tap_fail "$3" "output did not contain '$2'" ;; esac; }

printf "# === Review findings file (Decision t-0082) ===\n"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/rf-test.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
export REPO_ROOT="$WORK"
F="$WORK/docs/spec/review-findings/v1.yaml"

run() { OUT=$(bash "$TOOL" "$@" 2>&1); RC=$?; }
runin() { local input="$1"; shift; OUT=$(printf '%s\n' "$input" | bash "$TOOL" "$@" 2>&1); RC=$?; }
val() { awk -v id="$1" -v k="$2" '
  $0 ~ "^  - id: \"" id "\"$" { on=1; next }
  /^  - id: / { on=0 }
  on && $0 ~ "^    " k ": " { sub("^    " k ": \"", ""); sub("\"$", ""); print; exit }' "$F"; }

GOOD='findings:
  - id: "F1"
    kind: "critical"
    agent: "critic"
    spec_file: "docs/spec/drafts/v1/data-contracts.md"
    section: "ProjectRegistry"
    finding: "Names are not unique: \"Core\" and \"core\" both allowed"
    suggested_fix: "Match names ignoring case and spacing"
  - id: "F2"
    kind: "recommendation"
    agent: "architect"
    spec_file: "docs/spec/drafts/v1/architecture.md"
    section: "Storage"
    finding: "No backup plan"
    suggested_fix: "Add a nightly export"
  - id: "F3"
    kind: "idea"
    agent: "exploration"
    spec_file: "docs/spec/drafts/v1/product.md"
    section: "Onboarding"
    finding: "A sample project would help"
    suggested_fix: "Ship one example project"
  - id: "F4"
    kind: "critical"
    agent: "security-analyst"
    spec_file: "docs/spec/drafts/v1/integrations.md"
    section: "GitHub"
    finding: "Token scope is not stated"
    suggested_fix: "Name the minimum scopes"'

printf "\n# --- write ---\n"
runin "$GOOD" write v1
_tap_eq "$RC" "0" "write succeeds"
[ -f "$F" ] && _tap_pass "...and creates docs/spec/review-findings/v1.yaml" || _tap_fail "...and creates docs/spec/review-findings/v1.yaml"
_tap_contains "$(cat "$F" 2>/dev/null)" 'schema_version: "1.0.0"' "the file carries schema_version 1.0.0"
_tap_contains "$(cat "$F" 2>/dev/null)" 'spec_version: "v1"' "...and the spec version"
_tap_eq "$(val F1 severity)" "Blocking" "a critical finding is Blocking"
_tap_eq "$(val F2 severity)/$(val F3 severity)" "Advisory/Advisory" "recommendations and ideas are Advisory"
_tap_eq "$(val F1 status)" "open" "status defaults to open"
_tap_eq "$(val F2 agent)|$(val F2 spec_file)|$(val F2 section)|$(val F2 suggested_fix)" \
  "architect|docs/spec/drafts/v1/architecture.md|Storage|Add a nightly export" "agent, spec file, section and fix are stored"
_tap_contains "$(cat "$F" 2>/dev/null)" 'finding: "Names are not unique: \"Core\" and \"core\" both allowed"' "quotes in a value round-trip"
_tap_eq "$(ls -l "$F" 2>/dev/null | cut -c1-10)" "-rw-r--r--" "the file is written with mode 644"
BEFORE=$(cksum < "$F")
runin "$GOOD" write v1
_tap_eq "$RC" "1" "a second write is refused"
_tap_contains "$OUT" "--replace" "...naming --replace"
_tap_eq "$(cksum < "$F")" "$BEFORE" "...and leaves the file unchanged"

printf "\n# --- write refusals create nothing ---\n"
bad() {   # bad <label> <input>
  runin "$2" write v9
  if [ "$RC" -ne 0 ] && [ ! -e "$WORK/docs/spec/review-findings/v9.yaml" ]; then _tap_pass "$1"
  else _tap_fail "$1" "rc=$RC, file exists: $([ -e "$WORK/docs/spec/review-findings/v9.yaml" ] && echo yes || echo no)"; fi
}
ONE='findings:
  - id: "X1"
    kind: "critical"
    agent: "critic"
    spec_file: "a.md"
    section: "S"
    finding: "f"
    suggested_fix: "x"'
bad "a malformed line is refused" "$ONE
  colour: blue"
bad "a missing required field is refused" "$(printf '%s\n' "$ONE" | grep -v section)"
bad "an unknown kind is refused" "$(printf '%s\n' "$ONE" | sed 's/"critical"/"urgent"/')"
bad "an unknown status is refused" "$ONE
    status: \"done\""
bad "a supplied severity is refused" "$ONE
    severity: \"Advisory\""
bad "a duplicate id is refused" "$ONE
$(printf '%s\n' "$ONE" | sed 1d)"
bad "a value spread over two lines is refused" "$(printf '%s\n' "$ONE" | sed 's/finding: "f"/finding: "first/')
second\""
bad "a trailing comment after a value is refused" "$(printf '%s\n' "$ONE" | sed 's/section: "S"/section: "S" # note/')"
bad "an unescaped quote inside a value is refused" "$(printf '%s\n' "$ONE" | sed 's/finding: "f"/finding: "a" junk"/')"
bad "a final backslash escaping the closing quote is refused" "$(printf '%s\n' "$ONE" | sed 's/finding: "f"/finding: "x\\\\\\"/')"
bad "a field given twice is refused even when the first is empty" "$(printf '%s\n' "$ONE" | sed 's/    agent: "critic"/    agent: ""\
    agent: "critic"/')"
bad "a carriage return inside a value is refused" "$(printf '%s\n' "$ONE" | sed "s/finding: \"f\"/finding: \"a$(printf '\r')b\"/")"
run write "../x"
_tap_eq "$RC" "1" "a version that is not a plain name is refused"
runin "$ONE" write --replace
_tap_eq "$RC" "1" "an option in place of the version is refused"
[ -e "$WORK/docs/spec/review-findings/--replace.yaml" ] && _tap_fail "...and creates no file named after it" || _tap_pass "...and creates no file named after it"

printf "\n# --- set ---\n"
SNAP_F2=$(sed -n '/id: "F2"/,/id: "F3"/p' "$F")
run set v1 F1 applied
_tap_eq "$RC" "0" "set applied succeeds"
_tap_eq "$(val F1 status)" "applied" "...and records it"
_tap_eq "$(sed -n '/id: "F2"/,/id: "F3"/p' "$F")" "$SNAP_F2" "...leaving the other findings byte-identical"
run set v1 F4 dismissed
_tap_eq "$RC" "1" "dismissing a Blocking finding without --reason is refused"
run set v1 F4 dismissed --reason "   "
_tap_eq "$RC" "1" "...and with a reason of only spaces"
_tap_eq "$(val F4 status)" "open" "...and changes nothing"
run set v1 F2 dismissed
_tap_eq "$RC" "0" "dismissing an Advisory finding needs no reason"
run set v1 F3 deferred
_tap_eq "$(val F3 status)" "deferred" "set deferred records it"
run set v1 F9 applied
_tap_eq "$RC" "1" "set on an unknown id is refused"
run set v1 F1 finished
_tap_eq "$RC" "1" "set with an unknown status is refused"

printf "\n# --- check ---\n"
run check v1
_tap_eq "$RC" "1" "check fails while a Blocking finding is open"
_tap_contains "$OUT" "F4: open" "...naming it"
run set v1 F4 deferred
run check v1
_tap_eq "$RC" "1" "a deferred Blocking finding still blocks"
run set v1 F4 dismissed --reason "Scopes are set by the GitHub App manifest"
_tap_eq "$(val F4 reason)" "Scopes are set by the GitHub App manifest" "a dismissal stores its reason"
run check v1
_tap_eq "$RC" "0" "check passes once every Blocking finding is applied or dismissed with a reason"
_tap_contains "$OUT" "OK: 2 Blocking" "...and says so"
run set v1 F2 open
run check v1
_tap_eq "$RC" "0" "an open Advisory finding never blocks"
sed 's/^    reason: "Scopes are set by the GitHub App manifest"$/    reason: ""/' "$F" > "$F.x" && mv "$F.x" "$F"
run check v1
_tap_eq "$RC" "1" "a Blocking finding dismissed without a reason (hand edit) blocks"
_tap_contains "$OUT" "dismissed without a reason" "...naming why"
run set v1 F4 applied
_tap_eq "$(val F4 reason)" "" "a new decision replaces the old reason"
printf 'garbage line\n' >> "$F"
run check v1
_tap_eq "$RC" "1" "check on an unreadable file fails, never treated as passing"
run check v2
_tap_eq "$RC" "1" "check with no findings file fails"
mkdir -p "$WORK/docs/spec/review-findings"
sed 's/^spec_version: .*/spec_version: "v1"/' "$WORK/docs/spec/review-findings/v1.yaml" > "$WORK/docs/spec/review-findings/v3.yaml"
grep -v '^garbage line$' "$WORK/docs/spec/review-findings/v3.yaml" > "$WORK/docs/spec/review-findings/v3.x" && mv "$WORK/docs/spec/review-findings/v3.x" "$WORK/docs/spec/review-findings/v3.yaml"
run check v3
_tap_eq "$RC" "1" "a file copied from another version does not pass check for this one"
_tap_contains "$OUT" "is not 'v3'" "...naming the mismatch"

printf "\n# --- write --replace for a new review round ---\n"
runin "$ONE" write v1 --replace
_tap_eq "$RC" "0" "write --replace succeeds"
_tap_eq "$(val X1 status)" "open" "...and starts the new round open"

printf "\n# --- Prompt A uses the file ---\n"
PA="$REAL_REPO/docs/ai/prompts/prompt-a-repo-os.md"
_tap_contains "$(cat "$PA")" "review-findings.sh write" "Prompt A writes the findings with the tool"
_tap_contains "$(cat "$PA")" "review-findings.sh check" "...requires check before Phase 3"
_tap_contains "$(cat "$PA")" "findings: docs/spec/review-findings/" "...and names the file in the advisory-reviewed evidence"

printf "\n# === Summary ===\n"
printf "1..%d\n" "$_TAP_NUM"
printf "# Passed: %d / %d\n" "$_TAP_PASS" "$_TAP_NUM"
if [ "$_TAP_FAIL" -gt 0 ]; then printf "# Failures:\n%b" "$_TAP_FAILURES"; exit 1; fi
exit 0
