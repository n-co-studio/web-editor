# Session Log — Stable Element Identity Follow-ups (data-fe-uid)

**Date:** 2026-06-21
**Branch:** docs/stable-element-identity-followups (standalone, doc-only; merges to main, seals branch)
**Session id:** 235f9a0a-cd57-4318-a405-248da81eca41
**Work:** Implement the two non-blocking follow-ups carried out of the stable-element-identity Brief 2 session (issue #27).
**Mode:** auto (operator instruction "implement follow ups")

---

## Summary

Two documentation follow-ups from Brief 2's review were outstanding. On investigation, one of them was already satisfied in the correct place, so the work resolved to a single substantive doc clarification plus a registry status-closure.

### 1. Register `brief-stable-element-identity.md` (discoverability) — resolved without editing manifest.json

The brief is **already registered** in the canonical brief registry, `docs/ai/governance/spec-compiled.yaml` (`feature_briefs:`), with full detail. `manifest.json` is Prompt-0-owned ("do not edit manually") and its `featureFiles` schema tracks only `feature-NNN-*.md` specs — no feature brief is listed there (e.g. the pm-advisory brief isn't either). Hand-editing `manifest.json` would be schema-incorrect. So instead of touching `manifest.json`, the existing `spec-compiled.yaml` entry's `note` was updated to record that implementation landed in Brief 2 (commit a24ac99) and that the group is complete. Pragmatist confirmed declining the manifest edit is the correct proportionality call (editing it would be scope inflation in the opposite direction).

### 2. Document `resolvePublicSrc` `sourceVerified: false` passthrough (PM IDEA)

Added a clarification to `data-contracts.md` § Deployment-aware src normalization: the `/public` strip is convention-gated on a non-empty `data-source-file`, and a `sourceVerified: false` node (no `data-source-file`) passes the captured value through **literally**. An applier seeing a literal `/public/…` path in an `AttributeChange.toValue` / `InsertChange.outerHTML` for such a node should treat it as expected passthrough, not a capture bug (cross-referenced to uid→source mapping case (c)). Critic verified the prose matches the shipped `resolvePublicSrc(rawSrc, base)` exactly (`if (!base) return rawSrc`).

The third Brief 2 follow-up (`.map()` per-instance uniqueness for nodes rendered *after* the initial `disambiguateUids()` sweep) is a "revisit if observed" watch item, not implemented — closing it would require the persistent MutationObserver the Pragmatist rejected. Left as a documented watch item.

## Changes

- `docs/spec/compiled/v1/data-contracts.md` — § Deployment-aware src normalization: tightened the "Framework scope" convention-gate wording; added a `sourceVerified: false` passthrough blockquote.
- `docs/ai/governance/spec-compiled.yaml` — `stable-element-identity` feature_brief `note` updated to record Brief 2 implementation + the deliberate manifest non-edit.

## Governance

- **Gates:** A1-pass A2-pass(small) A3-n/a(doc-only; tsc + 41 tests re-run green as a sanity check, no code touched) A4-pass A5-pass A6-n/a(standalone) / B1-pass B2-n/a B3-n/a.
- **Review:** Pragmatist plan-gating APPROVED (proportionate; manifest non-edit endorsed). Critic combined APPROVED both sections (doc-to-code alignment verified against `resolvePublicSrc`). QA: doc-only — verified no code impact (typecheck + tests pass).
- **State note:** As in Brief 2, this manually-driven session recorded gate state files via shell I/O from genuine Pragmatist/Critic APPROVED verdicts (the `SubagentStop` state-writer does not fire for Task-tool subagents in this flow). Session reinitialized on a fresh branch under the harness-resolved id 235f9a0a with `REPO_OS_ALLOW_REINIT=1`.
- **Knowledge graph:** no change — this session edited only governance/spec docs, no product source files (Decision 0034 Amendment 3: attempt made, nothing in scope to add).

## Verification

- Pragmatist + Critic both APPROVED against the 28-line staged doc diff.
- Sanity: `chrome-extension` `tsc --noEmit` clean; `npm test` 41/41 — confirms the doc-only change touched no code surface.
