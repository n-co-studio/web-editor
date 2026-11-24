# Decision t-0088 — Branch names at creation, commits the gate can't see, and auto mode

**Status:** Accepted
**Date:** 2026-11-23
**Files:** `.claude/hooks/_branch-name-helper.sh`, `.claude/hooks/bash-guard.sh`,
`.claude/hooks/pre-push-gates.sh`, `.claude/.automation/queue-cli.sh`, `AI.md`,
`docs/ai/workflow.md`, `docs/ai/prompts/prompt-b-product-build.md`.

## Triggers

- type: file
- path: `\.claude/hooks/_branch-name-helper\.sh`
- keywords: `branch_name_valid, branch_name_suggest, branch_created_name, git_commit_bypass`

## Context

The operator closed three gaps found after t-0086 and t-0087.

- **Branch names were checked only at push.** B1 in the push gate rejected any name outside
  `feature/ fix/ hotfix/ release/ experiment/ live-editor-N`, but nothing checked when a branch
  was made. The agent used `feat/` for a whole series of units unnoticed, because its pushes
  went to main. bash-guard's governance advisories, which key on the valid prefixes, never ran
  on those branches either. The operator asked for a refusal at creation that suggests the right
  prefix.
- **Some git commands commit without the commit gate seeing the content.** The gate checks the
  staged diff, which is empty before `git merge`, `cherry-pick` or `revert` run. A merge of
  another branch therefore lands commits no gate has checked.
- **A drafting session could choose auto mode for its own draft (R4 follow-up).** It used
  `queue-cli edit <id> auto_mode true`. Approval was still the operator's, but whether the run
  skips review should be too.

## Decision

1. **One list of branch names.** It lives in `.claude/hooks/_branch-name-helper.sh` and is
   used by both bash-guard and B1.
   - `branch_name_suggest` keeps the rest of the name and maps the first segment by five rules:
     - `feat*` → `feature/`
     - `bug*` and `fix*` → `fix/`
     - `hot*` → `hotfix/`
     - `spike`, `poc`, `proto*`, `exp*` and `try` → `experiment/`
     - `rel*` → `release/`
   - Anything else becomes `feature/<whole name>`.
   - B1 prints the suggestion as a `git branch -m` command.
2. **bash-guard checks a branch when it is created.**
   - It recognises the new name through git's global options (`git_invokes`, t-0087) in these
     forms: `checkout -b/-B/--orphan`, `switch -c/-C/--create/--force-create`,
     `worktree add -b/-B`, and plain `git branch <name>` when the name is its only argument.
   - It refuses an invalid name with `NEXT: use <suggestion>`.
   - Switching to an existing branch is not checked.
   - Override: `REPO_OS_SKIP_BRANCH_NAME=1`.
3. **On a work branch, bash-guard refuses a merge, cherry-pick or revert that makes its own
   commit.** That includes `--continue`. The refusal points to `--no-commit`
   (`--no-commit --no-ff` for a merge), after which the result is committed normally and gated.
   - **Allowed:**
     - `--no-commit`, `-n` and `--squash`;
     - `--abort`, `--quit` and `--skip`;
     - a merge of exactly `main` or `origin/main`;
     - `taskgroup-merge` sessions, whose job is merging brief branches.
   - **On main:** Gate 7's merge guard and the close sequence are unchanged.
   - Override: `REPO_OS_SKIP_MERGE_GUARD=1`, the existing merge-guard override.
4. **`queue-cli edit <id> auto_mode` is refused in an agent session** (`CLAUDECODE=1`). The
   message points at `queue-cli approve <id> --mode auto|review`. The operator's terminal,
   `approve --mode`, and Prompt T's in-session "Approve & queue" choice are unchanged.

## Consequences

- Agents get a precise refusal at the moment they pick a bad name, not a failed push later.
- The only way to bring another branch's content into a work branch is now through a gated
  commit.
- Tests:
  - `test-branch-names.sh` (125 cases: names, suggestions, the creation parser, the
    commit-bypass detector).
  - layer3 t-0088 cases, including that the commit after a `--no-commit` merge goes through the
    commit gate.
  - `test-taskdef-draft.sh` for auto mode.
  - gate-conformance C11n.

## Known limits

- **Hidden git commands:** commands the text matcher cannot see (t-0087's limits) are not seen
  here either.
- **Renames, `git branch` with flags, and names built from a variable** (`git checkout -b "$b"`)
  are not checked at creation. B1 still checks at push.
- **Quoted prose is ignored; quoted commands are not.** Quoted text containing a space, such as
  a commit message or an `echo` that mentions `git merge`, is not read as a command. A string
  that runs is read: the argument of `sh -c` / `bash -c` / `zsh -c`, and a quoted `$( )` or
  backtick. Unbalanced quotes are not collapsed. A heredoc line such as `don't git merge x` is
  read as the command and refused, which errs toward refusing.
- **Forms not recognised:**
  - attached flags (`git checkout -bname`);
  - `$'…'` strings;
  - other wrappers that hide the words (`eval`, variables).
- **A failed switch:** `git checkout main || git merge x` counts the merge as on main even if the
  checkout fails.
- **Merges after checking out main:** a command that checks out `main` first
  (`git checkout main && git merge …`, the documented non-worktree close) is left to the
  merge-on-main rules.
- **The runner's own branches:** branches the runner creates from its own shell
  (`branch-manager.sh`) are not checked at creation, only by B1 at push.
- **Commits still made without a gate:**
  - merging `main` (its content was gated on main);
  - `git pull`;
  - `git rebase`;
  - `git am`.
- **Moving a branch without a commit:** `git reset --hard <other>`, `git checkout -B <work> <other>`,
  `git branch -f`, `git update-ref` and `git commit-tree` put other commits on a branch with no
  commit gate. They are not refused: `reset --hard` has ordinary uses.
- **Creation forms not parsed:** `git branch <name> <start>`, `git branch -c`, and
  `git worktree add <path>` without `-b` (git names the branch after the directory). B1 checks
  them at push.
- **`--auto-approve`:** `queue-cli add --auto-approve` and `follow-up --auto-approve` can still
  set auto mode from an agent session once the operator has approved the plan in-session. Prompt
  T uses them for the operator's "Approve & queue (auto)" choice. Only `edit` is refused.
- **How a command is read:** each part of it is read in order, with comments dropped. A merge
  counts as "on main" only after the same command has switched to `main`.
- **The auto-mode guard keys on `CLAUDECODE`.** An agent could clear it on purpose. Like the other
  guards, it stops accidents, not an adversary.
