# Decision 0038 — Handoff Bundle (Prompt T → Prompt B)

## Status
Accepted

> **Note (Decision t-0043):** §1 path resolution is **superseded by t-0043**. The singular interactive bundle now lives at the per-brief path `.claude/local/handoff-bundles/<brief_id>.yaml` (keyed on `brief_id`), not the single fixed slot below. The legacy fixed path `.claude/local/handoff-bundle.yaml` is **DEPRECATED** — read-only fallback for one release cycle. All other sections of this decision stand unchanged.

## Triggers

- type: file
- path: `docs/ai/prompts/prompt-t-task-definition\.md`
- path: `docs/ai/prompts/prompt-b-product-build\.md`
- path: `\.claude/hooks/_phase-helper\.sh`
- path: `\.claude/local/handoff-bundle\.yaml`
- path: `\.claude/local/task-groups/.*\.bundle\.yaml`
- keywords: `handoff bundle, drift-check, drift_check, bundle_valid, bundle_expired, deterministic alignment, handoff-bundle`

## Context

Prompt T and Prompt B both re-derived the same plan. Prompt T's Brief mode runs the advisory board, synthesizes a brief with an Implementation Design block, and obtains operator approval. Prompt B then opens a `plan → approval` phase that re-parses the brief, re-architects the same approach, and re-prompts the operator for a plan that is structurally a copy of the approved brief. Pragmatist Plan-Gating runs a second time over the same content. Two `AskUserQuestion` approvals per work item; two specialist dispatches over the same scope.

The cost is concrete: ~5–15K tokens per session for plan re-derivation, one redundant operator interaction, and a non-trivial chance of plan/brief drift (the second plan diverges from the brief that was approved, undermining the original approval signal).

This decision collapses the redundancy by promoting Prompt T's approval to be the single approval gate, packaging everything Prompt B needs into a sealed handoff bundle, and replacing Prompt B's `plan → approval` phases with a deterministic `drift-check`.

## Decision

### 1. Handoff Bundle Artifact

Prompt T writes a **handoff bundle** at Step 5 whenever an `Approve — *` path is selected. The bundle is a YAML file that packages the full context Prompt B needs:

```yaml
brief_id: "<slug-derived-from-title>"
approved_at: "<ISO 8601 UTC>"
approved_by: "operator"          # always operator (Prompt T approval is operator-gated)
mode: "auto" | "review"          # selected at Prompt T Step 4
contract:                         # inlined Task Contract (Decision 0020 schema)
  goal: ""
  scope_files: []
  scope_modules: []
  approach: []
  verification: []
  spec_references: []
  constraints: []
  implementation_design:         # optional — present when brief has ### Implementation Design
    components: ""
    key_interfaces: ""
    data_flow: ""
    error_handling: ""
  lifecycle: task-scoped
plan:                             # numbered Approach steps, verbatim from the brief
  - ""
implementation_design:           # optional — top-level mirror for fast lookup
  components: ""
  key_interfaces: ""
  data_flow: ""
  error_handling: ""
spec_snapshot:
  version: "<manifest.json active>"
  files:
    - path: "docs/spec/compiled/v1/architecture.md"
      sha: "<sha256 of file at approval time>"
pragmatist:
  verdict: "APPROVED" | "OVER-ENGINEERED-NOTED"
  findings: ""                   # short summary text (advisory findings carried forward)
expiry:
  soft_hours: 24                  # soft expiry — triggers operator advisory at drift-check
  hard_hours: 168                 # hard expiry — bundle invalid, falls through to legacy path
```

**Path resolution** (superseded by t-0043 — see below for the current scheme):

The three handoff-bundle paths across the system:

| Path | Scope | Status |
|------|-------|--------|
| `.claude/local/handoff-bundles/<brief_id>.yaml` | Singular interactive brief, per-brief (keyed on `brief_id`) | **Current** (Decision t-0043) |
| `.claude/local/handoff-bundle.yaml` | Singular interactive brief, single fixed slot | **DEPRECATED** — read-only legacy fallback for one release cycle; do not write |
| `.claude/local/task-groups/{group}/briefs/{seq}.bundle.yaml` | Task group, per-brief (group-scoped) | Current |
| `.claude/.automation/briefs/<YYYYMMDD-HHMMSS>-<slug>.bundle.yaml` | Queue intake (headless), per-brief | Current |

All paths sit under `.claude/local/` or `.claude/.automation/`, outside the hook-managed `.state/` perimeter — write via shell I/O or Write tool (no state-guard interference). The singular interactive path is resolved by `_handoff_bundle_path()` from `brief_id` (Decision t-0043); when no `brief_id` is present it falls back to the deprecated fixed slot.

### 2. Prompt T Step 4 — Merged Auto/Review Approval

Step 4's `AskUserQuestion` merges the auto/review mode selection into the brief-approval prompt. New options:

- **Approve — review** — Display brief, write bundle with `mode: review`. Prompt B will pause at op-review before commit.
- **Approve — auto** — Display brief, write bundle with `mode: auto`. Prompt B will close autonomously after gates pass.
- **Approve & queue (auto)** — Write bundle + brief to disk, queue for headless execution with auto mode.
- **Approve & queue (review)** — Write bundle + brief to disk, queue for headless execution with review mode.
- **Revise** — Operator requests changes. Re-synthesize.
- **Abandon** — Operator decides not to proceed.

`plan-approval.sh` hook contract (Gate 1 / Gate 2 / Gate 3) is satisfied by the same regex matches as today — the new option set adds the explicit `auto`/`review` keywords, which `DETECTED_MODE` (lines 109–113 of `plan-approval.sh`) already scans for.

### 3. Prompt T Step 5 — Bundle Write

After operator approval (any `Approve — *` path), Prompt T writes the bundle via shell I/O. For "Approve — review" and "Approve — auto" paths, the bundle is written and its path is included in the displayed handoff block. For "Approve & queue" paths, the bundle is written alongside the brief in `.claude/.automation/briefs/` and the bundle path is included in the queue intake metadata.

**Spec snapshot computation:** For each file in `contract.spec_references` (and, transitively, any file listed in `contract.scope_files` that is a spec file), compute `sha256sum` via `git rev-parse :path` if staged, else the working-tree file's sha256. Record `path` and `sha` in `spec_snapshot.files[]`.

### 4. Prompt B — drift-check Phase

The standard phase sequence becomes:

```
init → drift-check → build → review → verify → user-review → commit → op-review → close
```

The `plan` and `approval` phases are eliminated for sessions where a valid bundle is present. For sessions without a bundle (legacy briefs, paste-only briefs from before this decision), drift-check falls through to the legacy `plan → approval` path — see § 8.

**Hotfix** (`init → plan → approval → build → verify → commit → close`) and **editor-live** (no plan phase) are unchanged. Bundle handling does not apply to these session types.

### 5. drift-check Predicates

`drift_check()` in `_phase-helper.sh` evaluates:

1. **Bundle present:** `bundle_valid()` returns 0 — file exists, parses as YAML, has all required fields
2. **Approval freshness:** `bundle_expired()` returns 0 — `approved_at` is within `expiry.soft_hours`
3. **Spec snapshot match:** Each entry in `spec_snapshot.files[]` matches the current working-copy sha256
4. **Scope file stability:** No commits in `git log main..HEAD` touch files listed in `contract.scope_files` after `approved_at` (proxy: zero commits means no drift; presence of intervening commits triggers focused re-approval)

**Verdicts (return codes documented on `drift_check()` in `_phase-helper.sh`):**
- All predicates pass, bundle fresh → return 0. Write `plan-approved` from bundle, write `pragmatist-signed` from bundle's verdict, advance to `build`
- Predicate 1 fails (no bundle) → return 1. Fall through to legacy `plan → approval` path
- Predicate 2 fails (`approved_at` past `hard_hours`) → return 2. Invalidate bundle, fall through to legacy path
- Predicate 2 partial (between `soft_hours` and `hard_hours`) → return 3. Emit operator advisory. State files are still written (subsequent predicates evaluated normally); the orchestrator chooses between proceeding with code-0 semantics or surfacing the staleness to the operator for focused re-confirmation
- Predicate 3 fails (spec hash mismatch, or no portable hash command available) → return 4. Emit operator-facing diff (or "hash unavailable" advisory), focused re-approval
- Predicate 4 fails (scope-file commits since approval) → return 5. Emit per-file diff, focused re-approval

### 6. Bundle-Aware Prompt B Init

When a valid bundle is present:

1. **Task contract:** Load `.claude/local/task-contract.yaml` from `bundle.contract` (skip re-parsing brief markdown)
2. **Spec excerpts:** Load from `bundle.spec_snapshot` paths (skip selective-load re-derivation per Decision 0035)
3. **Pragmatist verdict:** Write `pragmatist-signed` state file directly from `bundle.pragmatist` (skip Pragmatist Plan-Gating dispatch)
4. **Plan-approved state:** Write `plan-approved` state file derived from bundle approval (skip `AskUserQuestion`)

### 7. Pragmatist Plan-Gating Demotion (Implementation Design Case)

When `bundle.implementation_design` is present, Plan-Gating's alignment sub-mode (Decision 0025) becomes a **deterministic Orchestrator-side check**, not a Pragmatist dispatch:

- Orchestrator compares the build's execution order/components against `contract.implementation_design.components`, `key_interfaces`, `data_flow`, and `error_handling`
- **Aligned** → write `pragmatist-signed` directly (no Task dispatch)
- **Diverged** → escalate to operator with the divergence diff. If operator confirms divergence is intentional, write `pragmatist-signed`. Otherwise, fall back to full Pragmatist dispatch
- **Missing-design** (no `implementation_design` field) → full Pragmatist Plan-Gating dispatch (current behavior)

This eliminates one specialist dispatch per session in the common case where the brief was synthesized via Prompt T with Implementation Design.

### 8. Backward Compatibility

The bundle path is **additive**:

- Sessions with no bundle (legacy briefs, pre-decision queued briefs) fall through to the legacy `plan → approval` path with full agent re-derivation. No regression.
- The `drift-check` phase logs the fall-through reason via `log_override("drift-check", "<reason>")` for audit traceability.
- `_phase-helper.sh::has_plan_gate()` semantics are preserved for standard/taskgroup: returns 0 because those types still carry a logical plan gate. The bundle path satisfies that gate by writing `plan-approved` from `bundle_to_plan_approved()`. When the bundle is absent, the legacy `AskUserQuestion` path satisfies the same gate.

### 9. Hook Updates

- **`bash-guard.sh`** — Gate 2 (phase gate) accepts `plan-approved` written from a bundle as equivalent to one written by the `AskUserQuestion` path. No code change required: `plan-approval.sh` and the bundle path both write the same file schema with a `session_id` field; existing validation is sufficient. A small comment update flags the dual provenance.
- **`pre-commit-gates.sh`** — Same equivalence applies to `plan-approved` and `pragmatist-signed`. No new validation required; a comment notes the bundle provenance for auditors.
- **`plan-approval.sh`** — Unchanged. The hook still fires on `AskUserQuestion` events for the operator's brief approval at Prompt T Step 4 (the single approval gate).
- **`state-writer.sh`** — Unchanged. Continues to write Critic / QA / Pragmatist verdicts on `SubagentStop`.

### 10. Override Audit

All bundle-driven state writes log via `log_override` with a descriptive reason:
- `log_override "drift-check" "bundle-valid:advancing-to-build"`
- `log_override "drift-check" "bundle-stale:fallthrough-to-legacy"`
- `log_override "drift-check" "spec-hash-mismatch:focused-reapproval"`
- `log_override "pragmatist-alignment" "deterministic-aligned"`

This preserves the audit trail Decision 0017's automation layer relies on.

## Consequences

- `docs/ai/decisions/t-0038-handoff-bundle.md` created (this file)
- `docs/ai/prompts/prompt-t-task-definition.md` updated: Step 4 merges auto/review into the approval question; Step 5 writes the bundle
- `docs/ai/prompts/prompt-b-product-build.md` updated: `plan → approval` replaced with `drift-check`; bundle-aware init logic added
- `docs/ai/decisions/t-0014-phase-aware-flow-model.md` amended: standard / taskgroup sequences updated to include `drift-check` phase; new helper functions documented
- `docs/ai/decisions/t-0020-task-contract-system.md` amended: contract may also be loaded from `bundle.contract` instead of re-parsed from brief
- `docs/ai/decisions/t-0025-pragmatist-agent.md` amended: Plan-Gating alignment sub-mode becomes deterministic Orchestrator check when `implementation_design:` present in bundle
- `docs/ai/decisions/t-0029-operator-ack-enforcement.md` amended: the bundle approval at Prompt T is the single operator-ack gate for Prompt B sessions with a valid bundle
- `docs/ai/decisions/t-0035-selective-spec-loading.md` amended: selective-load runs once in Prompt T (snapshotted into bundle); Prompt B reads the snapshot
- `.claude/hooks/_phase-helper.sh` updated: `drift_check()`, `bundle_valid()`, `bundle_expired()`, `bundle_to_plan_approved()`, `deterministic_alignment_check()` helpers added; `get_phases_for_type()` adds `drift-check` to standard/taskgroup sequences
- `.claude/agents/orchestrator.md` updated: single plan-approval template (replacing the dual auto/review prompt), drift-check on-demand procedure, deterministic alignment check procedure
- `.claude/agents/pragmatist.md` updated: Plan-Gating constraints note when a bundle with `implementation_design` is present
- `AI.md` hooks table updated to reference bundle-aware behavior
- `docs/ai/workflow.md` and `docs/ai/workflow-summary.md` updated: phase sequence reflects `drift-check`
- `docs/ai/quality-gates-summary.md` updated: `plan-approved` source clarified (AskUserQuestion OR bundle)
- No new state files (uses existing `plan-approved`, `pragmatist-signed`)
- No new hooks (drift-check is an agent-invoked helper, not a hook)
- New artifact: `.claude/local/handoff-bundle.yaml` (singular) / `.claude/local/task-groups/{group}/briefs/{seq}.bundle.yaml` (groups)

## Alternatives Considered

1. **Sequential task group of 4 briefs (decision + Prompt T + Prompt B + Pragmatist demotion).** Rejected — the changes are interlocked at the bundle schema; intermediate states would leave the system non-functional or require throwaway compatibility shims.
2. **Leave Plan-Gating Pragmatist as-is but skip it when bundle is fresh.** Smaller change but doesn't address the Orchestrator's own plan re-derivation (the larger token cost).
3. **Promote the brief itself (no separate bundle artifact).** The brief is markdown — drift-checking it requires markdown parsing in `_phase-helper.sh` (fragile). A separate YAML bundle gives a stable, machine-checkable contract while preserving the brief as the human-readable artifact.

## References

- Decision t-0014: Phase-Aware Flow Model (amended — new `drift-check` phase)
- Decision t-0020: Task Contract System (amended — contract sourced from bundle)
- Decision t-0025: Pragmatist Agent (amended — alignment sub-mode demoted)
- Decision t-0029: Operator Acknowledgment Enforcement (amended — bundle is the single ack)
- Decision t-0035: Selective Spec Loading (amended — snapshot once at Prompt T)
- Decision t-0017: Operator Automation Layer (bundle path works in headless mode)
