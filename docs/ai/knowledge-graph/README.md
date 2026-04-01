# Knowledge Graph — Repo OS

Decision 0034 — Knowledge Graph Data Layer

## Overview

The knowledge graph maps semantic connections between codebase entities (files, decisions, hooks, prompts, contracts, conventions). It is agent-maintained, operator-curated, and self-correcting via staleness signals.

## Two-Graph Architecture

The knowledge graph uses a two-graph model to maintain clear ownership boundaries between template infrastructure and product code:

| File | Layer | Owner | Syncs to child repos? |
|------|-------|-------|-----------------------|
| `graph.yaml` | Template | Template repo | Yes (normal template sync) |
| `product-graph.yaml` | Product | Child repos | No (in `.templatesyncignore`) |
| `schema.yaml` | — | Template repo | Yes (shared schema) |
| `README.md` | — | Template repo | Yes |

### Cross-Layer Edges
When a product node references a template node (e.g., a product file `depends-on` a template hook), the edge is stored in the **source node's graph**. This means cross-layer edges from product nodes live in `product-graph.yaml`.

### "Shared" Concept
"Shared" is not a stored `layer` value — it is derived at read time by detecting template nodes that have incoming cross-layer edges from the product graph.

### ID Uniqueness Convention
Product node IDs use distinct prefixes from template node IDs to prevent collisions. Template nodes use: `decision-*`, `hook-*`, `agent-*`, `prompt-*`, `sot-*`, `convention-*`, `concept-*`.

### Locking
Each graph has its own lock directory:
- Template graph: `.graph-lock`
- Product graph: `.product-graph-lock`

## Agent Protocol

### Reading
- Loaded on-demand at session start when task brief references files with graph nodes
- AI.md on-demand trigger: governance-adjacent paths or brief scope overlap
- Agents run relevance scoring (`.claude/tools/kg-relevance.sh`) against brief scope files — searches both graphs automatically

### Writing
- Graph writes use shell I/O (Bash `>` redirection) — bypasses write-guard
- Route writes to the correct graph: template files → `graph.yaml`, product files → `product-graph.yaml`
- Updates are append-style: new nodes added, new edges added, existing `last_verified` updated
- Concurrent write safety: `mkdir`-based locking (per-graph lock directories)
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

- `.claude/tools/kg-seed.sh` — Bootstrap seeder: `--target template` (default) seeds template graph, `--target product` seeds product graph. Includes cross-graph integrity check
- `.claude/tools/kg-relevance.sh` — Relevance scoring: weighted traversal from scope files, searches both graphs
