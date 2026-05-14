# Decision 0035 — Selective Spec Loading

## Status
Accepted

## Triggers

- type: file
- path: `docs/spec/compiled/`
- path: `.claude/tools/spec-digest.sh`
- path: `docs/spec/_templates/`
- keywords: `spec loading, spec digest, DIGEST.md, selective loading, manifest features, spec_digest_sha, feature index, token reduction, specialist dispatch`

## Decision

Reduce compiled spec token consumption via deterministic spec digests, a manifest-based feature index, and task-scoped selective loading. Full-load spec reading (~153K tokens for large projects) is replaced by selective loading (~5-10K tokens per specialist) for all specialist dispatch paths.

### Core Invariants

1. **Compiled specs remain authoritative.** `DIGEST.md` is a derived artifact — when digest and spec conflict, spec wins. Never treat `DIGEST.md` as a source of truth.
2. **Deterministic extraction only.** `spec-digest.sh` uses awk/sed extraction — no LLM calls. Same input always produces same output.
3. **Backward compatibility.** Absent `### Spec References` → full spec loading (legacy briefs, hotfixes). Absent knowledge graph → full feature loading. Both are fallbacks, not gates.
4. **Decision record required.** This change is a governance change to prompt loading behavior — recorded here per Decision 0002.

### Components

#### 1. YAML Frontmatter in Spec Templates

Each spec template in `docs/spec/_templates/` carries a YAML frontmatter block:

```yaml
---
title: "[spec name]"
scope_modules: []   # populated by Prompt 0 during interview
keywords: []        # populated by Prompt 0 during interview
spec_type: core     # or "feature"
---
```

Feature brief templates (`feature-brief.md`, `features/_feature-template.md`) use `spec_type: feature`. This enables deterministic extraction without LLM calls. Prompt 0 populates `scope_modules` and `keywords` during the interview phase.

**Retroactive path:** Existing spec files without YAML frontmatter fall back to extracting `# Title` headers and first paragraphs (less structured but functional). A future Prompt 0 Update run adds proper frontmatter.

#### 2. `spec-digest.sh` — Deterministic Digest Generator

Located at `.claude/tools/spec-digest.sh`. Reads `manifest.json` → finds active version → for each spec file in `docs/spec/compiled/{active}/`: extracts YAML frontmatter + first paragraph under each `##` heading. Writes `docs/spec/compiled/{active}/DIGEST.md`.

- Idempotent — same input always produces same output
- Runs in milliseconds
- Includes `spec_version` provenance stamp matching `manifest.json` `active`
- Falls back to header+paragraph extraction for files without YAML frontmatter
- Also updates `manifest.json` with `features` array and `spec_digest_sha`

**Staleness detection:** Consumers check `spec_version` in `DIGEST.md` against `manifest.json` `active`. Mismatch → fall back to full spec loading.

**Trigger:** Any session that writes to `docs/spec/compiled/{active}/` should regenerate the digest. Currently triggered by Prompt 0 close sequence (both Fresh and Update modes).

#### 3. `manifest.json` Extended Schema

```json
{
  "active": "v1",
  "versions": [...],
  "features": [
    {
      "id": "feature-slug",
      "title": "Feature Title",
      "status": "active",
      "scope_modules": ["module-a"],
      "keywords": ["keyword-a"]
    }
  ],
  "spec_digest_sha": "abc123...",
  "note": "..."
}
```

`features` array populated by `spec-digest.sh`. `spec_digest_sha` enables staleness detection without reading the digest file. Older sessions that read `manifest.json` without referencing these fields are unaffected (schema is additive).

#### 4. Mode-Aware Loading Rules

**Prompt T Query mode:** Full core specs loaded by Orchestrator. Features loaded only if operator references by name. No change from pre-decision behavior.

**Prompt T Brief mode (specialist dispatch):** All specialists receive `DIGEST.md` + `manifest.json` features array + task-relevant feature briefs. Per-specialist additions:
- Architect: + full `architecture.md`, `boundaries.md`
- Critic (spec mode): full core specs (gap detection requires full picture)
- Pragmatist: + full `architecture.md`
- Exploration: + full `architecture.md`, `integrations.md`
- PM Advisory: + full `product.md`, `mvp-scope.yaml`
- UX Strategist: + full `design-system.md`, `product.md`
- Performance Engineer: + full `architecture.md`
- Data Strategist: + full `data-contracts.md`
- Security Analyst: + full `architecture.md`, `integrations.md`

**Prompt A Phase 1:** Orchestrator reads full specs for activation signal scanning (tier selection). Specialists dispatched with selective loading per the same mapping above.

**Prompt B:** Reads `DIGEST.md` + spec files listed in `### Spec References`. When `### Spec References` is absent (legacy briefs, hotfixes), falls back to full spec loading.

**Fallback chain (Prompt B feature relevance, in priority order):**
1. Explicit reference in `### Spec References` section of the brief
2. Knowledge graph relevance (`kg-relevance.sh`) when product graph exists with spec-feature nodes
3. Keyword match between task scope modules and `manifest.json` `features[].scope_modules`
4. When none of the above produces results AND knowledge graph doesn't exist: load all feature briefs

### Retroactive Generation

Existing projects (specs compiled before this decision) run `.claude/tools/spec-digest.sh` standalone to generate the digest and features array. For spec files lacking YAML frontmatter, the script extracts `# Title` headers and first paragraphs — less structured but functional. A Prompt 0 Update run adds proper frontmatter.

### Sequencing

- Sequences after "Optimize Specialist Dispatch Token Efficiency" (queue 5afdbd43) — that brief establishes inline context injection; this brief establishes what content is loaded
- Sequences after "Prompt B Sidecar Task Contract Reading" (queue f381c32b) — shared scope on Prompt B loading logic
- Unblocks: Spec files as KG nodes (future — extends `kg-relevance.sh` to cover spec-feature nodes)
- Unblocks: Per-specialist model tier optimization (lighter models viable when context is smaller)

## Rationale

In mature projects (massimo: 42 files, 612KB, 31 feature briefs), full spec loading across 5 specialists costs ~765K tokens per Prompt T Brief session. Selective loading targets a 90%+ reduction while preserving full fidelity where structurally required (Critic in spec mode, Orchestrator activation scanning). Deterministic extraction is preferred over LLM-generated digests to avoid hallucination risk and non-reproducibility.

## Risks Accepted

1. **Digest staleness between Prompt 0 runs:** If a feature brief is added via Prompt B (two-brief Prompt T path), the digest may not include it until the next Prompt 0 Update or manual `spec-digest.sh` run. Mitigated by: the trigger rule above.
2. **Specialist under-loading:** A specialist might miss context because the Orchestrator didn't include a relevant spec. Mitigated by: Critic always getting full specs, fallback to full load when `Spec References` absent, and specialists retaining codebase access for independent exploration.
3. **Digest quality for retroactive projects:** Existing spec files without YAML frontmatter produce less-structured digests. Mitigated by header+paragraph fallback and Prompt 0 Update path.

## Amendment (Decision 0038 — Handoff Bundle)

When a handoff bundle is present, selective spec loading runs once at Prompt T and the resulting `spec_snapshot.files[]` (path + sha256) is sealed into the bundle. Prompt B's `drift-check` validates the snapshot matches the working tree before forward-jumping; if any file's sha differs, drift-check returns code 4 (focused re-approval). This eliminates the second selective-load pass that Prompt B would otherwise run in the legacy path. Sessions without a bundle (legacy briefs) continue to run selective spec loading at Prompt B init.
