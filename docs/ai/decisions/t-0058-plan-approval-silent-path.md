# Decision t-0058 — Plan Approval Silent-Path Warning

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/plan-approval\.sh`
- keywords: `plan-approval, Gate 1, Gate 2, not_approved, affirmative, silent, warning, stale marker`

## Context

`plan-approval.sh` requires three conditions before recording an approval: the
question text must mention plan/brief/task (Gate 1), the question or an option
label must contain confirmation language (Gate 2), and the selected answer must
contain an affirmative keyword. Miss any one and the hook exits 0 having written
nothing, leaving the previous `plan-approved` on disk looking current.

This was hit three times in a single session on 2026-10-21 (R28):

1. An answer labelled "All four, reaping first (Recommended)" carried no
   affirmative keyword — Gates 1+2 passed, but the answer check failed silently.
2. A question about "units of work" carried no Gate-1 keyword — the hook exited
   before Gate 2 was ever evaluated.
3. A "large scope" question with no Gate-1 keyword — the A2 scope flag was
   never set, so `large-scope: false` went into the eventual approval and blocked
   at commit time.

In every case the only trace was a `not_approved` line in the hook event log (or
nothing at all for a Gate-1 miss). The operator had no way to know the answer
did not land.

## Decision

### 1. Warn when Gates 1+2 pass but the answer is not affirmative

When the question text mentions plan/brief/task (Gate 1 passes) AND the question
or options carry confirmation language (Gate 2 passes) but the selected answer
contains no affirmative keyword, emit a WARNING on stderr. The operator has
answered what looks like a plan approval question; they are entitled to know the
answer was not recorded.

The warning text must:
- State that the approval was NOT recorded
- Quote the answer text that failed to match
- Name the affirmative keywords the hook accepts
- Exit 0 — `plan-approval.sh` is PostToolUse and must never block

### 2. Warn when Gate 2 passes but Gate 1 does not

A question that contains confirmation language (Gate 2 passes) but does not
mention plan/brief/task (Gate 1 fails) is almost certainly an intended plan
approval phrased without those keywords. Without this warning, the operator gets
no feedback of any kind — not even a `not_approved` event log entry.

Implement: compute Gate 2 before acting on the Gate-1 miss. If Gate 2 passed,
emit a WARNING naming the missing keyword class and log a `not_approved` event
with tag `gate1_miss_with_approval_language`. Still exit 0.

**Rationale for this option over the alternative (template-constrained question):**
Having the orchestrator always emit the question from a fixed template would
prevent the wording problem entirely, but it changes prompts rather than hooks,
has a wider blast radius (every session type that reaches the approval phase),
and does not help operators who phrase the question themselves. The prompt change
is not excluded — it may still be worth doing independently — but the hook-level
warning is proportionate, self-contained, and does not require updating any
prompt.

**Noise bound:** The warning fires ONLY when Gate 2 passes. A bare non-plan,
non-approval question (e.g. "Which library?") still exits silently. Gate 2
requires confirmation language in the question OR option labels; casual questions
do not carry that language, so the warning is not triggered.

### 3. Stale marker hint in the written state file

The written `plan-approved` file gains a `stale_check:` field that documents
how to verify the marker is current: compare its `timestamp:` against the
phase-state mtime, and compare its `question_hash:` against the current plan
text. This is informational only — no gate reads `stale_check:`.

`pre-commit-gates.sh` already verifies the hash via `session-resume.yaml`
when a resume marker exists (presence-only otherwise); this note makes the
mechanism discoverable without reading gate code.

## Out of scope

Adding a pre-commit warning when `plan-approved`'s timestamp predates the
phase-state's last transition is deferred. It requires parsing ISO 8601
timestamps portably across bash 3.2 and comparing them, and the `question_hash`
check already covers the case where the plan text changed (the common one).
A timestamp comparison guards silent re-use of an old approval when the plan
text happens to be identical — a narrower scenario, not worth the complexity now.

## Consequences

- `plan-approval.sh` restructured: Gate 2 is computed before the Gate-1 exit so
  the Gate-1 miss path can read `IS_CONFIRMATION`.
- No existing green test should fail. The tests that checked silent exit on a
  negative answer still pass — they use affirmative-keyword-free answers in
  questions that DO carry plan/brief/task (Gate 1 passes, Gate 2 passes, answer
  fails → now warns but still exits 0 and does not write state).
- New layer3 tests cover: Gate-1 miss with Gate-2 approval language (warns);
  Gate-1+2 pass but non-affirmative answer (warns, no state); non-plan
  non-approval question (silent); `stale_check:` field present.
