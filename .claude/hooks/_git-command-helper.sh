#!/usr/bin/env bash
# _git-command-helper.sh — does a Bash command run a given git subcommand?
#
# Decision t-0087. The commit gate, the push gate and the subagent git guard
# used to look for the literal text "git commit" / "git push", so any global
# option in between (`git -C /repo commit`) skipped them without a word. This
# matches git's global options instead, so the three agree on what a commit or
# a push is.
#
# Matching is deliberately not "git ... commit anywhere": at most phases the
# commit gate BLOCKS what it matches, so `git log --grep commit` must not count.
# Only git's own global options may sit between `git` and the subcommand:
#   -C <path>, -c <name=value>, --git-dir / --work-tree / --namespace /
#   --config-env / --super-prefix (with = or a separate argument), any other
#   --long[=value], and single-letter flags such as -P.
# An argument may mix quoted and unquoted parts (user.name="A B"), contain
# backslash-escaped characters (my\ dir), or be a backtick or $( ... )
# substitution without nested parentheses. The subcommand may be quoted. The invocation may start the text or
# follow ; & | ( $( a backtick, whitespace, a / , a quote or a backslash (so
# `cd x && git ...`, `env A=1 git ...`, `/usr/bin/git ...`, `sh -c 'git ...'`
# and `\git ...` all count). A backslash-newline is read as a space.
#
# An alias defined in the same command (`git -c alias.ci=commit ci`) counts as
# running it, even when its value only mentions the word: that errs toward
# running the gate.
#
# Not recognised (Known limits in t-0087): aliases already in git config
# (`git ci`), git reached
# through a variable (`$G commit`), wrappers that never show the subcommand
# word, and a -C argument with nested $( ). A directory literally named like
# the subcommand right after -C (`git -C commit status`) matches: that errs
# toward running the gate, never toward skipping it.
#
# Bash 3.2, no forks.

# One option argument: unquoted characters, "..." and '...' pieces in any mix
# (user.name="A B"), and $( ... ) without nested parentheses.
_GCH_ARG="(([^[:space:];&|()\`\"'\$\\\\]|\\\\.|\"[^\"]*\"|'[^']*'|\\\$\\([^()]*\\)|\`[^\`]*\`|\\\$)+)"
_GCH_OPT="(-[Cc][[:space:]]+${_GCH_ARG}|--(git-dir|work-tree|namespace|config-env|super-prefix)(=${_GCH_ARG}|[[:space:]]+${_GCH_ARG})|--[A-Za-z][A-Za-z0-9-]*(=${_GCH_ARG})?|-[A-Za-z])"

# git_invokes <subcommand> <command text> — 0 when the text runs that subcommand.
# `git` may be preceded by a quote or a backslash (sh -c 'git ...', "git",
# \git) and followed by a closing quote or parenthesis ("git", $(which git)).
git_invokes() {
  local sub="${1:-}" text="${2:-}" re nl=$'\n'
  [ -n "$sub" ] && [ -n "$text" ] || return 1
  text="${text//\\${nl}/ }"   # a backslash-newline continues the line
  re="(^|[;&|(\`[:space:]/\"'\\\\])git[\"')]?([[:space:]]+${_GCH_OPT})*[[:space:]]+[\"']?${sub}([[:space:]]|$|[;&|)\`<>\"'])"
  [[ "$text" =~ $re ]] && return 0
  # An alias made on the spot (git -c alias.ci=commit ci, git config alias.ci
  # commit) hides the word from the match above; treat defining one as running it.
  case "$text" in *git*) ;; *) return 1 ;; esac
  re="alias\\.[^=[:space:]]+[=[:space:]]+([\"'][^\"']*|!?[^[:space:]]*)${sub}([[:space:]]|$|[;&|)\`\"'])"
  [[ "$text" =~ $re ]]
}
