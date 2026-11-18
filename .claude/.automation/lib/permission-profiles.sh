#!/usr/bin/env bash
# Permission profiles — tool restriction profiles for headless runner sessions.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0017 — Operator Automation Layer.
#
# Profiles:
#   build   — standard build sessions (blocks push, destructive git, outbound network; allows web tools)
#   audit   — read-only audit sessions (blocks edits, commits, push, web access, interactive prompts)
#   strict  — high-security lockdown (blocks all outbound network, package installs, web tools, push)
#   default — fallback (blocks push)
#
# AskUserQuestion is allowed in build, strict and default: in headless mode
# ask-user-deny.sh records the question and waits for an operator answer
# (Decision t-0064). A disallowed tool never reaches that hook. It stays
# blocked in audit and judge, which have no operator in the loop.
#
# Depends on (sourced by runner.sh before this file):
#   runner.sh sets REPO_ROOT

set -euo pipefail

# --- Get disallowed tools string for a permission profile ---
# Arguments:
#   $1 — profile name (build | audit | default)
# Output: --disallowedTools argument value on stdout
# Usage: claude -p --disallowedTools "$(get_disallowed_tools "build")"
get_disallowed_tools() {
  local profile="${1:-default}"
  case "$profile" in
    build)
      echo "Bash(git push:*),Bash(git reset --hard:*),Bash(git push --force:*),Bash(curl:*),Bash(wget:*),Bash(nc:*),Bash(ncat:*),Bash(netcat:*)"
      ;;
    audit)
      echo "Edit,Write,Bash(git commit:*),Bash(git push:*),Bash(curl:*),Bash(wget:*),WebSearch,WebFetch,AskUserQuestion"
      ;;
    judge)
      # Read-only scoring profile — blocks all writes, commits, pushes, and interactive prompts.
      # Permits read-only Bash (Grep, Read, Glob pass through as dedicated tools).
      # Decision t-0046 Amendment 1.
      echo "Edit,Write,Bash(git commit:*),Bash(git push:*),AskUserQuestion"
      ;;
    strict)
      # Maximum lockdown — blocks all outbound network, package installs, web tools.
      # Agent can only read, edit, commit, and run local commands.
      echo "Bash(curl:*),Bash(wget:*),Bash(nc:*),Bash(ncat:*),Bash(netcat:*),Bash(pip install:*),Bash(npm install:*),Bash(npx:*),WebSearch,WebFetch,Bash(git push:*),Bash(git reset --hard:*),Bash(git push --force:*)"
      ;;
    *)
      # Default: block push only
      echo "Bash(git push:*)"
      ;;
  esac
}
