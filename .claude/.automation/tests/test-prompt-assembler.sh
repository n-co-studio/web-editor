#!/usr/bin/env bash
# Prompt assembler — task group placeholder substitution
#
# Covers the {group_name} / {brief_seq} / {is_final} placeholders that
# assemble_prompt fills from the brief's `### Task Group` section.
#
# Why this suite exists: all three placeholders were silently corrupted for
# every canonical brief until 2026-10-13. `group_name` came out as the literal
# `**`, `brief_seq` came out empty, and because brief_seq was empty `is_final`
# evaluated "false" for EVERY brief — so the final brief of every headless task
# group was handed a prompt telling it NOT to merge or seal its group branch.
# Nothing caught it because nothing tested the assembler at all, and the
# neighbouring suites used a bare `Group: x` fixture format that no real brief
# emits. These tests run the real assemble_prompt against canonical fixtures.
#
# is_final is the dangerous direction: a wrong "true" merges and seals a branch
# mid-group, a wrong "false" only leaves it open for the next brief. The
# malformed-input cases below therefore assert "false", not an error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/sandbox-setup.sh"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"; }
_tap_eq() {
  if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi
}

setup_adversarial_sandbox
trap 'teardown_adversarial_sandbox' EXIT

REPO_ROOT="$ADV_SANDBOX"
export REPO_ROOT
AUTOMATION_DIR="$ADV_SANDBOX/.claude/.automation"
export AUTOMATION_DIR

# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/queue-manager.sh"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/prompt-assembler.sh"

# --- Minimal template carrying just the placeholders under test ---
# The real taskgroup-brief.md is ~150 lines of instructions; the substitution
# contract is the same, and a focused template makes an assertion failure
# readable instead of buried in prose.
TEMPLATE_DIR="$ADV_SANDBOX/.claude/.automation/templates"
mkdir -p "$TEMPLATE_DIR"
printf 'GROUP=[{group_name}] SEQ=[{brief_seq}] FINAL=[{is_final}]\n\n{brief_text}\n' \
  > "$TEMPLATE_DIR/taskgroup-brief.md"

BRIEF_DIR="$ADV_SANDBOX/.claude/.automation/briefs"
ENTRY_DIR="$ADV_SANDBOX/.claude/.automation/queue/running"
mkdir -p "$BRIEF_DIR" "$ENTRY_DIR"

# --- Fixture helpers ---
# _write_brief <name> <body-generator-output-on-stdin>
_entry_n=0
_assemble_for_brief() {
  # $1 — brief file (repo-relative path as a queue entry would carry it)
  _entry_n=$((_entry_n+1))
  local entry="$ENTRY_DIR/entry-asm-$_entry_n.yaml"
  # Matches the real on-disk shape: an `entry:` root, two-space indentation and
  # quoted scalars. A flat key: value file parses to empty fields and the
  # assembler then reports "No brief content available", which looks like a
  # placeholder bug rather than a malformed fixture.
  {
    printf 'entry:\n'
    printf '  id: "asm-%d"\n' "$_entry_n"
    printf '  status: "running"\n'
    printf '  priority: "0"\n'
    printf '  session_type: "taskgroup"\n'
    printf '  branch: "feature/test"\n'
    printf '  brief_path: "%s"\n' "$1"
    printf '  prompt: ""\n'
    printf '  last_prompt: ""\n'
    printf '  auto_mode: "true"\n'
    printf '  solo_mode: "true"\n'
    printf '  push_on_complete: "false"\n'
    printf '  retry_count: "0"\n'
    printf '  max_retries: "3"\n'
    printf '  error_log: ""\n'
    printf '  work_order_id: ""\n'
    printf '  created_at: "2026-10-13T00:00:00Z"\n'
    printf '  updated_at: "2026-10-13T00:00:00Z"\n'
  } > "$entry"
  assemble_prompt "$entry" 2>/dev/null | grep -m1 '^GROUP=' || true
}
_field() {
  # $1 — assembled header line, $2 — field name
  printf '%s' "$1" | sed -n "s/.*$2=\[\([^]]*\)\].*/\1/p"
}

# --- Canonical: brief 2 of 3 — mid-group, not final ---
cat > "$BRIEF_DIR/asm-mid.md" <<'EOF'
## Task Brief: middle brief

### Task Group
- **Group:** details-header
- **Brief:** 2 of 3
- **Execution:** sequential

## Scope
Some work.
EOF
_LINE=$(_assemble_for_brief ".claude/.automation/briefs/asm-mid.md")
_tap_eq "$(_field "$_LINE" GROUP)" "details-header" "canonical: group_name has no bold markers"
_tap_eq "$(_field "$_LINE" SEQ)"   "2"              "canonical: brief_seq is 2"
_tap_eq "$(_field "$_LINE" FINAL)" "false"          "canonical: brief 2 of 3 is not final"

# --- Canonical: brief 3 of 3 — the case that was broken for every group ---
cat > "$BRIEF_DIR/asm-last.md" <<'EOF'
## Task Brief: last brief

### Task Group
- **Group:** details-header
- **Brief:** 3 of 3
- **Execution:** sequential
EOF
_LINE=$(_assemble_for_brief ".claude/.automation/briefs/asm-last.md")
_tap_eq "$(_field "$_LINE" SEQ)"   "3"    "canonical: brief_seq is 3"
_tap_eq "$(_field "$_LINE" FINAL)" "true" "canonical: brief 3 of 3 IS final (the regression)"

# --- Canonical: 1 of 1 — a single-brief group is immediately final ---
cat > "$BRIEF_DIR/asm-solo.md" <<'EOF'
## Task Brief: only brief

### Task Group
- **Group:** solo-group
- **Brief:** 1 of 1
- **Execution:** sequential
EOF
_LINE=$(_assemble_for_brief ".claude/.automation/briefs/asm-solo.md")
_tap_eq "$(_field "$_LINE" SEQ)"   "1"    "1-of-1: brief_seq is 1"
_tap_eq "$(_field "$_LINE" FINAL)" "true" "1-of-1: a single-brief group is final"

# --- Double digits — 10 of 10 must not read as 1 ---
cat > "$BRIEF_DIR/asm-ten.md" <<'EOF'
## Task Brief: tenth brief

### Task Group
- **Group:** big-group
- **Brief:** 10 of 10
- **Execution:** sequential
EOF
_LINE=$(_assemble_for_brief ".claude/.automation/briefs/asm-ten.md")
_tap_eq "$(_field "$_LINE" SEQ)"   "10"   "two digits: brief_seq is 10, not 1"
_tap_eq "$(_field "$_LINE" FINAL)" "true" "two digits: 10 of 10 is final"

cat > "$BRIEF_DIR/asm-nine.md" <<'EOF'
## Task Brief: ninth brief

### Task Group
- **Group:** big-group
- **Brief:** 9 of 10
- **Execution:** sequential
EOF
_LINE=$(_assemble_for_brief ".claude/.automation/briefs/asm-nine.md")
_tap_eq "$(_field "$_LINE" FINAL)" "false" "two digits: 9 of 10 is not final"

# --- Legacy bare format still parses ---
cat > "$BRIEF_DIR/asm-legacy.md" <<'EOF'
## Task Brief: legacy brief

### Task Group
Group: legacy-group
Brief: 2 of 2
EOF
_LINE=$(_assemble_for_brief ".claude/.automation/briefs/asm-legacy.md")
_tap_eq "$(_field "$_LINE" GROUP)" "legacy-group" "legacy: bare Group: still parses"
_tap_eq "$(_field "$_LINE" FINAL)" "true"         "legacy: bare Brief: 2 of 2 is final"

# --- Body prose must not supply the total (the unscoped-fallback defect) ---
# A malformed Brief line with no "of N" previously fell back to scanning the
# whole brief for 'of [0-9]+', so prose could set is_final=true on a number
# that has nothing to do with the group's size.
cat > "$BRIEF_DIR/asm-prose.md" <<'EOF'
## Task Brief: malformed header

### Task Group
- **Group:** prose-group
- **Brief:** 3
- **Execution:** sequential

## Scope
Fix 3 of 3 failing assertions in the parser suite.
EOF
_LINE=$(_assemble_for_brief ".claude/.automation/briefs/asm-prose.md")
_tap_eq "$(_field "$_LINE" SEQ)"   "3"     "prose: brief_seq still reads from the Brief line"
_tap_eq "$(_field "$_LINE" FINAL)" "false" "prose: 'Fix 3 of 3' in the body must NOT make the brief final"

# --- A title containing 'of N' must not corrupt the total ---
cat > "$BRIEF_DIR/asm-title.md" <<'EOF'
## Task Brief: brief 1 of 7 flavours of caching

### Task Group
- **Group:** title-group
- **Brief:** 1 of 4
- **Execution:** sequential
EOF
_LINE=$(_assemble_for_brief ".claude/.automation/briefs/asm-title.md")
_tap_eq "$(_field "$_LINE" FINAL)" "false" "title: 'of 7' in the title does not set the total"

# --- No Task Group section at all — placeholders resolve, nothing is final ---
cat > "$BRIEF_DIR/asm-none.md" <<'EOF'
## Task Brief: plain brief

## Scope
No task group section here.
EOF
_LINE=$(_assemble_for_brief ".claude/.automation/briefs/asm-none.md")
_tap_eq "$(_field "$_LINE" GROUP)" ""      "no section: group_name is empty, not '**'"
_tap_eq "$(_field "$_LINE" FINAL)" "false" "no section: is_final is false"

printf "\n1..%d\n" "$_TAP_NUM"
printf "# Tests: %d  Pass: %d  Fail: %d\n" "$_TAP_NUM" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then
  printf "\n# Failures:\n%b" "$_TAP_FAILURES"
  exit 1
fi
exit 0
