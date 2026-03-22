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

  # Shell builtins (safe environment management)
  'export '
  'unset '

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

  # Git write operations (governed by pre-commit-gates.sh and pre-push-gates.sh)
  'git add'
  'git commit'
  'git merge'
  'git push'
  'git clean'

  # Git navigation (may mutate working tree / HEAD)
  'git checkout'
  'git switch'
  'git stash'

  # Source helper scripts (scoped to Repo OS hooks — arbitrary source falls through to dialog)
  'source .claude/hooks/'
  'source "\$SCRIPT_DIR'
  'source "\$\{SCRIPT_DIR'
  'source "\$_BRIDGE_AUTOMATION_DIR'
  'source .claude/.automation/'
  '\. .claude/hooks/'
  '\. "\$SCRIPT_DIR'
  '\. "\$\{SCRIPT_DIR'
  '\. "\$_BRIDGE_AUTOMATION_DIR'
  '\. .claude/.automation/'

  # File watching (read-only passive tools — editor-live session type)
  'fswatch '
  'fswatch$'
  'inotifywait '
  'inotifywait$'
  '.claude/hooks/editor-watch.sh '
)

# --- Dangerous Bash commands that always trigger denial ---
# Each entry is a regex pattern. Checked BEFORE allow patterns.
#
# Invariant: Pattern Anchoring Convention
#
# All deny patterns are anchored to command-position to prevent false positives
# on quoted arguments (e.g., `echo "do not use sudo"` should NOT be denied).
#
# Two tiers:
#   Tier 1 (catastrophic) — Enhanced anchor with env-var prefix support:
#     (^|[;&|] *)([A-Za-z_][A-Za-z0-9_]*=[^ ]* )*PATTERN
#     Matches: `PATTERN`, `FOO=bar PATTERN`, `cmd; PATTERN`, `cmd | PATTERN`
#     Used for: rm -rf, rm -fr, sudo, kill -9, claude
#
#   Tier 2 (standard) — Basic command-position anchor:
#     (^|[;&|] *)PATTERN
#     Matches: `PATTERN`, `cmd; PATTERN`, `cmd | PATTERN`
#     Used for: dd, chmod 777, mkfs, fdisk, mkswap, eval
#
# Supplementary patterns (e.g., xargs pipelines) use context-specific anchors.
#
# Accepted gaps (defense-in-depth via other layers):
#   - Subshells: $(sudo ...) / `sudo ...` — caught by bash-guard
#   - Path-qualified: /usr/bin/sudo — adversarial-only, pre-existing gap
#   - Builtins via variable expansion: $cmd — caught by bash-guard
#   - Aliases: aliased commands — not relevant in non-interactive shells
#   - Newline-separated commands — grep operates per-line; caught by bash-guard
#
# These gaps are accepted risk because the deny list is one layer in a
# defense-in-depth stack: allow list, headless fail-closed, bash-guard,
# pre-commit-gates, and write-guard all provide additional coverage.
_PERMISSION_DENY_BASH=(
  # --- Tier 1: Catastrophic — enhanced anchor with env-var prefix ---
  '(^|[;&|] *)([A-Za-z_][A-Za-z0-9_]*=[^ ]* )*rm -rf'
  '(^|[;&|] *)([A-Za-z_][A-Za-z0-9_]*=[^ ]* )*rm -fr'
  '(^|[;&|] *)([A-Za-z_][A-Za-z0-9_]*=[^ ]* )*sudo '
  '(^|[;&|] *)([A-Za-z_][A-Za-z0-9_]*=[^ ]* )*kill -9'

  # Spawning claude subprocess bypasses session governance (Decision 0027)
  '(^|[;&|] *)([A-Za-z_][A-Za-z0-9_]*=[^ ]* )*claude( |$)'

  # --- Tier 2: Standard — basic command-position anchor ---
  '(^|[;&|] *)dd '
  '(^|[;&|] *)chmod 777'
  '(^|[;&|] *)mkfs'
  '(^|[;&|] *)fdisk'
  '(^|[;&|] *)mkswap'
  '(^|[;&|] *)eval '

  # --- Supplementary: context-specific anchors ---
  '(^|[;&|] *)xargs .*kill -9'
)

# --- Outbound network commands to non-localhost ---
# curl/wget to external URLs are denied; localhost is allowed.
_PERMISSION_DENY_NETWORK_CMD=(
  'curl'
  'wget'
)

# --- Read-only agent types permitted in no-write sessions ---
# These agent types have no write tools (Edit, Write, Bash) or are read-only
# by definition. When new read-only agent types are added to .claude/agents/,
# they must also be added here (maintenance obligation — Decision 0027).
_PERMISSION_READONLY_AGENTS=(
  architect
  critic
  exploration
  pragmatist
  pm-advisor
  analytics
  ux-strategist
  accessibility
  performance-engineer
  data-strategist
  security-analyst
  user-review-tier-1
  user-review-tier-2
  user-review-tier-3
  Explore
  Plan
  dev-orchestrator
  auditor
  claude-code-guide
  security-hacker
)

# --- Check if an agent subagent_type is in the read-only allowlist ---
# Arguments: $1 = subagent_type
# Returns: 0 if read-only (allowed in no-write sessions), 1 if not
is_readonly_agent() {
  local agent_type="$1"
  local a
  for a in "${_PERMISSION_READONLY_AGENTS[@]}"; do
    if [ "$agent_type" = "$a" ]; then
      return 0
    fi
  done
  return 1
}

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
      # Exemption: automation runner legitimately spawns claude (Decision 0027)
      case "$pat" in
        *'claude('*)
          if [ "${CLAUDE_HEADLESS:-0}" = "1" ]; then
            continue
          fi
          _DENY_REASON="spawning claude subprocess bypasses session governance"
          ;;
        *)
          _DENY_REASON="$pat"
          ;;
      esac
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
