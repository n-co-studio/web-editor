# Knowledge Graph — Repo OS

Decision 0034 — Knowledge Graph Data Layer

## Overview

The knowledge graph maps a child repo's product code: one node per meaningful source file, edges between them. It is agent-maintained, operator-curated, and self-correcting via staleness signals.

## One graph, child-owned (Amendment 9)

| File | Owner | Syncs to child repos? |
|------|-------|-----------------------|
| `product-graph.yaml` | Child repo | No (in `.templatesyncignore`) |
| `coverage.yaml` | Child repo | No (in `.templatesyncignore`) |
| `schema.yaml` | Template repo | Yes (shared schema) |
| `README.md` | Template repo | Yes |

The template graph (`graph.yaml`), which modelled Repo OS's own governance files, was **retired** in Amendment 9, along with the template-mode KG Update Gate and the governance seeding that built it. Template sync's withdrawn-file sweep removes `graph.yaml` from children. The template repo ships no graph of its own.

Every node has `layer: product`. A child edge that pointed at a retired template node (e.g. `hook-phase-helper`) now dangles: `kg-validate.sh` reports it as advisory and never blocks on it (§9).

## The commit gate (Amendment 9)

`pre-commit-gates.sh` blocks a commit whose staged product files and `product-graph.yaml` disagree. It judges **only the files the commit touches**, and only those the child declares in scope in `coverage.yaml`:

```yaml
roots:            # path globs; `*` crosses `/`. A leading ./ and trailing / are ignored
  - src/app
  - packages/*/src/content
extensions:       # an include-list — unknown file types pass. A leading dot is ignored
  - ts
  - tsx
  - css
  - scss
exclude:          # optional, on top of the built-ins:
  - "*.stories.*" # a glob, matched against the path and the file name
  - storybook/    # a trailing / means a directory, at the top or at any depth
                  # built-ins: *.test.* *.spec.* *.d.ts __tests__/ __fixtures__/ generated/ dist/ build/
```

Inline lists work too (`roots: [src/app, src/components]`). A `coverage.yaml` with no roots or no extensions puts nothing in scope, and the gate says it is inert rather than staying silent.

For each in-scope staged change:

- **Added / modified** — a **live** node (any status but `stale`) with that path must exist, and its `description` must not be the seeder default `"Product source file"` and must be at least 20 characters. A node is required, never an edge. A stale node is not coverage — marking a node stale cannot satisfy the gate.
- **Renamed** — the node's `path` is updated to the new name; no node may still point at the old one unless `status: stale`.
- **Deleted** — the node is removed or marked `status: stale`.
- **Freshness** — `product-graph.yaml` is staged with the commit, or this session already passed the gate (`kg-updated` marker).

Both `product-graph.yaml` and `coverage.yaml` are read from the **index**, i.e. what the commit will contain; an uncommitted edit to either changes nothing. Deleting either in the same commit as in-scope changes blocks. An invalid staged graph is reported once, as the validator's finding. Hand-edited forms the validator accepts — single-quoted values, trailing comments, folded (`>-`) descriptions — are read as written.

Exemptions (advisory, never block): a task-group **content** brief with a KG delta pending (its merge brief's commit is judged; a leftover delta exempts no one else), audit session, `REPO_OS_RECOVER`, `REPO_OS_SKIP_KG_GATE=1` (interactive only). `experiment/*` branches never reach the gate — the hook exits early on them. With no `coverage.yaml` the gate is not configured and says so; with `coverage.yaml` but no graph it points at `kg-seed.sh --target product` and logs the bypass.

### Fixing a block

1. `bash .claude/tools/kg-cover.sh --target product <file>...` scaffolds missing nodes. A scaffolded node says `"Product source file"`, which the gate rejects on purpose.
2. Replace that description with what the file does (20+ characters). Update `path` for renames, remove or mark `stale` for deletions.
3. `git add docs/ai/knowledge-graph/product-graph.yaml`. `kg-cover.sh` writes no `kg-updated` marker, so the graph must be staged.

## Agent Protocol

### Reading
- Loaded on demand when a task brief's scope files have product-graph nodes
- `.claude/tools/kg-relevance.sh` scores relevance from brief scope files over the product graph

### Writing
- Graph writes use shell I/O (Bash `>` redirection); child mode carves out `product-graph.yaml` and `coverage.yaml`
- Updates are append-style: new nodes added, new edges added, existing `last_verified` updated
- Concurrent write safety: `mkdir`-based locking (`.product-graph-lock`)
- Write timing: during build or commit phase, before session close

### Verification
- When an agent reads and confirms an edge, update `last_verified` and set `status: active`
- When an edge is no longer valid, set `status: stale` (do not delete)
- Edges stale for 90+ days are candidates for pruning

## Authority Hierarchy

- `operator-curated` edges: immutable by agents — cannot be overwritten, marked stale, or deleted
- `agent-inferred` edges: modifiable by any agent or operator

## ID Format

Node ids are lowercase alphanumerics separated by single hyphens (`^[a-z0-9]+(-[a-z0-9]+)*$`), unique per graph — both enforced by `kg-validate.sh --strict`. The tools derive a node's id from its full path (`src/app/Settings.tsx` → `product-src-app-settings-tsx`), so files with the same name in different packages cannot collide.

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

- `.claude/tools/kg-seed.sh` — Creates `product-graph.yaml` from source files (`--file-pattern 'src/**/*.ts'`, repeatable — one per extension). Refuses to touch an existing graph.
- `.claude/tools/kg-cover.sh` — Scaffolds nodes for given files in an existing graph (the gate's remediation step); a path whose only node is stale gets a new live one.
- `.claude/tools/kg-validate.sh` — Schema, id-format, uniqueness and quoting checks; `--file` validates any copy (the gate passes the index copy).
- `.claude/tools/kg-relevance.sh` — Relevance scoring: weighted traversal from scope files.
- `.claude/tools/kg-query.sh` — Query CLI: neighbors, path, hubs, stats, search.
- `.claude/tools/kg-merge-deltas.sh` — Aggregates parallel task-group deltas into the graph in one locked write.
