# Decision 0034 — Knowledge Graph Data Layer

## Status
Accepted

## Triggers

- type: file
- path: `docs/ai/knowledge-graph/`
- path: `.claude/tools/kg-`
- keywords: `knowledge graph, knowledge-graph, graph.yaml, product-graph.yaml, schema.yaml, kg-seed, kg-relevance, semantic connection, edge type, staleness, two-graph`

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
9. **Session integration**: Graph loaded on-demand at session start when task brief references files with graph nodes or when the session touches governance-adjacent paths (AI.md on-demand trigger). Graph writes at session close are REQUIRE-attempt/tolerate-failure (Amendment 3 — supersedes the original advisory reminder). Session-type profiles: Full (Prompt B), Expedited (Prompt H), Light (Prompt E), Audit (Prompt C)
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

## Amendment 5 — Parallel Task Group Delta Authoring (2026-05-13)

Replaces the N+1 per-brief direct graph writes in parallel task groups with N per-brief delta files (authored in-context by each content brief) plus one aggregating write performed by the merge brief. Eliminates lock contention on `graph.yaml` / `product-graph.yaml` across parallel worktrees and preserves the authorship context that direct re-authoring from a combined diff would lose.

### When this amendment applies

Only parallel task groups (`Execution: parallel` in `### Task Group`). Single-brief sessions, sequential task groups, hotfix, editor-live, and audit profiles continue to write directly to the shared graph at close — they do not have the N concurrent-writer contention that motivates this change.

### Delta file schema

Each parallel content brief authors one delta at session close. The merge brief authors a second delta from cross-session observations. Path: `$_REPO_OS_ROOT/.claude/.state/tg-{group}-brief-{seq}.kg-delta.yaml` (content brief) and `$_REPO_OS_ROOT/.claude/.state/tg-{group}-brief-merge.kg-delta.yaml` (merge brief). Shared state path is the canonical cross-worktree coordination location per Decision 0032.

```yaml
# Header
brief_seq: "1"                        # or "merge"
group_name: "kg-write-aggregation"
worktree_branch: "feature/kg-write-aggregation/brief-1"
authored_at: "2026-05-13T18:32:11Z"   # ISO 8601 — used for stale detection and dedup
target: "template"                    # template → graph.yaml ; product → product-graph.yaml

# Same node/edge structure as graph.yaml, scoped to one brief's contributions
nodes:
  - id: "..."
    type: "..."
    path: "..."
    description: "..."
    last_verified: "2026-05-13"
    status: "active"
    layer: "template"
edges:
  - source: "..."
    target: "..."
    relation: "..."   # 8-type taxonomy unchanged
    context: "..."
    source_type: "agent-inferred"
    last_verified: "2026-05-13"
    status: "active"
    confidence: 0.7
```

### Authoring split

1. **Content brief Builder (per brief).** Authors its delta from observations made in its own session — files it touched, edges it created or traversed. Writes via shell I/O from the worktree's main session (not from a subagent — Decision 0028 boundary preserved). The delta file is the only KG output from the content brief; the content brief never touches the shared graph.

2. **Merge brief.** Authors a second delta from observations only it can make: integration edges between files owned by different content briefs, cross-cutting relationships visible in the combined diff, edges spanning worktree boundaries. The merge brief never authors edges on behalf of content briefs — it only authors what it can verify directly.

### Aggregation

The merge brief invokes `.claude/tools/kg-merge-deltas.sh <group_name>` after writing its own delta. The aggregator:

1. Reads all `tg-{group_name}-brief-*.kg-delta.yaml` from `$_REPO_OS_ROOT/.claude/.state/`.
2. Drops stale deltas — `authored_at` older than the merge brief's start time. Logs a warning with the dropped file's path.
3. Dedups using these rules:
   - **Nodes by `id`** — union the node set; on attribute conflicts, last `authored_at` wins; non-conflicting attributes are merged.
   - **Edges by `(source, target, relation)` tuple** — last `authored_at` wins on `last_verified` and attribute updates; max wins on `confidence`.
   - **Operator-curated edges (`source_type: operator-curated`) are never overwritten** — if any delta carries an edge whose tuple matches an operator-curated edge in the existing graph, the delta's version is dropped with a warning. Aggregation never demotes an operator-curated edge to agent-inferred.
   - **Conflicting `status`** — when two deltas contribute the same `(source, target, relation)` tuple but with different `status` values (e.g., one marks the edge `active`, another marks it `stale`), the aggregator does not silently resolve. The conflict is recorded to `$_REPO_OS_ROOT/.claude/.state/kg-aggregation-conflicts.log` for the merge brief's Critic to surface as a CRITICAL cohesion finding. The first-seen value is kept in the aggregated output so the write does not block.
4. Acquires the appropriate graph lock once (`.graph-lock` for template, `.product-graph-lock` for product — separation per Amendment 2).
5. Splices the aggregated nodes and edges into the target graph file.
6. Releases the lock.

### Cleanup

`cleanup_session_files()` removes the group's `tg-{group}-brief-*.kg-delta.yaml` files and the conflict log when a `taskgroup-merge` session closes. Mirrors the existing completion-marker cleanup pattern. Stale delta files from crashed parallel sessions that were not aggregated (because the merge brief detected them as stale) are also swept by the same cleanup.

### Constraints carried forward

- Edge taxonomy unchanged (8 types from §5).
- Operator-curated immutability (§6) — strengthened: aggregator must never overwrite operator-curated edges and must never demote them.
- Decision 0028 worktree state isolation preserved: deltas are written from the worktree's main session via shell I/O, not from a subagent's `state-writer.sh` invocation.
- Decision 0032 shared state path is the canonical cross-worktree coordination location — same path family as `tg-*-brief-*.complete` markers.

### Authorization

This behavioral change is authorized under §2 (write authority — adds a session-boundary delta-staging step before the existing locked write) and §8 (concurrent write safety — replaces N+1 contended writes with one). No new node types, edge types, or schema fields — §3 amendment not triggered.

### Rationale

The single-locked-write alternative (file-lock-with-retry on each per-brief direct write) was rejected because it serialises but does not reduce write count, and conflict-resolution logic ends up duplicated per brief. Re-authoring all edges in the merge brief from the combined diff was rejected because it strips authorship intent — the Builder in the content brief knew *why* it created an edge; the merge brief would be reverse-engineering intent. Centralising authoring at the merge brief and centralising aggregation at the merge brief are different problems; this amendment separates them.

---

## Amendment 4 — Mechanical Schema Validation (2026-04-09)

Adds mechanical enforcement of KG schema constraints at three points: write time (inline in `add_edge()`), post-seed (after graph write, before lock release), and commit time (blocking pre-commit gate). Closes a recurring defect class where agents invent relations outside the 8-type taxonomy.

### Enforcement Points

1. **Inline `add_edge()` guard** — `kg-seed.sh` `add_edge()` rejects any relation not in the 8-type taxonomy via a `case` guard. Returns 1 on invalid relation (edge not appended). This is the earliest enforcement point — catches invalid relations at construction time.

2. **Post-seed validation** — after `kg-seed.sh` writes graph content and releases the lock, it calls `kg-validate.sh --strict --target <target>` before returning. If validation fails, an error is reported and the seeder exits non-zero. The lock release trap is idempotent so cleanup is safe regardless.

3. **Pre-commit gate** — `pre-commit-gates.sh` calls `kg-validate.sh --strict` when `docs/ai/knowledge-graph/graph.yaml` or `docs/ai/knowledge-graph/product-graph.yaml` is staged. Uses `GATE-RECOVERABLE` + `FAILED=1` (blocking) — schema violations are corrupt data, not advisory coverage gaps. Gate is scoped to staged graph files only: zero impact on commits that don't touch graph YAML.

### New Tool: `.claude/tools/kg-validate.sh`

Standalone validator using grep/awk only (no external dependencies). Accepts `--target template|product|both` and `--strict` flags.

Validates:
- `relation:` values against the 8-type taxonomy
- Node `type:` values against the 7 valid types
- `status:` values against 3 valid statuses
- `source_type:` values against 2 valid source types
- Required field presence for nodes (`id`, `type`, `description`, `last_verified`, `status`, `layer`) and edges (`source`, `target`, `relation`, `context`, `source_type`, `last_verified`, `status`)

Does NOT check referential integrity or node ID format.

Fail-open: if `schema.yaml` is absent, the validator exits 0 with a warning (does not block commits in repos without the schema file).

### Authorization

Authorized under §3 (schema changes require decision amendment) and §5 (edge type taxonomy — extensions require decision amendment). No new node types or edge types added — this amendment adds mechanical enforcement of existing constraints. Zero external dependencies maintained.

---

## Amendment — Layer Taxonomy (2026-03-31)

Adds a `layer` field to the node schema, enabling the knowledge graph to distinguish template infrastructure nodes from product code nodes.

1. **Field definition**: `layer` — required enum field on all nodes. Values: `template` (governance and template infrastructure), `product` (product application code). Added to `schema.yaml` after the `status` field. "Shared" is not a stored value — it is derived at read time (see Amendment 2)
2. **Migration**: All 69 existing nodes assigned `layer: "template"` — they are governance/template entities (decisions, hooks, prompts, agents, conventions, concepts, source-of-truth files)
3. **Product nodes**: Product-layer nodes are seeded separately by child repos (e.g., massimo). This amendment does not add product nodes to the template graph
4. **UI integration**: The massimo child repo implements layer-aware filtering in the knowledge graph explorer (filter chips, visual badges, color-coded edges). Product code changes live on branch `feature/knowledge-graph-layer-taxonomy` in the massimo repo
5. **Validation**: The massimo validator (`kg-validate.ts`) enforces the `layer` field as required on all nodes. The massimo branch must be merged before this template change syncs downstream to avoid validation failures
6. **Authorization**: This schema extension is authorized under §3 (schema changes require decision amendment)

## Amendment 3 — Mandatory Integration Across Session Types (2026-04-04)

Closes knowledge graph integration gaps and makes graph usage mandatory (not advisory) across Prompts B, H, E, and C via governance model enforcement. No new hooks.

### Behavioral Changes

1. **Write stance — REQUIRE attempt, tolerate failure.** Agents MUST attempt graph writes at session close. If the write fails (lock contention, parse error), log the failure in the closing summary and proceed to commit. Skipping the attempt entirely is a REQUIRE violation.

2. **Read stance — REQUIRE when context file is present and non-empty.** Agents MUST read `.claude/.state/kg-relevance-context` before broad codebase searches (`grep -r`, `find`, repo-wide glob patterns) when that file exists and is non-empty. When absent or empty, proceed with normal search (documented exception, not default behavior).

3. **Session-type profiles:**

   | Profile | Session Type | Read | Write |
   |---------|-------------|------|-------|
   | Full | Prompt B (standard build) | REQUIRE: read `kg-relevance-context` when present; `_inject_kg_context()` auto-populates at build phase entry | REQUIRE-attempt at close before final commit |
   | Expedited | Prompt H (hotfix/debug) | REQUIRE: call `kg-relevance.sh` directly with diagnosed affected files after plan phase investigation | REQUIRE-attempt at close |
   | Light | Prompt E (editor-live) | Read `kg-relevance-context` once at build phase entry if present | REQUIRE-attempt at close only (no mid-cycle writes) |
   | Audit | Prompt C (project audit) | Read-only — new `graph-health` Auditor mode | No writes |

### Rationale

REQUIRE creates auditable obligations — session logs, cohesion review, and Pragmatist plan-gating can flag violations. Hook-based enforcement is explicitly excluded (operator constraint). The distinction between REQUIRE and advisory: skipping the attempt is now a violation, not a missed suggestion. Agents whose attempt fails are compliant; agents who don't try are non-compliant.

### Prompt H — Direct Invocation Rationale

Prompt H has no task contract, so `_inject_kg_context()` silently no-ops. Direct invocation with diagnosed files fits the expedited session model.

### Authorization

This behavioral upgrade is authorized under §9 (session integration) and §2 (write authority). No schema changes — §3 amendment not triggered.

---

## Amendment 2 — Two-Graph Architecture (2026-03-31)

Splits the single graph data file into a two-graph model — one for template infrastructure (synced to child repos) and one for product code (child-owned, never overwritten by template sync). This prevents template sync from destroying product graph data in child repos.

1. **Split rationale**: Template sync overwrites `graph.yaml` in child repos, destroying product-layer nodes and edges added by the child. Splitting into two files with distinct sync behavior eliminates this data loss
2. **File locations**: Template graph remains at `docs/ai/knowledge-graph/graph.yaml`. Product graph at `docs/ai/knowledge-graph/product-graph.yaml`. The product graph is NOT created in the template repo — child repos create it locally
3. **Sync exclusion**: `product-graph.yaml` added to `.templatesyncignore`. This syncs to child repos as a protective measure, ensuring the path is excluded before any child creates their product graph
4. **Cross-layer edge ownership**: Edges are stored in the source node's graph file. A product node that `depends-on` a template hook stores that edge in `product-graph.yaml`. This ensures each graph is self-contained for its layer's outbound relationships
5. **Derived "shared" concept**: The `shared` value is removed from the `layer` enum. "Shared" is derived at read time by detecting template nodes that have incoming cross-layer edges from the product graph. This avoids ambiguity about which graph owns a "shared" node
6. **Lock separation**: Each graph has its own lock directory — `.graph-lock` for the template graph, `.product-graph-lock` for the product graph. This allows concurrent writes to different graphs without contention
7. **Seeder update**: `kg-seed.sh` gains `--target template|product` flag (default: `template`). The `--target` value determines the output file, lock directory, and `layer` field emitted on seeded nodes. Product seeding is a child-repo responsibility
8. **Relevance scoring update**: `kg-relevance.sh` searches both graph files automatically. If only one exists, it searches that one. No complex merge logic — grep naturally handles multiple files
9. **Cross-graph integrity check**: At the end of a seed run, `kg-seed.sh` validates that all edge `source`/`target` IDs exist as node IDs in the union of both graphs. Dangling references are reported as warnings (advisory)
10. **ID uniqueness convention**: Product nodes use distinct prefixes from template nodes to prevent collisions across graphs. Template prefixes: `decision-*`, `hook-*`, `agent-*`, `prompt-*`, `sot-*`, `convention-*`, `concept-*`. Product prefixes are child-defined
11. **Authorization**: This structural split is authorized under §3 (schema changes require decision amendment) and §8 (concurrent write safety)
