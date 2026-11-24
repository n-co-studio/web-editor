#!/usr/bin/env bash
# _branch-name-helper.sh — the one list of valid branch names, and what a bad
# name should have been (Decision t-0088).
#
# bash-guard checks a name when an agent creates the branch; the push gate's
# B1 checks the branch being pushed. Both read the list here, so they cannot
# disagree. Valid: feature/<x>, fix/<x>, hotfix/<x>, release/<x>,
# experiment/<x>, live-editor-N (digits). main is not a work branch name.
#
# Bash 3.2, builtins only (no external commands).

BRANCH_NAME_PREFIXES="feature/, fix/, hotfix/, release/, experiment/, live-editor-N (digits only)"

# branch_name_valid <name> — 0 when the name follows the convention.
branch_name_valid() {
  local name="${1:-}" n
  case "$name" in
    feature/?*|fix/?*|hotfix/?*|release/?*|experiment/?*) return 0 ;;
    live-editor-?*)
      n="${name#live-editor-}"
      case "$n" in *[!0-9]*) return 1 ;; esac
      return 0 ;;
  esac
  return 1
}

# branch_name_suggest <name> — prints the valid name to use instead. The first
# path segment decides the category and the rest is kept; a name with no
# recognised category keeps all of itself under feature/.
branch_name_suggest() {
  local name="${1:-}" first="" rest
  case "$name" in
    */*) first="${name%%/*}"; rest="${name#*/}" ;;
    *) rest="$name" ;;
  esac
  [ -n "$rest" ] || rest="work"
  case "$first" in
    feature|fix|hotfix|release|experiment) printf '%s/%s\n' "$first" "$rest" ;;
    feat*) printf 'feature/%s\n' "$rest" ;;
    bug*|fix*) printf 'fix/%s\n' "$rest" ;;
    hot*) printf 'hotfix/%s\n' "$rest" ;;
    spike|poc|proto*|exp*|try) printf 'experiment/%s\n' "$rest" ;;
    rel*) printf 'release/%s\n' "$rest" ;;
    *) printf 'feature/%s\n' "${name:-work}" ;;
  esac
}

# --- Reading a command (Decision t-0088) ---
# _bnh_parts <command text> prints the command's parts, one per line, in order:
# a backslash-newline is joined, quoted text containing a space becomes Q (so
# a -m "message", an echo or a heredoc line that mentions git is not read as a
# command), # comments are dropped, and ; & | ( ) a backtick and newlines
# separate parts. Quotes around a single word are kept for the parsers.
_bnh_parts() {
  local t="${1:-}" re nl=$'\n'
  t="${t//\\${nl}/ }"
  # Quoted text that runs is unwrapped first, so its commands are still read:
  # the string after sh -c / bash -c / zsh -c, and a quoted $( ) or backtick.
  re="((^|[[:space:];&|(])(ba|z)?sh[[:blank:]]+-c[[:blank:]]+)(\"([^\"]*)\"|'([^']*)')"
  while [[ "$t" =~ $re ]]; do t="${t/"${BASH_REMATCH[4]}"/ ${BASH_REMATCH[5]}${BASH_REMATCH[6]} }"; done
  re="(\"([^\"]*(\\\$\\(|\`)[^\"]*)\")"
  while [[ "$t" =~ $re ]]; do t="${t/"${BASH_REMATCH[1]}"/ ${BASH_REMATCH[2]} }"; done
  re="(\"[^\"]*[[:space:]][^\"]*\"|'[^']*[[:space:]][^']*')"
  while [[ "$t" =~ $re ]]; do t="${t/"${BASH_REMATCH[1]}"/Q}"; done
  re="(^|[[:space:]])(#[^${nl}]*)"
  while [[ "$t" =~ $re ]]; do t="${t/"${BASH_REMATCH[2]}"/}"; done
  t="${t//;/$nl}"; t="${t//&/$nl}"; t="${t//|/$nl}"
  t="${t//(/$nl}"; t="${t//)/$nl}"; t="${t//\`/$nl}"
  printf '%s\n' "$t"
}

# The start of a git invocation within one part, through git's global options
# (_GCH_OPT from _git-command-helper.sh, which must be sourced first).
_bnh_lead() {
  printf '%s' "(^|[[:space:]/\"'\\\\])git[\"']?([[:space:]]+${_GCH_OPT})*[[:space:]]+[\"']?"
}

# branch_created_name <command text> — prints every branch the command would
# create, one per line, in order:
#   checkout [flags] -b|-B|--orphan <name>    switch [flags] -c|-C|--create|--force-create <name>
#   worktree add [args] -b|-B <name>           branch <name>   (the name alone, no flags)
# Anything else, including git branch with flags or a start point, prints nothing.
_BNH_NAME="[\"']?([^[:space:]\"'-][^[:space:]\"']*)[\"']?"
_BNH_FLAGS="([[:blank:]]+-[^[:space:]]+)*"
branch_created_name() {
  local part lead re
  [ -n "${1:-}" ] && [ -n "${_GCH_OPT:-}" ] || return 0
  lead="$(_bnh_lead)"
  while IFS= read -r part; do
    [ -n "$part" ] || continue
    re="${lead}checkout[\"']?${_BNH_FLAGS}[[:blank:]]+(-b|-B|--orphan)[[:blank:]]+${_BNH_NAME}"
    if [[ "$part" =~ $re ]]; then printf '%s\n' "${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"; continue; fi
    re="${lead}switch[\"']?${_BNH_FLAGS}[[:blank:]]+(-c|-C|--create|--force-create)[[:blank:]=]+${_BNH_NAME}"
    if [[ "$part" =~ $re ]]; then printf '%s\n' "${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"; continue; fi
    # worktree add takes its path before or after -b: allow any arguments first.
    re="${lead}worktree[\"']?[[:blank:]]+add([[:blank:]]+[^[:space:]]+)*[[:blank:]]+(-b|-B)[[:blank:]]+${_BNH_NAME}"
    if [[ "$part" =~ $re ]]; then printf '%s\n' "${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"; continue; fi
    re="${lead}branch[\"']?[[:blank:]]+${_BNH_NAME}[[:blank:]]*$"
    if [[ "$part" =~ $re ]]; then printf '%s\n' "${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"; fi
  done <<EOF
$(_bnh_parts "$1")
EOF
  return 0
}

# git_commit_bypass <command text> — prints merge, cherry-pick or revert when
# the text runs one that would make its own commit, so the commit gate never
# sees the content (it checks a staged diff, empty before these run). Prints
# nothing for the forms that leave the result for a normal commit or make no
# commit: --no-commit / -n, --squash, --abort, --quit, --skip, and a merge of
# exactly main or origin/main (the base branch, gated already). --continue
# makes the commit, so it counts. (_git-command-helper.sh must be sourced.)
#
# Every part of the command is read, in order (_bnh_parts), so a harmless
# first merge cannot hide a committing second one, and a comment or a quoted
# message cannot supply the flag. A merge after the same command has switched
# to main (`git checkout main && git merge --ff-only x`, the documented
# non-worktree close) is left to bash-guard's merge-on-main rules.
git_commit_bypass() {
  local part lead re args sub on_main=false
  [ -n "${1:-}" ] && [ -n "${_GCH_OPT:-}" ] || return 0
  lead="$(_bnh_lead)"
  while IFS= read -r part; do
    [ -n "$part" ] || continue
    re="${lead}(checkout|switch)[\"']?([[:blank:]].*)?$"
    if [[ "$part" =~ $re ]]; then
      args=" ${BASH_REMATCH[${#BASH_REMATCH[@]}-1]} "
      args="${args//\"/}"; args="${args//\'/}"
      case "$args" in
        *" -- "*) ;;   # restores files; the branch does not change
        *) if [[ "$args" =~ ^([[:blank:]]+-[^[:space:]]+)*[[:blank:]]+main[[:blank:]]*$ ]]; then
             on_main=true
           else
             on_main=false
           fi ;;
      esac
      continue
    fi
    for sub in merge cherry-pick revert; do
      re="${lead}${sub}[\"']?([[:blank:]].*)?$"
      [[ "$part" =~ $re ]] || continue
      [ "$on_main" = false ] || break
      args=" ${BASH_REMATCH[${#BASH_REMATCH[@]}-1]} "
      args="${args//\"/}"; args="${args//\'/}"
      case "$args" in
        *" --no-commit "*|*" --squash "*|*" --abort "*|*" --quit "*|*" --skip "*) break ;;
      esac
      if [ "$sub" = merge ]; then
        re="^([[:blank:]]+(-[^[:space:]]+|Q))*[[:blank:]]+(origin/)?main([[:blank:]]+(-[^[:space:]]+|Q))*[[:blank:]]*$"
      else
        re="[[:blank:]]-n[[:blank:]]"
      fi
      if [[ "$args" =~ $re ]]; then break; fi
      printf '%s\n' "$sub"
      return 0
    done
  done <<EOF
$(_bnh_parts "$1")
EOF
  return 0
}
