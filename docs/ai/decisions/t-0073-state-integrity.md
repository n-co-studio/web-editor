# Decision t-0073 — An agent command cannot change state files or approve its own plan

**Status:** Accepted
**Date:** 2026-11-18
**Amends:** Decision t-0071 §5 (widens the removal check to a listed set of mutations); closes
known-issues R55 and R56 (with the residual below). `.claude/hooks/bash-guard.sh`,
`.claude/hooks/pre-commit-gates.sh`.

## Triggers

- type: file
- path: `\.claude/hooks/_headless-plan-approve\.sh`
- keywords: `_bg_is_state_mutation, _bg_runs_headless_approve, state_mutation_protected, headless_approve_refused`

## Context

The gates read state files under `.claude/.state/`: whether they exist (t-0071's BLOCKED sign-offs
and discard markers), what they say (`GATE_RESULT`, `contract_sha`), and one of them — the recover
signal — switches every state gate off. The guards refused write targets (`>`, `tee`, `cp`/`mv`
destinations — but only once a command got past bash-guard's early exits, which a bare `cp` did
not) and, since t-0071, delete/move verbs. Reviews of t-0072 found three other routes, all
passing both guards with nothing logged except the first:

- **R55** — `touch .claude/.state/.recover-signal`: the next guarded call skips every state gate.
  Two gate messages told the agent to do exactly this when `plan-approval.sh` misfired.
- **R56** — `sed -i` / `perl -i` on a state file: a BLOCKED `security-signed` becomes APPROVED, or
  `contract_sha` is rewritten to match a widened contract.
- **R56** — sourcing `_headless-plan-approve.sh` from an interactive agent command writes
  `plan-approved`: the agent approves its own plan.

## Decision

1. **The listed mutations of a state path are refused.** bash-guard's textual check refuses,
   besides t-0071's delete/move verbs (anywhere in the command):
   - `dd` whose `of=` is a state path;
   - in a simple command that names a state path, or anywhere after a `cd`/`pushd` into `.state`:
     the words `touch`, `ln`, `install`, `ed`, `ex`, `mkdir`, `chmod`, `cp`, `rsync`, `sponge`, and
     in-place editors (`sed`/`gsed -i` in any spelling, `perl` with `i` in a flag cluster, `-0pi`
     too, `yq -i`). A word
     anywhere in the simple command counts, so wrappers do not hide it (`sudo -u x`, `env A=1`,
     `nice`, `timeout 5`, `bash -c '…'`, `find -exec`, `if … then`, `{ }`) — **unless the command
     word is a read tool** (`grep`, `cat`, `ls`, `head`, `tail`, `wc`, `diff`, `jq`, `echo`,
     `printf`, `git`, `test`, `bash -n`, …), so `grep install .claude/.state/log` is a read;
   - `xargs` running one of those words when a state path appears anywhere (it arrives by pipe),
     and a command that names a state path and pipes into a shell (`echo touch … | sh`);
   - after a `cd`/`pushd` into `.state`, a redirect (other than to `/dev/null` or `N>&M`), `tee` or
     `dd of=` — whatever the command word, read tools included (relative targets land there).
   Simple commands are split twice and both sets checked: at newline `;` `&` `|` outside any
   `$(…)` or backtick substitution — so a built path stays with its verb
   (`touch "$(cd .. && pwd)/.claude/.state/x"`) — and also at `(` and backtick, so
   `echo $(touch …)` is its own command. `>&` is kept whole. Each split is done twice — as
   written, and with every backslash-newline joined — so a continuation (`touch \⏎<path>`) is
   seen as one command, and a newline that is a real separator (after `\\`, or ending a `#`
   comment) is still seen as a separator in the unjoined reading. Both readings are checked; an
   extra reading can only refuse more. Only the raw payload
   (the early exits run before it is parsed) is decoded, with `jq` — a newline sent as `\n` splits
   like one, and surrounding JSON does not glue onto the last word; an already-decoded command is
   never decoded again, so a brace group carrying a fake `"command":` marker hides nothing. Every
   `grep` reads a here-string, so a long command cannot make a `pipefail` pipeline fail open.
   `state_mutation_protected`, GATE-FINAL, override `REPO_OS_RECOVER=1`.
2. **The headless approval helper is not for agent commands.** Refused: a simple command naming it
   whose command word is not a read tool (`source`, `.`, a shell, direct execution, `cp`/`ln` of
   it, …), and a command naming it that also runs a shell, `source`, `eval` or `exec` anywhere
   (`cat … | bash`, `source <(cat …)`, `bash < …`). `headless_approve_refused`. No code, prompt or
   headless allowlist entry runs it, so only an interactive agent could; reading, grepping, diffing,
   staging and `bash -n` of the file stay allowed. (A check inside the helper on `CLAUDE_HEADLESS`
   was rejected: the agent controls that environment — Pragmatist.)
3. **The recover signal is the operator's.** The two plan-approval misfire messages now say to
   re-ask the question and, failing that, to ask the operator to recover from a terminal.

## Known limits

- **Text-based, as t-0071.** An interpreter (`python3 -c`, `node -e`, `awk` with `system`), a path
  or helper name built in a variable or split by quotes, `eval`, `xargs` with a built command, or a
  sourced shell function doing the I/O is not seen (R2's class). This raises the cost of the casual
  and accidental route; it is not a boundary against a determined agent. Only OS-level isolation or
  file permissions on `.claude/.state/` would be one — out of scope.
- **Text that mentions both is refused.** A command whose text names a mutation verb and a state
  path in the same simple command — a heredoc, a commit message, a `grep` for the phrase — is
  refused; write text with the Write tool and commit with `-F`.
- **Over-blocks it accepts:** `ln`/`cp`/`rsync` with a state path as the *source* (a read); after
  a `cd` into `.state`, any `>` in the command other than to `/dev/null` or `N>&M` — even one
  inside quotes (`jq '.a > 1'`) or to another directory (`> /tmp/out`), and in segments before
  the `cd`; a state read piped into `bash -n`; and a command naming the helper that also runs a
  shell for something else (`vim` on the helper too).
- **Not seen (security reviews, recorded):** a verb split by quotes (`to"uch"`, `tou\ch`) or held
  in a variable (`T=touch; $T …`); `sed`'s `w` command (`sed -n 'w <state-file>'`); verbs outside
  the list — `awk -i inplace`, `chown`, `curl -o`, `patch`, `git apply`, `sort -o`,
  `find -fprint`, `tar -C`, `unzip -d`, `vi -es`; a read tool doing the write
  (`git checkout -- .claude/.state`, `git -c alias.x='!…'`, `git diff --output=…`); the helper by
  a glob (`_headless-*`) or copied under another name and run later; a two-step `cd`
  (`cd .claude; cd .state`) or `CDPATH`. The read-tool list is a trust list: a read tool whose
  options can write is not inspected (`yq` was removed from it for `-i`).
- **Prose is parsed as commands.** A heredoc body is split into lines and each checked, so a
  session-log line that pairs a listed word with a `.state` path is refused — write such text
  with the Write tool. Each simple command costs a few `grep`s, paid only when the command names
  `.state` or the helper.
- **The override is still `REPO_OS_RECOVER=1`**, which an agent's environment prefix does not reach.
