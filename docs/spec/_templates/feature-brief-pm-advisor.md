---
title: "PM Advisory Agent"
scope_modules: []
keywords: []
spec_type: feature
---

# Feature Brief: PM Advisory Agent

## What
A read-only advisory agent that provides product strategy review, MVP scope management, and spec cohesion analysis across Repo OS prompt workflows. The PM agent advises on spec content — it does not modify files directly. Spec-edit proposals are structured outputs that the Orchestrator executes after operator approval.

## Why
As projects grow, scope drift and spec inconsistency become significant risks. The Critic agent gates code quality but has no mandate over product strategy or spec coherence. A dedicated PM advisory agent fills this gap: it guards the MVP scope definition, detects spec drift before it reaches implementation, and provides product strategy review alongside the existing advisory board specialists. Without this agent, scope decisions are implicit and spec inconsistencies are caught late (during build or code review) rather than early (during planning and advisory review).

## Prior Art
None.

## What It Touches

- [ ] UI / Design System / User Flows
- [ ] Auth / Sessions / Permissions
- [ ] Database / Schema / Migrations
- [x] API Contracts / Data Models
- [ ] Real-time / WebSockets / Streaming
- [ ] Large Datasets / Media / File Processing
- [ ] Payments / Billing / Financial
- [ ] External Integrations / Third-party APIs
- [ ] Performance-Critical Paths

## Key Requirements

### Agent Identity

- **Type:** Advisory agent (read-only)
- **BLOCK:** No Edit, Write, or Bash tools — enforced by `disallowedTools` in subagent frontmatter (same constraint as all advisory agents)
- **BLOCK:** No sub-subagents — enforced by `disallowedTools` (Agent/Task)
- **Subagent file:** `.claude/agents/_pm-advisor.md`
- **Output:** PM Assessment brief (structured text returned to Orchestrator)
- **Relationship to Orchestrator:** PM produces advisory output; Orchestrator decides whether to present to operator, execute spec-edit proposals, or defer

### Responsibilities

1. **MVP Scope Advisory** — Evaluate whether proposed work aligns with the defined MVP scope. Reference `mvp-scope.yaml` to classify features as IN-SCOPE, OUT-OF-SCOPE, or DEFER
2. **Spec Cohesion Guardian** — Detect inconsistencies, contradictions, and gaps across compiled spec files. Cross-reference `product.md`, `architecture.md`, `data-contracts.md`, `features/`, `boundaries.md`, and `integrations.md`
3. **Product Strategy Review** — Assess whether the spec or feature brief reflects sound product decisions: feature prioritization, user value alignment, dependency sequencing, and scope boundaries

### Integration Points

#### 1. Prompt T — Brief Mode (4th specialist)

When Prompt T runs in Brief mode, the PM agent is dispatched as a 4th specialist alongside Architect, Exploration, and Critic:

| Specialist | Focus |
|---|---|
| Architect | Structural fit, dependencies |
| Exploration | Alternatives, best practices |
| Critic | Gaps, risks, contradictions |
| **PM** | **Scope alignment, MVP fit, product strategy** |

**Dispatch condition:** PM is dispatched only when at least one of: (a) a compiled spec exists (`manifest.json` has `active` ≠ null), or (b) `mvp-scope.yaml` exists. When neither exists, PM is skipped silently (template mode without compiled spec).

**PM receives:** Task description from operator, compiled spec files (if they exist), `mvp-scope.yaml` (if it exists), codebase access (read-only).

**PM output:** PM Assessment brief (see PM Assessment Format below). Uses the standard advisory board severity labels (CRITICAL / RECOMMENDATION / IDEA) but extends the format with PM-specific sections (Spec-Edit Proposals, scope labels). The Orchestrator extracts severity-labeled findings for synthesis into the Refinement Report and handles PM-specific sections separately.

#### 2. Prompt A — Advisory Board Member (Initialize mode)

When Prompt A runs in Initialize mode (Phase 1 — Advisory Board Review), the PM agent joins the advisory board dispatch:

- **Tier activation:** PM is activated at **Standard tier and above** (same activation level as Exploration). At Lite tier, PM is not dispatched.
- **Activation signal:** Always active at Standard+ (no signal-based conditional activation — PM reviews the full spec, not a specific domain)
- **Input:** All compiled spec files in `docs/spec/compiled/{active}/`
- **Output:** PM Assessment brief (full format — see PM Assessment Format below)
- **Synthesis:** Orchestrator includes PM findings in the Refinement Report alongside other specialist briefs. PM findings appear under the standard sections (Critical Findings, Recommendations, Ideas) with their scope labels preserved

#### 3. Prompt B — Review Phase (parallel with Critic)

During the Prompt B build sequence, after Builder signals completion, the PM agent is dispatched in the `review` phase alongside the Critic (cohesion mode):

| Phase | Agent | Notes |
|-------|-------|-------|
| build | Builder | Implements changes |
| review | **Critic** (cohesion mode) + **PM** (spec-drift check) | Parallel dispatch |
| verify | QA Verifier | Commit blocker |

**PM focus in review phase:** Spec-drift detection. The PM compares the implementation diff against the compiled spec and `mvp-scope.yaml` to identify:
- Features implemented that are not in the spec or are marked OUT-OF-SCOPE/DEFER
- Spec sections that the implementation contradicts
- Scope creep indicators (implementation exceeds the task brief's stated scope)

**Dispatch condition:** Same as Prompt T — requires at least one of compiled spec or `mvp-scope.yaml`. If neither exists, PM is skipped in the review phase.

**PM output:** PM Assessment brief with spec-drift findings. These are advisory — they do not block the commit (Critic verdict is the gate; PM is informational).

#### 4. On-Demand

The operator can request PM analysis at any time by instructing the Orchestrator to dispatch the PM agent. On-demand dispatch follows the same input/output format as advisory board dispatch but is not tied to a specific phase.

#### 5. Task Group — Merge-Brief Contract-Init

When a merge brief session begins (`taskgroup-merge` session type), the PM agent is dispatched once during the `contract-init` phase to review the combined scope of all content briefs against the MVP scope:

- **Input:** Task group contract (all brief intents), `mvp-scope.yaml`, compiled spec
- **Output:** PM Assessment brief covering cross-brief scope coherence
- **Dispatch frequency:** Once per task group (at merge-brief init), not per individual content brief

### PM Assessment Format

The PM Assessment uses the standard advisory board severity levels plus orthogonal scope labels:

#### Severity Levels (standard)

| Severity | Meaning |
|----------|---------|
| CRITICAL | Must address before proceeding — spec contradiction, scope violation, or missing requirement |
| RECOMMENDATION | Should address — product improvement, scope clarification, or consistency fix |
| IDEA | Could address — opportunity for improvement, alternative approach, or future consideration |

#### Scope Labels (PM-specific, orthogonal to severity)

| Label | Meaning |
|-------|---------|
| IN-SCOPE | The finding relates to work that is within the defined MVP scope |
| OUT-OF-SCOPE | The finding relates to work that is outside the defined MVP scope |
| DEFER | The finding relates to work that should be deferred to a later phase |

**Synthesis routing:** Scope labels do not affect how findings are routed in the Refinement Report. Findings route to Critical Findings / Recommendations / Ideas by severity (same as all specialists). Scope labels are preserved inline in the finding text. The Orchestrator does not filter or group by scope label — the label is informational context for the operator. Spec-Edit Proposals are appended as a new subsection at the end of the Refinement Report (after Unresolved Critic Findings), titled "### PM Spec-Edit Proposals".

**Format:**

```
## PM Assessment

**Scope reviewed:** [spec files, feature brief, or diff reviewed]
**MVP scope source:** [mvp-scope.yaml path, or "none — advisory without scope file"]

### Findings
1. [Finding] — CRITICAL / RECOMMENDATION / IDEA — IN-SCOPE / OUT-OF-SCOPE / DEFER
   - Context: [why this matters from a product strategy perspective]
   - Suggestion: [what to do about it]
   - Spec reference: [which spec file/section this relates to, if applicable]

2. [Next finding...]

### Spec-Edit Proposals
[Structured proposals for spec changes — see Spec-Edit Proposal Format below. Empty section if no edits proposed.]

### Summary
- Critical: [count]
- Recommendations: [count]
- Ideas: [count]
- Scope distribution: [IN-SCOPE: N, OUT-OF-SCOPE: N, DEFER: N]
```

### mvp-scope.yaml

A YAML file that defines the MVP scope for the project. Created and maintained as a spec artifact.

#### Location
`docs/spec/compiled/{active}/mvp-scope.yaml`

#### Schema

```yaml
# MVP Scope Definition
# Created: at Prompt 0 (if operator provides MVP scope) or at first PM dispatch
# Updated: via spec-edit proposals (PM proposes, Orchestrator executes after operator approval)

goal: ""                    # 1-2 sentence MVP goal statement

features:
  - name: ""                # feature name (matches feature brief filename if one exists)
    status: in-scope        # in-scope | out-of-scope | defer
    rationale: ""           # why this status was chosen
    brief: ""               # path to feature brief (optional, empty if no brief exists)

status: draft               # draft | active | locked
last_modified_by: ""        # "prompt-0" | "pm-advisory" | "operator"
last_modified_date: ""      # ISO 8601
```

#### Lifecycle

1. **Creation:** `mvp-scope.yaml` is created during Prompt 0 if the operator provides MVP scope information during the spec interview. Alternatively, it is created at the first PM dispatch if the operator provides scope context at that time. The PM agent never creates this file directly — creation is always through the Orchestrator (via spec-edit proposal or Prompt 0 flow).
2. **Updates:** The PM agent proposes updates via spec-edit proposals. The Orchestrator presents proposals to the operator for approval, then executes approved changes.
3. **Status transitions:** `draft` → `active` (operator confirms scope is final) → `locked` (operator locks scope — PM findings against locked scope are automatically CRITICAL severity).
4. **Template mode:** When `manifest.json` has `active: null`, `mvp-scope.yaml` does not exist. The PM agent operates without a scope file in this case, providing advisory based on codebase analysis alone.

#### Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `goal` | string | yes | 1-2 sentence MVP goal statement |
| `features` | list | yes | Feature roster with scope status |
| `features[].name` | string | yes | Feature name |
| `features[].status` | enum | yes | `in-scope`, `out-of-scope`, or `defer` |
| `features[].rationale` | string | yes | Why this scope status was chosen |
| `features[].brief` | string | no | Path to feature brief file |
| `status` | enum | yes | `draft`, `active`, or `locked` |
| `last_modified_by` | string | yes | Who last modified this file |
| `last_modified_date` | string | yes | ISO 8601 date |

### Spec-Edit Proposal Format

When the PM agent identifies a spec inconsistency or gap, it includes a structured spec-edit proposal in its assessment. The PM never edits files directly — the proposal is output text that the Orchestrator presents to the operator and executes upon approval.

```yaml
spec_edit_proposals:
  - filename: "docs/spec/compiled/{active}/product.md"
    section: "## Target Users"          # section heading or field path
    current_value: |
      Target users are developers.
    proposed_value: |
      Target users are developers and technical project managers.
    rationale: "The PM advisory agent feature serves project managers as a secondary audience. The target users section should reflect this."
    severity: RECOMMENDATION
```

**Rules:**
- Each proposal targets a single file and a single section/field
- `current_value` must quote the existing text (so the Orchestrator can verify it still exists before applying)
- `proposed_value` provides the replacement text
- `rationale` explains why the change improves the spec
- The Orchestrator presents proposals to the operator as part of the PM Assessment review
- The operator may: **accept** (Orchestrator applies the edit), **reject** (no change), or **defer** (noted for later)
- Accepted proposals are applied by the Orchestrator using Edit tool — the PM agent is never given write access

### PM/Critic Boundary

The PM and Critic agents have distinct, complementary roles:

| Dimension | PM Advisory | Critic |
|-----------|-------------|--------|
| **Domain** | Product strategy, scope, spec coherence | Code quality, internal codebase coherence |
| **Input** | Compiled specs, mvp-scope.yaml, feature briefs | Implementation diff, source code |
| **Output** | PM Assessment (advisory) | Cohesion verdict (gate — blocks commit on CRITICAL) |
| **Authority** | Advisory only — findings are informational | Gate authority — CRITICAL findings block commit |
| **Spec edits** | Proposes via structured format | Does not propose spec edits |
| **Scope drift** | Detects scope drift (spec vs. intent) | Detects code drift (implementation vs. codebase patterns) |

**Conflict resolution:** When PM and Critic findings conflict (e.g., PM says a feature is OUT-OF-SCOPE but Critic says the implementation is coherent), the Critic verdict stands for commit gating purposes. The PM's scope concern is presented to the operator as advisory. The operator arbitrates: they may accept the PM's scope concern and defer the feature, or override and proceed with the Critic's clean verdict.

**No cross-dependency:** PM does not read Critic output, and Critic does not read PM output. They operate independently in the review phase. The Orchestrator synthesizes both outputs and presents them to the operator.

### Template Mode Behavior

When the repo is in template mode (`.claude/repo-mode` = `template`) and no compiled spec exists (`manifest.json` has `active: null`) and no `mvp-scope.yaml` exists:

- **PM is skipped entirely.** No dispatch in Prompt T, Prompt A, Prompt B review phase, or task group merge-brief.
- **Rationale:** Without a compiled spec or scope definition, the PM has no reference material to advise against. The PM's value comes from comparing work against defined scope and spec — without those artifacts, the agent would produce low-value generic advisory.

### Task Group Behavior

- **Sequential groups:** PM dispatches once at merge-brief `contract-init`, reviewing the combined intent across all briefs. Not dispatched per individual content brief.
- **Parallel groups:** Same as sequential — PM dispatches at merge-brief `contract-init` only.
- **No per-brief dispatch:** Individual content brief sessions do not trigger PM dispatch during their `contract-init` phase. The PM reviews the aggregate scope at merge time.

### Conditional Dispatch Summary

| Context | Condition | Dispatch? |
|---------|-----------|-----------|
| Prompt T (Brief mode) | compiled spec OR mvp-scope.yaml exists | Yes — 4th specialist |
| Prompt A (Initialize, Standard+) | compiled spec exists AND tier is Standard or Full | Yes — advisory board member |
| Prompt B (review phase) | compiled spec OR mvp-scope.yaml exists | Yes — parallel with Critic |
| On-demand | operator requests | Yes — any time |
| Task group merge-brief | compiled spec OR mvp-scope.yaml exists | Yes — at contract-init |
| Template mode (no spec, no scope) | neither exists | No — skipped |

## Files Requiring Amendment (Brief 2)

Brief 2 (Build) must amend these existing files to integrate the PM agent. This feature spec defines the target behavior; Brief 2 implements the wiring.

| File | Amendment |
|------|-----------|
| `.claude/agents/_pm-advisor.md` | **Create** — New subagent file with `disallowedTools` frontmatter (Edit, Write, Bash, Agent/Task). PM agent prompt, responsibilities, and assessment format |
| `docs/ai/prompts/prompt-t-task-definition.md` | Amend Step 2 dispatch table to include PM as conditional 4th specialist. Amend the REQUIRE rule ("3-agent team is fixed") to "3 core + conditional PM". Add conditional dispatch logic (compiled spec OR mvp-scope.yaml) |
| `docs/ai/prompts/prompt-a-repo-os.md` | No direct amendment needed — Prompt A delegates to `_advisory-board.md` for dispatch logic |
| `.claude/agents/_advisory-board.md` | Add PM to the Activation Summary table (Standard+ tier, Trigger value: "Standard+ (always)"). Add PM row to Orchestration Procedure. Add scope label handling to Refinement Report synthesis: scope labels are preserved inline with findings but do not affect routing (findings still route to Critical/Recommendations/Ideas by severity). Append new "### PM Spec-Edit Proposals" subsection at end of Refinement Report template (after Unresolved Critic Findings) |
| `.claude/agents/_advisory-board-lite.md` | Add PM to the compressed agent reference |
| `docs/ai/prompts/prompt-b-product-build.md` | Amend Build Sequence table: review phase becomes "Critic (cohesion mode) + PM (spec-drift)" with parallel dispatch note. Add conditional dispatch logic. Add PM output handling (advisory, presented alongside Critic verdict) |
| `.claude/agents/orchestrator.md` | Add PM dispatch to On-Demand Procedures. Add spec-edit proposal execution procedure (present to operator, apply on accept) |
| `.claude/agents/_agent-glossary.md` | Add PM scope labels (IN-SCOPE / OUT-OF-SCOPE / DEFER) to a new PM-specific section, or note them as PM-specific extensions to the advisory board severity system |

## Constraints

- BLOCK: PM agent has no Edit, Write, or Bash tools — enforced by `disallowedTools` in subagent frontmatter
- BLOCK: PM agent has no sub-subagent capability — enforced by `disallowedTools` (Agent/Task)
- REQUIRE: PM spec-edit proposals are executed by the Orchestrator only after operator approval
- REQUIRE: PM findings do not block commits — only Critic has gate authority in the review phase
- REQUIRE: PM dispatches at Standard+ tier in Prompt A (not Lite)
- Decision 0014 — phase model is canonical; PM integrates into existing review phase via parallel dispatch, no phase amendments required

## Open Questions

- Should `mvp-scope.yaml` be auto-created during Prompt 0, or only when the operator explicitly provides scope information? (Spec says: created at Prompt 0 if operator provides scope, or at first PM dispatch)
- Should PM be dispatchable in Prompt A Lite tier for feature briefs? (Current spec: no — PM activates at Standard+)

## Acceptance Criteria

- [ ] PM advisory agent subagent file exists at `.claude/agents/_pm-advisor.md` with correct `disallowedTools` frontmatter
- [ ] PM is dispatched as conditional 4th specialist in Prompt T Brief mode (`prompt-t-task-definition.md` amended)
- [ ] PM is dispatched at Standard+ tier in Prompt A advisory board (`_advisory-board.md` amended with PM row, synthesis logic, and scope label handling)
- [ ] PM is dispatched in Prompt B review phase parallel with Critic (`prompt-b-product-build.md` amended)
- [ ] PM is dispatched at merge-brief contract-init for task groups
- [ ] PM Assessment format includes severity + scope labels
- [ ] mvp-scope.yaml schema is implemented with all fields
- [ ] Spec-edit proposal format is implemented in PM output
- [ ] Orchestrator handles spec-edit proposal execution after operator approval (`orchestrator.md` amended)
- [ ] PM on-demand dispatch added to `orchestrator.md` On-Demand Procedures
- [ ] PM is skipped in template mode when no compiled spec and no mvp-scope.yaml exist
- [ ] PM/Critic operate independently — no cross-dependency
