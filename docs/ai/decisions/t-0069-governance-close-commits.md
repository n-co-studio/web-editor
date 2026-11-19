# Decision t-0069 — Governance-close session types commit on their own evidence

**Status:** Accepted
**Date:** 2026-11-17
**Amends:** Decision t-0025 (the Pragmatist plan gate applies to implementation plans only —
spec types are exempt at approval and at commit), Decision t-0019 (the commit gate's phase
requirement is per session type), Decision t-0041 (the governance-evidence `spec_version`
predicate becomes blocking for the session type that writes the evidence).
`.claude/hooks/_phase-helper.sh` (`is_pragmatist_exempt`, `get_close_commit_phases`),
`.claude/hooks/pre-commit-gates.sh`.

## Triggers

- type: file
- path: `\.claude/hooks/pre-commit-gates\.sh`
- keywords: `get_close_commit_phases, is_pragmatist_exempt, close_commit_evidence, spec-compiled, advisory-reviewed, governance-close`

## Context

Prompts 0, A and C all end with a commit at close: the compiled spec and `spec-compiled`
evidence, the advisory review and `advisory-reviewed`, or an audit's deferrals. None of their
session types could make that commit. Run against the real hooks in a test sandbox:

- **spec-fresh / spec-update** could not reach `approval` without `pragmatist-signed`.
  `has_plan_gate` treats any type with an approval phase as plan-gated, and the exemption list
  (`experiment|prototype-*|ephemeral`) named only types with no approval phase, so it never
  exempted anything. Prompt 0 never dispatches the Pragmatist: it reviews implementation
  plans, and spec approval is the operator's "Spec complete".
- Committing from `governance`, a spec session was then blocked by the phase gate (spec types
  have no `commit` phase, so `assert_phase commit` cannot pass), by the missing `qa-verified`
  (Prompt 0 never dispatches QA) and again by the missing `pragmatist-signed`.
- **advisory-init / advisory-reinit / audit** hit the same phase-gate and `qa-verified` blocks,
  and also `plan-approved`, which nothing can write for a type with no approval phase.

## Decision

### 1. The Pragmatist reviews implementation plans only

`is_pragmatist_exempt` returns true for `experiment|prototype-*|ephemeral|spec-fresh|spec-update`.
Both the approval substance check (`advance_phase`) and the commit gate's `pragmatist-signed`
check skip exempt types. The `plan-approved` requirement is unchanged: a spec session still
needs the operator's approval at its approval phase.

### 2. Commit phases

`get_close_commit_phases` names the phases a governance-close type commits from:

| Type | Commits from |
|---|---|
| spec-fresh, spec-update, advisory-init, advisory-reinit | `governance`, `close` |
| audit | `close` |

Every other type gets an empty list, and the commit gate requires the `commit` phase as before.

### 3. Scope and evidence in place of `qa-verified`

The evidence below is a file the agent writes itself, so it cannot stand in for QA on its own.
What makes the waiver safe is **scope**: a governance-close commit may only add or modify the
paths its prompt writes. A staged deletion, type change or a rename's source (read with
`--no-renames --name-status`, not the gate's `ACMR` list) blocks, as does any other path.
Unstaged changes to tracked files are held to the same scope, because `commit -a` or a
pathspec commits them without their ever reaching the index the hook reads; a listing that
fails blocks. The hook runs before the whole Bash call, so a commit call that also changes the
index (`git add|stage|rm|mv|apply|checkout|restore|reset|update-index|stash|merge|cherry-pick|revert|pull|switch|read-tree`)
is refused: stage in one call, commit in the next. Commit message text naming one of those
verbs is refused too; `git commit -F <file>` avoids it.

| Type | May commit (plus flat `docs/ai/logs/sessions/session-*.md` and state-writer's `docs/ai/governance/criteria-verdicts/*.yaml`) | Evidence |
|---|---|---|
| spec-fresh, spec-update | `docs/spec/compiled/**`, `docs/ai/governance/spec-compiled`, `docs/ai/knowledge-graph/product-graph.yaml` (the close-sequence graph refresh, workflow.md step 1; the KG gate still checks it) | `spec-compiled` |
| advisory-init, advisory-reinit | `docs/ai/governance/advisory-reviewed`, `docs/ai/knowledge-graph/coverage.yaml`, `docs/ai/knowledge-graph/product-graph.yaml` | `advisory-reviewed` |
| audit | `docs/ai/logs/known-issues.md`, `.claude/.deferrals-pending` (Prompt C's deferral exception) | none — scope only |

Evidence passes when the file exists, says `status: complete`, and its `spec_version` equals
`manifest.json` `active` (null equals null — the t-0041 predicate). Gate 3's advisory warning
and this check read `spec_version` with one shared function, so they cannot disagree.

The path opens only with a live phase: when phase-state is missing or stale,
`get_session_type` falls back to `.claude/.session-type`, and the gate then applies the
ordinary rules (`qa-verified` required).

### 4. `plan-approved`

Required when the type has an approval phase (`has_plan_gate`): spec types keep it. advisory-*
and audit do not need it — nothing could write it for them.

## Known limits

- **The evidence carries no provenance.** Unlike the state files, it has no `session_id` and
  no hook writes it — Prompts 0 and A have the agent write it. A session can therefore satisfy
  it by hand, but only for a commit already limited to the paths in § 3, which are the paths
  that session type legitimately writes. Stamping it would need a writer the agent cannot
  imitate (t-0004: mechanical enforcement deters, it does not cryptographically prevent).
- **The scope sees the call's text and the pre-call tree, not its effect.** The chained-verb
  check stops the plain and wrapped forms (`git -C d add`, `env git add`, `sh -c "git add"`),
  but not a disguised or indirect one: a quoted or variable verb (`git "add"`, `git $v`), a
  script, function or git alias that stages, `GIT_INDEX_FILE=…`, or a same-call working-tree
  edit (`sed -i`, `cp`) followed by `commit -a`. The agent already holds Bash, so these are
  not closable by matching text (t-0004: deters, does not prevent). In headless runs the
  permission allowlist already denies `bash -c`, `eval` and inline interpreters.
- **Session type is self-declared at `init_phase`.** Choosing a governance-close type gains
  only the § 3 scope, not a path around QA for other files.
- **Evidence from an earlier session passes while the version is unchanged.** The check reads
  the file on disk, not this session's write. A spec-update bumps `manifest.json` `active`,
  which forces a rewrite; a re-run at the same version does not. Not closed here.
- **The scope lists repeat what Prompts 0, A and C write.** They are defined once, in
  `_close_commit_allowed`; a prompt that starts writing elsewhere must change the gate with it.
