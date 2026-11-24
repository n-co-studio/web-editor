# Decision t-0087 — The git gates recognise a commit or push however git is called

**Status:** Accepted
**Date:** 2026-11-23
**Files:** `.claude/hooks/_git-command-helper.sh`, `.claude/hooks/pre-commit-gates.sh`,
`.claude/hooks/pre-push-gates.sh`, `.claude/hooks/agent-git-guard.sh`, `AI.md`.

## Triggers

- type: file
- path: `\.claude/hooks/_git-command-helper\.sh|\.claude/hooks/agent-git-guard\.sh`
- keywords: `git_invokes, _git-command-helper`

## Context

Since the hooks moved to the `Bash` matcher, each git gate decides for itself whether a Bash
command is a commit or a push:

- **`pre-commit-gates.sh`** checked for the literal text `git commit`, and `pre-push-gates.sh`
  checked for `git push`. Anything else exited 0 at once. So `git -C /repo commit -F msg` ran no
  commit gate at all: no A1–A6, no secret scan, no phase check and no output. Both files' comments
  claimed `git -C . commit` matched, which was false.
- **`agent-git-guard.sh`** blocks commit and push for the Builder, QA and Security subagents, but
  only for a command that *starts* with `git commit|push`. `cd x && git commit` and
  `git -C . push` got through.

Found on 2026-11-23 while checking Decision t-0086's first real commit. The commit gate's record
was missing because the gate never ran. The agent had been committing with `git -C`, so its R8
commit (33d90f4), its t-0086 commit (6efde0c) and its pushes to main were never checked by the
hooks, only by the QA agent's manual check. The analytics log has no `pre-commit-gates` event
for either branch.

## Decision

1. **One shared rule.** `git_invokes <subcommand> <text>` in `.claude/hooks/_git-command-helper.sh`
   is true when the text runs git with that subcommand. It is bash 3.2 `[[ =~ ]]` with no forks.
   - **Where the invocation may sit:** at the start, or after `;`, `&`, `|`, `(`, `$(`, a
     backtick, whitespace or `/`. That covers `cd x && git …`, `env A=1 git …` and
     `/usr/bin/git …`.
   - **What may come between `git` and the subcommand:** only git's global options. These are
     `-C <path>`, `-c <name=value>`, `--git-dir` / `--work-tree` / `--namespace` /
     `--config-env` / `--super-prefix` (with `=` or a separate argument), any other
     `--long[=value]`, and single-letter flags such as `-P`. An argument may mix quoted and
     unquoted parts (`user.name="A B"`), or be a `$( … )` without nested parentheses.
   - **Also recognised (added after the Critic's review):**
     - `git` inside quotes or after a backslash: `sh -c 'git -C . commit'`, `"git" commit`,
       `\git commit`, `$(which git) commit`;
     - a backslash-newline continuation;
     - a subcommand followed directly by `>` or `<`.
   - **Also recognised (added after the Reviewer's and Security's reviews):**
     - a quoted subcommand (`git "commit"`);
     - backslash-escaped characters (`-C my\ dir`) and backticks (`` -C `pwd` ``) in an argument;
     - an alias defined in the same command (`git -c alias.ci=commit ci`,
       `git config alias.ci commit`). Defining one counts as running it.
   - **Why it is precise, not "git … commit anywhere":** at most phases the commit gate blocks
     what it matches. `git log --grep commit` and `git config commit.gpgsign` must not count,
     and nor must `git commit-tree`.
2. **The two gates** run when the old literal match or `git_invokes` matches. The old match is
   kept as a superset, so nothing checked before stops being checked, and `git commit` inside a
   `-m` message stays an accepted false positive.
3. **The subagent guard** blocks when either `git_invokes commit` or `git_invokes push` matches,
   anywhere in the command.
4. **If the helper file is missing**, each hook treats any text naming git and the subcommand as
   a match (fail closed).

## Consequences

- An agent's `git -C <path> commit` is now gated like `git commit`. That includes this repo's
  own agent, which used `git -C` for every commit this session.
- `test-git-command-match.sh` pins 105 cases, recognised and not, for commit and push. layer3 and
  gate-conformance check that the real hooks are reached through `git -C`, `cd &&` and `-c`
  forms.

## Known limits

- **`git -C <another repo>`:** the gate checks the repo the session runs in, not the `-C`
  target. That can block wrongly; it never waves through.
- **Not a boundary against deliberate obfuscation.** No text matcher can be one. This one
  catches the natural forms; these are not recognised:
  - aliases already in git config (`git ci`);
  - git or the subcommand built from variables, `eval` or concatenation (`$G commit`,
    `git co""mmit`, `git $(echo commit)`);
  - an option argument with nested `$( )`;
  - git run from a script, a Makefile, npm or another language.
- **Commands that make commits or push without those words** (`git merge`, `cherry-pick`,
  `revert`, `am`, `stash`, `subtree push`, `send-pack`, `commit-tree` with `update-ref`) are
  outside the gates, as they were before. `git rebase --exec` is caught only when its body
  contains the literal text.
- **The alias check is loose:** it is not tied to one git word, so rare harmless text with
  `git`, `alias.<x>` and the subcommand word (`git log --grep=alias.x commit`) runs the gate.
  That errs toward running it.
- **Subagent text can block:** unquoted `git push` text in a subagent's heredoc or `echo` is now
  blocked by the subagent guard. That errs toward blocking.
- **A directory named after the subcommand:** one directly after `-C` (`git -C commit status`)
  matches. That errs toward running the gate.
- **Commits made outside Claude Code:** the git `pre-commit` hook still covers only the secret
  scan, as before.
