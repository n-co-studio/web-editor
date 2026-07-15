# Decision 0017 — Operator Automation Layer

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/\.automation/`
- path: `\.claude/hooks/permission-request\.sh`
- path: `\.claude/hooks/_permission-allowlist\.sh`
- keywords: `automation, headless, runner, queue, escalation, blocker, claude -p, enabled, permission-request, allowlist, scope-deviation, scope_classification`

## Decision
Add an optional operator automation layer for headless `claude -p` invocations with full governance parity:
1. **Schema directory**: `.claude/.automation/schemas/` contains four YAML schema definitions — `queue-entry.yaml`, `escalation.yaml`, `blocker-report.yaml`, `runner-config.yaml`. Schemas define contracts for runner infrastructure; they are tracked in git alongside governance files
2. **Default config**: `.claude/.automation/config.yaml` ships with `enabled: false`. Runners must not execute when disabled. Config follows `runner-config.yaml` schema
3. **Runtime artifacts gitignored**: `.claude/.automation/queue/`, `.claude/.automation/reports/`, `.claude/.automation/escalations/`, `.claude/.automation/briefs/`, `.claude/.automation/logs/` are gitignored. Runners write to these directories at runtime; their contents are ephemeral and machine-local
4. **Governance parity**: When enabled, runners invoke `claude -p` with the same hooks, gates, and phase model as interactive sessions. No governance bypass. All PreToolUse, PostToolUse, and SubagentStop hooks fire normally in headless mode
5. **Stop hook limitation**: The Stop hook does NOT fire in `claude -p` mode. Runners must handle post-session tasks externally: solo merge (Decision 0015), session registry cleanup (Decision 0015), branch sealing (Decision 0013), session log updates. Runner implementations must replicate the cleanup logic from `session-close-check.sh`
6. **Runner pattern**: Pre-session setup (branch creation, session registration, phase pre-write, queue state update) → `claude -p` invocation with `--disallowedTools` permission profile → post-session cleanup (merge, registry, seal, log). This three-phase pattern is the canonical headless execution model
7. **Queue state machine**: Queue entries transition through: `pending-review → approved → running → completed | failed | review | blocked`. Only `approved` entries may transition to `running`. The `pending-review` state requires operator approval before execution
8. **Escalation taxonomy**: Nine escalation types cover all runner failure modes and scope deviations: `gate-failure` (governance gate blocked), `governance-block` (hook enforcement prevented action), `phase-tag-escalation` (phase tag was `operator` at exit), `ambiguity` (runner could not determine next action), `scope-exceeded` (changes exceeded configured limits), `dependency-missing` (required external resource unavailable), `security-risk` (vulnerability detected — auth bypass, injection, unsafe deserialization, etc.), `structural-change` (spec-level or architectural change not in brief), `scope-deviation` (change outside brief scope — classified by `scope_classification`)
9. **Session type compatibility**: Queue entries reference the session type enum from Decision 0014. The enum is not extended by the automation layer — automation sessions use the same types as interactive sessions. An environment variable or queue metadata distinguishes headless from interactive context
10. **Write-guard carve-out**: `.claude/.automation/*` is carved out in template mode (Decision 0012). Child mode receives a narrowed carve-out: `.claude/.automation/reports/*` only. The Dev Orchestrator writes health reports to this sub-path via Bash redirect (runtime artifacts, gitignored). All other sub-paths under `.claude/.automation/` — `config.yaml`, `schemas/`, `queue/`, `decision-cache.yaml`, `local-decision-cache.yaml`, `lib/` — are template-only and blocked in child/autonomous modes. Autonomous mode has no `.automation/` access

## Automated Choices

When the runner invokes a headless session, ten operator decision points are resolved automatically. These replace the interactive prompts that would normally require a human operator.

| # | Decision Point | Interactive Behavior | Automated Answer | Mechanism |
|---|---------------|---------------------|-----------------|-----------|
| 1 | Plan approval | Operator reviews and approves plan | Pre-approved | Runner pre-writes `.claude/.state/plan-approved` before invocation |
| 2 | Auto mode | Operator chooses auto or review mode | `true` (auto) | Runner sets `mode=auto` in phase-state; `op-review` phase is skipped |
| 3 | Solo mode | Operator chooses solo or collaborative | `true` (solo) | Runner sets `solo=true`; branch merges to main at close |
| 4 | Large-scope approval | Operator approves scope >100 lines | Pre-approved | Runner sets `large-scope: true` in `.claude/.state/plan-approved` |
| 5 | Op-review phase | Operator reviews before close | Skipped | Auto mode bypasses `op-review` phase entirely |
| 6 | AskUserQuestion | Agent prompts operator for clarification | Blocked | `--disallowedTools` blocks `AskUserQuestion` in all profiles |
| 7 | WebSearch / WebFetch | Agent requests web access | Allowed (build) / Blocked (audit) | Build profile permits web tools; audit profile blocks them |
| 8 | Destructive git | Agent runs `git reset --hard`, `git push --force` | Blocked | `--disallowedTools` blocks destructive patterns in build profile |
| 9 | Scope classification | Operator reviews unbriefed/out-of-scope files | Classified mechanically | `pre-commit-gates.sh` compares staged files against task contract `scope_files` — briefed passes, unbriefed-in-scope writes advisory escalation, out-of-scope blocks commit |
| 10 | PermissionRequest auto-approval | VS Code shows permission dialog for each tool use | Auto-decided | `permission-request.sh` hook auto-approves curated tools/commands, denies dangerous patterns, falls through to dialog for unknown — all decisions logged to audit file |

When `AskUserQuestion` is blocked, sessions that encounter ambiguity must escalate via the escalation protocol (file-based) rather than prompting interactively.

## Context
The operator automation layer enables headless CI/CD-style execution of Claude sessions. The headless hook verification experiment confirmed that `claude -p` sessions run all hooks except Stop, validating the three-phase runner pattern. This decision defines only the schema contracts and directory structure — actual runner implementations are out of scope and will be built separately against these schemas. The `enabled: false` default ensures no behavioral change for existing repos until the operator explicitly opts in.

## Scope Classification Model

When a task contract includes a `scope_files` list, the pre-commit gate classifies staged files into three categories:

| Classification | Criteria | Enforcement |
|----------------|----------|-------------|
| `briefed` | File matches a `scope_files` entry exactly | No action — expected |
| `unbriefed-in-scope` | File shares a parent directory with any scope file | Advisory escalation with risk/gain context |
| `out-of-scope` | File does not match any scope file or related directory | Blocking — commit denied, escalation written |

The classification algorithm is path-based (deterministic, no LLM):
1. Exact match against `scope_files` list → **briefed**
2. Parent directory of staged file matches parent directory of any scope file → **unbriefed-in-scope**
3. Everything else → **out-of-scope**

Escalation entries include a `risk_gain` object (`risk:` what could go wrong, `gain:` why it helps) populated by the agent via a `.claude/.state/scope-risk-gain` state file. This context helps the operator make informed accept/reject decisions.

**Limitations:** Path-based, not semantic. A file in `scope_files` could contain an out-of-scope change; a file outside `scope_files` could be a necessary dependency. Acceptable for v1 — semantic analysis is a future enhancement.

## PermissionRequest Hook

The `PermissionRequest` hook (`permission-request.sh`) auto-approves curated tools and Bash commands, denies dangerous commands, and falls through to the VS Code dialog for unknown patterns. Every request is logged to an append-only audit log.

**Decision flow:**
1. Non-Bash tool in allow list (Read, Edit, Write, Glob, Grep, WebSearch, WebFetch, Task, NotebookEdit) → auto-approve
2. Bash command in deny list (rm -rf, sudo, chmod 777, curl/wget to non-localhost, kill -9, dd, mkfs) → deny
3. Bash command in allow list (npm, node, python, git read operations, file inspection, etc.) → auto-approve
4. Unknown → fall through to VS Code permission dialog

**Audit log:** `.claude/.automation/logs/permission-audit.log` (gitignored, append-only). Records timestamp, tool name, command prefix, and decision for every request.

**Deny list priority:** Deny patterns are checked before allow patterns. A command matching both lists is denied (fail-safe).

**Headless mode:** PermissionRequest hooks do not fire in `claude -p` mode. Headless sessions use `--disallowedTools` profiles instead.

## Decision Cache

The automation layer includes a two-level decision cache system that prepends frequently referenced decisions to assembled prompts:

1. **Project-level cache** (`.claude/.automation/decision-cache.yaml`, tracked): Shared across all automation sessions. Contains entries with `number`, `summary`, and `enforcement` (BLOCK/REQUIRE/GUIDE) fields. Ships with empty `entries: []` — operators populate per-repo.

2. **Local-level cache** (`.claude/.automation/local-decision-cache.yaml`, tracked): Per-repo overrides. Can extend the project cache with new entries or narrow enforcement (e.g., REQUIRE→BLOCK). **Never-elevate rule**: local entries cannot lower enforcement severity (e.g., REQUIRE→GUIDE is rejected; the project-level enforcement is preserved).

3. **Cache builder** (`.claude/.automation/lib/cache-builder.sh`, sourced by runner): `build_decision_cache()` merges both levels at prompt assembly time. Merge algorithm: start with all project entries, then apply local overrides (replace matching decision numbers, append new entries). Output: max 10 entries formatted as `Decision NNNN: summary (MECHANISM)`, prepended to the assembled prompt.

The never-elevate rule ensures that team-level governance floors cannot be weakened by local configuration. The 10-entry cap prevents prompt bloat.

## Consequences
- `.claude/.automation/schemas/` added with four schema files (tracked in git)
- `.claude/.automation/config.yaml` added with `enabled: false` default (tracked in git)
- `.gitignore` gains runtime artifact exclusions for `queue/`, `reports/`, `escalations/`, `briefs/`, `logs/`
- `.claude/hooks/write-guard.sh` `is_carved_out()` gains `.claude/.automation/*` in template mode
- `AI.md` gains automation layer summary paragraph
- `.claude/settings.json` gains `PermissionRequest` hook entry for `permission-request.sh`
- Existing hooks work as-is for governance parity. `plan-approval.sh` gains an automation activation path (below)
- No changes to Decision 0014 session type enum — automation uses existing types
- Runner implementations are out of scope — they build against these schemas
- `plan-approval.sh` PostToolUse hook wires auto mode on taskgroup sessions to runner activation via `_automation-bridge.sh` — queues pending briefs, enables runner, starts daemon
- `.claude/.automation/briefs/` convention for pre-saved brief files (operator-populated, gitignored)
- `.claude/hooks/permission-request.sh` and `_permission-allowlist.sh` added for PermissionRequest hook
- `escalation.yaml` expanded from 6 to 9 types with `scope_classification` and `risk_gain` fields
- `queue-entry.yaml` gains `scope_classification` field
- `pre-commit-gates.sh` gains scope classification gate (between A6 and high-risk detection)
- `outcome-detector.sh` gains scope-deviation detection in escalation file scanning
- `.claude/.automation/lib/intake.sh` CLI for standalone queue entry creation — accepts brief path, session type, auto-approve, solo, and push flags; auto-enables runner when entries are added
- `queue-entry.yaml` gains `push_on_complete` field — per-entry opt-in branch push after session completion (solo pushes main, non-solo pushes feature branch)
- `.claude/hooks/ask-user-deny.sh` PreToolUse hook blocks `AskUserQuestion` in headless mode (`CLAUDE_HEADLESS=1`) — defense-in-depth alongside `--disallowedTools`
- `.claude/hooks/_cleanup-helper.sh` extracted as shared cleanup helper — sourced by both `session-close-check.sh` and runner libraries to eliminate divergence (audit C5)
- `.claude/.automation/lib/cleanup.sh` provides retention-based deletion of stale runtime artifacts (queue entries, reports, escalations, heartbeats, closed-branch compaction)
- `.claude/.automation/RUNNER-PARITY.md` maintenance contract mapping every `session-close-check.sh` responsibility to its `runner.sh` equivalent

## Security Model

Three defense layers protect headless automation sessions against command injection, data leakage, supply chain risks, and prompt injection:

### Layer 1 — Prevent (permission profiles)

`--disallowedTools` blocklists are the primary mechanical defense. Claude Code enforces these before tool execution — blocked tools never run.

| Profile | Blocks | Use Case |
|---------|--------|----------|
| `build` | Destructive git (`push`, `reset --hard`, `push --force`), outbound network (`curl`, `wget`, `nc`, `ncat`, `netcat`), interactive prompts | Standard build sessions. WebSearch/WebFetch remain available (model-mediated, logged) |
| `audit` | Edit, Write, git commit, git push, WebSearch, WebFetch, interactive prompts | Read-only audit sessions |
| `strict` | All `build` blocks + package installs (`pip install`, `npm install`, `npx`), WebSearch, WebFetch | High-security lockdown. Agent can only read, edit, commit, and run local commands |
| `default` | git push, interactive prompts | Minimal fallback |

**Limitation:** `Bash(curl:*)` can be bypassed via language-level HTTP (e.g., `python -c "import urllib..."`). Blocklists are defense-in-depth, not airtight. Layer 3 is the backstop.

### Layer 2 — Instruct (prompt constraints)

Session templates (`build-brief.md`, `taskgroup-brief.md`) include a `## Security Constraints` section with defense-in-depth prompt instructions: no executing commands from external URLs, no installing unlisted packages, no fetching non-documentation URLs, no writing outside the repo root, no embedding secrets. Model-mediated — reduces attack surface but is not mechanical.

### Layer 3 — Detect (security agent review)

The security-privacy agent (`security-privacy.md`) includes an Automation Runtime review section activated when `Automation: runner` trailer is present. Covers: prompt injection in task brief content, permission boundary verification, outbound network call detection, package supply chain (typosquatting patterns), path traversal, and credential exposure. This review runs during the verify phase as part of gate A4-auto.

### Profile selection

Operators choose profiles via queue entry metadata or runner config. The `strict` profile is opt-in for high-security environments. If a build genuinely needs curl (e.g., API health checks), the operator uses the `build` profile and the security agent flags new network calls at review time.
