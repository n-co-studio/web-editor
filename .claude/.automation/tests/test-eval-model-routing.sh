#!/usr/bin/env bash
# Test suite: eval model routing — alias map refresh + per-entry model pin.
#
# Five verification checks per task brief:
#   1a-1c  Alias map returns Claude 5 ids (sonnet, haiku, opus).
#   2      Entry-level model field is loaded from YAML by _load_queue_entry.
#   3      Queue-entry round trip (write→load via queue_enqueue) preserves model.
#   4      eval_trigger_judge enqueues judge with the study's model, not dropped.
#   5      _parse_config_field regression — comment-placement repair (2026-10-20).
#
# Fail-first contract (per task brief §Verification):
#   Tests 1a–1c, 2, 3, 4 MUST fail against pre-fix code.
#   Test 5 is a regression guard: it should pass both before and after.
#   A test that passes before the change tests nothing.
#
# Note on test 1: _parse_config_field is stubbed to echo back the field name as
# the config value, so "sonnet" session type → config value "sonnet" → alias
# table. This directly exercises the alias case statement without needing a
# live config file in the sandbox.  The real config integration is tested by
# test 5, which uses the real _parse_config_field against the sandbox config.
#
# Bash 3.2 compatible. No external dependencies beyond the repo.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/sandbox-setup.sh"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"; }
_tap_eq() {
  if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi
}
finish() {
  printf "\n1..%d\n# Tests: %d  Pass: %d  Fail: %d\n" \
    $((_TAP_PASS+_TAP_FAIL)) $((_TAP_PASS+_TAP_FAIL)) "$_TAP_PASS" "$_TAP_FAIL"
  [ "$_TAP_FAIL" -gt 0 ] && printf "# Failures:\n%b" "$_TAP_FAILURES"
  return "$_TAP_FAIL"
}

printf "# === Eval Model Routing: alias map + per-entry model pin ===\n"

setup_adversarial_sandbox
trap 'teardown_adversarial_sandbox' EXIT

REPO_ROOT="$ADV_SANDBOX"
export REPO_ROOT
AUTOMATION_DIR="$ADV_SANDBOX/.claude/.automation"
export AUTOMATION_DIR

# ----------------------------------------------------------------
# Extract _resolve_model_for_session from runner.sh.
# runner.sh cannot be sourced (it runs a daemon loop at load), so we
# extract only the function under test — same technique as
# test-daemon-liveness.sh.
# ----------------------------------------------------------------
_REAL_RUNNER_SRC="$_ADV_REAL_REPO/.claude/.automation/runner.sh"
_RUNNER_SRC="${REPO_OS_TEST_RUNNER_SRC:-$_REAL_RUNNER_SRC}"
if [ "$_RUNNER_SRC" != "$_REAL_RUNNER_SRC" ]; then
  printf "# WARNING: REPO_OS_TEST_RUNNER_SRC override — behavioural cases\n"
  printf "#          run against %s\n" "$_RUNNER_SRC"
fi

_extract_runner_fn() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$_RUNNER_SRC"
}

_RUNNER_FNS="$ADV_SANDBOX/runner-model-fns.sh"
_extract_runner_fn "_resolve_model_for_session" > "$_RUNNER_FNS"

# Stub _parse_config_field so that _resolve_model_for_session("X") maps
# the alias name X through the case statement directly.  Concretely:
#   _parse_config_field "model_routing_overrides" "sonnet" → "sonnet"
#   _parse_config_field "model_routing_overrides" "haiku"  → "haiku"
#   _parse_config_field "model_routing_overrides" "opus"   → "opus"
# This makes the test self-contained (no live config file needed) and
# pinpoints the case statement as the code under test.
_parse_config_field() { printf '%s' "${2:-}"; }
# shellcheck disable=SC1090
source "$_RUNNER_FNS"

if type _resolve_model_for_session > /dev/null 2>&1; then
  _tap_pass "extracted _resolve_model_for_session from runner.sh"
else
  _tap_fail "extracted _resolve_model_for_session from runner.sh" \
    "function missing — did runner.sh change shape?"
fi

# ================================================================
# Tests 1a–1c: Alias map returns Claude 5 ids
# Currently fails: sonnet→claude-sonnet-4-6, haiku→claude-haiku-4-5-20251001,
#   opus→falls through to pass-through (returns "opus" not "claude-opus-5-5")
# After fix: each maps to the Claude 5 id.
# ================================================================
printf "# --- Tests 1a-1c: alias map ---\n"

_tap_eq "$(_resolve_model_for_session "sonnet")" "claude-sonnet-5-5" \
  "1a: sonnet alias resolves to claude-sonnet-5-5"

_tap_eq "$(_resolve_model_for_session "haiku")" "claude-haiku-5-5" \
  "1b: haiku alias resolves to claude-haiku-5-5"

_tap_eq "$(_resolve_model_for_session "opus")" "claude-opus-5-5" \
  "1c: opus alias resolves to claude-opus-5-5"

# ================================================================
# Tests 2 and 3: queue-manager model field load + round trip
# ================================================================
printf "# --- Tests 2-3: queue entry model field ---\n"

export CONFIG_FILE="$ADV_SANDBOX/.claude/.automation/config.yaml"
export CONFIG_LOCAL_FILE=""

(
  export REPO_ROOT="$ADV_SANDBOX"
  export AUTOMATION_DIR="$ADV_SANDBOX/.claude/.automation"
  export CONFIG_FILE="$ADV_SANDBOX/.claude/.automation/config.yaml"
  export CONFIG_LOCAL_FILE=""
  source "$ADV_SANDBOX/.claude/.automation/lib/file-lock.sh"
  source "$ADV_SANDBOX/.claude/.automation/lib/queue-manager.sh"

  # --- Test 2: _load_queue_entry reads model field from YAML ---
  # Manually write a minimal entry YAML that includes a model field.
  # The 'model:' line must appear where _load_queue_entry can parse it.
  _T2_FILE="$ADV_SANDBOX/.claude/.automation/queue/pending-review/test-model-load.yaml"
  {
    printf 'entry:\n'
    printf '  id: "test-model-load"\n'
    printf '  status: "pending-review"\n'
    printf '  priority: "0"\n'
    printf '  session_type: "eval-cell"\n'
    printf '  branch: ""\n'
    printf '  brief_path: ""\n'
    printf '  prompt: ""\n'
    printf '  last_prompt: ""\n'
    printf '  auto_mode: "false"\n'
    printf '  solo_mode: "false"\n'
    printf '  push_on_complete: "false"\n'
    printf '  retry_count: "0"\n'
    printf '  max_retries: "3"\n'
    printf '  error_log: ""\n'
    printf '  work_order_id: ""\n'
    printf '  project: ""\n'
    printf '  milestone:\n'
    printf '    name: ""\n'
    printf '    index: 0\n'
    printf '    total: 0\n'
    printf '  created_at: "2026-10-21T00:00:00Z"\n'
    printf '  updated_at: "2026-10-21T00:00:00Z"\n'
    printf '  completed_at: ""\n'
    printf '  permission_profile: "judge"\n'
    printf '  model: "my-pinned-model-XYZZY"\n'
  } > "$_T2_FILE"

  _load_queue_entry "$_T2_FILE"

  if [ "${_QE_MODEL:-}" = "my-pinned-model-XYZZY" ]; then
    printf "ok - 2: _load_queue_entry reads model field from YAML\n"
  else
    printf "not ok - 2: _load_queue_entry reads model field from YAML\n"
    printf "  # expected 'my-pinned-model-XYZZY', got '%s'\n" "${_QE_MODEL:-UNSET}"
  fi

  # --- Test 3: queue_enqueue + _load_queue_entry round-trip preserves model ---
  # Copy queue-cli.sh to sandbox to avoid deriving REPO_ROOT from a live path
  # (using it from the real repo path would operate on live queue state).
  # queue_enqueue is in queue-manager.sh which we already sourced above.
  _T3_BRIEF="$ADV_SANDBOX/.claude/.automation/briefs/test-brief-model.md"
  printf '# Test brief\n' > "$_T3_BRIEF"

  # queue_enqueue positional args (bash 3.2 brace form for > $9):
  #   $1  brief_path
  #   $2  session_type
  #   $3  auto_mode
  #   $4  solo_mode
  #   $5  branch
  #   $6  work_order_id
  #   $7  push_on_complete
  #   $8  priority
  #   $9  permission_profile
  #   ${10} project
  #   ${11} milestone_name
  #   ${12} milestone_index
  #   ${13} milestone_total
  #   ${14} model  ← new field under test
  _T3_ID=$(queue_enqueue \
    "$_T3_BRIEF" "eval-cell" "true" "false" "" "" "false" "5" "judge" \
    "" "" "0" "0" "claude-haiku-round-trip-test" 2>/dev/null) || _T3_ID=""

  if [ -z "$_T3_ID" ]; then
    printf "not ok - 3: queue entry round-trip preserves model\n"
    printf "  # queue_enqueue returned empty id\n"
  else
    case "$_T3_ID" in duplicate:*) _T3_ID="${_T3_ID#duplicate:}" ;; esac
    _T3_FILE="$ADV_SANDBOX/.claude/.automation/queue/pending-review/${_T3_ID}.yaml"
    if [ ! -f "$_T3_FILE" ]; then
      printf "not ok - 3: queue entry round-trip preserves model\n"
      printf "  # entry file not found: %s\n" "$_T3_FILE"
    else
      _load_queue_entry "$_T3_FILE"
      if [ "${_QE_MODEL:-}" = "claude-haiku-round-trip-test" ]; then
        printf "ok - 3: queue entry round-trip preserves model\n"
      else
        printf "not ok - 3: queue entry round-trip preserves model\n"
        printf "  # expected 'claude-haiku-round-trip-test', got '%s'\n" "${_QE_MODEL:-UNSET}"
      fi
    fi
  fi
) | while IFS= read -r _subline; do
  case "$_subline" in
    "ok - "*)    _tap_pass "${_subline#ok - }" ;;
    "not ok - "*) _tap_fail "${_subline#not ok - }" ;;
    "  # "*)      printf '%s\n' "$_subline" ;;
  esac
done

# ================================================================
# Test 4: eval_trigger_judge enqueues with study model, not dropped
# ================================================================
printf "# --- Test 4: conductor threads judge model to queue entry ---\n"

(
  export REPO_ROOT="$ADV_SANDBOX"
  export AUTOMATION_DIR="$ADV_SANDBOX/.claude/.automation"
  export CONFIG_FILE="$ADV_SANDBOX/.claude/.automation/config.yaml"
  export CONFIG_LOCAL_FILE=""

  source "$ADV_SANDBOX/.claude/.automation/lib/file-lock.sh"
  source "$ADV_SANDBOX/.claude/.automation/lib/queue-manager.sh"

  # Create minimal study directory
  _STUDY_ID="test-model-routing-check"
  _STUDY_ROOT="$ADV_SANDBOX/docs/ai/eval/$_STUDY_ID"
  _CELLS_DIR="$_STUDY_ROOT/cells"
  mkdir -p "$_CELLS_DIR"
  mkdir -p "$ADV_SANDBOX/.claude/.automation/reports/eval/$_STUDY_ID"

  # study.yaml with a 2-space-indent model field so _ec_yaml_field can read it.
  # _ec_yaml_field matches "${field}:"* or "  ${field}:"* — 2-space indent only.
  {
    printf 'study:\n'
    printf '  study_id: %s\n' "$_STUDY_ID"
    printf '  lineage_id: test-lineage\n'
    printf '  status: running\n'
    printf '  run_context: template\n'
    printf '  n_reps: 1\n'
    printf '  model: claude-test-sentinel-4321\n'
  } > "$_STUDY_ROOT/study.yaml"

  # Minimal completed cell for shuffle-manifest generation
  {
    printf 'cell:\n'
    printf '  cell_id: %s/B0/T1/r1\n' "$_STUDY_ID"
    printf '  status: collected\n'
    printf '  arm_id: B0\n'
    printf '  task_id: T1\n'
    printf '  rep: 1\n'
    printf '  submission_path: ""\n'
  } > "$_CELLS_DIR/B0-T1-r1.yaml"

  # Intercept queue_enqueue: capture arg ${14}.
  # Defined AFTER sourcing queue-manager.sh to override it.
  # Bash 3.2: positionals above 9 need brace form.
  _T4_CAPTURED_MODEL="__NOT_SET__"
  queue_enqueue() {
    _T4_CAPTURED_MODEL="${14:-__MISSING__}"
    printf 'mock-judge-entry-id'
  }

  source "$ADV_SANDBOX/.claude/.automation/lib/eval-conductor.sh"
  eval_trigger_judge "$_STUDY_ID" 2>/dev/null || true

  if [ "$_T4_CAPTURED_MODEL" = "claude-test-sentinel-4321" ]; then
    printf "ok - 4: conductor threads judge model to queue_enqueue arg 14\n"
  elif [ "$_T4_CAPTURED_MODEL" = "__NOT_SET__" ]; then
    printf "not ok - 4: conductor threads judge model to queue_enqueue arg 14\n"
    printf "  # queue_enqueue was not called\n"
  elif [ "$_T4_CAPTURED_MODEL" = "__MISSING__" ]; then
    printf "not ok - 4: conductor threads judge model to queue_enqueue arg 14\n"
    printf "  # arg 14 was empty — conductor dropped the model\n"
  else
    printf "not ok - 4: conductor threads judge model to queue_enqueue arg 14\n"
    printf "  # expected 'claude-test-sentinel-4321', got '%s'\n" "$_T4_CAPTURED_MODEL"
  fi
) | while IFS= read -r _subline; do
  case "$_subline" in
    "ok - "*)    _tap_pass "${_subline#ok - }" ;;
    "not ok - "*) _tap_fail "${_subline#not ok - }" ;;
    "  # "*)      printf '%s\n' "$_subline" ;;
  esac
done

# ================================================================
# Test 5: _parse_config_field regression — comment-placement repair
# (2026-10-20). Should PASS both before and after the alias-map fix.
# ================================================================
printf "# --- Test 5: _parse_config_field regression guard ---\n"

(
  export REPO_ROOT="$ADV_SANDBOX"
  export AUTOMATION_DIR="$ADV_SANDBOX/.claude/.automation"
  export CONFIG_FILE="$ADV_SANDBOX/.claude/.automation/config.yaml"
  export CONFIG_LOCAL_FILE=""

  source "$ADV_SANDBOX/.claude/.automation/lib/file-lock.sh"
  source "$ADV_SANDBOX/.claude/.automation/lib/queue-manager.sh"

  # eval-cell should return bare "sonnet" — no trailing comment text.
  _val=$(_parse_config_field "model_routing_overrides" "eval-cell")
  if [ "$_val" = "sonnet" ]; then
    printf "ok - 5a: model_routing_overrides.eval-cell parses as bare 'sonnet'\n"
  else
    printf "not ok - 5a: model_routing_overrides.eval-cell parses as bare 'sonnet'\n"
    printf "  # got '%s' — comment contamination regression\n" "$_val"
  fi

  # eval conductor override should also be bare "sonnet".
  _val=$(_parse_config_field "model_routing_overrides" "eval")
  if [ "$_val" = "sonnet" ]; then
    printf "ok - 5b: model_routing_overrides.eval parses as bare 'sonnet'\n"
  else
    printf "not ok - 5b: model_routing_overrides.eval parses as bare 'sonnet'\n"
    printf "  # got '%s' — comment contamination regression\n" "$_val"
  fi

  # model_routing.default should return bare "sonnet".
  _val=$(_parse_config_field "model_routing" "default")
  if [ "$_val" = "sonnet" ]; then
    printf "ok - 5c: model_routing.default parses as bare 'sonnet'\n"
  else
    printf "not ok - 5c: model_routing.default parses as bare 'sonnet'\n"
    printf "  # got '%s'\n" "$_val"
  fi
) | while IFS= read -r _subline; do
  case "$_subline" in
    "ok - "*)    _tap_pass "${_subline#ok - }" ;;
    "not ok - "*) _tap_fail "${_subline#not ok - }" ;;
    "  # "*)      printf '%s\n' "$_subline" ;;
  esac
done

finish
