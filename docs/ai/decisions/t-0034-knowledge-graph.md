# Decision 0034 — Knowledge Graph Data Layer

## Status
Accepted

## Triggers

- type: file
- path: `docs/ai/knowledge-graph/`
- path: `.claude/tools/kg-`
- keywords: `knowledge graph, knowledge-graph, graph.yaml, schema.yaml, kg-seed, kg-relevance, semantic connection, edge type, staleness`

## Decision
Add a persistent knowledge graph that maps semantic connections between codebase entities, enabling agents to consume pre-computed context and persist connection knowledge across sessions.

1. **Storage path**: `docs/ai/knowledge-graph/` — outside `.claude/` governance prefix per Decision 0012. Three files: `schema.yaml` (schema definition), `graph.yaml` (consolidated graph data), `README.md` (usage reference)
2. **Write authority**: Graph writes use shell I/O (Bash redirection) at session boundaries, matching the analytics pattern from Decision 0009. This bypasses write-guard for session-boundary state while keeping the graph as a committed, version-controlled artifact. Agents update the graph during the build or commit phase; the session-close-check hook provides an advisory reminder
3. **Schema versioning**: `schema_version: 1` at graph root. Massimo and child repos read this field to validate compatibility before consuming graph data. Schema changes require a decision amendment
4. **Node types**: `file`, `decision`, `hook`, `prompt`, `contract`, `concept`, `convention` — convention nodes represent implicit codebase patterns (e.g., naming conventions, co-located tests)
5. **Edge type taxonomy (8 types)**: `governs` (authority), `constrains` (restriction), `implements` (spec-to-code), `depends-on` (structural dependency), `produces` (data flow out), `consumes` (data flow in), `tests` (verification), `supersedes` (versioning/deprecation). Extensions require decision amendment
6. **Authority hierarchy**: Edges carry `source_type: operator-curated | agent-inferred`. Operator-curated edges are immutable by agents — agents cannot overwrite, mark stale, or delete them. Agent-inferred edges can be modified by any agent or operator
7. **Staleness protocol**: Edges carry `status: active | stale | unverified` and `last_verified` (ISO date). When an agent reads and confirms an edge, it updates `last_verified` and sets `status: active`. Invalid edges get `status: stale` (not deleted). Edges stale for 90+ days are prune candidates. Session-count-based staleness (30 sessions without verification) is tracked via `last_verified` date aging
8. **Concurrent write safety**: Single-file graph means worktree sessions writing simultaneously could conflict. Graph writes use `mkdir`-based locking (atomic directory creation as lock — same approach used by merge-lock in Decision 0030 for macOS compatibility)
9. **Session integration**: Graph loaded on-demand at session start when task brief references files with graph nodes or when the session touches governance-adjacent paths (AI.md on-demand trigger). Advisory graph-update reminder in session-close-check.sh
10. **Bootstrap seeder**: `.claude/tools/kg-seed.sh` generates initial graph from governance metadata (DIGEST.md trigger annotations, AI.md source-of-truth, hook table). All seeded edges are `agent-inferred` and `unverified`. Utility scripts placed under `.claude/tools/` (not `scripts/`) because they are governance utilities — `scripts/` is treated as product code by the mode guard, which blocks writes in template mode
11. **Relevance scoring**: `.claude/tools/kg-relevance.sh` performs weighted graph traversal given scope files, producing ranked also-relevant files with edge paths. Weight model: scope files x50, direct edges x10, governance edges x5, two-hop x2, stale x0.3, unverified x0.5
12. **Convention nodes**: Nodes with `type: convention` represent implicit codebase patterns. Edges from convention nodes to exemplar files use `constrains` relation. Agent-inferred conventions start with confidence 0.3–0.5, promotable to `operator-curated` when verified

## Consequences
- `docs/ai/knowledge-graph/` directory added with `schema.yaml`, `graph.yaml`, `README.md`
- `.claude/tools/kg-seed.sh` and `.claude/tools/kg-relevance.sh` added as utility scripts
- `AI.md` gains on-demand entry for `docs/ai/knowledge-graph/graph.yaml`
- `session-close-check.sh` gains advisory graph-update reminder
- Mode guard: `docs/ai/knowledge-graph/` falls under existing `docs/ai/` governance prefix — no carve-out needed in template mode
- Decision 0012 satisfied: storage outside `.claude/` prefix
- Decision 0009 pattern followed: shell I/O for session-boundary writes
- Decision 0014 respected: graph read at init, graph write before commit
- Decision 0030/0033 respected: concurrent write safety via mkdir locking
