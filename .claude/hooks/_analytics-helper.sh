#!/usr/bin/env bash
# Shared analytics capture — sourced by all hooks.
# Writes one NDJSON event per hook invocation to ~/.local/share/repo-os-analytics/<repo>/events/<date>.ndjson.
# All writes are fail-silent (|| true) — analytics never blocks enforcement.
#
# Usage (in hook scripts):
#   REPO_ROOT="$(get_repo_root)"
#   START_MS=$(now_ms)
#   ... hook logic ...
#   log_hook_event "hook-name" "PreToolUse" "Edit" "allow" "$START_MS" "reason_code"

# --- Portable millisecond timestamp ---
# GNU date supports %N (nanoseconds); macOS date does not — it outputs literal "N".
# Detect platform once at source-time to avoid repeated probe overhead.
case "${OSTYPE:-}" in
  darwin*)  _REPO_OS_HAS_GNU_DATE=false ;;
  linux*)   _REPO_OS_HAS_GNU_DATE=true ;;
  *)
    # Unknown platform: probe once at source time
    if [[ "$(date +%s%3N 2>/dev/null)" =~ ^[0-9]+$ ]]; then
      _REPO_OS_HAS_GNU_DATE=true
    else
      _REPO_OS_HAS_GNU_DATE=false
    fi
    ;;
esac

# --- jq availability (probed once at source-time) ---
# Security-critical hooks (agent-git-guard, branch-guard, write-guard) fail-closed
# when jq is absent. Analytics and HVST tracking degrade gracefully.
_REPO_OS_HAS_JQ=false
command -v jq &>/dev/null && _REPO_OS_HAS_JQ=true

now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    # Bash 5+: zero-fork millisecond timestamp
    local sec="${EPOCHREALTIME%%.*}"
    local frac="${EPOCHREALTIME#*.}"
    frac="${frac}000"
    echo "${sec}${frac:0:3}"
  elif [ "$_REPO_OS_HAS_GNU_DATE" = true ]; then
    date +%s%3N
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

# --- Portable SHA-256 (stdin-based) ---
# Three-way fallback: shasum / sha256sum / openssl. Reads stdin, outputs hex digest.
portable_hash() {
  if command -v shasum &>/dev/null; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum &>/dev/null; then
    sha256sum | awk '{print $1}'
  else
    openssl sha256 | awk '{print $NF}'
  fi
}

# --- Repo root (derived from this file's location — never depends on CWD or git) ---
# _analytics-helper.sh lives at .claude/hooks/ — repo root is always two levels up.
# Eliminates: CWD dependency, git dependency, stale PID-based /tmp/ cache.
# Test seam: _REPO_OS_TEST_ROOT overrides repo root, but ONLY when
# REPO_OS_TEST_MODE=1 is also set (dual guard prevents accidental env leaks).
if [ "${REPO_OS_TEST_MODE:-0}" = "1" ] && [ -n "${_REPO_OS_TEST_ROOT:-}" ]; then
  _REPO_OS_ROOT="$_REPO_OS_TEST_ROOT"
else
  _REPO_OS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

get_repo_root() {
  echo "$_REPO_OS_ROOT"
}

# --- Portable path normalization (macOS-safe) ---
# Collapses .., ., and duplicate slashes without resolving symlinks.
# Fast-path: if no special components, return as-is (zero forks).
# Fallback: python3 os.path.normpath for edge cases (.., ., //).
# NOTE: python3 is recommended for reliable path normalization. Without it,
# paths containing .. components pass through un-normalized, which may weaken
# is_in_repo() boundary checks (a path like /repo/../outside/file would not
# be collapsed and could pass the prefix check incorrectly).
normalize_path() {
  local raw="$1"
  case "$raw" in
    */./*|*/../*|*//*|./*|../*)
      # Has components needing normalization — fall back to Python
      if command -v python3 &>/dev/null; then
        python3 -c "import os.path,sys; print(os.path.normpath(sys.argv[1]))" "$raw" 2>/dev/null || echo "$raw"
      else
        echo "$raw"
      fi
      ;;
    *)
      # Common case: clean path, return as-is
      echo "$raw"
      ;;
  esac
}

# --- Resolve path to absolute (no symlink resolution) ---
# Converts relative paths to absolute using $PWD. Fast-path for absolute
# paths (zero forks). Falls back to normalize_path for relative paths or
# paths with special components.
resolve_path() {
  local raw="$1"
  if [[ "$raw" == /* ]]; then
    # Absolute — normalize only if it has special components
    normalize_path "$raw"
  else
    # Relative — prepend PWD then normalize
    normalize_path "$PWD/$raw"
  fi
}

# --- Check if a resolved absolute path is within the repo tree ---
# Returns 0 if the path is under REPO_ROOT, 1 otherwise.
is_in_repo() {
  local abs_path="$1"
  local repo_root="${2:-$(get_repo_root)}"
  local root_prefix="${repo_root}/"
  if [[ "$abs_path" == "$root_prefix"* || "$abs_path" == "$repo_root" ]]; then
    return 0
  fi
  return 1
}

# --- Extract write targets from a Bash command string ---
# Parses redirect (>, >>), file-descriptor redirects ([0-9]>, [0-9]>>), and
# tee patterns from a command.
# Applies filter set: skip /dev/*, skip tokens with < > =, skip tokens without / or .
# Outputs one path per line. Callers handle resolve_path/is_in_repo.
#
# Known limitations (residual gaps — not detectable via regex):
#   - Here-documents (<<EOF ... EOF)
#   - Process substitution (>(cmd), <(cmd))
#   - Positional write commands (cp, mv, curl -o, install, python -c open())
extract_write_targets() {
  local cmd="$1"
  local redir tee_targets
  # Match [N]> and [N]>> redirects (standard + file-descriptor)
  redir=$(echo "$cmd" | grep -oE '[0-9]?[>]{1,2}\s*[^ |;&]+' | sed 's/^[0-9]//' | sed 's/[>]*//' | sed 's/^[[:space:]]*//' || true)
  tee_targets=$(echo "$cmd" | grep -oE 'tee\s+(-a\s+)?[^ |;&]+' | sed 's/tee\s*//' | sed 's/-a\s*//' || true)
  local wt
  for wt in $redir $tee_targets; do
    [ -z "$wt" ] && continue
    [[ "$wt" == /dev/* ]] && continue
    [[ "$wt" == *"<"* || "$wt" == *">"* || "$wt" == *"="* ]] && continue
    [[ "$wt" != *"/"* && "$wt" != *"."* ]] && continue
    echo "$wt"
  done
}

# --- Centralized analytics directory for this repo ---
# All repos write to ~/.local/share/repo-os-analytics/<repo-name>/events/.
# Repo name derived from basename (same convention as register_repo).
get_analytics_dir() {
  local repo_root="${1:-$(get_repo_root)}"
  local repo_name
  repo_name="$(basename "$repo_root")"
  echo "$HOME/.local/share/repo-os-analytics/$repo_name/events"
}

# --- Session ID (created on first hook fire, cleaned by Stop hook) ---
_CACHED_SESSION_ID=""
get_session_id() {
  local repo_root="$1"
  if [ -n "$_CACHED_SESSION_ID" ]; then
    echo "$_CACHED_SESSION_ID"
    return
  fi
  local sid_file="$repo_root/.claude/.session-id"
  if [ -f "$sid_file" ]; then
    _CACHED_SESSION_ID=$(cat "$sid_file")
  else
    _CACHED_SESSION_ID="$(date +%Y%m%d-%H%M%S)"
    echo "$_CACHED_SESSION_ID" > "$sid_file" 2>/dev/null || true
  fi
  echo "$_CACHED_SESSION_ID"
}

# --- Cached branch name (avoid repeated git calls) ---
_CACHED_BRANCH=""
get_branch() {
  if [ -z "$_CACHED_BRANCH" ]; then
    _CACHED_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  fi
  echo "$_CACHED_BRANCH"
}

# --- Cached operating mode ---
_CACHED_MODE=""
get_mode() {
  if [ -z "$_CACHED_MODE" ]; then
    local repo_root
    repo_root="$(get_repo_root)"
    _CACHED_MODE="${REPO_OS_MODE:-}"
    if [ -z "$_CACHED_MODE" ]; then
      local mode_file="$repo_root/.claude/repo-mode"
      if [ -f "$mode_file" ]; then
        _CACHED_MODE=$(head -1 "$mode_file" | tr -d '[:space:]')
      fi
    fi
    _CACHED_MODE="${_CACHED_MODE:-child}"
  fi
  echo "$_CACHED_MODE"
}

# --- Session type from phase-state (with session ID validation) ---
# Reads session_type from phase-state if present and current (session ID match).
# Falls back to .session-type file. Returns empty string if neither exists.
# Cached per-process to avoid repeated file I/O on each hook invocation.
# Uses boolean sentinel (not empty-string check) because empty result is
# valid — session type is legitimately absent before init_phase().
_CACHED_SESSION_TYPE=""
_CACHED_SESSION_TYPE_SET=false
# Audit C7: process-scoped overlap check cache (avoids redundant globs per invocation)
_SESSION_OVERLAP_CHECKED=false
get_session_type() {
  if [ "$_CACHED_SESSION_TYPE_SET" = true ]; then
    echo "$_CACHED_SESSION_TYPE"
    return
  fi

  local repo_root
  repo_root="$(get_repo_root)"
  local state_file="$repo_root/.claude/.state/phase-state"
  local result=""

  # Try phase-state first (with session ID validation)
  if [ -f "$state_file" ]; then
    local sid
    sid=$(grep '^session_id:' "$state_file" 2>/dev/null | sed 's/^session_id: *//')
    local current_sid
    current_sid=$(cat "$repo_root/.claude/.session-id" 2>/dev/null)
    if [ -n "$sid" ] && [ "$sid" = "$current_sid" ]; then
      result=$(grep '^session_type:' "$state_file" 2>/dev/null | sed 's/^session_type: *//')
    fi
  fi

  # Fallback to .session-type file
  if [ -z "$result" ]; then
    local type_file="$repo_root/.claude/.session-type"
    if [ -f "$type_file" ]; then
      result=$(head -1 "$type_file" 2>/dev/null | tr -d '[:space:]')
    fi
  fi

  _CACHED_SESSION_TYPE="$result"
  _CACHED_SESSION_TYPE_SET=true
  echo "$_CACHED_SESSION_TYPE"
}

# --- Cached analytics directory and date (avoid redundant forks per invocation) ---
_CACHED_ANALYTICS_DIR=""
_CACHED_TODAY=""

# --- Write analytics event ---
# v2 signature: log_hook_event "hook" "evt" "tool" "out" "$START_MS" "reason" ["detail"] ["path"]
# detail and path are optional v2 enrichment fields.
# mode and branch are auto-appended from git state.
log_hook_event() {
  local hook="$1"
  local event="$2"
  local tool="${3:-}"
  local outcome="${4:-allow}"
  local start_ms="${5:-0}"
  local reason="${6:-}"
  local detail="${7:-}"
  local path="${8:-}"

  local repo_root
  repo_root="$(get_repo_root)"
  local sid
  sid="$(get_session_id "$repo_root")"
  local end_ms
  end_ms=$(now_ms)
  local dur=$(( end_ms - start_ms ))

  # Cached analytics directory (avoids basename fork on every call)
  if [ -z "$_CACHED_ANALYTICS_DIR" ]; then
    _CACHED_ANALYTICS_DIR="$(get_analytics_dir "$repo_root")"
  fi
  local events_dir="$_CACHED_ANALYTICS_DIR"
  mkdir -p "$events_dir" 2>/dev/null || true

  # Cached date (avoids date fork on every call — stable within a session)
  if [ -z "$_CACHED_TODAY" ]; then
    _CACHED_TODAY="$(date +%Y-%m-%d)"
  fi
  local today="$_CACHED_TODAY"

  # Auto-resolve v2 enrichment fields
  local mode
  mode="$(get_mode)"
  local branch
  branch="$(get_branch)"

  # Sanitize all string values interpolated into JSON (escape \ and ", strip control chars)
  local _sanitize_var
  for _sanitize_var in sid hook event tool outcome reason mode branch detail path; do
    eval "local _v=\"\$$_sanitize_var\""
    _v="${_v//\\/\\\\}"; _v="${_v//\"/\\\"}"
    _v="${_v//$'\n'/}"; _v="${_v//$'\r'/}"; _v="${_v//$'\t'/}"
    eval "$_sanitize_var=\"\$_v\""
  done

  # Build v2 event with optional fields (omit empty fields to keep events compact)
  local json
  json=$(printf '{"v":2,"ts":%s,"sid":"%s","hook":"%s","evt":"%s","tool":"%s","out":"%s","dur":%s,"reason":"%s","mode":"%s","branch":"%s"' \
    "$end_ms" "$sid" "$hook" "$event" "$tool" "$outcome" "$dur" "$reason" "$mode" "$branch")

  # Append optional v2 fields only when populated
  if [ -n "$detail" ]; then
    json="$json,\"detail\":\"$detail\""
  fi
  if [ -n "$path" ]; then
    json="$json,\"path\":\"$path\""
  fi

  # Session type from cached getter (avoids redundant file I/O per invocation)
  local stype
  stype="$(get_session_type)"
  if [ -n "$stype" ]; then
    stype="${stype//\\/\\\\}"; stype="${stype//\"/\\\"}"
    stype="${stype//$'\n'/}"; stype="${stype//$'\r'/}"; stype="${stype//$'\t'/}"
    json="$json,\"session_type\":\"$stype\""
  fi

  # Automation context (set by runner before claude -p invocation)
  if [ -n "${REPO_OS_AUTOMATION_ENTRY:-}" ]; then
    local auto_entry="${REPO_OS_AUTOMATION_ENTRY}"
    auto_entry="${auto_entry//\\/\\\\}"; auto_entry="${auto_entry//\"/\\\"}"
    auto_entry="${auto_entry//$'\n'/}"; auto_entry="${auto_entry//$'\r'/}"; auto_entry="${auto_entry//$'\t'/}"
    json="$json,\"automation_context\":\"$auto_entry\""
  fi

  json="$json}"
  printf '%s\n' "$json" >> "$events_dir/$today.ndjson" 2>/dev/null || true
}

# --- Log override usage for session audit ---
# Appends to .claude/.state/overrides.log (gitignored, session-scoped).
# Session-close hook reads this for override audit summary.
log_override() {
  local hook="$1"
  local env_var="$2"

  local repo_root
  repo_root="$(get_repo_root)"
  local state_dir="$repo_root/.claude/.state"
  mkdir -p "$state_dir" 2>/dev/null || true

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s %s %s\n' "$ts" "$hook" "$env_var" \
    >> "$state_dir/overrides.log" 2>/dev/null || true
}

# --- Cleanup: delete event files older than 90 days ---
cleanup_old_analytics() {
  local repo_root="$1"
  local events_dir
  events_dir="$(get_analytics_dir "$repo_root")"
  [ -d "$events_dir" ] && find "$events_dir" -name "*.ndjson" -type f -mtime +90 -delete 2>/dev/null || true
}

# --- Auto-register repo in global analytics registry ---
register_repo() {
  local repo_root="$1"
  local registry_dir="$HOME/.local/share/repo-os-analytics"
  local registry="$registry_dir/registry.json"

  # Skip if already registered (check by path)
  if [ -f "$registry" ] && grep -q "\"$repo_root\"" "$registry" 2>/dev/null; then
    return 0
  fi

  mkdir -p "$registry_dir" 2>/dev/null || true

  # Derive repo name from directory
  local repo_name
  repo_name="$(basename "$repo_root")"

  if [ ! -f "$registry" ]; then
    # Create new registry
    printf '{"schema_version":"1.0.0","repos":[{"name":"%s","path":"%s"}]}\n' \
      "$repo_name" "$repo_root" > "$registry" 2>/dev/null || true
  else
    # Append to existing registry (jq if available, otherwise skip)
    if command -v jq &>/dev/null; then
      local tmp="$registry.tmp"
      jq --arg name "$repo_name" --arg path "$repo_root" \
        '.repos += [{"name": $name, "path": $path}]' "$registry" > "$tmp" 2>/dev/null && \
        mv "$tmp" "$registry" 2>/dev/null || true
    fi
  fi
}

# --- Portable ISO 8601 to epoch seconds ---
# macOS date cannot parse ISO 8601 natively. Uses python3 if available,
# falls back to GNU date -d. Returns empty string on failure.
# Fail-silent: callers skip age checks when conversion fails.
_iso_to_epoch() {
  local iso="$1"
  if command -v python3 &>/dev/null; then
    python3 -c "
import sys, datetime
try:
    dt = datetime.datetime.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ')
    print(int(dt.replace(tzinfo=datetime.timezone.utc).timestamp()))
except:
    pass
" "$iso" 2>/dev/null
  elif date -d "$iso" +%s &>/dev/null 2>&1; then
    date -d "$iso" +%s 2>/dev/null
  else
    echo ""
  fi
}

# --- Register session in the session registry ---
# Writes a YAML file to .claude/.state/sessions/{session-id}.yaml.
# Called at session init (from init_phase in _phase-helper.sh).
# Checks for same-branch overlap and emits an advisory warning.
# Fail-silent: registry failures never block session start.
register_session() {
  local repo_root
  repo_root="$(get_repo_root)"
  local sid
  sid="$(get_session_id "$repo_root")"
  local stype="${1:-}"
  local branch
  branch="$(get_branch)"
  local pid="$$"
  local started_at
  started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local sessions_dir="$repo_root/.claude/.state/sessions"
  mkdir -p "$sessions_dir" 2>/dev/null || true

  # Write session file
  printf 'session_id: %s\nsession_type: %s\nbranch: %s\npid: %s\nstarted_at: %s\n' \
    "$sid" "$stype" "$branch" "$pid" "$started_at" \
    > "$sessions_dir/${sid}.yaml" 2>/dev/null || true

  # Check for same-branch overlap (advisory at registration time)
  local overlap_file
  for overlap_file in "$sessions_dir"/*.yaml; do
    [ -f "$overlap_file" ] || continue
    local other_sid
    other_sid=$(basename "$overlap_file" .yaml)
    [ "$other_sid" = "$sid" ] && continue

    local other_branch
    other_branch=$(grep '^branch: ' "$overlap_file" 2>/dev/null | sed 's/^branch: *//')
    [ "$other_branch" = "$branch" ] || continue

    local other_type
    other_type=$(grep '^session_type: ' "$overlap_file" 2>/dev/null | sed 's/^session_type: *//')
    echo "Warning: Session $other_sid (type: $other_type) is also active on branch '$branch'. Concurrent edits may cause conflicts." >&2
  done
}

# --- Unregister session from the session registry ---
# Removes this session's YAML file and cleans stale entries (dead PID + 24h age).
# Called by cleanup_session() in session-close-check.sh.
# Fail-silent: cleanup failures are non-fatal.
unregister_session() {
  local repo_root
  repo_root="$(get_repo_root)"
  local sid
  sid="$(get_session_id "$repo_root")"

  local sessions_dir="$repo_root/.claude/.state/sessions"

  # Remove this session's file
  rm -f "$sessions_dir/${sid}.yaml" 2>/dev/null || true

  # Clean stale entries: dead PID or age > 24h
  local stale_file
  for stale_file in "$sessions_dir"/*.yaml; do
    [ -f "$stale_file" ] || continue

    local file_pid
    file_pid=$(grep '^pid: ' "$stale_file" 2>/dev/null | sed 's/^pid: *//')

    # PID check: if process is dead, remove stale entry
    if [ -n "$file_pid" ] && ! kill -0 "$file_pid" 2>/dev/null; then
      rm -f "$stale_file" 2>/dev/null || true
      continue
    fi

    # Age guard: if started_at is older than 24h, remove regardless of PID
    local file_started
    file_started=$(grep '^started_at: ' "$stale_file" 2>/dev/null | sed 's/^started_at: *//')
    if [ -n "$file_started" ]; then
      local file_epoch
      file_epoch=$(_iso_to_epoch "$file_started")
      local now_epoch
      now_epoch=$(date +%s)
      if [ -n "$file_epoch" ] && [ $(( now_epoch - file_epoch )) -gt 86400 ]; then
        rm -f "$stale_file" 2>/dev/null || true
      fi
    fi
  done
}

# --- Check for concurrent session overlap on the same branch ---
# Called by branch-guard-edit.sh and branch-guard.sh on each Edit/Write/Bash.
# Returns: 0 = no overlap or advisory only, 2 = blocking overlap.
# Advisory for task group sharing; BLOCKING for non-task-group overlap.
# Override: REPO_OS_SKIP_OVERLAP_CHECK=1
# Exempt session types: taskdef-query, taskdef-brief (Prompt T reads only).
check_session_overlap() {
  # Override
  if [ "${REPO_OS_SKIP_OVERLAP_CHECK:-0}" = "1" ]; then
    log_override "overlap-check" "REPO_OS_SKIP_OVERLAP_CHECK"
    return 0
  fi

  # Audit C7: skip redundant checks after first successful pass
  if [ "$_SESSION_OVERLAP_CHECKED" = true ]; then
    return 0
  fi

  local repo_root
  repo_root="$(get_repo_root)"
  local sessions_dir="$repo_root/.claude/.state/sessions"
  [ -d "$sessions_dir" ] || return 0

  local sid
  sid="$(get_session_id "$repo_root")"
  local branch
  branch="$(get_branch)"

  # Get current session type
  local my_type
  my_type="$(get_session_type)"

  # Exempt session types (Prompt T — read-only, no file writes)
  case "$my_type" in
    taskdef-query|taskdef-brief) return 0 ;;
  esac

  local check_file
  for check_file in "$sessions_dir"/*.yaml; do
    [ -f "$check_file" ] || continue
    local other_sid
    other_sid=$(basename "$check_file" .yaml)
    [ "$other_sid" = "$sid" ] && continue

    local other_branch
    other_branch=$(grep '^branch: ' "$check_file" 2>/dev/null | sed 's/^branch: *//')
    [ "$other_branch" = "$branch" ] || continue

    # Same branch — check if the other session is still alive
    local other_pid
    other_pid=$(grep '^pid: ' "$check_file" 2>/dev/null | sed 's/^pid: *//')
    if [ -n "$other_pid" ] && ! kill -0 "$other_pid" 2>/dev/null; then
      # Stale entry — clean up opportunistically
      rm -f "$check_file" 2>/dev/null || true
      continue
    fi

    # Check other session type
    local other_type
    other_type=$(grep '^session_type: ' "$check_file" 2>/dev/null | sed 's/^session_type: *//')

    # Skip exempt types in the other session too
    case "$other_type" in
      taskdef-query|taskdef-brief) continue ;;
    esac

    # Task group sharing is advisory only (taskgroup and taskgroup-merge can coexist)
    if { [ "$my_type" = "taskgroup" ] || [ "$my_type" = "taskgroup-merge" ]; } && \
       { [ "$other_type" = "taskgroup" ] || [ "$other_type" = "taskgroup-merge" ]; }; then
      echo "Advisory: Task group session overlap — session $other_sid is also active on branch '$branch'." >&2
      return 0
    fi

    # Non-task-group overlap — BLOCK
    echo "BLOCKED: Session $other_sid (type: $other_type) is already active on branch '$branch'. Concurrent non-task-group sessions on the same branch are not allowed. (override: REPO_OS_SKIP_OVERLAP_CHECK=1)" >&2
    return 2
  done

  # Audit C7: cache successful check to skip redundant globs on subsequent calls
  _SESSION_OVERLAP_CHECKED=true
  return 0
}