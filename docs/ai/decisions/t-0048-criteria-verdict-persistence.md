# Decision t-0048 — Per-Criterion Verdict Persistence

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/state-writer\.sh`
- path: `\.claude/hooks/_cleanup-helper\.sh`
- path: `docs/ai/governance/criteria-verdicts/`
- keywords: `criteria-verdicts, _capture_criteria_verdicts, contract_verification, completeness verdict, repo-os/criteria-verdicts`

## Context

Decision 0020 gave Critic the task contract's `verification:` criteria to evaluate,
and Decision 0039 folded that evaluation into the combined cohesion dispatch. The
Critic produces two independent per-criterion tables in its cohesion brief:

- `### Contract Verification` — VERIFIED / UNVERIFIED / INCONCLUSIVE, judged against
  structural evidence *in the diff*.
- `### Completeness` — COMPLETE / INCOMPLETE / PARTIAL / N/A, judged against the
  *current codebase state*.

`state-writer.sh` captured only the two aggregate sentinels from that output —
`COMPLETENESS: N/M criteria met` and `COMPLETENESS_GATE: APPROVED|NEEDS_WORK` — and
discarded the rest of the message. The per-criterion rows, with their verdicts and
evidence strings, existed only in the agent transcript.

The consequence is that governance state can answer "did completeness pass?" but not
"which criterion failed, and why". Every consumer that needs the latter — an operator
reading back a blocked session, a desktop interface rendering intent-vs-output, an
audit of which criteria historically go INCONCLUSIVE — has nothing to bind to except
transcript scraping, which is format-fragile and unavailable once the session ends.

## Decision

### Capture

Add `_capture_criteria_verdicts()` to `state-writer.sh`, called from both critic
cohesion paths (the combined dual-section write and the single cohesion-mode write).
It parses both per-criterion tables out of the cohesion message and emits them as
structured YAML.

Both tables are recorded and **kept separate — never merged into one verdict**. A
criterion can be UNVERIFIED in the diff yet COMPLETE in the codebase; that means it
was already satisfied before this session touched anything. Collapsing the two to a
single badge destroys that distinction.

Criteria are keyed by their ordinal within each section. A row present in one table
and absent from the other records `verdict: ABSENT` for the missing side.

### Parsing

The verdict is extracted by anchoring on the closed verdict vocabulary at end of
line, not on the `—` separator: criterion text routinely contains dashes, and the
em dash's `substr()` width differs between byte- and character-oriented awk builds.
`INCOMPLETE` precedes `COMPLETE` in the alternation and a leading space is required,
so `INCOMPLETE` cannot match as `...IN` + `COMPLETE`.

### Artifacts

**Live sidecar** — `<state_dir>/criteria-verdicts.yaml`, session-scoped, holding the
most recent dispatch only. `session_id` is written **unquoted**, matching every other
state file: `_cleanup-helper.sh::_delete_if_owned` strips the `session_id: ` prefix
but not surrounding quotes, so a quoted value would never equal the closing sid and
the file would survive session close. Cleaned at close alongside `cohesion-reviewed`.

**Durable record** — `docs/ai/governance/criteria-verdicts/<session_id>.yaml`,
tracked and committed with the session's work. One file per session, one `rounds:`
block appended per Critic dispatch. Remediation re-dispatches Critic, so rounds
accumulate rather than overwrite; that append is what makes the round-over-round view
(a criterion going INCOMPLETE → COMPLETE) reconstructable after the state dir is
cleaned.

Both carry `schema: repo-os/criteria-verdicts@1`.

The durable append is a read-modify-write (count existing rounds, then append the
next), so it runs under `flock` on `.claude/.state/.criteria-verdicts-lock`, reusing
the pattern `record_closed_branch()` in `_cleanup-helper.sh` already uses for the
same hazard. Without it, two overlapping dispatches can read the same count and both
append a `round: N`, or interleave partial writes. The no-`flock` fallback is
best-effort, matching that function's own fallback.

No evidence-manifest entry is written. `refresh_manifest_entry()` only rewrites
entries that `write_evidence_manifest()` already created from `_EVIDENCE_FILES`, and
this artifact is deliberately not in that set — calling it would be a silent no-op
that reads like integrity tracking.

### Advisory, not gate-bearing

This capture is **deliberately not a gate**. A parse miss degrades the sidecar; it
never blocks a commit. `COMPLETENESS_GATE` remains the sole enforcement signal, read
by `pre-commit-gates.sh` (A5 extension), `outcome-detector.sh`, and
`session-close-check.sh` exactly as before. Every write is best-effort so a malformed
brief cannot abort the hook under `set -euo pipefail` and cost the session its real
verdict files.

### Non-Goals

- Does not change how criteria are evaluated, or by whom.
- Does not change `COMPLETENESS` / `COMPLETENESS_GATE` semantics or their consumers.
- Does not introduce stable authoring-time criterion IDs. Criteria remain freeform
  strings keyed by ordinal, so matching a criterion across remediation rounds still
  relies on position and text. See Open Questions.

## Consequences

- `.claude/hooks/state-writer.sh`: `_capture_criteria_verdicts()` added; called from
  the combined path and the single cohesion path.
- `.claude/hooks/_cleanup-helper.sh`: `criteria-verdicts.yaml` added to session-close
  cleanup. The durable copy is tracked and deliberately survives.
- `docs/ai/governance/criteria-verdicts/`: new tracked artifact directory.
- `.claude/hooks/tests/layer7-criteria-verdicts.sh`: new suite (31 assertions) —
  verdict-token coverage including the `INCOMPLETE`/`COMPLETE` mis-split guard,
  dash-bearing criterion text, YAML parseability of both artifacts, quote escaping,
  round-append, `_delete_if_owned` round-trip in both directions, and the advisory
  contract (absent and malformed briefs both return 0). It extracts the function
  from the shipped hook rather than copying it.
- `.claude/hooks/tests/run-phase-tests.sh`: Layer 7 wired into the runner and its
  exit aggregation.
- `.claude/agents/critic.md`: the two per-criterion section formats become a
  machine-read contract, not just a human-readable convention.
- `AI.md`: `state-writer.sh` hook-table row updated.
- `.claude/agents/_agent-glossary.md`: artifact and schema documented.
- `docs/ai/decisions/t-manifest.txt`: entry added.

## Alternatives Considered

1. **Extend the `cohesion-reviewed` state file instead of a sidecar.** Rejected —
   that file is parsed by four hooks that expect `GATE_RESULT:` to be its last
   non-empty line. Appending a multi-line criteria table risks exactly the
   verdict-rejection failures Decision t-0047 and the 2026-09-01 follow-up work
   were written to eliminate.

2. **Transcript scraping by the consumer.** Rejected — pushes a fragile parse of
   agent prose onto every consumer, and the transcript is unavailable once the
   session ends. Parsing once, at the hook that already reads the message, is
   strictly cheaper and keeps the format contract in one place.

3. **Make the capture gate-bearing (block when a criterion is UNVERIFIED).**
   Rejected — `COMPLETENESS_GATE` already blocks on INCOMPLETE. Contract
   Verification is advisory by design (Decision 0020): UNVERIFIED frequently and
   legitimately means "satisfied before this diff", so blocking on it would produce
   false failures.

4. **Session-scoped sidecar only, no durable copy.** Rejected during review — the
   round-over-round history is the substantive artifact, and it is destroyed by the
   existing close-time cleanup.

## Open Questions

- **Stable criterion IDs.** Criteria are freeform strings in a YAML array with no
  identifiers, re-emitted as numbered prose by the Critic. Cross-round and
  cross-session correlation therefore depends on ordinal position and text matching.
  Assigning IDs at authoring time (`prompt-t-task-definition.md` § Task Contract)
  would make correlation exact, at the cost of a brief-format change that ripples
  into every existing contract. Deferred to its own decision.

## References

- Decision 0020: Task contract verification criteria passed to Critic.
- Decision 0039: Critic consolidation (combined cohesion + diff-review dispatch).
- Decision t-0047: Session lifecycle Stop/SessionEnd split (state file cleanup).
- `.claude/agents/critic.md` § Contract Verification, § Completeness Pass.
- `.claude/agents/_cohesion-review.md` steps 2, 6, 7.
