# Decision t-0042 — Hook Check Hoisting via phase-state.gates Cache

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/_phase-helper\.sh`
- path: `\.claude/hooks/bash-guard\.sh`
- path: `\.claude/hooks/write-guard\.sh`
- path: `\.claude/hooks/pre-commit-gates\.sh`
- path: `\.claude/hooks/_cleanup-helper\.sh`
- keywords: `compute_phase_gates, read_phase_gates, phase-state.gates, hook hoist, GATES_SESSION_OVERLAP, GATES_BRANCH_ISOLATION`

## Context

Three hooks — `bash-guard.sh` (PreToolUse:Bash), `write-guard.sh` (PreToolUse:Edit/Write), and `pre-commit-gates.sh` (PreToolUse:Bash for `git commit`) — each independently performed two governance checks on every invocation:

1. **Session overlap** (Decision 0013) via `check_session_overlap()` in `_analytics-helper.sh`. The function globs `.claude/.state/sessions/*.yaml`, parses each registry entry, and runs `kill -0 <pid>` per remote session. The function carries a per-PID memo cache (`_SESSION_OVERLAP_CHECKED`), but each PreToolUse hook fires in a fresh subprocess — the memo never survives across invocations, so the glob/parse/kill loop ran on every Bash and Edit call.

2. **Branch isolation** (Decision 0013) via an inline `grep -qxF` against `.claude/local/closed-branches`. Cheap individually but duplicated across `bash-guard.sh` and `write-guard.sh`.

The verdicts of both checks are functions of state that only changes at well-defined moments (a new session registers, a branch is sealed). They do not change between Bash calls within a phase. Recomputing them per-invocation is waste.

## Decision

### 1. Cache file

Session-scoped at `<session_state_dir>/phase-state.gates`, written by `compute_phase_gates()` in `_phase-helper.sh`. Format is a single-quoted shell-sourceable `KEY=VALUE` file (one `source` to read, no `grep` per field). Schema:

```
GATES_SESSION_ID='<sid>'
GATES_COMPUTED_AT='<ISO 8601 UTC>'
GATES_CURRENT_PHASE='<phase>'
GATES_SESSION_TYPE='<type>'
GATES_CURRENT_BRANCH='<branch>'
GATES_CLOSED_BRANCHES_MTIME='<epoch_or_empty>'
GATES_SESSION_OVERLAP='ok|blocked|advisory'
GATES_SESSION_OVERLAP_DETAIL='<message_when_not_ok>'
GATES_BRANCH_ISOLATION='ok|blocked'
GATES_BRANCH_ISOLATION_DETAIL='<message_when_not_ok>'
```

Written atomically: `printf … > <gates>.tmp.$$ && mv -f`. Cache is cleaned by `cleanup_session_files()` at session close. `_delete_if_owned` is extended in `_cleanup-helper.sh` to fall back to the `GATES_SESSION_ID='<sid>'` line when the YAML `^session_id: ` field is absent — preserving the parallel-session ownership guard for the new shell-sourceable file format (Critic L1d.9 cohesion finding).

### 2. Helper functions in `_phase-helper.sh`

- `compute_phase_gates()` — runs the two checks once and writes the cache. Called from `init_phase()` (after the phase-state file is written) and from `advance_phase()` (after every transition). Override env vars (`REPO_OS_SKIP_OVERLAP_CHECK`, `REPO_OS_SKIP_BRANCH_REUSE`) are intentionally *not* consulted at compute time — overrides are per-invocation policy and remain the responsibility of the hooks.
- `read_phase_gates()` — sources the cache file and validates freshness. Returns 0 (cache valid; `GATES_*` vars exposed in caller scope) when:
  - file exists
  - `GATES_SESSION_ID` matches the current session
  - `GATES_CURRENT_BRANCH` matches `get_branch` (catches mid-phase `git checkout`)
  - `GATES_CLOSED_BRANCHES_MTIME` matches the current mtime (catches mid-phase branch seal by a parallel session)

  Returns 1 on any miss; caller falls through to the legacy inline check.

### 3. Hook integration

Each of the three hooks attempts a cache read first, then dispatches:

- **Cache hit** → consult `GATES_SESSION_OVERLAP` / `GATES_BRANCH_ISOLATION` (and `GATES_CURRENT_PHASE` in `pre-commit-gates.sh`). Override env vars are evaluated FIRST in each branch and continue to write `log_override` audit entries; cache hit does not bypass overrides.
- **Cache miss** → original inline check runs unchanged (BC by construction). The fall-through path is the explicit safety net for crashed sessions, post-checkout drift, and the first hook fired immediately after a recovery signal consumes prior state.

Hook log lines append `cache:hit` as a metadata field on cache-hit branches so `permission-audit.log` analysis can distinguish hot-path hits from cold-path inline runs.

### 4. Phase enforcement is intentionally NOT cached

Each of the three hooks asserts a different target phase (`build` for `bash-guard`, `commit` for `pre-commit-gates`, `init|plan` blocking + session-type write phases for `write-guard`). Pre-computing per-hook verdicts would multiply the cache schema with no shared field. `assert_phase` already reads only the small `phase-state` file — its overhead is one `grep`, dwarfed by the overlap/isolation savings. The current phase IS exposed as `GATES_CURRENT_PHASE` so future callers can read it without a second `get_phase` invocation, but no per-hook precomputation is performed.

## Rationale

- **Performance** — the dominant per-invocation cost in PreToolUse:Bash and PreToolUse:Edit was the `sessions/*.yaml` glob + parse + `kill -0` loop. After hoisting, that work runs once per phase transition (typically 5–10 times per session) instead of once per Bash/Edit call (often 100+ times per session).
- **Safety** — every BLOCK preserved. Cache miss falls through to the original code path; no behavioural change when the cache is unavailable. Override env vars are checked first in each hook branch, so audit log semantics are unchanged.
- **Concurrency** — atomic temp-file write avoids torn reads. Mid-phase branch seals by a parallel session are caught by `GATES_CLOSED_BRANCHES_MTIME` invalidation. Mid-phase `git checkout` (rare but possible during HVST debugging) is caught by `GATES_CURRENT_BRANCH` invalidation.
- **No feature flag** — the cache miss fallback IS the safety net. Adding `REPO_OS_HOOK_CACHE=0` would create two code paths to maintain with no diagnostic benefit beyond what `cache:hit` log metadata already provides.

## Tradeoffs

- **Mid-phase overlap drift** — if a parallel session registers itself on the same branch *between* phase transitions, the cached `GATES_SESSION_OVERLAP=ok` verdict will mask the new conflict until the next transition. This is acceptable because (a) the parallel session's own `register_session` call detects the same overlap from its side and blocks itself, and (b) overlap is registered at session init — the window between "other session registers" and "we transition phase" is small in practice.
- **Stat overhead per hook** — every hook now performs `stat` on `phase-state.gates` plus `stat` on `closed-branches` (for mtime comparison). On macOS/Linux that is two cheap syscalls vs. the prior glob + parse + kill loop — net win.
- **Schema rigidity** — the `KEY=VALUE` shell-sourceable format does not nest. If future hoisting needs structured fields, migrate to YAML and use the existing AWK readers in `_phase-helper.sh`. Today's schema is intentionally flat.

## Verification

- `compute_phase_gates` writes the cache file at `init_phase` and after every `advance_phase`.
- `read_phase_gates` returns 1 on session-ID mismatch, branch mismatch, or closed-branches mtime change.
- Hooks behave identically to pre-refactor on cache miss (inline path preserved verbatim).
- Cache miss falls through silently (no operator-visible error).
- shellcheck clean on all touched hooks.
- Hook test suite (Layer 1b registry + Layer 3 integration) passes with new cache assertions.

## Migration / Rollback

- **No data migration required.** Existing sessions without `phase-state.gates` simply hit the inline path on first read; the cache materialises on the next `advance_phase`.
- **Rollback procedure**: remove the `compute_phase_gates || true` calls from `init_phase` and `advance_phase`, and revert the three hook diff blocks to the inline-only versions. The `phase-state.gates` file becomes orphaned but is cleaned by the existing `cleanup_session_files()` sweep.
