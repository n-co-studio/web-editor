# Decision t-0050 — Expected Changes (Intent-to-Diff Mapping)

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/tools/ec-report\.sh`
- path: `docs/ai/prompts/prompt-t-task-definition\.md`
- path: `docs/ai/task-groups/_contract-template\.yaml`
- keywords: `expected_changes, Expected Changes, EC-, Changes: trailer, additional change, intent-to-diff, ec-report`

## Context

Nothing in a task brief maps a unit of *requested* work to the *diffs* that
realise it, at a granularity a non-engineer can read.

The existing fields were each considered and rejected for this purpose:

- **`Verification`** is falsifiable, list-shaped, and already carries
  per-criterion verdicts (Decision t-0048) — but it is written for the Critic
  to test against, not for a person to read. Real examples run to
  *"eval-cell carries pointers/metrics only; eval-suite references TAP"*.
  It also asserts properties, not changes, so it has no natural diff mapping.
- **`Approach`** is the right *shape* (discrete, ordered steps) but the wrong
  *content*: it is implementation instruction for the Builder, and it goes
  stale the moment implementation deviates. Attributing diffs to it would show
  a plan, not a claim about what happened.
- **`scope_files`** maps to diffs precisely but is a file list — it answers
  "what was touched", never "what was delivered".
- **`briefs[].branch`** (task groups) gives an exact per-brief diff range and
  is used that way by the merge brief. But its granularity is one checkbox per
  *session's worth of work*, which is too coarse, and it does not exist for
  single-brief sessions at all.

So the mapping is added rather than inferred. Inferring it — attributing
commits to `Approach` steps after the fact — was rejected explicitly: it
produces a confident checkbox nobody verified, which is the worst failure mode
for a non-engineer audience.

## Decision

### 1. Briefs declare Expected Changes in plain language

Prompt T output gains an `### Expected Changes` section: a list of outcomes
stated as **what a user of the system can now do or observe**, each with a
stable ID.

```
### Expected Changes
- EC-1: People can sign in with a Google account
- EC-2: Sessions expire after 30 days of inactivity
```

Rules (enforced by prompt instruction, not by code):

- Written for someone who will not read the diff. No file paths, no symbol
  names, no schema jargon.
- One observable outcome each. If a line needs "and", it is two changes.
- IDs are stable within a brief and never renumbered once work begins — the
  commit trailer references them.
- Typically 2–6 per brief. A brief needing more than that is usually two
  briefs.

### 2. Commits declare which Expected Change they serve

```
feat(auth): add Google OAuth provider

Changes: EC-1
```

This mirrors the existing `Decisions:` trailer (Decision 0002 / gate A1),
deliberately: the convention, the parser shape, and the operator habit already
exist.

### 3. Unattributed commits are a first-class result, not an error

A commit with no `Changes:` trailer is reported as an **additional change** —
work that no Expected Change predicted. This is the most informative row in the
report: it is where scope creep, discovered requirements, and incidental fixes
surface. It is never filtered out and never treated as a failure.

Consequently **nothing blocks on the trailer.** A gate that forced every
commit to name an Expected Change would push people to attach false IDs to
chores and session logs, destroying the signal it was trying to protect.

### 4. `expected_changes` is carried as data

Added to the handoff-bundle `contract:` block (Decision t-0038 § 1), beside
`goal`, `scope_files`, `approach` and `verification`, and to the task-group
contract `intent:` block (Decision 0020). Both are optional — briefs and
groups without it continue to work unchanged.

```yaml
expected_changes:
  - id: "EC-1"
    statement: "People can sign in with a Google account"
```

### 5. `ec-report.sh` performs the join

`.claude/tools/ec-report.sh` emits the intent-vs-outcome view as JSON for
downstream consumers (a UI, a report, a close summary):

```json
{
  "expected_changes": [
    { "id": "EC-1", "statement": "...", "status": "delivered",
      "commits": [...], "files": [...] }
  ],
  "additional_changes": [ { "sha": "...", "subject": "...", "files": [...] } ]
}
```

Status is derived only from what is recorded: `delivered` when at least one
commit carries the ID, `not-started` otherwise. The tool never guesses which
diff belongs to which change.

## Consequences

- A brief now states its outcome twice: once for the Critic (`Verification`,
  falsifiable) and once for a person (`Expected Changes`, readable). That
  duplication is deliberate — the two audiences need different language, and
  collapsing them is what made the existing field unusable for this purpose.
- Attribution is exact where recorded and absent where not. There is no
  partial credit and no inference. A change with no trailer appears as an
  additional change, which is honest rather than wrong.
- Line-level attribution is explicitly **not** provided. A commit can be
  attributed to an Expected Change; a hunk cannot. Consumers should present
  "files that changed for this outcome", not "these 40 lines".

## Alternatives Considered

1. **Reuse `Verification` as the checkbox list.** Rejected: engineer-facing
   language, and criteria are assertions about properties rather than units of
   change, so they have no diff mapping.
2. **Infer attribution from `Approach` steps post-hoc.** Rejected: no schema
   change, but unverifiable output presented as fact.
3. **Block commits lacking a `Changes:` trailer** (an A1-style gate with a
   sentinel). Rejected for now: it would force false attribution on chore and
   session-log commits and poison the additional-changes signal. Revisit only
   if trailers prove to be widely omitted on substantive commits.
4. **Per-hunk attribution.** Rejected: not derivable from a commit trailer, and
   promising it would misrepresent the precision of the data.
