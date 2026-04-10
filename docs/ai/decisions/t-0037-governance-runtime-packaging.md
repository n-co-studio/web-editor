# Decision t-0037 — Governance Runtime Packaging: Content/Enforcement Split

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/.*\.sh`
- path: `\.claude/\.automation/`
- keywords: `governance packaging, content/enforcement split, hook lifecycle, enforcement standalone, content standalone`

## Context

The Repo OS template deploys governance artifacts as plaintext files in the working directory. This creates a distinction between governance *content* (which is inherently portable and readable by Claude directly) and governance *enforcement* (hooks, automation runner, state machine), which may depend on external tooling or platform features.

The Template Standalone Guarantee (see `docs/spec/_templates/boundaries.md`) requires the template to work without any external app. This is correct for content but creates a deliberate separation for enforcement: content remains local plaintext; enforcement is implementation-defined by the child repo or platform.

## Decision

### 1. Content/Enforcement Split

Split the Template Standalone Guarantee into two tiers:

- **Content standalone (unconditional):** Governance content — prompts, agent definitions, decisions, workflow docs, spec files — remains fully functional without any external app. Claude Code can read and follow these files regardless of platform installation status. This is the standing guarantee.

- **Enforcement standalone (platform-dependent):** Governance enforcement — hooks, automation runner, state machine — may require platform-specific tooling. Without the platform, enforcement degrades to pass-through with advisory warnings. The template is usable but ungoverned.

### 2. Directory-Pattern Classification

Classify template directories into three tiers based on their role in the content/enforcement split. Classification is by directory pattern, not per-file — this eliminates maintenance cost.

**Content tier** — always local plaintext, Claude reads these directly:
- `.claude/agents/` — agent definitions and glossary
- `docs/ai/prompts/` — session prompts (Prompt 0, A, B, T, etc.)
- `docs/ai/decisions/` — decision records
- `docs/ai/workflow.md`, `docs/ai/workflow-summary.md` — workflow documentation
- `docs/ai/quality-gates.md`, `docs/ai/quality-gates-summary.md` — gate definitions
- `docs/ai/hook-rules-summary.md` — hook rule documentation
- `docs/ai/task-groups/` — task group contracts
- `docs/ai/logs/` — session logs
- `docs/ai/governance/` — inter-session governance evidence
- `docs/ai/knowledge-graph/` — knowledge graph definitions
- `docs/spec/` — compiled specs, templates, prototypes

**Runtime tier** — may migrate to a platform backend over time:
- `.claude/hooks/` — all executable hook scripts (write-guard, bash-guard, pre-commit-gates, etc.)
- `.claude/.automation/lib/` — automation library scripts (state-manager, queue-manager, etc.)
- `.claude/.automation/runner.sh` — headless automation runner
- `.claude/.automation/queue-cli.sh` — queue management CLI
- `.claude/.state/` — session state files (phase-state, plan-approved, etc.)

**Hybrid tier** — content definitions embedded in runtime scripts; requires split during any migration:
- `.claude/hooks/_phase-helper.sh` — phase definitions (content) + phase enforcement logic (runtime)
- `.claude/hooks/_analytics-helper.sh` — analytics event definitions (content) + telemetry reporting logic (runtime)

### 3. Hook Lifecycle States

Each hook may transition through three states during platform integration:

1. **`local`** — Full shell logic executes locally. Default state for all hooks in the template. No platform dependency.
2. **`stub`** — Thin client that calls a platform backend via IPC. The shell script becomes a ~10-line wrapper: check if platform is running, call the backend command, return the result. All enforcement logic lives platform-side.
3. **`frozen`** — Stub is stable and no longer changes. All future modifications happen platform-side only. The stub file is effectively immutable in the template.

Migration is hook-by-hook, not all-at-once. Each hook migrates independently when its next significant rewrite occurs. Child repos that do not use a platform backend keep all hooks in `local` state.

## Alternatives Considered

1. **Per-file manifest** — Directory-pattern classification rules cover the same ground with zero maintenance cost. Per-file enumeration can be generated programmatically when needed.

2. **Technical DRM / obfuscation** — Not viable for shell scripts distributed as plaintext. The content/enforcement split acknowledges that content is inherently portable; enforcement is the value-add layer.

## Consequences

**Positive:**
- Resolves the implicit conflict between standalone guarantee and platform-dependent enforcement
- Directory-pattern classification is zero-maintenance (no per-file tracking)
- Hook-by-hook migration avoids big-bang risk
- Pass-through fallback means users without a platform have a functional (if ungoverned) repo
- Provides a clear mental model for child repo operators customizing enforcement

**Negative:**
- Hybrid-tier files (`_phase-helper.sh`, `_analytics-helper.sh`) require careful splitting during any migration
- Pass-through stubs mean users without platform retain template functionality — this is the explicit trade-off (content standalone guarantee)

## References

- Decision t-0017: Operator Automation Layer (runner infrastructure)
- Decision t-0031: Recover Risk Posture (`REPO_OS_RECOVER=1` mechanism)
- Decision t-0001: Repo OS Baseline (Template Standalone Guarantee)
