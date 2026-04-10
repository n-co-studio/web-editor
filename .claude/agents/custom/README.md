# Custom Agents

Operator-defined agents that extend the template's predefined agent roster.

## Namespace

This directory (`.claude/agents/custom/`) is the custom agent namespace. Files here are project-owned and operator-writable in child mode, unlike template agents in `.claude/agents/` which are template-protected.

## Format Requirements

Custom agents use the same markdown + YAML frontmatter format as template agents (Decision 0003):

```markdown
---
model: standard
tools:
  - Read
  - Glob
  - Grep
---

# Agent Name

## Role
[Agent's role description]

## Scope
[What the agent can do]

## Constraints
[Behavioral rules]
```

## Plugin-Tier Restrictions

Custom agents operate at Claude Code's plugin tier. The following frontmatter fields are **restricted** and will be stripped at validation:

| Field | Reason |
|-------|--------|
| `hooks` | Custom agents cannot register event hooks |
| `mcpServers` | Custom agents cannot add MCP server connections |
| `permissionMode` | Custom agents cannot escalate session permissions |

## Name Collision Rules

Custom agent filenames must not match any template agent filename in `.claude/agents/`. Name uniqueness is enforced at creation time. If a template sync introduces a collision, the template agent takes precedence.

## Resolution

Claude Code resolves agents from `.claude/agents/` at priority 2 (project directory). Custom agents in this subdirectory are resolved at the same tier.
