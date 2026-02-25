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
now_ms() {
  local ms
  ms=$(date +%s%3N 2>/dev/null)
  if [[ "$ms" =~ [^0-9] ]]; then
    ms=$(( $(date +%s) * 1000 ))
  fi
  echo "$ms"
}

# --- Repo root cache (never changes within a session) ---
get_repo_root() {
  local cache="${TMPDIR:-/tmp}/.repo-os-root-$$"
  if [ -f "$cache" ]; then
    cat "$cache"
  else
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
    echo "$root" > "$cache" 2>/dev/null || true
    echo "$root"
  fi
}

# --- Portable path normalization (macOS-safe) ---
# Collapses .., ., and duplicate slashes without resolving symlinks.
normalize_path() {
  local raw="$1"
  if command -v python3 &>/dev/null; then
    python3 -c "import os.path,sys; print(os.path.normpath(sys.argv[1]))" "$raw" 2>/dev/null || echo "$raw"
  else
    echo "$raw"
  fi
}

# --- Resolve path to absolute (no symlink resolution) ---
# Converts relative paths to absolute using $PWD. Uses os.path.abspath
# (not realpath) so the result stays consistent with git's repo root.
resolve_path() {
  local raw="$1"
  if command -v python3 &>/dev/null; then
    python3 -c "import os.path,sys; print(os.path.abspath(sys.argv[1]))" "$raw" 2>/dev/null || echo "$raw"
  else
    if [[ "$raw" == /* ]]; then
      normalize_path "$raw"
    else
      normalize_path "$PWD/$raw"
    fi
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
# Parses redirect (>, >>) and tee patterns from a command.
# Applies filter set: skip /dev/*, skip tokens with < > =, skip tokens without / or .
# Outputs one path per line. Callers handle resolve_path/is_in_repo.
extract_write_targets() {
  local cmd="$1"
  local redir tee_targets
  redir=$(echo "$cmd" | grep -oE '[>]{1,2}\s*[^ |;&]+' | sed 's/[>]*//' | sed 's/^[[:space:]]*//' || true)
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
get_session_id() {
  local repo_root="$1"
  local sid_file="$repo_root/.claude/.session-id"
  if [ -f "$sid_file" ]; then
    cat "$sid_file"
  else
    local sid
    sid="$(date +%Y%m%d-%H%M%S)"
    echo "$sid" > "$sid_file" 2>/dev/null || true
    echo "$sid"
  fi
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

  local events_dir
  events_dir="$(get_analytics_dir "$repo_root")"
  mkdir -p "$events_dir" 2>/dev/null || true

  local today
  today="$(date +%Y-%m-%d)"

  # Auto-resolve v2 enrichment fields
  local mode
  mode="$(get_mode)"
  local branch
  branch="$(get_branch)"

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

  # Read session type if available
  local session_type_file="$repo_root/.claude/.session-type"
  if [ -f "$session_type_file" ]; then
    local stype
    stype=$(head -1 "$session_type_file" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$stype" ]; then
      json="$json,\"session_type\":\"$stype\""
    fi
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