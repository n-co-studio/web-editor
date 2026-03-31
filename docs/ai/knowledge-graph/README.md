# Knowledge Graph — Repo OS

Decision 0034 — Knowledge Graph Data Layer

## Overview

The knowledge graph maps semantic connections between codebase entities (files, decisions, hooks, prompts, contracts, conventions). It is agent-maintained, operator-curated, and self-correcting via staleness signals.

## Files

| File | Purpose |
|------|---------|
| `schema.yaml` | Schema definition — node/edge field types, edge taxonomy |
| `graph.yaml` | Consolidated graph data — nodes and edges |
| `README.md` | This file |

## Agent Protocol

### Reading
- Loaded on-demand at session start when task brief references files with graph nodes
- AI.md on-demand trigger: governance-adjacent paths or brief scope overlap
- Agents run relevance scoring (`.claude/tools/kg-relevance.sh`) against brief scope files

### Writing
- Graph writes use shell I/O (Bash `>` redirection) — bypasses write-guard
- Updates are append-style: new nodes added, new edges added, existing `last_verified` updated
- Concurrent write safety: `mkdir`-based locking (same pattern as merge-lock)
- Write timing: during build or commit phase, before session close

### Verification
- When an agent reads and confirms an edge, update `last_verified` and set `status: active`
- When an edge is no longer valid, set `status: stale` (do not delete)
- Edges stale for 90+ days are candidates for pruning

## Authority Hierarchy

- `operator-curated` edges: immutable by agents — cannot be overwritten, marked stale, or deleted
- `agent-inferred` edges: modifiable by any agent or operator

## Edge Types (8)

| Type | Meaning |
|------|---------|
| `governs` | Authority relationship |
| `constrains` | Behavioral restriction |
| `implements` | Spec-to-code binding |
| `depends-on` | Structural dependency |
| `produces` | Data flow out |
| `consumes` | Data flow in |
| `tests` | Verification relationship |
| `supersedes` | Versioning/deprecation |

## Utilities

- `.claude/tools/kg-seed.sh` — Bootstrap seeder: generates initial graph from governance metadata
- `.claude/tools/kg-relevance.sh` — Relevance scoring: weighted traversal from scope files
