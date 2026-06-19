# Decision 0043 — Handoff Bundle Per-Brief Paths

## Status
Accepted

**Supersedes:** t-0038 §1 (path resolution) — scoped supersession. The rest of t-0038 (the bundle artifact, drift-check predicates, Prompt B init, Pragmatist demotion, backward compatibility) stands unchanged. See `docs/ai/decisions/t-0030-worktree-sessions.md` for the scoped-supersession precedent (t-0030 supersedes t-0028 "for full worktree sessions only").

## Triggers

- type: file
- path: `\.claude/hooks/_phase-helper\.sh`
- path: `\.claude/local/handoff-bundles/.*\.yaml`
- path: `\.claude/local/handoff-bundle\.yaml`
- path: `docs/ai/prompts/prompt-t-task-definition\.md`
- path: `docs/ai/prompts/prompt-b-product-build\.md`
- keywords: `handoff-bundles, per-brief bundle, _resolve_brief_id, _atomic_write_bundle, brief_id, handoff bundle path`

## Context

Decision 0038 §1 defined two handoff-bundle path schemes:
- **Singular brief:** `.claude/local/handoff-bundle.yaml` — a single fixed slot.
- **Task group:** `.claude/local/task-groups/{group}/briefs/{seq}.bundle.yaml` — already per-brief.

The queue path (`.claude/.automation/briefs/<YYYYMMDD-HHMMSS>-<slug>.bundle.yaml`) is also per-brief. The singular interactive path is the odd one out: a single fixed slot is **last-writer-wins**. When an operator approves several briefs back-to-back through the interactive `Approve — review` / `Approve — auto` path, each approval overwrites the previous bundle. A brief approved earlier but not yet started in a build session then reads the *wrong* bundle (the most-recently-approved one), or a stale one — silently. The drift-check spec-snapshot predicate catches some divergence, but the collision is real with a **single** interactively-approved brief followed by another, not only batches.

## Decision

### 1. Per-brief singular bundle path

The singular interactive handoff bundle is written to a **per-brief path keyed on `brief_id`**:

```
.claude/local/handoff-bundles/<brief_id>.yaml
```

This brings the singular path in line with the already-per-brief queue and task-group paths. Per-brief **files in a directory** (not a multi-document single YAML) are required: bash/grep/awk cannot reliably parse multi-document YAML, and every existing extractor (`bundle_valid`, `bundle_expired`, the awk spec-snapshot parser) would have to become block-scoped. Per-file gives an atomic `mv` write and O(1) lookup (Maildir / claim-check prior art).

### 2. `brief_id` standardization

`brief_id` is locked to the form `<YYYYMMDD-HHMMSS>-<slug>`. The timestamp prefix guarantees filename uniqueness and removes the title-slug collision that a slug-only key would relocate rather than fix. `brief_id` is added as an optional field to the Task Contract schema (Decision 0020) and to the Prompt T `### Task Contract` template.

### 3. Resolution

`_handoff_bundle_path([brief_id])` in `_phase-helper.sh`:
- When `brief_id` is determinable — passed as an argument, else resolved from `.claude/local/task-contract.yaml` via the new `_resolve_brief_id()` — returns `.claude/local/handoff-bundles/<brief_id>.yaml`.
- When `brief_id` is **absent** (legacy / pre-t-0043 briefs), falls back to the legacy fixed path `.claude/local/handoff-bundle.yaml`.

`_resolve_brief_id()` greps `^brief_id:` from the task contract and returns the empty string (not an error) when the file or field is absent.

### 4. Atomic write

Prompt T Step 5 writes the singular bundle via the `_atomic_write_bundle(brief_id)` helper: `mkdir -p` the `handoff-bundles/` directory, write a temp file in the same directory, then `mv` (atomic same-filesystem rename) into place. Concurrent Prompt T writers can neither interleave nor be read mid-write.

### 5. Init ordering

`drift_check` resolves the per-brief path by reading `brief_id` from the task contract. **Standard sessions have no `contract-init` phase**, so Prompt B init MUST write `.claude/local/task-contract.yaml` (including `brief_id`) **before** invoking `drift_check`. Task groups already satisfy this via `contract-init → drift-check`.

### 6. Distinct fallthrough logs

`drift_check`'s predicate-1 fallthrough emits two distinct reasons so a failed drift-check is diagnosable:
- `bundle-file-absent` — `brief_id` present but the per-brief file is missing (written-then-pruned, or never written).
- `no-brief-id:fallthrough` — no `brief_id` in the contract; the legacy fixed path was probed.

### 7. Identity and lifecycle

Bundle identity = `brief_id` keying + the existing `spec_snapshot` sha predicate. **No goal-text cross-check** (brittle to whitespace/paraphrase, collision-prone across briefs sharing a goal sentence). **No consumed-marker / rename-on-consume** (it would break crash-recovery resume — bundles persist until expiry, same staleness model as the legacy fixed file). Garbage collection is **one age-prune line** in `init_phase`: remove `handoff-bundles/*.yaml` older than the `hard_hours` default (168h ≈ 7 days). The concurrent-same-`brief_id` writer case remains last-writer-wins scoped to an identical `brief_id` only (acceptable residual; the spec-snapshot predicate catches content divergence).

### 8. Legacy fallback policy

The legacy fixed path `.claude/local/handoff-bundle.yaml` is a **read-only fallback**, retained for one release cycle, and is **not** deleted. A pre-change brief with no `brief_id` falls back to it; the `no-brief-id:fallthrough` log distinguishes this from a genuine missing per-brief bundle, and the `spec_snapshot` predicate catches content divergence (falling through to plan/approval) so a stale fixed-path bundle is never silently loaded for a different brief.

## Consequences

- `.claude/hooks/_phase-helper.sh`: `_resolve_brief_id()` added; `_handoff_bundle_path([brief_id])` rewritten for per-brief resolution; `_atomic_write_bundle()` added; `drift_check()` resolves `brief_id` and emits distinct fallthrough logs; `init_phase()` gains one age-prune line. `bundle_valid` / `bundle_expired` / `bundle_to_plan_approved` / `bundle_to_pragmatist_signed` are unchanged — they already take a path argument.
- `docs/ai/prompts/prompt-t-task-definition.md`: Step 5 writes the per-brief path via `_atomic_write_bundle`; `### Task Contract` template gains `brief_id`; handoff block `Bundle:` line and instructions reference the per-brief path.
- `docs/ai/prompts/prompt-b-product-build.md`: drift-check section documents the per-brief path and the REQUIRE init-ordering (task contract written before `drift_check`).
- `docs/ai/decisions/t-0038-handoff-bundle.md`: §1 path resolution superseded by this decision; singular fixed path marked DEPRECATED; all three bundle paths documented.
- `docs/ai/decisions/t-0020-task-contract-system.md`: optional `brief_id` added to the contract schema.
- `AI.md`: bundle path references updated.

**Deferred to follow-ups (recorded here):**
- **Three-path unification:** the queue, task-group, and singular paths now all key on a brief-scoped identifier but use three different directory layouts. A future brief can unify them behind a single resolver.
- **Parity-CI guard:** a CI check verifying that all three bundle paths resolve and round-trip (write → resolve → read) under each session type, so a future path change cannot silently regress one scheme.

## Alternatives Considered

1. **Multiple briefs in one document (keyed list in a single YAML).** Rejected — bash/grep/awk cannot reliably parse multi-document YAML; every existing extractor would need to become block-scoped, and concurrent appends are not atomic.
2. **Flat unique files directly in `.claude/local/`.** Viable and slightly lighter (no `mkdir`), but a dedicated directory is consistent with the existing `.claude/local/task-groups/` convention and scopes the age-prune cleanly. Directory chosen.
3. **Goal-text cross-check for bundle identity.** Dropped — brittle to whitespace/paraphrase and collision-prone across briefs sharing a goal sentence; `brief_id` + spec-snapshot is sufficient.
4. **Docs-only fix ("use Approve & queue for batches").** Rejected — the collision reproduces with a single interactively-approved brief, not just batches.

## References

- Decision t-0038: Handoff Bundle (Prompt T → Prompt B) — §1 path resolution superseded by this decision.
- Decision t-0020: Task Contract System (amended — optional `brief_id` field).
- Decision t-0030: Worktree Sessions (scoped-supersession precedent).
- Decision t-0013: Session Branch Isolation (surgical commits).
