#!/usr/bin/env bash
# _governance-helper.sh — which governance modules this repo has switched off.
# Decision t-0085. Sourced (after _analytics-helper.sh, for _REPO_OS_ROOT) by
# pretooluse-permission.sh and hvst-failure-tracker.sh.
#
# module_is_off <module id>
#   True only when all three hold:
#   - .claude/.automation/governance-overrides.json is valid JSON and says
#     "off" for the id;
#   - .claude/.automation/governance-kit.json is valid JSON and marks exactly
#     one module with that id turn_off_safe true;
#   - the id is not on the never-off list below.
#   Anything else is false, including a missing or unreadable file or no jq:
#   the module stays on. Bash 3.2 compatible.
#
# The never-off list lives here, in a hook, not in the kit. The kit and the
# override file are data a repo can edit, so a hand-edited turn_off_safe must
# never be able to switch off a gate-required agent or a guard hook.

_gov_never_off() {
  case "$1" in
    agent.critic|agent.qa-verifier|agent.reviewer|agent.security-privacy|agent.pragmatist|agent.builder|agent.orchestrator|agent.dev-orchestrator) return 0 ;;
    hook.hvst-failure-tracker) return 1 ;;
    hook.*) return 0 ;;
  esac
  return 1
}

module_is_off() {
  local id="${1:-}" root="${_REPO_OS_ROOT:-}"
  [ -n "$id" ] && [ -n "$root" ] || return 1
  _gov_never_off "$id" && return 1
  local ov="$root/.claude/.automation/governance-overrides.json"
  local kit="$root/.claude/.automation/governance-kit.json"
  [ -f "$ov" ] && [ -f "$kit" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e --arg id "$id" '(.modules // {})[$id] == "off"' "$ov" >/dev/null 2>&1 || return 1
  jq -e --arg id "$id" '[(.modules // [])[] | select(.id == $id and .turn_off_safe == true)] | length == 1' \
    "$kit" >/dev/null 2>&1 || return 1
  return 0
}
