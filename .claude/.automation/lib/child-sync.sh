#!/usr/bin/env bash
# child-sync.sh — Last-mile sync: trigger template-sync workflows on child
# repos and pull updates to local clones.
#
# Called by the post-push git hook after pushing template changes to main.
# Can also be run standalone: .claude/.automation/lib/child-sync.sh
#
# Reads child-repos.conf for the registry of child repos and local paths.
# Requires: gh CLI (authenticated), git.
#
# Exit codes:
#   0  All repos synced successfully
#   1  One or more repos failed to sync (partial success logged)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOMATION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONF=""
if [ -f "$AUTOMATION_DIR/child-repos.conf" ]; then
  CONF="$AUTOMATION_DIR/child-repos.conf"
elif [ -f "$AUTOMATION_DIR/child-repos.conf.example" ]; then
  echo "WARNING: child-repos.conf not found — falling back to child-repos.conf.example" >&2
  echo "  Copy child-repos.conf.example to child-repos.conf and customize for your environment." >&2
  CONF="$AUTOMATION_DIR/child-repos.conf.example"
else
  echo "ERROR: Neither child-repos.conf nor child-repos.conf.example found in $AUTOMATION_DIR" >&2
  echo "  Create child-repos.conf with your child repo registry. See child-repos.conf.example for format." >&2
  exit 1
fi
# Owner-only, per-user log: it carries git error text and local paths, and a
# fixed /tmp path was world-readable and open to a planted symlink. With no
# HOME the directory can't be created and logging stops; the sync still runs.
LOG_DIR="${XDG_STATE_HOME:-${HOME:-}/.local/state}/repo-os"
mkdir -p -m 700 "$LOG_DIR" 2>/dev/null && chmod 700 "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/child-sync.log"
MAX_WAIT=180   # seconds to wait for workflow completion

# --- Resolve GitHub org (three-tier fallback) ---
# 1. REPO_OS_GITHUB_ORG env var (operator override)
# 2. child-repos.conf header directive: "# org: <value>"
# 3. Hardcoded fallback
_resolve_github_org() {
  # Tier 1: env var
  if [ -n "${REPO_OS_GITHUB_ORG:-}" ]; then
    printf '%s' "$REPO_OS_GITHUB_ORG"
    return
  fi
  # Tier 2: conf header (first `# org:` line)
  if [ -f "$CONF" ]; then
    local conf_org
    conf_org=$(grep '^# org:' "$CONF" 2>/dev/null | head -1 | sed 's/^# org:[[:space:]]*//' | tr -d '[:space:]')
    if [ -n "$conf_org" ]; then
      printf '%s' "$conf_org"
      return
    fi
  fi
  # Tier 3: default fallback (set REPO_OS_GITHUB_ORG or add `# org:` to child-repos.conf)
  echo "ERROR: GitHub org not configured. Set REPO_OS_GITHUB_ORG env var or add '# org: <your-org>' to child-repos.conf" >&2
  return 1
}
GITHUB_ORG=$(_resolve_github_org) || exit 1
POLL_INTERVAL=10

# --- Globals set by functions ---
_TRIGGERED=0
_PULL_SUCCESS=0
_PULL_FAILED=0

# --- Logging ---
# Always appends to LOG file. Also prints to stderr when a terminal is
# attached (interactive use). When spawned by pre-push hook (no terminal),
# only the log file receives output.
log() {
  local msg
  msg=$(printf '[%s] %s' "$(date +%H:%M:%S)" "$*")
  printf '%s\n' "$msg" >> "$LOG" 2>/dev/null || true
  if [ -t 2 ]; then printf '%s\n' "$msg" >&2; fi
}

# --- Parse config ---
read_repos() {
  [ -f "$CONF" ] || { log "ERROR: $CONF not found"; exit 1; }
  grep -v '^#' "$CONF" | grep -v '^[[:space:]]*$'
}

# --- Trigger sync workflows ---
trigger_syncs() {
  _TRIGGERED=0
  while read -r repo_name local_path; do
    if gh workflow run template-sync.yml --repo "$GITHUB_ORG/$repo_name" 2>/dev/null; then
      log "  Triggered: $repo_name"
      _TRIGGERED=$((_TRIGGERED + 1))
    else
      log "  SKIP: $repo_name (workflow trigger failed — check SOURCE_REPO_TOKEN)"
    fi
  done < <(read_repos)
}

# --- Wait for all workflows to complete ---
wait_for_syncs() {
  local elapsed=0

  log "Waiting for workflows (max ${MAX_WAIT}s)..."

  while [ "$elapsed" -lt "$MAX_WAIT" ]; do
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))

    local all_done=true
    while read -r repo_name local_path; do
      local run_info
      run_info=$(gh run list --repo "$GITHUB_ORG/$repo_name" --workflow=template-sync.yml --limit 1 --json status,conclusion --jq '.[0] | "\(.status) \(.conclusion)"' 2>/dev/null || echo "unknown null")
      local run_status="${run_info%% *}"
      local run_conclusion="${run_info#* }"
      if [ "$run_status" != "completed" ]; then
        all_done=false
        break
      fi
      if [ "$run_conclusion" = "failure" ]; then
        log "  WARNING: $repo_name workflow completed with conclusion: failure"
      fi
    done < <(read_repos)

    if [ "$all_done" = true ]; then
      log "All workflows completed (${elapsed}s)"
      return 0
    fi
  done

  log "WARNING: Timeout after ${MAX_WAIT}s — some workflows may still be running"
  return 0
}

# --- Pull local clones ---
# Collapse git's multi-line output into one log line, masking any credentials
# in a remote URL. The match runs to the last '@' before whitespace or a quote,
# so a credential containing '/' or '@' is masked whole; a URL with '@' in its
# path is over-masked, which is the safe direction.
_oneline() { printf '%s' "$1" | tr '\n\t' '  ' | sed -e "s#://[^ '\"]*@#://***@#g" -e 's/ *$//'; }

# Bring one clone's local main up to origin/main without touching the branch
# that is checked out. Template sync only ever lands on main, so a clone sitting
# on a feature branch must still get main updated (a plain `git pull` there
# pulls the feature branch's upstream, or fails when it has none).
# Prints a one-line outcome; returns 1 when main was not brought up to date.
# Run in a subshell: it cd's into the clone.
_pull_one() {
  local out counts ahead behind branch dirty
  cd "$1" || { echo "cannot cd into $1"; return 1; }
  out=$(git fetch origin 2>&1) || { echo "fetch failed: $(_oneline "$out")"; return 1; }
  git rev-parse --verify -q refs/remotes/origin/main >/dev/null || { echo "origin/main not found"; return 1; }
  branch=$(git symbolic-ref -q --short HEAD 2>/dev/null || true)

  if ! git rev-parse --verify -q refs/heads/main >/dev/null; then
    out=$(git branch main origin/main 2>&1) || { echo "could not create main: $(_oneline "$out")"; return 1; }
    echo "created local main from origin/main$(_branch_note "$branch")"
    return 0
  fi

  counts=$(git rev-list --left-right --count refs/heads/main...refs/remotes/origin/main)
  ahead=${counts%%[[:space:]]*}
  behind=${counts##*[[:space:]]}
  if [ "$ahead" -gt 0 ]; then
    echo "main diverged ($ahead ahead / $behind behind origin/main) — manual"
    return 1
  fi
  if [ "$behind" -eq 0 ]; then
    echo "main up to date$(_branch_note "$branch")"
    return 0
  fi

  if [ "$branch" = "main" ]; then
    # Untracked files don't block a fast-forward that doesn't touch them.
    dirty=$(git status --porcelain --untracked-files=no | wc -l | tr -d '[:space:]')
    if [ "$dirty" -gt 0 ]; then
      echo "main checked out and dirty, $dirty files — skipped ($behind behind origin/main)"
      return 1
    fi
    out=$(git pull --ff-only origin main 2>&1) || { echo "pull failed: $(_oneline "$out")"; return 1; }
  else
    # Fast-forward only; git refuses if main is checked out in another worktree.
    out=$(git fetch origin main:main 2>&1) || { echo "could not update main: $(_oneline "$out")"; return 1; }
  fi
  echo "main updated ($behind commits)$(_branch_note "$branch")"
}

# "; <branch> checked out, N behind main" — empty when main itself is checked out.
_branch_note() {
  case "$1" in
    main) ;;
    "") printf '; detached HEAD left alone' ;;
    *) printf '; %s checked out, %s behind main' "$1" "$(git rev-list --count "refs/heads/$1..refs/heads/main")" ;;
  esac
}

pull_locals() {
  _PULL_SUCCESS=0
  _PULL_FAILED=0

  local outcome
  while read -r repo_name local_path; do
    if [ ! -e "$local_path/.git" ]; then
      log "  SKIP: $local_path (not a git clone)"
      _PULL_FAILED=$((_PULL_FAILED + 1))
      continue
    fi

    # Subshell prevents persistent cd from corrupting loop iterations (audit 6.2)
    if outcome=$(_pull_one "$local_path"); then
      log "  Pulled: $repo_name → $local_path ($outcome)"
      _PULL_SUCCESS=$((_PULL_SUCCESS + 1))
    else
      log "  FAIL: $repo_name — $outcome"
      _PULL_FAILED=$((_PULL_FAILED + 1))
    fi
  done < <(read_repos)
}

# --- Notify (macOS) ---
notify() {
  local title="$1"
  local msg="$2"
  osascript -e "display notification \"$msg\" with title \"$title\"" 2>/dev/null || true
}

# --- Main ---
main() {
  log "=== Repo OS Child Sync ==="
  log "Config: $CONF"

  # Step 1: Trigger
  log "Triggering sync workflows..."
  trigger_syncs
  log "Triggered $_TRIGGERED workflow(s)"

  if [ "$_TRIGGERED" -eq 0 ]; then
    log "No workflows triggered — nothing to do"
    return 0
  fi

  # Step 2: Wait
  wait_for_syncs

  # Step 3: Check results
  log "Workflow results:"
  while read -r repo_name local_path; do
    result=$(gh run list --repo "$GITHUB_ORG/$repo_name" --workflow=template-sync.yml --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo "unknown")
    log "  $repo_name: $result"
  done < <(read_repos)

  # Step 4: Pull
  log "Pulling local clones..."
  pull_locals
  log "Pull complete: $_PULL_SUCCESS succeeded, $_PULL_FAILED failed"

  # Step 5: Notify
  if [ "$_PULL_FAILED" -eq 0 ]; then
    notify "Repo OS" "All $_PULL_SUCCESS child repos synced successfully"
  else
    notify "Repo OS" "$_PULL_SUCCESS synced, $_PULL_FAILED failed — check $LOG"
  fi

  log "=== Done ==="
}

# Sourced by test-child-sync.sh for pull_locals; run main only when executed.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
