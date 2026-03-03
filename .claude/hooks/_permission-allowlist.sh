#!/usr/bin/env bash
# Permission allowlist — curated tool and command lists for PermissionRequest hook.
# Sourced by permission-request.sh. NOT executed standalone.
# Decision 0017 — Operator Automation Layer.
#
# Three lists:
#   ALLOW_TOOLS — non-Bash tools auto-approved without dialog
#   ALLOW_BASH_PATTERNS — safe Bash command prefixes auto-approved
#   DENY_BASH_PATTERNS — dangerous Bash commands always denied
#
# Priority: deny > allow > fall-through (dialog).

# --- Non-Bash tools that are always safe to auto-approve ---
# These tools operate within Claude Code's sandbox and cannot cause harm.
_PERMISSION_ALLOW_TOOLS=(
  Read
  Edit
  Write
  Glob
  Grep
  WebSearch
  WebFetch
  Task
  NotebookEdit
)

# --- Safe Bash command prefixes ---
# Commands matching these prefixes are auto-approved.
# Each entry is a regex pattern matched against the start of the command.
_PERMISSION_ALLOW_BASH=(
  # Package managers / build tools
  'npm '
  'npm$'
  'npx '
  'node '
  'python '
  'python3 '
  'tsc '
  'tsc$'
  'eslint '
  'prettier '
  'jest '
  'jest$'
  'vitest '
  'vitest$'
  'bun '
  'bun$'

  # File inspection (read-only)
  'ls '
  'ls$'
  'cat '
  'head '
  'tail '
  'wc '
  'wc$'
  'diff '
  'sort '
  'uniq '
  'basename '
  'dirname '
  'realpath '
  'readlink '
  'file '
  'stat '
  'test '
  'true$'
  'false$'
  'echo '
  'printf '
  'date '
  'date$'

  # File operations (write — safe within sandbox)
  'mkdir '
  'touch '
  'cp '
  'mv '

  # Git read operations
  'git status'
  'git log'
  'git diff'
  'git branch'
  'git fetch'
  'git remote'
  'git rev-parse'
  'git show'
  'git tag'
  'git rev-list'
  'git name-rev'
  'git describe'
  'git ls-files'
  'git ls-tree'
  'git cat-file'
  'git merge-base'
  'git for-each-ref'
  'git shortlog'
  'git blame'

  # Git navigation (may mutate working tree / HEAD)
  'git checkout'
  'git switch'
  'git stash'

  # Source helper scripts (common in Repo OS hooks)
  'source '
  '\. '
)

# --- Dangerous Bash commands that always trigger denial ---
# Each entry is a regex pattern. Checked BEFORE allow patterns.
_PERMISSION_DENY_BASH=(
  'rm -rf'
  'rm -fr'
  'sudo '
  'chmod 777'
  'kill -9'
  '\bdd '
  'mkfs'
  'fdisk'
  'mkswap'
)

# --- Outbound network commands to non-localhost ---
# curl/wget to external URLs are denied; localhost is allowed.
_PERMISSION_DENY_NETWORK_CMD=(
  'curl'
  'wget'
)

# --- Check if a tool name is in the allow list ---
# Arguments: $1 = tool_name
# Returns: 0 if allowed, 1 if not
is_tool_allowed() {
  local tool="$1"
  local t
  for t in "${_PERMISSION_ALLOW_TOOLS[@]}"; do
    if [ "$tool" = "$t" ]; then
      return 0
    fi
  done
  return 1
}

# --- Check if a Bash command matches the deny list ---
# Arguments: $1 = command string
# Returns: 0 if denied, 1 if not
# Sets: _DENY_REASON with the matched pattern
_DENY_REASON=""
is_bash_denied() {
  local cmd="$1"
  _DENY_REASON=""

  # Check explicit deny patterns
  local pat
  for pat in "${_PERMISSION_DENY_BASH[@]}"; do
    if echo "$cmd" | grep -qE "$pat"; then
      _DENY_REASON="$pat"
      return 0
    fi
  done

  # Check network commands (curl/wget to non-localhost)
  local net_cmd
  for net_cmd in "${_PERMISSION_DENY_NETWORK_CMD[@]}"; do
    if echo "$cmd" | grep -qE "^${net_cmd} |^${net_cmd}\$| ${net_cmd} | ${net_cmd}\$"; then
      # Allow if targeting localhost
      if echo "$cmd" | grep -qE '(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])'; then
        continue
      fi
      _DENY_REASON="${net_cmd} to non-localhost"
      return 0
    fi
  done

  return 1
}

# --- Check if a Bash command matches the allow list ---
# Arguments: $1 = command string
# Returns: 0 if allowed, 1 if not
is_bash_allowed() {
  local cmd="$1"
  local pat
  for pat in "${_PERMISSION_ALLOW_BASH[@]}"; do
    if echo "$cmd" | grep -qE "^${pat}"; then
      return 0
    fi
  done
  return 1
}
