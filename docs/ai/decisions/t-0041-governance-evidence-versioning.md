# Decision t-0041 — Governance Evidence Versioning

## Status
Accepted

## Triggers

- type: file
- path: `docs/ai/governance/spec-compiled`
- path: `docs/ai/governance/advisory-reviewed`
- path: `docs/spec/compiled/manifest\.json`
- path: `docs/ai/prompts/prompt-0-spec-builder\.md`
- path: `docs/ai/prompts/prompt-a-repo-os\.md`
- path: `docs/ai/prompts/prompt-b-product-build\.md`
- path: `\.claude/hooks/pre-commit-gates\.sh`
- path: `\.claude/hooks/bash-guard\.sh`
- keywords: `governance evidence, spec_version, governance-checked, governance-bash-fired, fast-skip predicate, inter-session governance`

## Context

`docs/ai/governance/spec-compiled` (written by Prompt 0) and `docs/ai/governance/advisory-reviewed` (written by Prompt A) are read by Prompt B at session start and re-validated by `pre-commit-gates.sh` Gate 3 at commit time. Both files already carried a `spec_version` field, but the field was informational — every Prompt B session re-checked file existence only, regardless of whether the spec had changed since the last governance run.

Identified in `docs/ai/research/process-audit-2026-05-13.md` Finding 8. The audit's recommendation: treat the evidence files as version-stamped artefacts and fast-skip the warning when the embedded `spec_version` matches `manifest.json`'s `active` version. This is the standard cache-with-invalidation pattern used elsewhere in the build system (state files, knowledge-graph relevance context, finish-loop dimension cache — Decision 0040).

## Decision

### 1. Fast-skip predicate

```
governance_match(file) :=
  exists(file)
  AND (normalised(spec_version in file) == normalised(manifest.json.active))
```

Normalisation rules (applied to both sides before comparison):
- `null` → `""`
- `~` (YAML null shorthand) → `""`
- missing field → `""`
- surrounding single or double quotes are stripped
- trailing whitespace is stripped

Empty-equals-empty matches (template-mode / pre-spec state) so the predicate stays silent in green-field repos.

### 2. Three enforcement points

The predicate is mirrored at three checkpoints. Each is advisory — never blocks — and uses a session-scoped first-fire marker so the warning surfaces once per session on success and re-fires on every check while the divergence persists.

| Checkpoint | When it fires | First-fire marker |
|---|---|---|
| Prompt B Inter-Session Governance prose | Session start (operator-facing) | (none — prose check) |
| `pre-commit-gates.sh` Gate 3 | Each `git commit` attempt | `.claude/.state/governance-checked` |
| `bash-guard.sh` Phase 1d | First Bash-write call of session | `.claude/.state/governance-bash-fired` |

### 3. Marker semantics

- **Match** (predicate passes for both evidence files) → write marker, suppress for rest of session.
- **Mismatch** (file exists but `spec_version` differs) → emit `Advisory: Prompt {0|A} not re-run since spec v<old> → v<new> — re-run to refresh docs/ai/governance/{spec-compiled|advisory-reviewed}.` Delete any existing marker so the warning re-surfaces on the next check.
- **Missing** (file absent) → emit existing missing-file warning. Delete any existing marker so the warning re-surfaces.

The marker is session-scoped: `_cleanup-helper.sh` deletes both `governance-checked` and `governance-bash-fired` at session close (idempotent commit-gate / advisory-fire markers, no `session_id` field — concurrent deletion is benign).

### 4. Hook implementation notes

- `pre-commit-gates.sh` reads `manifest.json.active` via `jq` (already a hard dependency in this hook) and `spec_version` via `awk` (no `yq` dependency added).
- `bash-guard.sh` reads `manifest.json.active` via `jq` and `spec_version` via `awk`, gated by an inline write-pattern test (`"file_path"`, `>`, `tee `) so the check fires only on first Bash-write call per session. The marker-first pattern (`[ -f marker ]` test before any subprocess) keeps the steady-state hot path cheap; the cold path pays one `jq` + two `awk` invocations once per session on match, or on every Bash-write call while mismatched.
- Branches gated to `feature/*`, `fix/*`, `hotfix/*`, `release/*` — main / experiment / queue-triage paths exempt (consistent with existing Gate 3 scoping).

### 5. Prompt 0 / Prompt A authoring contract

Both prompts already emit `spec_version`. The decision elevates this from informational to **load-bearing**: the active version string MUST be written verbatim from `manifest.json.active`. When `active` is `null`, write `spec_version: null` so the predicate matches in template-mode / pre-spec repos.

## Consequences

### Positive
- Prompt B sessions no longer pay an operator-readable warning on every session start when the spec hasn't drifted.
- Mismatch produces a sharper, actionable message (`v<old> → v<new>`) instead of the previous "may not have completed governance write" line, which existed for both missing-file and never-fired states.
- The reset-on-mismatch semantics keep the warning visible across multiple commit attempts and Bash writes — the operator cannot accidentally suppress a divergence by clicking through one prompt.
- Pattern is consistent with Decision 0040 (finish-loop cache) and the rest of the build-system's cache-with-invalidation model.

### Negative
- `bash-guard.sh` Phase 1d adds a `jq` + `awk` subprocess cost on the first Bash-write call of each session. The marker fast-path keeps subsequent calls cheap. The Pragmatist flagged this as a third enforcement point; operator accepted the trade-off in favour of mid-session coverage.
- A version-bump to `manifest.json.active` without re-running Prompt 0 / Prompt A produces a persistent advisory on every commit attempt and every Bash-write call until the operator either re-runs the upstream prompts or accepts the divergence (no clean suppression — by design).

### Neutral
- No new override flag introduced. Existing `REPO_OS_RECOVER=1` and `.claude/.state/.recover-signal` already bypass the relevant branches of bash-guard / pre-commit-gates.

## Implementation references

- `docs/ai/prompts/prompt-b-product-build.md` § Inter-Session Governance
- `.claude/hooks/pre-commit-gates.sh` Gate 3 (Inter-session governance)
- `.claude/hooks/bash-guard.sh` Phase 1d
- `.claude/hooks/_cleanup-helper.sh` (cleanup of `governance-bash-fired` marker)
- `docs/ai/prompts/prompt-0-spec-builder.md` § Governance Evidence
- `docs/ai/prompts/prompt-a-repo-os.md` § Governance Evidence

## Related decisions

- Decision 0014 — Phase-aware flow model (first-fire marker pattern)
- Decision 0035 — Selective spec loading (manifest.active as source of truth)
- Decision 0040 — Finish-loop dimension verdict cache (cache-with-invalidation precedent)
