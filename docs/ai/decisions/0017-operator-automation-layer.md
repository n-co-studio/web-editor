# Decision 0017 — Operator Automation Layer

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/\.automation/`
- keywords: `automation, headless, runner, queue, escalation, blocker, claude -p, enabled`

## Decision
Add an optional operator automation layer for headless `claude -p` invocations with full governance parity:
1. **Schema directory**: `.claude/.automation/schemas/` contains four YAML schema definitions — `queue-entry.yaml`, `escalation.yaml`, `blocker-report.yaml`, `runner-config.yaml`. Schemas define contracts for runner infrastructure; they are tracked in git alongside governance files
2. **Default config**: `.claude/.automation/config.yaml` ships with `enabled: false`. Runners must not execute when disabled. Config follows `runner-config.yaml` schema
3. **Runtime artifacts gitignored**: `.claude/.automation/queue/`, `.claude/.automation/reports/`, `.claude/.automation/escalations/`, `.claude/.automation/briefs/`, `.claude/.automation/logs/` are gitignored. Runners write to these directories at runtime; their contents are ephemeral and machine-local
4. **Governance parity**: When enabled, runners invoke `claude -p` with the same hooks, gates, and phase model as interactive sessions. No governance bypass. All PreToolUse, PostToolUse, and SubagentStop hooks fire normally in headless mode
5. **Stop hook limitation**: The Stop hook does NOT fire in `claude -p` mode. Runners must handle post-session tasks externally: solo merge (Decision 0015), session registry cleanup (Decision 0015), branch sealing (Decision 0013), session log updates. Runner implementations must replicate the cleanup logic from `session-close-check.sh`
6. **Runner pattern**: Pre-session setup (branch creation, session registration, phase pre-write, queue state update) → `claude -p` invocation with `--disallowedTools` permission profile → post-session cleanup (merge, registry, seal, log). This three-phase pattern is the canonical headless execution model
7. **Queue state machine**: Queue entries transition through: `pending-review → approved → running → completed | failed | review | blocked`. Only `approved` entries may transition to `running`. The `pending-review` state requires operator approval before execution
8. **Escalation taxonomy**: Six escalation types cover all runner failure modes: `gate-failure` (governance gate blocked), `governance-block` (hook enforcement prevented action), `phase-tag-escalation` (phase tag was `operator` at exit), `ambiguity` (runner could not determine next action), `scope-exceeded` (changes exceeded configured limits), `dependency-missing` (required external resource unavailable)
9. **Session type compatibility**: Queue entries reference the existing 15-value session type enum from Decision 0014. The enum is not extended — automation sessions use the same types as interactive sessions. An environment variable or queue metadata distinguishes headless from interactive context
10. **Write-guard carve-out**: `.claude/.automation/*` is carved out in template mode only (Decision 0012). Child and autonomous modes have no access to automation schemas or config

## Automated Choices

When the runner invokes a headless session, eight operator decision points are resolved automatically. These replace the interactive prompts that would normally require a human operator.

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

When `AskUserQuestion` is blocked, sessions that encounter ambiguity must escalate via the escalation protocol (file-based) rather than prompting interactively.

## Context
The operator automation layer enables headless CI/CD-style execution of Claude sessions. The headless hook verification experiment confirmed that `claude -p` sessions run all hooks except Stop, validating the three-phase runner pattern. This decision defines only the schema contracts and directory structure — actual runner implementations are out of scope and will be built separately against these schemas. The `enabled: false` default ensures no behavioral change for existing repos until the operator explicitly opts in.

## Consequences
- `.claude/.automation/schemas/` added with four schema files (tracked in git)
- `.claude/.automation/config.yaml` added with `enabled: false` default (tracked in git)
- `.gitignore` gains runtime artifact exclusions for `queue/`, `reports/`, `escalations/`, `briefs/`, `logs/`
- `.claude/hooks/write-guard.sh` `is_carved_out()` gains `.claude/.automation/*` in template mode
- `AI.md` gains automation layer summary paragraph
- No changes to `.claude/settings.json` — no new hooks added
- Existing hooks work as-is for governance parity. `plan-approval.sh` gains an automation activation path (below)
- No changes to Decision 0014 session type enum — automation uses existing types
- Runner implementations are out of scope — they build against these schemas
- `plan-approval.sh` PostToolUse hook wires auto mode on taskgroup sessions to runner activation via `_automation-bridge.sh` — queues pending briefs, enables runner, starts daemon
- `.claude/.automation/briefs/` convention for pre-saved brief files (operator-populated, gitignored)

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
