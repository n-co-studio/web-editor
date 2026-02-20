#!/usr/bin/env bash
# Shared analytics capture — sourced by all hooks.
# Writes one NDJSON event per hook invocation to .claude/analytics/events/<date>.ndjson.
# All writes are fail-silent (|| true) — analytics never blocks enforcement.
#
# Usage (in hook scripts):
#   REPO_ROOT="$(get_repo_root)"
#   START_MS=$(date +%s%3N 2>/dev/null || date +%s)
#   ... hook logic ...
#   log_hook_event "hook-name" "PreToolUse" "Edit" "allow" "$START_MS" "reason_code"

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

# --- Write analytics event ---
log_hook_event() {
  local hook="$1"
  local event="$2"
  local tool="${3:-}"
  local outcome="${4:-allow}"
  local start_ms="${5:-0}"
  local reason="${6:-}"

  local repo_root
  repo_root="$(get_repo_root)"
  local sid
  sid="$(get_session_id "$repo_root")"
  local end_ms
  end_ms=$(date +%s%3N 2>/dev/null || date +%s)
  local dur=$(( end_ms - start_ms ))

  local events_dir="$repo_root/.claude/analytics/events"
  mkdir -p "$events_dir" 2>/dev/null || true

  local today
  today="$(date +%Y-%m-%d)"

  # Single atomic append — ~1-3ms overhead
  printf '{"v":1,"ts":%s,"sid":"%s","hook":"%s","evt":"%s","tool":"%s","out":"%s","dur":%s,"reason":"%s"}\n' \
    "$end_ms" "$sid" "$hook" "$event" "$tool" "$outcome" "$dur" "$reason" \
    >> "$events_dir/$today.ndjson" 2>/dev/null || true
}

# --- Cleanup: delete event files older than 90 days ---
cleanup_old_analytics() {
  local repo_root="$1"
  local events_dir="$repo_root/.claude/analytics/events"
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