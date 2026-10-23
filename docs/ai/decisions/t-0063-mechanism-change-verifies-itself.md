# Decision t-0063 — A change to the enforcement mechanism must be verified from outside itself

**Status:** Accepted
**Date:** 2026-10-22
**Amends:** the high-risk classification and commit-gate chain in `.claude/hooks/pre-commit-gates.sh`; adds `.claude/tools/verify-pristine.sh` and `.claude/hooks/_mechanism-helper.sh`. No queue-schema change.

## Triggers

- type: file
- path: `\.claude/hooks/pre-commit-gates\.sh`
- path: `\.claude/hooks/_mechanism-helper\.sh`
- path: `\.claude/tools/verify-pristine\.sh`
- keywords: `mechanism change, pristine evidence, verify-pristine, enforcement mechanism, high-risk exclusion, mechanism-change-detected, harness tampering`

## Context

The commit gate classifies a staged change as high-risk and demands reviewer and security sign-off. Its scan was fed by one filtered list that dropped test paths and everything under `.claude/` for both the path scan and the keyword scan. The reason for the exclusion is real — governance prose says "password" and "token" constantly — but applying it to the path scan meant a hook named `session-*.sh` was invisible to classification.

Separately, a change to hooks, the runner, queue libraries or their tests is checked by the harness it just changed. If `test-helpers.sh` is edited so its `ok` helper always passes, every suite is green, and the commit gate (which ran that same helper) agrees. Nothing in the chain looked at the change from outside.

## Decision

### 1. One definition of "the mechanism" (`_mechanism-helper.sh`)

Sourced by the gate and the tool, so they cannot disagree. `mech_is_path`: `.claude/hooks/**.sh`, `.claude/tools/*.sh`, `.claude/.automation/**.sh`, `.claude/settings.json`. Prose (agents, READMEs, decisions, specs) and product code are not mechanism. `mech_is_test_path`: layer and `test-*` files only. **Harness files (`test-helpers.sh`, `test-fixtures.sh`, `run-*.sh`, `sandbox-*.sh`) are not tests**: copying them into the pristine checkout would let a change carry its own altered harness into the place meant to be free of it.

### 2. `verify-pristine.sh` — the load-bearing piece

Resolves the merge base against `main`; makes a `git clone --local --no-checkout` of the object store in `/tmp/verify-pristine.XXXXXX`, checked out detached at the merge base with a `main` ref and no remote; copies in only the change's added or modified **test** files (from the **index** when the file is staged, so the run measures what the evidence is bound to); runs the named suites with `env -i` and an own watchdog (macOS has no `timeout`); reports `pass`/`fail` from TAP lines; removes the checkout in a trap. A suite that exits non-zero without a single `not ok` line crashed and is counted as one failure, never as silence. `harness_changed`, `code_changed` and `deleted` are printed so a reviewer sees what was NOT copied. A deleted mechanism file is a mechanism change like any other.

A **clone, not a linked worktree.** A linked worktree shares the common dir with the real repository, which reintroduces the real-repo-root hazard (R35, 2026-10-20). A clone has its own `.git`, so a suite that resolves "the repo root" resolves the clone. The tool never names the real state directory or the queue; a static test asserts that, and a before/after snapshot test asserts the real directories, HEAD, index and worktree list are unchanged, including when `--repo` is itself a linked worktree (the daemon's shape).

**A pristine run measures the change's tests against the code before the change.** New tests for new behaviour therefore fail there; that is "fail first", not a defect. What the run establishes is that the harness cannot be what makes them pass. For that reason the gate demands that the run **happened and is fresh**, not that it was green.

### 3. The marker and the gate — block, not advise

`pre-commit-gates.sh` writes `mechanism-change-detected` (same guarded shell-I/O idiom as `high-risk-detected`; removed in `_cleanup-helper.sh`) when the staged set intersects the mechanism, then requires staged evidence under `docs/ai/governance/pristine-evidence/`.

**Block, with a documented exit.** Advisory-only would be the behaviour that already failed: a warning the committing agent can read and proceed past is the same agent that wrote the change. The block is `GATE-RECOVERABLE` and names the command that clears it. It is not a sixth no-exit guard:

- `REPO_OS_SKIP_PRISTINE_GATE=1` — **interactive only.** Logged via `log_override`. In headless/auto mode (`IS_NO_REVIEW_BACKSTOP`) it is ignored and an escalation file is written, following A3.4's `SKIP_FUNC_CHECK` rule (t-0044 Amendment 1).
- `REPO_OS_RECOVER` / `.recover-signal` / experiment branches (`SKIP_STATE`) skip it like the other state gates. These are honoured in headless too; that is the existing recovery posture (t-0031), not something this gate adds or hardens.
- `outcome: tool_error` in the evidence **does not block**: a broken `verify-pristine.sh` must not wedge the repo. It warns loudly and writes an escalation. This is a weak point stated plainly: an agent can produce a `tool_error` record on demand (for example by naming a missing suite), so for a headless committer it is an escape that is recorded rather than prevented. The escalation and the session log are the compensating controls.

**Freshness.** Evidence is read from the **index** (a file only in the working tree does not count), must carry a `change_hash` equal to the hash of the staged mechanism files' index state, and a `merge_base` that is an ancestor of HEAD (any ancestor, not necessarily the current merge base — the hash, not the base, is what ties it to this change). The hashed state is `mode,blob` per path, or `deleted` when a staged deletion removed it, over `--no-renames --diff-filter=ACMDT`: so a deleted guard, a rename (a delete plus an add), a mode flip and a typechange (a script replaced by a symlink, git status `T`, mode `120000`) all move the hash. The hash and the evidence lookup are computed from the repository top level, so they do not depend on the committer's working directory. Editing a mechanism file after the run makes the evidence stale. A failing run is still fresh evidence and is shown to the committer.

**A run that executed nothing is not evidence.** Evidence whose `pass` and `fail` are both zero (or not numbers) is reported as `empty` and blocks, with the message to name an existing suite with `--suite`. A `tool_error` record is the one exception, since it is handled separately above.

The marker `mechanism-change-detected` is write-only, like `high-risk-detected`: the gate that writes it is the gate that acts, and nothing downstream reads it. It exists for the session record and the analytics trail.

### 4. The exclusion is narrowed to the keyword scan

The path scan no longer excludes `.claude/`; it still excludes `docs/ai/`, `AI.md`, `CLAUDE.md`, the explainer, `(test|fixture|__mocks__)/` and the mechanism's own test files (`tests/` does not match `(test|fixture)/`, so they are named through `mech_is_test_path`). The keyword scan (`password|secret|token`) keeps the full exclusion. `NON_TEST_FILES` is consumed only by this block (checked), so the split touches nothing else. Cost: a staged `.claude/` script with `session`, `auth`, etc. in its path now needs reviewer + security sign-off (see known-issues R36(f)).

### 5. A different Critic dispatch

When `verify-pristine.sh --classify` prints `mechanism-change: yes`, the Critic prompt gains four questions: what verifies this change and did this change touch it; what does the verifier no longer catch; which exit is not a gate and which is unreachable; what was shown to fail before it was shown to pass. The marker itself only exists at commit time, after review, so review consumes the classification instead; both come from the same helper.

## Deliberately not done

- **No re-run at commit time.** The gate checks that evidence exists and is bound to the staged files; it does not re-execute the tool. That would make the commit hook run test suites, and the tool is the thing being trusted.
- **Evidence honesty is not proven.** An agent can stage evidence from a run it arranged. `gate-conformance.sh` computes the hash independently of the helper so a defect in the helper cannot make the conformance run agree with itself, but the producer of the evidence remains the committer. The compensating control is the Critic's question 1 and the operator reading `harness_changed`.
- **Prose that steers the mechanism** (`.claude/agents/*.md`, `.claude/.automation/templates/*.md`, prompts) is not classified as mechanism. Widening it would make every prompt edit demand a test run with no suite to name.
- **R35 is not fixed.** `gate-conformance.sh` unsets inherited session variables so its own cases are meaningful in a daemon; the other suites with the same signature are untouched.
- **`machinery-manifest.txt` is not regenerated** (stale per R35(b); the rebuilder is blocked in headless). New files are listed in the session log for the operator.

## Verification

What "failed first" means differs by suite, and only the second round was checked case by case.

- First round (before the Critic's review): `layer9-mechanism-change.sh` failed at L9.0 (no helper) and `test-verify-pristine.sh` at its first assertion (no tool) — an absent-file failure, which shows the files were needed, not that each case discriminates. Constructed case: a fixture whose harness is altered so `chk` always passes shows `3/0` in the working tree and `pass=1 fail=2` from the tool. `gate-conformance.sh` section "mechanism-change gate": against the unmodified hook, the block, the marker, the `verify-pristine.sh` message, the escalations, the headless-override rejection and the `High-risk` path case failed behaviourally; the allow-path cases passed only after the environment scrub described in R36(g).
- Second round (the Critic's cycle-1 findings: deletions, empty evidence, cwd, crashed suites, `--timeout=0`, staged-vs-working-tree copy): each fix's cases were run against the pre-fix logic. Against the pre-fix helper, `layer9` failed 6 of its 8 new cases (`empty` x2, deletion hash, mode flip, subdirectory hash, subdirectory evidence lookup); the other 2 pass either way (the deletion hash differing from the unchanged hash, and `tool_error` with zero counts). Against `verify-pristine.sh` with the four fixes reverted together, `test-verify-pristine.sh` failed 7 cases (`--timeout=0`, deleted file in `--classify` and in `deleted:`, the three crash cases, the staged-version copy); the remaining new cases (deletion counted by `--classify`, no-suite note, unstaged-edit warning, no leftover checkout) pass either way and are regression guards, not discriminators. `gate-conformance.sh` against the pre-fix helper failed the empty-run and deletion-with-evidence cases among the 12 that moved.

- Third round (the Critic's cycle-2 finding: a typechange to a symlink was outside `--diff-filter=ACMD`): `gate-conformance.sh` M15. Against the gate with the filter reverted to `ACMD`, "a staged TYPECHANGE ... with no evidence blocks" failed (expected 2, got 0); the "with evidence passes" case passes either way and is a regression guard. The same filter was widened in `verify-pristine.sh` (evidence binding, changed-file list). The Critic also noted that a `tool_error` before the merge base resolves writes no evidence (a repo whose default branch is not `main` needs `--base=`); the block message now says so. That path still has no escape short of `--base`, RECOVER or the interactive override, which is a stated limit. Cycle 2 was the last review cycle; this round was not re-reviewed by a Critic.

## References

- `.claude/hooks/_mechanism-helper.sh`, `.claude/tools/verify-pristine.sh`, `.claude/hooks/pre-commit-gates.sh`
- `.claude/agents/_cohesion-review.md` — Critic addendum
- `.claude/.automation/RUNNER-PARITY.md` row 62
- `docs/ai/logs/known-issues.md` R35, R36
- `docs/ai/decisions/t-0044-*.md` — A3.4 headless-override rule this follows
