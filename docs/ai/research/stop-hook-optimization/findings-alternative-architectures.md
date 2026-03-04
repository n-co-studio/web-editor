# Alternative Architecture Research — Findings

**Brief:** 3 of 4 (Stop Hook Optimization)
**Date:** 2026-03-03
**Scope:** Research-only — no code modifications
**API Version:** Claude Code hooks documentation accessed 2026-03-03

---

## 1. Claude Code Hook API Ceiling

### Available Lifecycle Events

| Event | When | Matcher | Can Block | Handler Types |
|-------|------|---------|-----------|---------------|
| `SessionStart` | Session begins/resumes | `startup`, `resume`, `clear`, `compact` | No | command only |
| `UserPromptSubmit` | User submits prompt | None | Yes | all four |
| `PreToolUse` | Before tool executes | tool name (regex) | Yes | all four |
| `PermissionRequest` | Permission dialog about to appear | tool name | Yes | all four |
| `PostToolUse` | After tool succeeds | tool name | No (feedback) | all four |
| `PostToolUseFailure` | After tool fails | tool name | No (feedback) | all four |
| `SubagentStart` | Subagent spawns | agent type | No | command only |
| `SubagentStop` | Subagent finishes | agent type | Yes | all four |
| `Stop` | Main agent finishes | None | Yes | all four |
| `Notification` | Notification sent | notification type | No | command only |
| `TeammateIdle` | Teammate about to idle | None | Yes | command only |
| `TaskCompleted` | Task marked complete | None | Yes | command only |
| `ConfigChange` | Config file changes | config source | Yes* | command only |
| `WorktreeCreate` | Worktree creation | None | Yes | command only |
| `WorktreeRemove` | Worktree removal | None | No | command only |
| `PreCompact` | Before compaction | `manual`, `auto` | No | command only |
| `SessionEnd` | Session terminates | reason type | No | command only |

*ConfigChange cannot block `policy_settings` changes.

### Handler Types

Four types: `command` (shell), `http` (POST webhook), `prompt` (LLM evaluation), `agent` (subagent with tools). Most events support only `command`; PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, Stop, SubagentStop, TaskCompleted, and UserPromptSubmit support all four.

### Input/Output Contracts

**Input (stdin JSON):** Every event receives `session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, plus event-specific fields (e.g., `tool_name`, `tool_input` for PreToolUse; `stop_hook_active` for Stop/SubagentStop; `last_assistant_message` for Stop).

**Output (stdout JSON on exit 0):**
- **Universal:** `continue` (bool), `stopReason`, `suppressOutput`, `systemMessage`
- **PreToolUse:** `hookSpecificOutput.permissionDecision` (allow/deny/ask), `permissionDecisionReason`, `updatedInput`, `additionalContext`
- **PermissionRequest:** `hookSpecificOutput.decision.behavior` (allow/deny), `updatedInput`, `updatedPermissions`, `message`, `interrupt`
- **PostToolUse:** `decision` (block feeds reason to Claude), `additionalContext`, `updatedMCPToolOutput`
- **Stop/SubagentStop:** `decision` (block prevents stopping), `reason` (required on block)

**Exit codes:** 0 = success (parse JSON), 2 = blocking error (stderr to Claude), other = non-blocking.

### Key API Capabilities

| Capability | Status | Notes |
|------------|--------|-------|
| `SessionStart` hook | Available | Fires on startup, resume, clear, compact |
| `CLAUDE_ENV_FILE` | SessionStart only | Exports for subsequent Bash calls |
| `async: true` | command hooks only | Non-blocking; `systemMessage`/`additionalContext` on next turn |
| `stop_hook_active` | Stop/SubagentStop | Retry loop detection |
| `additionalContext` | PreToolUse, PostToolUse, SessionStart, UserPromptSubmit | Context injection |
| `updatedInput` | PreToolUse, PermissionRequest | Modify tool parameters |
| Prompt/Agent handlers | Blocking events | LLM-evaluated with `{ok, reason}` |
| Matcher regex | Per event | Filter by tool name, config source, etc. |

### Limitations

- `SessionStart` cannot block (exit 2 shows stderr only)
- `PostToolUse` cannot undo actions
- `PermissionRequest` hooks don't fire in `-p` mode; use `PreToolUse`
- `Stop` fires on every response completion, not only task end; no fire on user interrupts
- Async hooks cannot block; output on next turn
- Hook timeout: 600s default (configurable)

---

## 2. Analytics Baseline

### Data Source

`~/.local/share/repo-os-analytics/`, 2026-02-24 to 2026-03-03. 90 repos, 27,906 events. `repo-OS-template` = 62.7%.

### Hook Invocation Distribution

| Hook | Count | Share | Avg Dur. | Fast-exit |
|------|------:|------:|---------:|----------:|
| mode-guard | 8,151 | 29.2% | 40ms | 96% |
| branch-guard | 6,395 | 22.9% | 49ms | 95% |
| branch-guard-edit | 3,723 | 13.3% | 50ms | 95% |
| pre-commit-gates | 1,933 | 6.9% | 139ms | 86% |
| session-close-check | 1,719 | 6.2% | 148ms | 85% |
| agent-git-guard | 1,576 | 5.6% | 18ms | 98% |
| plan-approval | 1,135 | 4.1% | 1,303ms* | 91% |
| state-writer | 1,080 | 3.9% | 37ms | 96% |
| hvst-failure-tracker | 794 | 2.8% | 30ms | 97% |
| state-guard | 476 | 1.7% | 27ms | 97% |
| pre-push-gates | 418 | 1.5% | 22ms | 98% |
| permission-request | 377 | 1.4% | 127ms | 87% |
| write-guard | 128 | 0.5% | 125ms | 88% |

*plan-approval skewed by user interaction wait. **Top 3 = 65.4% of invocations.**

### Outcome Distribution

| Outcome | Count | Share |
|---------|------:|------:|
| allow | 22,938 | 82.2% |
| block | 2,707 | 9.7% |
| write | 1,297 | 4.6% |
| warn | 520 | 1.9% |
| skip | 281 | 1.0% |
| dialog | 163 | 0.6% |

### Fast-Exit Patterns

Combined `bash_no_write_target` + `bash_out_of_repo` + `not_git_commit_push` = **23.2%** at near-zero cost.

### Per-Session

Median: 4 hooks/session. P90: 95. Max: 495. P90 cumulative duration: 5s. Max: 27s.
**94.2% of invocations complete in under 10ms.**

### Baseline Conclusions

1. Hook overhead is 0–27s per session — minimal in absolute terms.
2. Fast-exit patterns eliminate 23%+ at near-zero cost.
3. Heaviest hooks (pre-commit 139ms, session-close 148ms) fire infrequently.
4. Highest-frequency hooks already 95–96% fast-exit.
5. Duration granularity is coarse (1-second buckets).

---

## 3. Alternative Architecture Evaluations

### 3a. Prompt-Only Enforcement

**Concept:** Move all governance to CLAUDE.md / system prompts. Remove all hooks.

**Governance:** Probabilistic. Cursor community confirms prompt rules degrade with context pressure. Constitutional AI shows ~50% reduction — significant but not deterministic.

**Time:** Zero per action. **Token:** +2,000–5,000 tokens in system prompt.

**Failure modes:** Silent violations. Secret scanning advisory-only. No mechanical block.

**Assessment:** Eliminates all overhead but sacrifices Repo OS's core value — mechanical enforcement immune to model behavior. Only viable for low-stakes repos.

### 3b. SessionStart Pre-Computation

**Concept:** Pre-compute invariants at start, persist via `CLAUDE_ENV_FILE`.

**Governance:** Identical. **Time:** Marginal (10–50ms/session).

**Limitation:** `CLAUDE_ENV_FILE` only available to subsequent Bash calls, NOT hook processes. Hooks already cache invariants at source-time (`_REPO_OS_HAS_JQ`, etc.).

**Assessment:** Marginal improvement. API limitation narrows benefit significantly.

### 3c. Minimal-Hook Hybrid

**Concept:** Keep commit/push mechanical. Move edit/write guards to prompts. Advisory stop hook.

**Retained:** pre-commit-gates, pre-push-gates, agent-git-guard, state-writer.
**Removed:** write-guard, branch-guard, plan-approval. **Downgraded:** session-close-check → advisory.

**Governance:** Hybrid — mechanical at commit, probabilistic at edit-time.
**Time:** ~60% reduction. **Token:** +1,000 tokens prompt rules.

**Failure modes:** Edit-time violations caught at commit (late detection, more rework). Mode guard especially hard via prompts (path-prefix matching unreliable). Immune paths not caught until review.

**Assessment:** Significant overhead reduction with governance gap between edit and commit time.

### 3d. State-Machine-Only Enforcement

**Concept:** Phase model sole enforcement. No per-tool-call hooks. Validate at commit only.

**Governance:** Mechanical at commit only. Zero during build. **Time:** Near-zero active.

**Failure modes:** All violations deferred. Agent may do extensive wasted work on wrong branch / before plan approval.

**Assessment:** "Fail late" model likely increases total session time despite faster build phase.

### 3e. Async Governance Audit

**Concept:** All hooks `async: true`. Violations as advisories via `systemMessage` on next turn.

**Governance:** Probabilistic. **Time:** Zero blocking.

**API limitation:** Async only for `command` hooks. Response fields have no effect. Only `systemMessage`/`additionalContext` delivered on next turn.

**Failure modes:** Model ignores advisories. Cannot prevent secret from being committed.

**Assessment:** Unsuitable for security-critical governance. OK for style/naming conventions only.

### 3f. Fast-Path / Full-Path Split

**Concept:** <10-line fast path without library sourcing; full path for edge cases.

**Governance:** Identical — fast path only when hook would allow anyway. **Time:** 100–300ms/session.

**Current state:** Partially implemented (branch-guard fast-exit). Would extend to eliminate `source` entirely on fast path.

**Assessment:** Most pragmatic zero-risk optimization. Small absolute savings. "Polish" not architecture.

### 3g. Event-Sourced Governance

**Concept:** Record all tool actions. Replay at commit for compliance verification.

**Governance:** Mechanical at commit. **Time:** Near-zero active; 1–5s at commit (replay).

**Failure modes:** Late detection. Complex implementation. Event log integrity.

**Assessment:** Architecturally elegant but high implementation cost. Better as supplement than replacement.

---

## 4. External Research

### 4a. Cursor
Prompt-only (`.cursor/rules/`). **Low.** Community confirms rules degrade. Feature requests for mechanical hooks validate Repo OS's approach.

### 4b. Windsurf (Codeium)
Prompt + enterprise MCP allowlists. **Low-Medium.** Mechanical enforcement only for external API, not code edits.

### 4c. Aider
Prompt conventions + lint/test loops. **Low-Medium.** "Verify after action" vs Repo OS's "verify before action."

### 4d. LangGraph
State machine topology + interrupt gates. **High for flow.** Graph topology parallels phase model. Validates state-machine governance.

### 4e. CrewAI
Task guardrails + tool hooks + Safety Kernel. **Med-High to Very High.** Tool hooks closest analog to PreToolUse. Safety Kernel = OS-level.

### 4f. MCP
OAuth + gateway + containerization. **Variable (high when deployed).** Gateway parallels Repo OS hooks as "gateway" for state changes.

### 4g. Guardrails AI / NeMo
Programmatic pipeline (Guardrails AI) and Colang state machine (NeMo). Both validate mechanical enforcement layers. Reask pattern parallels stop hook retry.

### 4h. Academic Patterns
- **Pre-execution intervention** (TrustAgent, Safiron): Planning-stage interception parallels pre-commit.
- **Governance-as-a-Service** (GaaS): Trust Factor scoring — clean history = faster enforcement.
- **Agent-Precommit**: Human fast checks (~3s) vs agent comprehensive checks (~5 min).

### Comparative Summary

| Framework | Enforcement | Boundary | Strength | LLM-Bypassable? |
|-----------|-------------|----------|----------|------------------|
| Cursor rules | Prompt | Per-request | Low | Yes |
| Windsurf rules | Prompt | Per-session | Low-Med | Yes |
| Aider conventions | Prompt + lint | Per-edit | Low-Med | Yes |
| LangGraph | Arch + HITL | Per-node | High (flow) | No (topology) |
| CrewAI hooks | Programmatic | Per-tool-call | Med-High | No |
| MCP gateway | Protocol + policy | Per-tool-call | High* | No |
| Guardrails AI | Programmatic | Per-LLM-call | High | No |
| NeMo Guardrails | State machine | Per-message | High | No (runtime) |
| **Repo OS hooks** | **Git transaction** | **Per-commit/push** | **Very high** | **No** |

**Repo OS is the only system enforcing at the git transaction boundary** — actor-independent and bypass-resistant.

---

## 5. Tiered Recommendations

### Tier 1 — Zero-Governance-Risk

**T1-A: Fast-path library sourcing elimination.** Move `source` after fast-path checks. 80–90% skip library overhead.
- Savings: 100–300ms/session | Complexity: Low | Risk: None

**T1-B: Consolidate write-guard + branch-guard for Bash.** Single hook entry: one stdin read, one parse.
- Savings: 300–600ms/session | Complexity: Medium | Risk: None

**T1-C: Phase-state cross-invocation cache.** Shared cache file for redundant reads.
- Savings: 50–100ms/session | Complexity: Low | Risk: Minimal

### Tier 2 — Governance-Neutral Refactors

**T2-A: Unified PreToolUse dispatcher.** Single `"Edit|Write|Bash"` hook with internal routing.
- Savings: ~50% process reduction | Complexity: Medium | Risk: Low

**T2-B: Mode-guard → SessionStart + per-commit.** Compute once, verify at commit.
- Savings: Eliminates 29.2% of invocations | Complexity: Medium | Risk: Medium (late detection)

**T2-C: Stop hook completion-marker pattern.** Write checklist, exit 0 with `additionalContext`.
- Savings: Eliminates retry loops | Complexity: Medium | Risk: Low-medium

### Tier 3 — Architectural Alternatives

**T3-A: Minimal-hook hybrid.** Commit/push mechanical, edit-time prompt.
- Reduction: ~65% | Governance: Edit-time → commit-time detection

**T3-B: Advisory-only stop hook.** Exit 0 always with systemMessage.
- Reduction: Retries eliminated | Governance: Close sequence probabilistic

**T3-C: Composite (T1-A + T1-B + T2-B).** Fast-path + consolidation + mode cache.
- Reduction: ~40% | Governance: Mode guard deferred

**T3-D: Prompt + agent handler hybrid.** LLM-evaluated soft boundaries.
- Reduction: Variable | Governance: Soft boundaries probabilistic | Time: Negative

---

## 6. Options Matrix

| Alternative | Governance | Token Red. | Time Red. | Complexity | Migration | Reversibility | Failure Sev. | API |
|-------------|-----------|-----------|----------|------------|-----------|---------------|-------------|-----|
| 3a. Prompt-only | Probabilistic | 80% | 95% | Low | Medium | Easy | **High** | Current |
| 3b. SessionStart | Mechanical | 5% | 5–10% | Low | Low | Easy | Low | Current* |
| 3c. Minimal hybrid | Hybrid | 60% | 65% | Medium | Medium | Easy | Medium | Current |
| 3d. State-machine | Mech (commit) | 70% | 80% | Low | Low | Easy | **High** | Current |
| 3e. Async | Probabilistic | 40% | 90% | Medium | Medium | Easy | **High** | Current |
| 3f. Fast-path | Mechanical | 0% | 3–5% | Low | Low | Easy | Low | Current |
| 3g. Event-sourced | Mech (commit) | 50% | 75% | **High** | **High** | Hard | Medium | Current |

*Limited by `CLAUDE_ENV_FILE` Bash-only availability.

### Tier Summary

| Tier | Items | Governance Impact |
|------|-------|-------------------|
| Tier 1 (zero risk) | T1-A, T1-B, T1-C | None — identical guarantees |
| Tier 2 (neutral) | T2-A, T2-B, T2-C | Same integrity, different timing |
| Tier 3 (architectural) | T3-A–D | Changed guarantee model |

### Recommended Evaluation Order

1. **T1-A + T1-B** — highest return/effort, zero risk
2. **T2-A** — significant process reduction, low risk
3. **T2-C** — eliminates retry loops, moderate risk
4. **T3-C** — if operator accepts mode-guard deferral
5. **T3-A** — if operator accepts edit-time governance gap

---

## 7. Architectural Insights

### Repo OS's Competitive Position

Only system enforcing at the git transaction boundary:
1. **Actor-independent** — fires for human and AI commits
2. **Bypass-resistant** — shell hooks immune to prompt manipulation
3. **Audit-complete** — analytics records every invocation

### Enforcement Timing Spectrum

| Timing | Detection Delay | Rework Cost |
|--------|-----------------|-------------|
| Pre-action (blocking) | Zero | Zero |
| Post-action feedback | One action | Low |
| Commit-time gate | Minutes-hours | Med-High |
| Post-session audit | Hours | High |
| Prompt-based | Variable | Variable |

### Patterns Worth Adopting

1. **Agent-typed enforcement** (Agent-Precommit): Stricter hooks for AI vs human
2. **Trust scoring** (GaaS): Clean history → faster hooks
3. **Checkpoint/resume** (LangGraph): Explicit checkpointing vs implicit retries

### Upstream API Improvements That Would Help

- **SessionStart blocking** — enforce preconditions before work
- **Cross-hook shared state** — beyond Bash-only env vars
- **Hook priority/ordering** — sequential with short-circuit on block

---

## 8. Verification Checklist

- [x] Claude Code hook API capabilities documented (§1)
- [x] Analytics baseline established (§2)
- [x] 7 alternative architectures evaluated (§3a–3g)
- [x] External research: 8 tools/frameworks + academic patterns (§4a–4h)
- [x] Each alternative has governance strength, token/time reduction, feasibility (§3, §6)
- [x] Options matrix with all columns (§6)
- [x] Tiered recommendations (Tier 1/2/3) with governance impact (§5)
