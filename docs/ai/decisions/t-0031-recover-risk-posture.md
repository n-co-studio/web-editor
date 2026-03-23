# Decision 0031 — REPO_OS_RECOVER Risk Posture

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/(bash-guard|write-guard|pre-commit-gates|pre-push-gates)\.sh`
- keywords: `REPO_OS_RECOVER, recover-signal, recovery bypass`

## Decision
Document and accept the risk posture of the `REPO_OS_RECOVER` emergency recovery mechanism. Recovery mode intentionally bypasses all state-dependent governance checks to unblock stuck sessions. The bypassed scope and compensating controls are enumerated below.

### Problem
Sessions can become stuck when governance state files are corrupted, missing, or inconsistent (e.g., phase-state lost after crash, session-id mismatch, plan-approval hook failure). Without a recovery path, the operator must manually debug hook internals or abandon the session. `REPO_OS_RECOVER` provides a documented escape hatch, but its bypass scope is broad and its audit trail has a structural limitation.

### Bypass Scope

Recovery mode (`REPO_OS_RECOVER=1` env var or `.claude/.state/.recover-signal` file) bypasses:

| Hook | Checks Bypassed |
|------|----------------|
| `bash-guard.sh` | State-guard (`.state/` write protection), mode-guard, all branch-guard gates (main protection, phase gate, session overlap, branch isolation) |
| `write-guard.sh` | State-guard, mode-guard, all branch-guard gates (same set as bash-guard) |
| `pre-commit-gates.sh` | All state verification (plan-approved, cohesion-reviewed, qa-verified, pragmatist-signed), scope classification, high-risk sign-off enforcement, inter-session governance checks |
| `pre-push-gates.sh` | No recovery bypass (always enforces B1 naming convention) |

### Signal Mechanism

Two activation paths:
1. **Environment variable**: `REPO_OS_RECOVER=1` — set by operator in shell environment. Persists for the shell session.
2. **File-based signal**: `.claude/.state/.recover-signal` — created by agent (`touch`). Single-use: consumed (deleted) on first hook invocation that reads it. Designed for autonomous recovery when env var is not available.

The file-based signal is consumed by the first hook that checks it. In a multi-hook chain (e.g., bash-guard + write-guard), only the first hook benefits from the signal. Subsequent hooks in the same tool call see the signal already consumed. This is a known limitation — the env var path does not have this constraint.

### Audit Trail

All recovery activations are logged to `.claude/.state/overrides.log` with timestamp, hook name, and override type. This log resides in the same `.state/` directory that recovery mode bypasses — an accepted structural limitation. The override log is defense-in-depth evidence, not a tamper-proof audit trail.

Recovery activations are also recorded in the NDJSON analytics log (`~/.local/share/repo-os-analytics/`) with event type `recovery_bypass` or `recovery_signal_file`, providing an out-of-repo audit trail that is not affected by `.state/` bypasses.

### Immune Paths (Enforced During Recovery)

The following are NOT bypassed by recovery mode:
- **A4 secret scanning** in `pre-commit-gates.sh` — always runs regardless of recovery state
- **B1 branch naming** in `pre-push-gates.sh` — no recovery bypass implemented
- **disallowedTools** in `settings.json` — CLI-level enforcement, not hook-based
- **Immune paths** in mode-guard — hardcoded paths that cannot be modified in any mode

### Trigger Patterns

Recovery mode is typically needed when:
- Plan-approval hook fails to fire after AskUserQuestion (known VS Code extension issue — R13)
- Phase-state file is corrupted or has mismatched session ID
- Session-id file is missing (prevents `get_phase` / `get_session_type` from validating state)
- State files from a crashed session block a new session on the same branch

## Implication
The recovery mechanism trades governance enforcement for session continuity. Operators should use it sparingly and review the overrides.log after recovery sessions. The file-based signal's single-use design limits blast radius — it cannot persist across multiple tool invocations (unlike the env var, which persists for the shell session).

## Alternatives Considered

1. **Per-check granular overrides**: Individual `SKIP_*` env vars for each check (e.g., `REPO_OS_SKIP_PLAN_GATE`, `REPO_OS_SKIP_STATE_GUARD`). Already exist as targeted overrides — `REPO_OS_RECOVER` is the "skip everything" umbrella for when the root cause is unclear.

2. **Automatic state repair**: Detect and fix inconsistent state files automatically. Rejected — the recovery scenarios are too varied (crash timing, partial writes, external interference) for reliable automatic repair without risk of masking real governance violations.

3. **Remove file-based signal, env-var only**: Simpler but blocks autonomous recovery. The agent cannot set env vars that persist to hook execution — file-based signal is the only self-service path.
