# Decision 0044 — Functional Verification Gate (A3.4)

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/pre-commit-gates\.sh`
- path: `\.claude/hooks/_cleanup-helper\.sh`
- path: `\.claude/.state/functional-verified`
- keywords: `functional-verified, SKIP_FUNC_CHECK, REPO_OS_FUNC_CHECK_TIMEOUT, IS_NO_REVIEW_BACKSTOP, A3.4`

## Context

Decision 0017 (Operator Automation Layer) enables headless/auto mode, where the
`op-review` phase is skipped by design — the operator is not in the loop to catch
a brief that omits build, pack, or test steps. This creates a self-attestation gap:
an agent-authored commit brief can claim "build passes" without any mechanical
enforcement of that claim.

Gate A3.3 enforces TypeScript type-checks but only covers `tsc --noEmit`. It does
not run `npm build`, `npm pack`, or `npm test` — the full build/package/test lifecycle
that a human would verify at op-review before merging.

## Decision

### Gate A3.4: Functional Verification

Add Gate A3.4 to `pre-commit-gates.sh`, placed immediately after A3.3:

**Engagement condition:** `IS_NO_REVIEW_BACKSTOP=true`, which is set when
`CLAUDE_HEADLESS=1` OR phase mode is `auto` (read from `phase-state` file).

**Script discovery:** Read `package.json` (if present) via `jq` to discover
applicable scripts: `build`, `build:pack`, `test`, `verify`. Additionally run
`npm pack --dry-run` when the package has a `name` field.

**Execution:** Each script runs with `timeout $REPO_OS_FUNC_CHECK_TIMEOUT npm run
<script>` (default timeout: 120s). Non-zero exit codes accumulate into a failure
detail string.

**Pass outcome:** `functional-verified` state file written with `timestamp`,
`session_id`, and `result: PASSED`.

**Fail outcome (IS_NO_REVIEW_BACKSTOP=true):** Emit `GATE-RECOVERABLE` message with
full failure output, write escalation YAML to `.claude/.automation/escalations/`,
call `block "A3.4_func_verification_failed"`. Commit is blocked.

**Fail outcome (interactive mode):** Advisory warning only — `warn
"A3.4_func_verification_advisory"`. Commit proceeds. Human at op-review is the
backstop.

**Inapplicability:** No `package.json` → `_A34_APPLICABLE=false` → A3.4 skipped
silently. `package.json` present but no applicable scripts and no `name` field →
`_A34_APPLICABLE=false` → skipped.

### Binding Gate (defense-in-depth)

After the `qa-verified` check, add a secondary check: when `IS_NO_REVIEW_BACKSTOP=true`
AND `_A34_APPLICABLE=true` AND no earlier gate has already blocked (`FAILED -eq 0`),
require `functional-verified` to exist with a matching `session_id`. This catches
crash-recovery scenarios where the A3.4 block ran in a previous gate invocation but
the state file was cleaned between runs.

### State File

`functional-verified` is a session-scoped state file written by `pre-commit-gates.sh`
(not `state-writer.sh`). It is cleaned by `_cleanup-helper.sh` at session close,
same as `cohesion-reviewed` and `qa-verified`.

### Overrides

- `SKIP_FUNC_CHECK=1` — bypass A3.4 entirely (both the execution block and the
  binding gate). Logged via `log_override`.
- `REPO_OS_FUNC_CHECK_TIMEOUT` — per-command timeout in seconds (default: 120).
- `REPO_OS_RECOVER=1` — bypasses all state-dependent checks including A3.4 via
  `SKIP_STATE=true`.

### Non-Goals

- Does not replace A3.3 (TypeScript type-check).
- Does not enforce script *existence* — repos without `package.json` are silently
  exempt.
- Does not gate on specific test coverage thresholds.

## Consequences

- `.claude/hooks/pre-commit-gates.sh`: IS_NO_REVIEW_BACKSTOP detection added after
  IS_HEADLESS; A3.4 block added after A3.3; binding gate added after qa-verified.
- `.claude/hooks/_cleanup-helper.sh`: `functional-verified` added to session-close
  cleanup.
- `docs/ai/decisions/t-manifest.txt`: entry added.
- `docs/ai/quality-gates.md`, `docs/ai/quality-gates-summary.md`: A3 row updated.
- `.claude/agents/_agent-glossary.md`: `functional-verified` state file and
  `SKIP_FUNC_CHECK` / `REPO_OS_FUNC_CHECK_TIMEOUT` overrides documented.
- `AI.md`: pre-commit-gates.sh hook-table row and overrides updated.
- `.claude/agents/qa-verifier.md`: A3.4 note added.

## Alternatives Considered

1. **Always-blocking (interactive + headless).** Rejected — interactive sessions
   have a human at op-review who is the natural backstop. Making A3.4 always-blocking
   would break repos with non-standard or slow test suites during ordinary development.

2. **Separate state-writer.sh dispatch.** Rejected — the check is simple enough to
   inline in pre-commit-gates.sh. Adding a subagent dispatch for a pass/fail
   subprocess call would add latency and complexity without benefit.

3. **Require explicit script configuration in repo config.** Rejected — inferring
   from `package.json` scripts is zero-config and works for the common case.

## Amendment 1 — SKIP_FUNC_CHECK Interactive-Only (2026-06-18)

### Problem

The original decision listed `SKIP_FUNC_CHECK=1` as a general override with no
mode restriction. A headless runner could silently set `SKIP_FUNC_CHECK=1` and
nullify Gate A3.4 entirely, defeating its purpose as the automated backstop for
the missing op-review phase.

### Change

`SKIP_FUNC_CHECK=1` is now **interactive-only**:

- **Interactive mode** (`IS_NO_REVIEW_BACKSTOP=false`): `SKIP_FUNC_CHECK=1`
  works as before — `log_override` fires, `_A34_SKIP_EFFECTIVE=true`, A3.4
  checks are skipped. Human at op-review is the backstop.

- **Headless/auto mode** (`IS_NO_REVIEW_BACKSTOP=true`): `SKIP_FUNC_CHECK=1`
  is **ignored**. `log_override` fires with `SKIP_FUNC_CHECK_IGNORED_HEADLESS`,
  a `governance-block` escalation YAML is written to
  `.claude/.automation/escalations/a34-skip-ignored-<ts>.yaml`, and A3.4 checks
  proceed as normal.

- **`REPO_OS_RECOVER=1`** remains the legitimate headless emergency bypass. When
  used in headless mode it now also writes a `governance-block` escalation to
  `.claude/.automation/escalations/recover-bypass-<ts>.yaml` (best-effort).

The **binding gate** (`IS_NO_REVIEW_BACKSTOP=true && _A34_APPLICABLE=true &&
FAILED -eq 0`) no longer has a `SKIP_FUNC_CHECK != "1"` short-circuit — it is
active whenever A3.4 was applicable, and the override hint in both its messages
points to `REPO_OS_RECOVER=1`.

### Files Changed

- `.claude/hooks/pre-commit-gates.sh`: SKIP_FUNC_CHECK block replaced with
  mode-aware structure; REPO_OS_RECOVER block gains headless escalation write;
  npm/failure error hints updated; binding gate condition and hints updated.
- `docs/ai/decisions/t-0044-functional-verification-gate.md`: this amendment.
- `AI.md`: hook table row updated to note interactive-only scope.
- `.claude/agents/_agent-glossary.md`: SKIP_FUNC_CHECK row updated.
- `.claude/hooks/tests/layer3-hook-integration.sh`: new headless-ignored tests.


## References

- Decision 0017: Operator Automation Layer (headless mode, auto phase mode).
- Decision 0014: Phase-Aware Flow Model (phase sequences, gate profiles).
- Gate A3.3: TypeScript type-check in `pre-commit-gates.sh`.
