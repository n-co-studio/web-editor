# Decision t-0075 — An approving verdict counts only for the approval it followed

**Status:** Accepted
**Date:** 2026-11-19
**Amends:** Decision t-0071 (sign-offs must be APPROVED and session-valid — now also from this
approval); t-0074 (the deleted helper's marker). `.claude/hooks/state-writer.sh`,
`.claude/hooks/pre-commit-gates.sh`, `.claude/hooks/_cleanup-helper.sh`.

## Triggers

- type: file
- path: `\.claude/hooks/state-writer\.sh`
- keywords: `approval_ref, _verdict_follows_approval, stale_approval`

## Context

The operator chose to make gate evidence unforgeable with Claude Code's Bash sandbox: hooks run
outside it, and a deny list stops agent commands — and every program they start — from writing
the verdict files and the recover signal. Step 1 (t-0074) removed the helpers that forged
verdicts. This is step 2.

A work unit's verdicts are cleared by `init_phase` when the next unit starts
(`clear_session_evidence`). `init_phase` runs in the agent's Bash, so under the sandbox that
delete fails. The commit gate accepted any verdict carrying this session's `session_id`, so the
previous unit's APPROVED Critic, QA, Reviewer and Security verdicts would have carried into the
next unit — a stale approval that nothing re-checked.

## Decision

1. **Each verdict records the approval it followed.** `state-writer.sh` writes
   `approval_ref:` into every verdict file — the first 16 hex of the SHA-256 of `plan-approved` at
   capture, `none` without one. Every `plan-approved` writer stamps a timestamp, so each approval
   has its own digest; the runner's copy into a worktree is byte-identical, so it keeps it.
2. **An APPROVED verdict from an earlier approval does not count.** The commit gate compares the
   stamp with the current `plan-approved` for `cohesion-reviewed`, `diff-review-complete`,
   `qa-verified`, and the high-risk `reviewer-signed` / `security-signed` sign-offs:
   `<file> was written before the current plan approval`, GATE-RECOVERABLE
   (`state_*_stale_approval`), re-run that agent. A stamp of `none` does not match a real
   approval. A re-approval mid-unit (an amended contract) therefore voids every APPROVED verdict —
   as the phase reset already implied.
3. **A block binds whatever approval it followed.** A non-APPROVED Reviewer or Security verdict
   still blocks after a re-approval (t-0071), so a re-approval cannot void a block.
4. **A verdict without the stamp is accepted, with an advisory.** It was written before this
   change. This check stops a *stale* verdict; stopping a *forged* one is the sandbox's job.
5. **Only APPROVED passes.** The commit gate blocked a Critic (cohesion, diff-review) or QA
   verdict only when it said exactly `BLOCKED`, so `NEEDS_WORK` — the Critic's defined word, and
   one QA returned twice on 2026-11-19 although its instructions name only APPROVED and BLOCKED —
   or any other word let a commit through (Security, this review; it predates t-0075).
   Any `GATE_RESULT` other than `APPROVED` now blocks, and the stale check covers every such
   verdict that is not `BLOCKED`.
6. **The deleted helper's marker no longer survives init.** `_is_prewritten_evidence` stops
   accepting `question_hash: headless-runner` (its writer went in t-0074).

## Not in this step

`plan-approved` and `pragmatist-signed` are also written from the agent's Bash —
`drift_check` (handoff bundle), `accept_draft_approval` (queued draft) and
`write_alignment_check_pragmatist_signed`. Each decides from inputs the agent can write (the bundle,
the queue entries, the outcome argument), so moving the write into a hook would make a forged input
produce a hook-written approval. They stay agent-side; `plan-approved` and `pragmatist-signed`
stay off the sandbox deny list (so `init_phase` can still clear them); known-issues R58.

## Known limits

- **The binding is only as strong as `plan-approved`.** An agent that rewrites `plan-approved`
  (R2's class; the sandbox will not cover it) changes the digest — which voids its own verdicts
  rather than reviving old ones, but it can also self-approve (R58).
- **Transitional:** a verdict written before this change carries no stamp and is accepted, so
  one stale pre-change verdict can survive a failed delete. It ends after one work unit; the
  acceptance itself should be removed once the sandbox is on (R58 follow-up).
- **No binding without a plan approval.** In session types with no plan gate (or with
  `REPO_OS_SKIP_PLAN_GATE`), every verdict is stamped `none` and the current approval is `none`,
  so they match: a stale verdict there still counts once the sandbox stops init deleting it
  (Security). A per-unit nonce written at init would close it.
- **An agent that can rewrite `plan-approved` can restore an old one's exact bytes** and so
  revive that approval's verdicts — narrow (it needs the bytes) and part of R58; it closes when
  `plan-approved` leaves agent reach.
- The phase helper's substance checks (cohesion before verify, QA before commit), the close check
  and outcome classification still read verdicts by presence; the commit gate is the one place a
  stale verdict is refused (Critic).
- The stamp is taken when the verdict is captured, not when the agent was dispatched: a
  re-approval while an agent runs stamps its verdict with the new approval. The phase reset and
  the dispatch-phase check cover most of that window (Critic).
- Anything that rewrites `plan-approved` voids every APPROVED verdict — a re-approval, or
  `drift_check` re-run mid-unit (it re-stamps the bundle approval). Nothing calls either mid-unit
  except a re-approval, which already resets the phase.
