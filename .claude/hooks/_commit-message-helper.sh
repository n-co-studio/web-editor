#!/usr/bin/env bash
# Commit-message text resolution and trailer extraction for pre-commit-gates.sh.
#
# WHY THIS EXISTS
#
# The gate hook runs at PreToolUse and sees the Bash command string, not the
# commit message. For `git commit -m "..."` the two coincide — the message text
# is physically in the command — and three gates grepped that string directly:
# A1's `Decisions:` (blocking), `Changes: EC-` and `Overrides:` (advisory).
#
# For `git commit -F <file>` they do not coincide. The trailer sits in the file,
# the grep never saw it, and A1 blocked commits whose trailer was correct. The
# template's own gate-conformance suite only ever exercised `-m` (cases C7/C8),
# which is why the fault survived. Nothing in the prompts prescribes an
# invocation form, and a multi-line message naturally wants `-F`, so agents
# reached for the one form the gate could not read.
#
# WHY ADDITIVE, NOT A PARSER
#
# The obvious fix — parse git's flags and resolve the message properly — was
# reviewed and rejected. Reimplementing git's flag grammar in bash means `-am`,
# `-aF`, `--message=` and heredocs all become parser cases, and a miss on any of
# them silently breaks a form that works today. Resolving `-C`/`--amend` would
# need `git log -1 --format=%B`, which exits non-zero in a repo with no commits
# and, under `set -euo pipefail`, would abort the whole gate chain — the exact
# failure class t-0049 exists to prevent, self-inflicted inside its own fix.
#
# So this is strictly additive: the caller searches the command string AND, when
# a `-F` path is readable, that file's contents. The searched text is a superset
# of today's, so no working invocation can regress and no new evasion path
# opens — the floor is current behaviour.
#
# KNOWN LIMITS, deliberately not papered over
#
# PreToolUse fires before the command runs, so `build-msg > m.txt && git commit
# -F m.txt` presents a file that does not exist yet. That is unreadable in
# principle at this layer, not an implementation gap. Such a commit is treated
# exactly as it is today: only the command string is searched.
#
# A quoted path containing spaces (`-F "my file.txt"`) is captured only up to
# the first space, fails the readability test, and falls back the same way.
# Safe, but inert — worth knowing before assuming such a commit was checked.
#
# See t-0053.

# Echo the text the trailer checks should search: the command string, plus the
# contents of a `-F`/`--file` argument when one is present and readable.
#
# Every step is guarded. This is sourced into a `set -euo pipefail` script, and
# a grep that matches nothing exits 1 — which is how an unrelated gate chain was
# once killed wholesale (t-0049).
resolve_commit_text() {
  local cmd="$1"
  printf '%s\n' "$cmd"

  local path=""

  # Only look for a message FILE when the command carries no inline message.
  #
  # This is the anchor. A naive search for a `-F <token>` shape anywhere in the
  # command string also matches text *inside* a quoted message — `git commit -m
  # "see -F notes"` would read a file named `notes` and let its contents satisfy
  # a trailer gate. That is an evasion path, not a superset of old behaviour.
  #
  # git itself refuses to combine them ("fatal: cannot combine -m with -F"), so
  # when an inline message is present any `-F`-shaped substring belongs to that
  # message and must be ignored. Conservative in the odd compound case
  # (`... -m x ; git commit -F y`): the file is skipped and the command string
  # alone is searched, which is exactly the pre-existing behaviour.
  # Match ANY short-option cluster containing `m` — `-m`, `-am`, `-sm`, `-qm`,
  # `-ma`, with or without a space before the text — plus the `--message` long
  # form. An earlier version enumerated `-m`/`-am`/`-ma` with trailing spaces and
  # review showed `git commit -sm "see -F notes"` walked straight through it: a
  # finite list of surface forms is not the general rule this needs to be.
  #
  # `-[A-Za-z]*m` cannot match a long option: after `--` the next character is
  # `-`, not a letter, and the cluster must start at a word boundary.
  # `--message` is matched by PREFIX, not as a literal. git's option parser
  # accepts any unambiguous abbreviation, and `--m`, `--me`, `--mes` and
  # `--mess` were all verified to work against real git — a literal `--message`
  # check misses every one of them, which is the long-option twin of the
  # short-cluster enumeration this already replaced. No other `git commit` long
  # option begins with `m`, so `--m` is exactly the unambiguous set.
  if printf '%s' "$cmd" | grep -qE '(^|[[:space:]])-[A-Za-z]*m' \
     || printf '%s' "$cmd" | grep -qE '(^|[[:space:]])--m'; then
    return 0
  fi

  # `-F <path>` / `--file <path>` (space-separated), then `--file=<path>`.
  # sed, not bash regex: BSD and GNU agree on this form, and macOS ships
  # bash 3.2.57 where some [[ =~ ]] captures behave differently.
  # `-F`, `--file`, and `--fil` — the shortest unambiguous abbreviation git
  # accepts (`--fi` and `--f` are rejected outright as ambiguous with
  # `--fixup`, verified against real git, so there is nothing shorter to match).
  #
  # Spelled out rather than written as `[Ff](ile|il)?`: that form also accepted
  # bare `--f` and lowercase `-f`, neither of which git has, so the code claimed
  # a narrower contract than it kept.
  # sed -E: BSD basic regex has no \| alternation, and both BSD and GNU sed
  # accept -E for extended. Using BRE here silently matched nothing on macOS.
  path=$(printf '%s' "$cmd" \
    | sed -nE 's/.*[[:space:]](-F|--file|--fil)[[:space:]]+([^[:space:]]+).*/\2/p' \
    | head -1 || true)
  if [ -z "$path" ]; then
    path=$(printf '%s' "$cmd" \
      | sed -nE 's/.*--fil(e)?=([^[:space:]]+).*/\2/p' \
      | head -1 || true)
  fi

  [ -n "$path" ] || return 0

  # `-F -` reads the message from stdin: nothing to read here, by construction.
  [ "$path" = "-" ] && return 0

  # Strip one layer of surrounding quotes, as they appear in the command string.
  path="${path%\"}"; path="${path#\"}"
  path="${path%\'}"; path="${path#\'}"

  # Not yet written (built by the same command line), a directory, or
  # unreadable: fall back to the command string alone, which is today's
  # behaviour. Never an error.
  [ -f "$path" ] && [ -r "$path" ] || return 0

  cat "$path" 2>/dev/null || true
}

# Echo the value of a `<Key>:` trailer found in TEXT, or nothing.
# Replaces three near-identical greps that each had to remember `|| true`.
extract_trailer() {
  local text="$1" key="$2"
  printf '%s' "$text" | grep -oE "${key}:[^\\n]+" || true
}
