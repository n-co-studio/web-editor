# Agent Glossary

Shared terminology used across all agent definitions. All agents should interpret these terms consistently.

---

## Scope & Size Definitions

### Small Scope
A change is considered "small" when it meets ALL of these criteria:
- **Lines changed**: <100 lines of production code (excluding generated files, tests, config)
- **Files touched**: ≤3 files (not counting lock files, generated assets)
- **Single concern**: Addresses exactly one logical change (one bug fix, one feature addition, one refactor target)
- **Reviewable in <10 minutes**: A competent reviewer can understand the change quickly

### Large Scope
Any change that exceeds small scope thresholds. Large scope changes must be:
- Split into smaller increments, OR
- Explicitly approved by operator with documented rationale

### Structural Change
A change that modifies the fundamental organization or architecture:
- New modules, packages, or major directory restructuring
- Changes to core abstractions, base classes, or interfaces
- Database schema modifications
- API contract changes (endpoints, request/response shapes)
- Build system or dependency graph changes

### Cross-Cutting Change
A change that affects multiple unrelated parts of the system:
- Logging, monitoring, or observability modifications
- Authentication/authorization changes
- Error handling patterns
- Configuration or environment variable changes
- Shared utility updates used across modules

---

## Risk Levels

### High-Risk Domains
Changes in these areas automatically require Reviewer + Security sign-off:
- **Authentication & Authorization**: Login, logout, session management, permissions, OAuth, tokens
- **Payments & Financial**: Billing, transactions, pricing, refunds, payment provider integrations
- **Data Persistence**: Database migrations, schema changes, data deletion, backup/restore
- **Security Boundaries**: Input validation, output encoding, cryptography, secrets handling
- **PII & Sensitive Data**: User personal information, health data, financial records
- **External Integrations**: Third-party APIs, webhooks, data export/import

### Medium-Risk Domains
Changes that warrant extra scrutiny but don't automatically require additional review:
- Public-facing UI changes
- Performance-critical paths
- Caching logic
- Background job processing
- Rate limiting or throttling

### Low-Risk Domains
Routine changes with minimal downstream impact:
- Documentation updates
- Test additions or modifications
- Code formatting or style fixes
- Comment updates
- Development tooling changes

---

## Compliance Terminology

### Decision
A version-controlled constraint stored in `docs/ai/decisions/`. Decisions are mandatory ("laws, not notes"). Violations block commits.

### Decision Compliance
The gate that verifies:
1. All applicable decisions have been identified
2. Each applicable decision's constraints are satisfied
3. No decision is violated or ignored

### Gate
A blocking verification requirement. Gates must pass before commits (commit gates) or pushes (push gates). Types:
- **Process Gates**: Plan exists, scope is small, changes are explainable
- **Quality Gates**: Format, lint, build, tests, typecheck
- **Safety Gates**: No secrets, no PII, dependency audit
- **Conditional Gates**: Project-specific (e.g., GPS testing, auth verification)

### Evidence
Proof that a gate was checked and passed. Valid evidence includes:
- Command executed (exact command string)
- Output excerpt (relevant lines)
- Pass/fail determination
- Timestamp (implicit in session log)

---

## Workflow Terminology

### Plan
A documented approach for implementing a change before any code is written. A valid plan includes:
- Goal statement
- Applicable decisions identified
- Implementation steps (ordered)
- Files to be modified
- Verification approach
- Risks or open questions

### Handoff
The formal transition of work from one agent to another. A valid handoff includes:
- Summary of work completed
- Status (ready for next phase / blocked / needs revision)
- Specific items for receiving agent to verify

### Session
A bounded unit of work with a defined goal, documented in `docs/ai/logs/session-log.md`. Sessions have:
- Clear start and end
- Defined scope
- Verification evidence
- Clean commit state at close

### Escalation
Routing a decision or issue to a higher authority when:
- The agent lacks authority to decide
- Requirements are ambiguous
- Constraints conflict
- A gate fails with no clear resolution path

---

## Enforcement Terminology

### Hook
An automated script triggered by Claude Code lifecycle events (e.g., before a commit, when a session stops). Hooks run regardless of agent behavior — they are mechanical enforcement, not voluntary compliance.

### Subagent
An agent invocable via the Task tool with an isolated context and enforced tool restrictions defined in YAML frontmatter. Subagents cannot exceed their declared tool boundaries.

### Settings (Shared)
`.claude/settings.json` — team-wide permissions and hooks, committed to git. Applies to every session automatically. Personal overrides go in `.claude/settings.local.json` (gitignored).

---

## Agent Roles (Summary)

| Agent | Primary Responsibility | Blocks Commits? |
|-------|----------------------|-----------------|
| **Orchestrator** | Planning, coordination, architecture alignment | No (but controls workflow) |
| **Builder** | Scoped implementation | No |
| **QA/Verifier** | Gate verification | **Yes** |
| **Reviewer** | Code quality, architecture review | **Yes** (when required) |
| **Security/Privacy** | Secrets, auth, privacy risks | **Yes** (when required) |
| **Accessibility** | UI accessibility | No (advisory) |

---

## Cross-References

All agents must be familiar with:
- [AI.md](../../AI.md) — Root contract between operator and agents
- [workflow.md](../../docs/ai/workflow.md) — How work happens, role definitions
- [quality-gates.md](../../docs/ai/quality-gates.md) — Gate definitions and requirements
- [decisions/](../../docs/ai/decisions/) — Mandatory constraints (check before planning)
- [session-log.md](../../docs/ai/logs/session-log.md) — Session documentation template
