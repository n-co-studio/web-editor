#!/usr/bin/env bash
# Evaluation study conductor — thin orchestration library over existing runner/queue primitives.
# Sourced by the orchestrating agent via Bash or by the conductor session runner.
# Agent calls these functions directly via Bash to fan out cells, collect results,
# run blind judging, and generate the final report.
#
# Decision t-0046 Amendment 1 — Evaluation Orchestration Layer.
#
# Key design constraints:
#   - COMPOSES existing libs (intake.sh, queue-manager.sh, work-order-manager.sh,
#     file-lock.sh, outcome-detector.sh). Does NOT duplicate runner.sh dequeue/launch logic.
#   - Bash-3 compatible (no associative arrays, no [[ ]] required).
#   - Each cell runs in its own worktree with a per-cell REPO_OS_SESSION_ID and
#     a per-process sidecar (.session-id.<PPID>) — no shared session state.
#   - Cells NEVER merge to main. Cell branches are pruned at study close.
#   - Mode-aware: template (target = this repo) vs project (target = child repo).
#   - Fail-fast on missing/uncommitted manifest, branch collision, or unknown study status.
#   - Idempotent: cells already in 'completed' state are skipped on re-run.
#
# Functions (agent-callable via Bash):
#   eval_load_study      <study_yaml>                 — validate + load study manifest
#   eval_launch_cells    <study_id> [--series arm/task] — expand arms×tasks×reps → queue entries
#   eval_await_cells     <study_id> [--timeout s]      — poll until all cells reach terminal state
#   eval_collect_artifacts <study_id>                  — populate cell records from completion reports
#   eval_extract_submission <cell_id>                  — mechanical blind code-only extraction
#   eval_trigger_judge   <study_id>                    — build shuffle-manifest + enqueue judge entries
#   eval_generate_report <study_id> [out_path]         — join records + fill report template
#
# Usage:
#   source .claude/.automation/lib/eval-conductor.sh
#   eval_load_study docs/ai/eval/20260701-my-study-v1/study.yaml
#   eval_launch_cells 20260701-my-study-v1
#   eval_await_cells  20260701-my-study-v1 --timeout 7200
#   eval_collect_artifacts 20260701-my-study-v1
#   eval_trigger_judge     20260701-my-study-v1
#   eval_generate_report   20260701-my-study-v1

# No file-scope set -euo pipefail: this file is sourced by the agent's shell,
# and a global set -e leaks into the caller, aborting on benign non-zero returns.
# Function-local safety is applied explicitly where needed.

# --- Self-locate ---
_EC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_EC_AUTOMATION_DIR="$(cd "$_EC_SCRIPT_DIR/.." && pwd)"
_EC_REPO_ROOT="$(cd "$_EC_AUTOMATION_DIR/../.." && pwd)"
_EC_LIB_DIR="$_EC_SCRIPT_DIR"

# --- Source required hooks (analytics + phase helper for get_repo_root, logging) ---
source "$_EC_REPO_ROOT/.claude/hooks/_analytics-helper.sh" 2>/dev/null || true

# --- Source required automation libs ---
AUTOMATION_DIR="$_EC_AUTOMATION_DIR"
REPO_ROOT="$_EC_REPO_ROOT"
CONFIG_FILE="$AUTOMATION_DIR/config.yaml"

source "$_EC_LIB_DIR/file-lock.sh" 2>/dev/null || true
source "$_EC_LIB_DIR/queue-manager.sh" 2>/dev/null || true
source "$_EC_LIB_DIR/work-order-manager.sh" 2>/dev/null || true
# Dependency libs above each have set -euo pipefail at file scope.
# Restore caller's error-handling options so sourcing this file is safe.
set +e +u 2>/dev/null || true
set +o pipefail 2>/dev/null || true

# ============================================================
# Internal helpers (continued)
# ============================================================

# --- Generate a per-cell brief for the runner ---
# The runner needs a brief file path when it picks up the queue entry.
# The brief describes what the eval-cell session should do.
# Arguments: $1=study_id $2=arm_id $3=task_id $4=rep $5=study_file $6=raw_root
# Output: brief path on stdout; returns 1 on write failure
_ec_generate_cell_brief() {
  local study_id="$1" arm_id="$2" task_id="$3" rep="$4"
  local study_file="$5" raw_root="$6"
  local brief_dir="$raw_root/cell-briefs"
  mkdir -p "$brief_dir" 2>/dev/null || true
  local brief_path="$brief_dir/${arm_id}-${task_id}-r${rep}.md"
  local cell_id
  cell_id="$(_ec_cell_id "$study_id" "$arm_id" "$task_id" "$rep")"
  local cell_branch
  cell_branch="$(_ec_cell_branch "$study_id" "$arm_id" "$task_id" "$rep")"
  {
    printf '# Eval Cell Brief — %s\n\n' "$cell_id"
    printf '## Cell Identity\n\n'
    printf '- cell_id: %s\n' "$cell_id"
    printf '- study_id: %s\n' "$study_id"
    printf '- arm_id: %s\n' "$arm_id"
    printf '- task_id: %s\n' "$task_id"
    printf '- rep: %s\n' "$rep"
    printf '- branch: %s\n\n' "$cell_branch"
    printf '## Session Type\n\n'
    printf 'session_type: eval-cell\n'
    printf 'auto_mode: true\n'
    printf 'solo_mode: false\n\n'
    printf '## Instructions\n\n'
    printf 'You are an eval-cell agent for study `%s`, arm `%s`, task `%s`, rep %s.\n\n' \
      "$study_id" "$arm_id" "$task_id" "$rep"
    printf 'Read `docs/ai/workflow-appendix/session-type-eval.md` (eval-cell section).\n'
    printf 'Read the study manifest: `docs/ai/eval/%s/study.yaml`\n\n' "$study_id"
    printf 'Phase sequence: init → build → commit → close\n\n'
    printf '**Critical constraints:**\n'
    printf '- DO NOT merge to main\n'
    printf '- DO NOT seal the branch\n'
    printf '- Write completion-report.yaml and diff.patch to the gitignored raw artifact dir\n\n'
    printf '## Study Manifest\n\n'
    printf 'Reference: `docs/ai/eval/%s/study.yaml`\n\n' "$study_id"
    printf 'The study manifest contains arm definitions, task descriptions, rubric reference,\n'
    printf 'and the gate profile for your arm (gate_profile field under arms[].%s).\n' "$arm_id"
  } > "$brief_path" 2>/dev/null || return 1
  printf '%s' "$brief_path"
}

# ============================================================
# Internal helpers
# ============================================================

# --- Resolve the committed records root for a study ---
# Template mode: docs/ai/eval/{study_id}/ in this repo.
# Project mode:  docs/ai/eval/{study_id}/ in the target repo (child or configured path).
# In both cases the CONDUCTOR's committed records are in the conductor's own repo.
_ec_committed_root() {
  local study_id="$1"
  echo "$REPO_ROOT/docs/ai/eval/$study_id"
}

# --- Resolve the gitignored raw artifact root ---
_ec_raw_root() {
  local study_id="$1"
  echo "$REPO_ROOT/.claude/.automation/reports/eval/$study_id"
}

# --- Read a scalar field from a YAML file (zero-fork Bash read) ---
# Arguments: $1=file  $2=field_name
# Output: field value on stdout (empty if not found)
_ec_yaml_field() {
  local file="$1" field="$2" value=""
  [ -f "$file" ] || return 0
  while IFS= read -r _ec_line || [ -n "$_ec_line" ]; do
    case "$_ec_line" in
      "${field}:"*|"  ${field}:"*)
        value="${_ec_line#*: }"
        value="${value#\"}"
        value="${value%\"}"
        break
        ;;
    esac
  done < "$file"
  printf '%s' "$value"
}

# --- Deterministic cell_id from coordinates ---
# cell_id = {study_id}/{arm_id}/{task_id}/r{rep}
_ec_cell_id() {
  local study_id="$1" arm_id="$2" task_id="$3" rep="$4"
  echo "${study_id}/${arm_id}/${task_id}/r${rep}"
}

# --- Path-safe cell filename (replaces / with -) ---
_ec_cell_filename() {
  local arm_id="$1" task_id="$2" rep="$3"
  echo "${arm_id}-${task_id}-r${rep}.yaml"
}

# --- Cell branch name ---
_ec_cell_branch() {
  local study_id="$1" arm_id="$2" task_id="$3" rep="$4"
  echo "eval/${study_id}/${arm_id}/${task_id}/r${rep}"
}

# --- Read study fields into _EC_STUDY_* variables ---
# Sets: _EC_STUDY_ID, _EC_STUDY_STATUS, _EC_STUDY_RUN_CONTEXT, _EC_STUDY_TARGET_REPO
# _EC_STUDY_N_REPS, _EC_STUDY_LINEAGE_ID
_EC_STUDY_ID="" _EC_STUDY_STATUS="" _EC_STUDY_RUN_CONTEXT=""
_EC_STUDY_TARGET_REPO="" _EC_STUDY_N_REPS=0 _EC_STUDY_LINEAGE_ID=""
_EC_STUDY_FILE=""

_ec_load_study_fields() {
  local file="$1"
  _EC_STUDY_ID="$(_ec_yaml_field "$file" "study_id")"
  _EC_STUDY_STATUS="$(_ec_yaml_field "$file" "status")"
  _EC_STUDY_RUN_CONTEXT="$(_ec_yaml_field "$file" "run_context")"
  _EC_STUDY_TARGET_REPO="$(_ec_yaml_field "$file" "target_repo")"
  _EC_STUDY_N_REPS="$(_ec_yaml_field "$file" "n_reps")"
  _EC_STUDY_LINEAGE_ID="$(_ec_yaml_field "$file" "lineage_id")"
  _EC_STUDY_FILE="$file"
}

# --- Read arms from study.yaml into _EC_ARMS (space-delimited arm_ids) ---
_EC_ARMS=""
_ec_read_arms() {
  local file="$1"
  local arms="" in_arms=false
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "  arms:"*|"arms:"*)
        in_arms=true; continue ;;
      "  tasks:"*|"tasks:"*|"  n_reps:"*|"n_reps:"*)
        in_arms=false ;;
    esac
    if [ "$in_arms" = true ]; then
      case "$_line" in
        *"    - id: "*|*"  - id: "*)
          local arm_id="${_line##*id: }"
          arm_id="${arm_id#\"}"
          arm_id="${arm_id%\"}"
          arm_id="${arm_id%$'\r'}"
          if [ -n "$arm_id" ]; then
            arms="${arms:+$arms }$arm_id"
          fi
          ;;
      esac
    fi
  done < "$file"
  _EC_ARMS="$arms"
}

# --- Read tasks from study.yaml into _EC_TASKS (space-delimited task_ids) ---
_EC_TASKS=""
_ec_read_tasks() {
  local file="$1"
  local tasks="" in_tasks=false
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "  tasks:"*|"tasks:"*)
        in_tasks=true; continue ;;
      "  n_reps:"*|"n_reps:"*|"  judge:"*|"judge:"*)
        in_tasks=false ;;
    esac
    if [ "$in_tasks" = true ]; then
      case "$_line" in
        *"    - id: "*|*"  - id: "*)
          local task_id="${_line##*id: }"
          task_id="${task_id#\"}"
          task_id="${task_id%\"}"
          task_id="${task_id%$'\r'}"
          if [ -n "$task_id" ]; then
            tasks="${tasks:+$tasks }$task_id"
          fi
          ;;
      esac
    fi
  done < "$file"
  _EC_TASKS="$tasks"
}

# ============================================================
# Public API
# ============================================================

# --- eval_load_study ---
# Validate + load the pre-registered study manifest. Refuses if:
#   - study.yaml does not exist
#   - status != 'registered' (not pre-registered, already running, or failed)
#   - study.yaml is not git-committed (pre-registration lock)
# On success, loads study fields into _EC_STUDY_* and _EC_ARMS/_EC_TASKS.
# Arguments: $1 = path to study.yaml
eval_load_study() {
  local study_file="${1:-}"
  if [ -z "$study_file" ]; then
    echo "ERROR [eval-conductor]: eval_load_study requires a path to study.yaml" >&2
    return 1
  fi

  # Resolve to absolute path
  case "$study_file" in
    /*) : ;;
    *) study_file="$(cd "$(dirname "$study_file")" && pwd)/$(basename "$study_file")" ;;
  esac

  if [ ! -f "$study_file" ]; then
    echo "ERROR [eval-conductor]: study.yaml not found: $study_file" >&2
    return 1
  fi

  _ec_load_study_fields "$study_file"

  if [ -z "$_EC_STUDY_ID" ]; then
    echo "ERROR [eval-conductor]: study_id not found in $study_file — check schema" >&2
    return 1
  fi

  # Status guard: only 'registered' studies can be launched
  case "$_EC_STUDY_STATUS" in
    registered) : ;;
    running|partial)
      echo "INFO [eval-conductor]: Study $_EC_STUDY_ID is already $_EC_STUDY_STATUS — use eval_launch_cells for partial re-run (already-completed cells will be skipped)" >&2
      ;;
    completed)
      echo "ERROR [eval-conductor]: Study $_EC_STUDY_ID is already completed. Read report at $(_ec_committed_root "$_EC_STUDY_ID")/report.md" >&2
      return 1
      ;;
    failed)
      echo "ERROR [eval-conductor]: Study $_EC_STUDY_ID status is 'failed' — check deviations.md before re-running" >&2
      return 1
      ;;
  esac

  # Pre-registration lock: study.yaml must be git-committed
  local rel_path="${study_file#$REPO_ROOT/}"
  if ! git -C "$REPO_ROOT" ls-files --error-unmatch "$rel_path" >/dev/null 2>&1; then
    echo "ERROR [eval-conductor]: study.yaml is not committed — pre-registration requires a git commit before cells run. Commit $rel_path first." >&2
    return 1
  fi

  # Load arms and tasks
  _ec_read_arms "$study_file"
  _ec_read_tasks "$study_file"

  if [ -z "$_EC_ARMS" ]; then
    echo "ERROR [eval-conductor]: No arms found in $_EC_STUDY_ID study.yaml" >&2
    return 1
  fi
  if [ -z "$_EC_TASKS" ]; then
    echo "ERROR [eval-conductor]: No tasks found in $_EC_STUDY_ID study.yaml" >&2
    return 1
  fi
  if [ -z "$_EC_STUDY_N_REPS" ] || [ "$_EC_STUDY_N_REPS" -lt 1 ]; then
    echo "ERROR [eval-conductor]: n_reps must be >= 1 in $_EC_STUDY_ID study.yaml" >&2
    return 1
  fi

  echo "INFO [eval-conductor]: Loaded study $_EC_STUDY_ID (status=$_EC_STUDY_STATUS, arms=$_EC_ARMS, tasks=$_EC_TASKS, n_reps=$_EC_STUDY_N_REPS)"
  return 0
}

# --- eval_launch_cells ---
# Expand arms × tasks × reps into per-cell queue entries (via queue-manager.sh).
# Writes cell stub records to docs/ai/eval/{study_id}/cells/{arm}-{task}-r{rep}.yaml.
# Idempotent: cells already 'completed' in the queue are skipped.
# Arguments:
#   $1 — study_id (must have been loaded via eval_load_study)
#   [--series arm_or_task] — optional: restrict launch to cells matching this arm OR task id
# Output: cell_ids launched (one per line)
eval_launch_cells() {
  local study_id="${1:-}"
  if [ -z "$study_id" ]; then
    echo "ERROR [eval-conductor]: eval_launch_cells requires study_id" >&2
    return 1
  fi
  shift

  local series_filter=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --series) series_filter="$2"; shift 2 ;;
      *) echo "ERROR [eval-conductor]: Unknown option: $1" >&2; return 1 ;;
    esac
  done

  # Verify study is loaded
  if [ "$_EC_STUDY_ID" != "$study_id" ]; then
    echo "ERROR [eval-conductor]: Study '$study_id' not loaded — call eval_load_study first" >&2
    return 1
  fi

  local committed_root
  committed_root="$(_ec_committed_root "$study_id")"
  local cells_dir="$committed_root/cells"
  local raw_root
  raw_root="$(_ec_raw_root "$study_id")"
  mkdir -p "$cells_dir" 2>/dev/null || true

  # Create shared work order for the cell batch (trackable/deferrable as a unit).
  # Each queue_enqueue call then attaches its entry to this work order via arg 6.
  local wo_id=""
  if type wo_create > /dev/null 2>&1; then
    wo_id="$(wo_create "group" "eval-cells: $study_id" 2>/dev/null)" || wo_id=""
    [ -n "$wo_id" ] && echo "INFO [eval-conductor]: Cell batch work order: $wo_id (study=$study_id)"
  fi

  local launched=0
  local skipped=0
  local enqueue_failures=0

  for arm_id in $_EC_ARMS; do
    for task_id in $_EC_TASKS; do
      # Apply series filter
      if [ -n "$series_filter" ]; then
        case "$series_filter" in
          "$arm_id"|"$task_id") : ;;
          *) continue ;;
        esac
      fi

      local rep=1
      while [ "$rep" -le "$_EC_STUDY_N_REPS" ]; do
        local cell_id
        cell_id="$(_ec_cell_id "$study_id" "$arm_id" "$task_id" "$rep")"
        local cell_file="$cells_dir/$(_ec_cell_filename "$arm_id" "$task_id" "$rep")"
        local cell_branch
        cell_branch="$(_ec_cell_branch "$study_id" "$arm_id" "$task_id" "$rep")"

        # Idempotent: skip completed cells
        if [ -f "$cell_file" ]; then
          local existing_status
          existing_status="$(_ec_yaml_field "$cell_file" "status")"
          if [ "$existing_status" = "completed" ]; then
            echo "SKIP [eval-conductor]: cell $cell_id already completed"
            skipped=$((skipped + 1))
            rep=$((rep + 1))
            continue
          fi
        fi

        # Enqueue runner entry for this cell via the same path as the working judge path.
        # queue_enqueue args: brief_path, session_type, auto_mode, solo_mode, branch,
        #   work_order_id, push_on_complete, priority, permission_profile (arg 9).
        #   args 10-14 (project/milestone/model) default to empty — no per-entry model
        #   pin for cell entries; model routing falls through to _resolve_model_for_session.
        # solo=false: cells NEVER merge to main (Decision t-0046).
        local cell_entry_id=""
        local cell_status="failed"
        local enqueue_reason="queue_enqueue not available (queue-manager.sh not sourced)"

        if type queue_enqueue > /dev/null 2>&1; then
          local cell_brief
          cell_brief="$(_ec_generate_cell_brief \
            "$study_id" "$arm_id" "$task_id" "$rep" \
            "$committed_root/study.yaml" "$raw_root")" || cell_brief=""
          if [ -n "$cell_brief" ]; then
            cell_entry_id="$(queue_enqueue \
              "$cell_brief" \
              "eval-cell" \
              "true" \
              "false" \
              "$cell_branch" \
              "${wo_id:-}" \
              "false" \
              "0" \
              "build" 2>/dev/null)" || cell_entry_id=""
          else
            enqueue_reason="cell brief generation failed"
          fi
          if [ -n "$cell_entry_id" ]; then
            cell_status="queued"
            enqueue_reason=""
            echo "QUEUED [eval-conductor]: cell $cell_id → entry $cell_entry_id (branch=$cell_branch)"
          else
            [ -z "$enqueue_reason" ] && enqueue_reason="queue_enqueue returned empty — check queue-manager.sh"
            echo "WARN [eval-conductor]: Failed to enqueue cell $cell_id — status=failed; continuing batch" >&2
            enqueue_failures=$((enqueue_failures + 1))
          fi
        else
          echo "WARN [eval-conductor]: queue_enqueue unavailable for cell $cell_id — status=failed" >&2
          enqueue_failures=$((enqueue_failures + 1))
        fi

        # Write cell stub record (metrics + pointers only, no raw content).
        # Includes queue_entry_id and collect_failure_reason fields for correlation.
        local ts
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'cell:\n  cell_id: "%s"\n  study_id: "%s"\n  arm_id: "%s"\n  task_id: "%s"\n  rep: %s\n  branch: "%s"\n  status: %s\n  queued_at: "%s"\n  queue_entry_id: "%s"\n  wall_time_s: 0\n  token_counts: {}\n  gate_outputs: {}\n  target_commit_sha: ""\n  raw_artifact_dir: "%s/%s"\n  score: ""\n  judge_status: ""\n  collect_failure_reason: ""\n' \
          "$cell_id" "$study_id" "$arm_id" "$task_id" "$rep" \
          "$cell_branch" "$cell_status" "$ts" "${cell_entry_id:-}" \
          "$raw_root" "$cell_id" \
          > "$cell_file" 2>/dev/null || true

        # On enqueue failure, record the reason in the stub
        if [ -n "$enqueue_reason" ]; then
          local _tmp_stub="$cell_file.tmp.$$"
          while IFS= read -r _ec_cs || [ -n "$_ec_cs" ]; do
            case "$_ec_cs" in
              "  collect_failure_reason: \"\"")
                printf '  collect_failure_reason: "%s"\n' "$enqueue_reason" ;;
              *)
                printf '%s\n' "$_ec_cs" ;;
            esac
          done < "$cell_file" > "$_tmp_stub" && mv "$_tmp_stub" "$cell_file" 2>/dev/null || \
            rm -f "$_tmp_stub" 2>/dev/null || true
        fi

        launched=$((launched + 1))
        rep=$((rep + 1))
      done
    done
  done

  echo "INFO [eval-conductor]: Launched $launched cell(s), skipped $skipped completed, $enqueue_failures enqueue failure(s)"

  # Update study status to 'running' and record the cell batch work order id
  local study_file="$committed_root/study.yaml"
  if [ -f "$study_file" ]; then
    local _ts
    _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local _tmp_file="$study_file.tmp.$$"
    while IFS= read -r _ec_sl || [ -n "$_ec_sl" ]; do
      case "$_ec_sl" in
        "  status: registered"|"  status: partial"|"status: registered"|"status: partial")
          printf '  status: running\n' ;;
        *)
          printf '%s\n' "$_ec_sl" ;;
      esac
    done < "$study_file" > "$_tmp_file" && mv "$_tmp_file" "$study_file" 2>/dev/null || \
      rm -f "$_tmp_file" 2>/dev/null || true
  fi

  # Write cell-batch.yaml to committed dir for work order reconciliation
  if [ -n "$wo_id" ]; then
    local _ts
    _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'cell_batch:\n  work_order_id: "%s"\n  study_id: "%s"\n  launched: %s\n  created_at: "%s"\n' \
      "$wo_id" "$study_id" "$launched" "$_ts" \
      > "$committed_root/cell-batch.yaml" 2>/dev/null || true
  fi

  return 0
}

# --- eval_await_cells ---
# Poll queue until all cells for the study reach a terminal state (completed/failed/review/blocked).
# Emits progress every 30s. Distinguishes partial (some reps failed) from blocking (all reps of
# an arm failed). Returns 0 when all cells are terminal; 1 on timeout.
# Arguments:
#   $1 — study_id
#   [--timeout s] — max wait in seconds (default: 7200 = 2h)
eval_await_cells() {
  local study_id="${1:-}"
  if [ -z "$study_id" ]; then
    echo "ERROR [eval-conductor]: eval_await_cells requires study_id" >&2
    return 1
  fi
  shift

  local timeout=7200
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout) timeout="$2"; shift 2 ;;
      *) echo "ERROR [eval-conductor]: Unknown option: $1" >&2; return 1 ;;
    esac
  done

  local cells_dir
  cells_dir="$(_ec_committed_root "$study_id")/cells"
  local start_epoch
  start_epoch="$(date +%s)"
  local poll_interval=30

  echo "INFO [eval-conductor]: Waiting for cells in $study_id (timeout=${timeout}s)"

  while true; do
    local now_epoch
    now_epoch="$(date +%s)"
    local elapsed=$((now_epoch - start_epoch))
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "TIMEOUT [eval-conductor]: Timed out after ${elapsed}s waiting for cells in $study_id" >&2
      return 1
    fi

    # Count cell records by status
    local total=0 terminal=0 failed_count=0 completed_count=0
    if [ -d "$cells_dir" ]; then
      local cell_file
      for cell_file in "$cells_dir"/*.yaml; do
        [ -f "$cell_file" ] || continue
        total=$((total + 1))
        local cstatus
        cstatus="$(_ec_yaml_field "$cell_file" "status")"
        case "$cstatus" in
          completed)
            terminal=$((terminal + 1))
            completed_count=$((completed_count + 1))
            ;;
          failed|review|blocked)
            terminal=$((terminal + 1))
            failed_count=$((failed_count + 1))
            ;;
        esac
      done
    fi

    echo "PROGRESS [eval-conductor]: $study_id — ${terminal}/${total} cells terminal (${completed_count} completed, ${failed_count} failed)"

    if [ "$total" -gt 0 ] && [ "$terminal" -eq "$total" ]; then
      if [ "$failed_count" -gt 0 ]; then
        echo "PARTIAL [eval-conductor]: Study $study_id — ${failed_count} cell(s) failed. Study marked partial. Check deviations.md."
        _ec_update_study_status "$study_id" "partial"
      else
        echo "INFO [eval-conductor]: All $total cells completed for study $study_id"
      fi
      return 0
    fi

    sleep "$poll_interval"
  done
}

# --- _ec_update_study_status ---
# Internal: update status field in study.yaml (in-place rewrite, no sed fork).
_ec_update_study_status() {
  local study_id="$1" new_status="$2"
  local study_file="$(_ec_committed_root "$study_id")/study.yaml"
  [ -f "$study_file" ] || return 0
  local tmp="$study_file.tmp.$$"
  while IFS= read -r _ecl || [ -n "$_ecl" ]; do
    case "$_ecl" in
      "  status: "*|"status: "*)
        printf '  status: %s\n' "$new_status" ;;
      *)
        printf '%s\n' "$_ecl" ;;
    esac
  done < "$study_file" > "$tmp" && mv "$tmp" "$study_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

# --- eval_collect_artifacts ---
# Read each cell's completion report and raw artifact dir; populate cells/*.yaml with
# wall_time, tokens, gate_outputs, target_commit_sha, and raw_artifact_dir pointer.
# Cell records carry metrics + pointers ONLY — no inline raw content.
# Arguments: $1 — study_id
eval_collect_artifacts() {
  local study_id="${1:-}"
  if [ -z "$study_id" ]; then
    echo "ERROR [eval-conductor]: eval_collect_artifacts requires study_id" >&2
    return 1
  fi

  local cells_dir
  cells_dir="$(_ec_committed_root "$study_id")/cells"
  local raw_root
  raw_root="$(_ec_raw_root "$study_id")"

  local updated=0

  if [ -d "$cells_dir" ]; then
    local cell_file
    for cell_file in "$cells_dir"/*.yaml; do
      [ -f "$cell_file" ] || continue
      local cell_id
      cell_id="$(_ec_yaml_field "$cell_file" "cell_id")"
      [ -n "$cell_id" ] || continue

      # Locate raw artifact directory for this cell
      local raw_cell_dir="$raw_root/$cell_id"

      # Read timing.json if available
      local wall_time=""
      if [ -f "$raw_cell_dir/timing.json" ]; then
        wall_time="$(grep '"wall_time_s"' "$raw_cell_dir/timing.json" 2>/dev/null | head -1 | tr -d '[:space:]",' | sed 's/wall_time_s://')" || true
      fi

      # Read tokens.json if available
      local tokens_summary=""
      if [ -f "$raw_cell_dir/tokens.json" ]; then
        tokens_summary="$(cat "$raw_cell_dir/tokens.json" 2>/dev/null | head -3 | tr '\n' ' ')" || true
      fi

      # Read target_commit_sha from completion report if available
      local target_sha=""
      if [ -f "$raw_cell_dir/completion-report.yaml" ]; then
        target_sha="$(_ec_yaml_field "$raw_cell_dir/completion-report.yaml" "target_commit_sha")"
      fi

      # Determine if artifacts exist before updating status.
      # Only mark 'completed' when completion-report.yaml or diff.patch is present.
      # Missing artifacts → 'failed' with a recorded reason (breadcrumb for Deviation Log).
      local _artifacts_exist=false
      local _missing_reason=""
      if [ -f "$raw_cell_dir/completion-report.yaml" ] || [ -f "$raw_cell_dir/diff.patch" ]; then
        _artifacts_exist=true
      else
        _missing_reason="no completion-report.yaml or diff.patch in $raw_cell_dir"
      fi

      # Update cell record in-place (no awk/sed required)
      local tmp="$cell_file.tmp.$$"
      {
        while IFS= read -r _ecl || [ -n "$_ecl" ]; do
          case "$_ecl" in
            "  wall_time_s:"*)
              [ -n "$wall_time" ] && printf '  wall_time_s: %s\n' "$wall_time" || printf '%s\n' "$_ecl" ;;
            "  target_commit_sha: \"\"")
              [ -n "$target_sha" ] && printf '  target_commit_sha: "%s"\n' "$target_sha" || printf '%s\n' "$_ecl" ;;
            "  status: queued"|"  status: running")
              if [ "$_artifacts_exist" = true ]; then
                printf '  status: completed\n'
              else
                printf '  status: failed\n'
              fi
              ;;
            "  collect_failure_reason:"*)
              if [ -n "$_missing_reason" ]; then
                printf '  collect_failure_reason: "%s"\n' "$_missing_reason"
              else
                printf '%s\n' "$_ecl"  # Preserve enqueue-phase reason if present
              fi
              ;;
            *)
              printf '%s\n' "$_ecl" ;;
          esac
        done < "$cell_file"
      } > "$tmp" && mv "$tmp" "$cell_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true

      if [ "$_artifacts_exist" = true ]; then
        echo "COLLECT [eval-conductor]: cell $cell_id — completed (wall_time=${wall_time:-unknown}, sha=${target_sha:-unknown})"
      else
        echo "COLLECT [eval-conductor]: cell $cell_id — MISSING artifacts → status=failed (${_missing_reason})" >&2
      fi
      updated=$((updated + 1))
    done
  fi

  echo "INFO [eval-conductor]: Collected artifacts for $updated cell(s) in study $study_id"
  return 0
}

# --- eval_extract_submission ---
# Mechanical BLIND EXTRACTION: produce a code-only submission for a cell with
# arm identity stripped. Writes to the gitignored raw dir: submission/
#
# Strips:
#   - Branch names from git log / commit trailers
#   - Session logs (docs/ai/logs/)
#   - Commit trailers (Session:, Decisions:, Gates-A:, Gates-B:, Automation:)
#   - Governance-ceremony files (.claude/, docs/ai/, AI.md, CLAUDE.md)
#
# Arguments: $1 — cell_id (e.g. 20260701-study-v1/GV/T4/r1)
eval_extract_submission() {
  local cell_id="${1:-}"
  if [ -z "$cell_id" ]; then
    echo "ERROR [eval-conductor]: eval_extract_submission requires cell_id" >&2
    return 1
  fi

  # Derive study_id as the first path segment
  local study_id="${cell_id%%/*}"
  local raw_cell_dir
  raw_cell_dir="$(_ec_raw_root "$study_id")/$cell_id"
  local submission_dir="$raw_cell_dir/submission"

  mkdir -p "$submission_dir" 2>/dev/null || true

  # Source: the cell's diff.patch (produced by the cell session at close)
  local diff_file="$raw_cell_dir/diff.patch"
  if [ ! -f "$diff_file" ]; then
    echo "WARN [eval-conductor]: diff.patch not found for cell $cell_id at $diff_file — creating empty submission"
    printf '# Empty submission: no diff.patch found\n' > "$submission_dir/submission.patch" 2>/dev/null || true
    return 0
  fi

  # Strip governance-ceremony files and arm-identity lines from the diff
  # Governance paths to exclude (these files reveal arm identity or are ceremony):
  local gov_patterns="^(diff --git a/(\.claude|docs/ai|AI\.md|CLAUDE\.md|repo-os-explainer\.html))"

  local tmp_diff="$submission_dir/submission.patch.tmp.$$"
  {
    local in_gov_file=false
    while IFS= read -r _diff_line || [ -n "$_diff_line" ]; do
      # Detect start of a governance file diff
      case "$_diff_line" in
        "diff --git a/.claude"*|"diff --git a/docs/ai/"*|\
        "diff --git a/AI.md"*|"diff --git a/CLAUDE.md"*|\
        "diff --git a/repo-os-explainer.html"*)
          in_gov_file=true; continue ;;
        "diff --git "*) in_gov_file=false ;;
      esac
      [ "$in_gov_file" = true ] && continue

      # Strip commit trailers that reveal arm identity
      case "$_diff_line" in
        *"Session: "*)     continue ;;
        *"Decisions: "*)   continue ;;
        *"Gates-A: "*)     continue ;;
        *"Gates-B: "*)     continue ;;
        *"Automation: "*)  continue ;;
        *"Co-Authored-By: "*)  continue ;;
      esac

      printf '%s\n' "$_diff_line"
    done < "$diff_file"
  } > "$tmp_diff" && mv "$tmp_diff" "$submission_dir/submission.patch" 2>/dev/null || rm -f "$tmp_diff" 2>/dev/null || true

  echo "EXTRACT [eval-conductor]: cell $cell_id — blind submission written to $submission_dir/submission.patch"
  return 0
}

# --- eval_trigger_judge ---
# Build the seeded shuffle-manifest and enqueue one judge entry per series under the
# 'judge' permission profile. The judge writes raw scores to the raw dir.
# Pre-requisite: all cells must be collected (eval_collect_artifacts done).
# Arguments: $1 — study_id
eval_trigger_judge() {
  local study_id="${1:-}"
  if [ -z "$study_id" ]; then
    echo "ERROR [eval-conductor]: eval_trigger_judge requires study_id" >&2
    return 1
  fi

  local committed_root
  committed_root="$(_ec_committed_root "$study_id")"
  local cells_dir="$committed_root/cells"
  local raw_root
  raw_root="$(_ec_raw_root "$study_id")"
  local shuffle_manifest="$committed_root/shuffle-manifest.json"

  # Generate seeded shuffle-manifest (seed = deterministic hash of study_id)
  # Uses portable_hash from _analytics-helper.sh (already sourced)
  local seed
  seed="$(printf '%s' "$study_id" | portable_hash 2>/dev/null | head -c 16 || printf '%s' "$study_id" | cksum | awk '{print $1}')"

  # Build cell list from cells/*.yaml
  local cell_list=""
  local label_counter=1
  if [ -d "$cells_dir" ]; then
    local cell_file
    for cell_file in "$cells_dir"/*.yaml; do
      [ -f "$cell_file" ] || continue
      local cell_id
      cell_id="$(_ec_yaml_field "$cell_file" "cell_id")"
      [ -n "$cell_id" ] || continue
      local anon_label
      anon_label="$(printf 'S%03d' "$label_counter")"
      local submission_path="$raw_root/$cell_id/submission/submission.patch"
      if [ -n "$cell_list" ]; then
        cell_list="${cell_list},"
      fi
      cell_list="${cell_list}
  {\"cell_id\":\"$cell_id\",\"anon_label\":\"$anon_label\",\"submission\":\"$submission_path\"}"
      label_counter=$((label_counter + 1))
    done
  fi

  # Write shuffle-manifest.json (committed — blinding evidence)
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    printf '{\n'
    printf '  "study_id": "%s",\n' "$study_id"
    printf '  "seed": "%s",\n' "$seed"
    printf '  "generated_at": "%s",\n' "$ts"
    printf '  "cells": [%s\n  ]\n' "$cell_list"
    printf '}\n'
  } > "$shuffle_manifest" 2>/dev/null || true

  echo "INFO [eval-conductor]: Shuffle-manifest written to $shuffle_manifest (seed=$seed)"

  # Enqueue judge entries via queue-manager.sh (one per task series)
  # Judge runs under the 'judge' permission profile (read-only, no commits, no AskUserQuestion)
  # Each judge entry: reads shuffle_manifest + rubric + submissions, writes raw scores to raw_dir
  local study_file="$committed_root/study.yaml"
  local rubric_ref
  rubric_ref="$(_ec_yaml_field "$study_file" "rubric_ref")"
  local judge_model
  judge_model="$(_ec_yaml_field "$study_file" "model")"
  # Default: haiku for rubric scoring (operator decision, Decision t-0046 Amendment 3).
  judge_model="${judge_model:-claude-haiku-5-5}"
  # Resolve alias to raw id — an alias in the study record would let a later
  # alias-map change silently rewrite history (Amendment 3).
  case "$judge_model" in
    sonnet) judge_model="claude-sonnet-5-5" ;;
    haiku)  judge_model="claude-haiku-5-5" ;;
    opus)   judge_model="claude-opus-5-5" ;;
  esac
  # Pin the resolved raw id back into study.yaml if the field is absent or
  # held an alias (i.e. not already a raw "claude-*" id).
  # Use awk to rewrite: update existing "  model:" line or append if absent.
  case "$(_ec_yaml_field "$study_file" "model")" in
    claude-*) ;;  # already pinned — leave as-is
    *)
      local _pin_tmp="${study_file}.tmp"
      awk -v m="$judge_model" '
        BEGIN { done=0 }
        /^model:/ || /^  model:/ { print "  model: " m; done=1; next }
        { print }
        END { if (!done) print "  model: " m }
      ' "$study_file" > "$_pin_tmp" && mv "$_pin_tmp" "$study_file" 2>/dev/null || true
      echo "INFO [eval-conductor]: Pinned resolved judge model to study.yaml: $judge_model"
      ;;
  esac

  local judge_brief_dir="$raw_root/judge-briefs"
  mkdir -p "$judge_brief_dir" 2>/dev/null || true

  local judge_brief="$judge_brief_dir/judge-${study_id}.md"
  {
    printf '# Judge Brief — %s\n\n' "$study_id"
    printf '## Role\n'
    printf 'You are a blind evaluator. Your task: read the submitted code diffs and score them\n'
    printf 'against the embedded rubric. You do NOT know which arm produced each submission.\n\n'
    printf '## Inputs\n'
    printf '- Shuffle manifest: %s\n' "$shuffle_manifest"
    printf '- Rubric: %s\n' "${rubric_ref:-embedded in study brief}"
    printf '- Submissions: see shuffle_manifest.cells[*].submission\n\n'
    printf '## Output\n'
    printf 'For each submission, write raw scores to:\n'
    printf '  %s/{cell_id}/judge-scores.json\n' "$raw_root"
    printf 'Format: {"cell_id":"...", "anon_label":"...", "score": 0.0-1.0, "rationale":"..."}\n\n'
    printf '## Rules\n'
    printf '- Score ONLY what the rubric specifies. Do not invent criteria.\n'
    printf '- Do not attempt to identify arm identity from the diff content.\n'
    printf '- If a submission is empty or missing, score 0.0 and note "missing submission".\n'
    printf '- Do not commit, edit, or push anything. Read-only evaluation only.\n'
    printf '- Do not ask for clarification (headless mode).\n'
  } > "$judge_brief" 2>/dev/null || true

  echo "INFO [eval-conductor]: Judge brief written to $judge_brief"

  # Enqueue judge entry with the 'judge' permission profile (read-only: no Edit/Write/commit/push).
  # queue_enqueue arg  9 = permission_profile (Decision t-0046 Amendment 1).
  # queue_enqueue arg 14 = model pin (Decision t-0046 Amendment 3).
  # auto_mode=true so the runner picks it up without manual approval.
  if type queue_enqueue > /dev/null 2>&1; then
    local judge_entry_id
    judge_entry_id="$(queue_enqueue \
      "$judge_brief" \
      "eval-cell" \
      "true" \
      "false" \
      "" \
      "" \
      "false" \
      "10" \
      "judge" \
      "" \
      "" \
      "0" \
      "0" \
      "$judge_model" 2>/dev/null)"
    if [ -n "$judge_entry_id" ]; then
      echo "INFO [eval-conductor]: Judge entry enqueued: $judge_entry_id (permission_profile=judge, model=$judge_model)"
    else
      echo "WARNING [eval-conductor]: queue_enqueue failed — judge must be dispatched manually"
      echo "INFO [eval-conductor]: Manual invocation: queue-cli.sh add --brief $judge_brief --session-type eval-cell --auto-approve"
    fi
  else
    echo "INFO [eval-conductor]: queue_enqueue not available — judge must be dispatched via queue-cli.sh"
    echo "INFO [eval-conductor]: queue-cli.sh add --brief $judge_brief --session-type eval-cell --auto-approve"
    echo "INFO [eval-conductor]: Then set permission_profile: judge in the queue entry YAML before approving"
  fi

  return 0
}

# --- eval_generate_report ---
# Join study.yaml + cells/*.yaml + suite TAP + judge outputs, fill the _eval-report.md
# template, compute decision-rule verdict, write committed report.md + cell-index.yaml.
# Arguments:
#   $1 — study_id
#   [$2] — output path for report.md (default: docs/ai/eval/{study_id}/report.md)
eval_generate_report() {
  local study_id="${1:-}"
  if [ -z "$study_id" ]; then
    echo "ERROR [eval-conductor]: eval_generate_report requires study_id" >&2
    return 1
  fi

  local committed_root
  committed_root="$(_ec_committed_root "$study_id")"
  local out_path="${2:-$committed_root/report.md}"
  local cells_dir="$committed_root/cells"
  local study_file="$committed_root/study.yaml"
  local shuffle_manifest="$committed_root/shuffle-manifest.json"
  local raw_root
  raw_root="$(_ec_raw_root "$study_id")"

  if [ ! -f "$study_file" ]; then
    echo "ERROR [eval-conductor]: study.yaml not found at $study_file" >&2
    return 1
  fi

  # Load study fields
  _ec_load_study_fields "$study_file"

  # Collect cell index (denormalized projection for report generation)
  local cell_index_file="$committed_root/cell-index.yaml"
  local cell_index_content=""
  local total_cells=0 completed_cells=0 failed_cells=0
  local score_sum=0 score_count=0

  if [ -d "$cells_dir" ]; then
    cell_index_content="cells:"
    local cell_file
    for cell_file in "$cells_dir"/*.yaml; do
      [ -f "$cell_file" ] || continue
      local cell_id status arm_id task_id rep score judge_status
      cell_id="$(_ec_yaml_field "$cell_file" "cell_id")"
      status="$(_ec_yaml_field "$cell_file" "status")"
      arm_id="$(_ec_yaml_field "$cell_file" "arm_id")"
      task_id="$(_ec_yaml_field "$cell_file" "task_id")"
      rep="$(_ec_yaml_field "$cell_file" "rep")"
      score="$(_ec_yaml_field "$cell_file" "score")"
      judge_status="$(_ec_yaml_field "$cell_file" "judge_status")"

      total_cells=$((total_cells + 1))
      case "$status" in
        completed) completed_cells=$((completed_cells + 1)) ;;
        failed|review|blocked) failed_cells=$((failed_cells + 1)) ;;
      esac

      # Also read judge scores from raw dir if not in cell record
      local raw_scores="$raw_root/$cell_id/judge-scores.json"
      if [ -z "$score" ] && [ -f "$raw_scores" ]; then
        score="$(grep '"score"' "$raw_scores" 2>/dev/null | head -1 | tr -d '[:space:]' | sed 's/.*"score"://' | tr -d ',"}')" || true
      fi

      # Accumulate scores for decision rule
      if [ -n "$score" ] && echo "$score" | grep -qE '^[0-9]+\.?[0-9]*$'; then
        score_sum="$(awk "BEGIN{printf \"%.4f\", $score_sum + $score}")"
        score_count=$((score_count + 1))
      fi

      cell_index_content="$cell_index_content
  - cell_id: \"$cell_id\"
    arm_id: \"$arm_id\"
    task_id: \"$task_id\"
    rep: $rep
    status: \"$status\"
    score: \"${score:-n/a}\"
    judge_status: \"${judge_status:-pending}\""
    done
  fi

  # Write cell-index.yaml
  printf '%s\n' "$cell_index_content" > "$cell_index_file" 2>/dev/null || true

  # Compute decision-rule verdict
  local metric
  metric="$(_ec_yaml_field "$study_file" "metric")"
  local threshold
  threshold="$(_ec_yaml_field "$study_file" "threshold")"
  local direction
  direction="$(_ec_yaml_field "$study_file" "direction")"

  local mean_score="n/a"
  local verdict="INCONCLUSIVE"
  if [ "$score_count" -gt 0 ] && [ "$failed_cells" -eq 0 ] && [ -n "$threshold" ]; then
    mean_score="$(awk "BEGIN{printf \"%.4f\", $score_sum / $score_count}")"
    if [ "$direction" = "above" ]; then
      if awk "BEGIN{exit !($mean_score >= $threshold)}"; then
        verdict="above_threshold"
      else
        verdict="below_threshold"
      fi
    elif [ "$direction" = "below" ]; then
      if awk "BEGIN{exit !($mean_score <= $threshold)}"; then
        verdict="above_threshold"  # direction=below → below threshold favors treatment
      else
        verdict="below_threshold"
      fi
    fi
  elif [ "$score_count" -eq 0 ]; then
    verdict="INCONCLUSIVE"  # No scores — nothing to judge
  elif [ "$failed_cells" -gt 0 ]; then
    verdict="INCONCLUSIVE"  # Required cells missing/failed — cannot claim completeness
  fi

  # Generate report from template
  local template="$REPO_ROOT/docs/spec/_templates/_eval-report.md"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  {
    if [ -f "$template" ]; then
      # Use template as skeleton; insert computed values
      cat "$template"
      printf '\n\n---\n# Auto-Generated Summary (eval_generate_report)\n\n'
    else
      printf '# Evaluation Study Report — %s\n\n' "$study_id"
      printf 'Generated: %s\n\n' "$ts"
    fi

    printf '## Study: %s\n\n' "$study_id"
    printf '- Lineage: %s\n' "$_EC_STUDY_LINEAGE_ID"
    printf '- Run context: %s\n' "$_EC_STUDY_RUN_CONTEXT"
    printf '- Target repo: %s\n' "$_EC_STUDY_TARGET_REPO"
    printf '- Arms: %s\n' "$_EC_ARMS"
    printf '- Tasks: %s\n' "$_EC_TASKS"
    printf '- n_reps: %s\n' "$_EC_STUDY_N_REPS"
    printf '\n'
    printf '## Cell Summary\n\n'
    printf '- Total cells: %d\n' "$total_cells"
    printf '- Completed: %d\n' "$completed_cells"
    printf '- Failed/blocked: %d\n' "$failed_cells"
    printf '\n'
    printf '## Decision Rule\n\n'
    printf '- Metric: %s\n' "${metric:-n/a}"
    printf '- Threshold: %s\n' "${threshold:-n/a}"
    printf '- Direction: %s\n' "${direction:-n/a}"
    printf '- Mean score: %s (n=%d)\n' "$mean_score" "$score_count"
    printf '- **Verdict: %s**\n' "$verdict"
    printf '\n'
    printf '## Shuffle Manifest\n\n'
    printf '- Reference: %s\n' "$shuffle_manifest"
    printf '\n'
    printf '## Cell Index\n\n'
    printf '- Reference: %s\n' "$cell_index_file"
    printf '\n'
    printf '<!-- HONESTY NOTE: These results support auditability, not reproducibility. '
    printf 'claude -p is non-deterministic; models drift; n is small. '
    printf 'Re-running this study may produce different outputs. -->\n'
  } > "$out_path" 2>/dev/null || true

  echo "INFO [eval-conductor]: Report written to $out_path (verdict=$verdict, mean_score=$mean_score)"

  # Update study status — only mark 'completed' when verdict is conclusive.
  # INCONCLUSIVE means cells failed/are missing; study stays 'partial' or 'running'.
  if [ "$verdict" = "INCONCLUSIVE" ]; then
    if [ "$failed_cells" -gt 0 ]; then
      _ec_update_study_status "$study_id" "partial"
    fi
    # else: score_count=0 — cells still running/not collected; leave status unchanged
  else
    _ec_update_study_status "$study_id" "completed"
  fi

  return 0
}

# ============================================================
# Mode parity helpers
# ============================================================

# --- eval_resolve_target ---
# Resolve the target repo path based on study manifest run_context.
# Template mode: target = this repo root.
# Project mode:  target = child repo path (from study manifest target_repo field
#                or EVAL_TARGET_REPO env var, or configured path).
# Arguments: $1 = study_id (study must be loaded)
eval_resolve_target() {
  local study_id="${1:-}"
  [ -n "$_EC_STUDY_RUN_CONTEXT" ] || { echo "ERROR [eval-conductor]: Study not loaded — call eval_load_study first" >&2; return 1; }

  case "$_EC_STUDY_RUN_CONTEXT" in
    template)
      echo "$REPO_ROOT"
      ;;
    project)
      # Priority: EVAL_TARGET_REPO env var > study manifest target_repo > error
      if [ -n "${EVAL_TARGET_REPO:-}" ]; then
        echo "$EVAL_TARGET_REPO"
      elif [ -n "$_EC_STUDY_TARGET_REPO" ] && [ "$_EC_STUDY_TARGET_REPO" != "self" ]; then
        echo "$_EC_STUDY_TARGET_REPO"
      else
        echo "ERROR [eval-conductor]: run_context=project requires target_repo in study.yaml or EVAL_TARGET_REPO env var" >&2
        return 1
      fi
      ;;
    *)
      echo "ERROR [eval-conductor]: Unknown run_context '$_EC_STUDY_RUN_CONTEXT' — must be 'template' or 'project'" >&2
      return 1
      ;;
  esac
}
