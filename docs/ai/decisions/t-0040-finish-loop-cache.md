# Decision t-0040 — Finish-Loop Dimension Verdict Cache

## Status
Accepted

## Triggers

- type: file
- path: `docs/ai/prompts/prompt-f-finish-loop\.md`
- path: `\.claude/hooks/_phase-helper\.sh`
- keywords: `finish-loop cache, dimension input hash, cached_dimension_verdict, record_dimension_verdict, INHERITED verdict`

## Context

Prompt F (finish-loop) re-assesses all six convergence dimensions on every cycle, including a regression-check pass on already-PASS dimensions. The intent is correct (regressions can surface as side-effects of fixing other dimensions) but in the common case — one dimension fails, fixes target that dimension, the other five are stable — five-sixths of the per-cycle work is redundant.

Identified in `docs/ai/research/process-audit-2026-05-13.md` Finding 7. The audit's recommendation: hash each dimension's input set; when the hash hasn't changed since the prior PASS, inherit the prior verdict. This is the standard cache-with-invalidation pattern already used elsewhere in the build system (state files, governance evidence, KG relevance context).

## Decision

### 1. Cache file

Session-scoped YAML at `<session_state_dir>/finish-loop-cache.yaml`. Schema:

```
session_id: <id>
entries:
  - dimension: "<slug>"
    hash: "<sha256-hex>"
    verdict: "PASS"
    cycle: <N>
    timestamp: "<ISO 8601 UTC>"
```

Append-only across cycles. FAIL verdicts are not cached — only PASS. The cache is cleaned by `cleanup_session_files()` at session close (Decision 0013 / Decision 0030 session-bound state lifecycle).

### 2. Helper functions in `_phase-helper.sh`

- `dimension_input_hash <dimension> <file...>` — deterministic SHA-256 over the input file set. Files are sorted with `LC_ALL=C` for OS-independent ordering. Per-file content sha via `git hash-object` (working-tree state). Absent files contribute a literal `MISSING` marker so deletion changes the hash. The dimension name is for traceability only and is NOT part of the hash, so the same input set always produces the same hash regardless of which dimension owns it.
- `cached_dimension_verdict <dimension> <current_hash>` — exit 0 with `PASS` on stdout when a PASS entry exists whose hash matches `current_hash`. Exit 1 on miss or no cache. AWK-based YAML reader — no `yq` dependency.
- `record_dimension_verdict <dimension> <hash> <verdict> <cycle>` — appends an entry to the cache. Creates the file with header on first call.

### 3. Per-dimension input sets (codified in prompt-f-finish-loop.md)

| Dimension          | Input set                                                                                |
|--------------------|------------------------------------------------------------------------------------------|
| Spec Alignment     | `scope_files` ∪ active spec files                                                        |
| Completeness       | `scope_files`                                                                            |
| Correctness        | `scope_files`                                                                            |
| Test Gate          | `scope_files` ∪ matching test files                                                      |
| Governance         | `scope_files` ∪ working-tree change fingerprint (`git diff --name-only HEAD`)            |
| Integration        | `scope_files` ∪ caller files identified at first fresh assessment                        |

Input sets are agent-interpreted (D6 caller discovery requires reasoning, not a file-system rule), so they live in the prompt rather than in shell. Codifying them in shell would be more brittle for D4/D6.

### 4. Assessment loop semantics

- **Cycle 1**: always fresh assessment. After each PASS verdict, the agent calls `record_dimension_verdict`.
- **Cycle N ≥ 2**: for each dimension, compute the current input hash. If `cached_dimension_verdict` returns PASS, mark the dimension `[INHERITED]` in the assessment block and skip reassessment. Otherwise reassess fully.
- **Convergence**: ALL PASS or INHERITED (no FAIL) → converged.

### 5. Force-reassess on loop-back source

Before each cycle ≥ 2, the agent computes the touched-files set (files modified by the previous fix phase). For each dimension whose input set intersects the touched-files set, the cache lookup is skipped and the dimension is reassessed fully — regardless of hash. This is a belt-and-suspenders guard against touch-and-revert edge cases (file modified then reverted to identical content within the same fix phase) where hash comparison alone would not invalidate the cache. In the common path, hash mismatch is sufficient.

### 6. Regression-check semantics

Hash comparison is the regression signal:

- **Hash unchanged** → inputs identical → no regression is possible. Inherit `PASS`.
- **Hash changed (or force-reassess triggered)** → reassess fully. If the dimension was PASS in a prior cycle and now FAILs, the existing `FINISH_LOOP_REGRESSION:` sentinel path applies — sentinel written, runner routes to `review:scope-deviation`.

The invariant "previously-passing dimension is verified still passing" is preserved with strictly weaker work: hash equality → input equality → verdict equality.

## Alternatives Considered

1. **Cache the dimension output rather than the verdict.** More flexible (could replay output without reasoning) but adds storage and lacks the regression invariant — output cached from a different input is meaningless. Verdict + input hash is the minimum sufficient information.

2. **Use `git ls-files -s` for input hashing (the audit's literal suggestion).** Reads staged blob shas (index state). Finish-loop fix phases write to the working tree without staging until the commit phase, so `git ls-files -s` would not reflect the state the dimensions evaluate. `git hash-object` on working-tree content is the correct hash source.

3. **Drop the force-reassess rule and rely solely on hash mismatch.** Pragmatist-flagged as the leaner option (touch-and-revert is a vanishingly rare edge case). Operator chose to retain force-reassess per brief contract — the invariant is explicit and defensive guards against a future change that introduces touch-and-revert (e.g., a fix that auto-formats then reverts unchanged sections).

4. **Persist the cache across sessions.** Cross-session inheritance would require validating spec/codebase state continuity. Session-scoped is the safe minimum; finish-loop sessions are short-lived (5-cycle cap) and the cost of the first fresh assessment per session is acceptable.

## Consequences

**Positive:**
- Five-sixths of redundant per-cycle work eliminated in the common case (one dimension fails, rest stable).
- Regression invariant strictly preserved — hash comparison is a stronger guarantee than re-execution, since hash equality implies input equality.
- Cache is fail-soft: a missing or malformed cache falls through to fresh assessment (exit 1 from `cached_dimension_verdict`).

**Negative:**
- Cache YAML is agent-written; format determinism depends on `record_dimension_verdict`'s `printf` template. The AWK reader tolerates simple flat schema only.
- Input set accuracy depends on the brief's declared `scope_files`. If `scope_files` is misdeclared, dimensions could inherit stale verdicts. Mitigation: documented in prompt-f, reviewer-detectable, force-reassess on touched-files intersection provides a second invalidation path.
- Slight prompt-f complexity increase (two new subsections: Dimension Input Sets, Assessment Cycle Cache).

## References

- Decision t-0013: Session Branch Isolation (session-scoped state lifecycle)
- Decision t-0030: Worktree Session Isolation (per-session state directories)
- `docs/ai/research/process-audit-2026-05-13.md` Finding 7
- `docs/ai/prompts/prompt-f-finish-loop.md` § Dimension Input Sets, Assessment Cycle Cache
- `.claude/hooks/_phase-helper.sh` § Finish-loop dimension cache
- `.claude/hooks/_cleanup-helper.sh` (`cleanup_session_files`)
