# Decision 0023 — Editor-Live Session Type

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/_phase-helper\.sh`
- path: `\.claude/\.state/phase-state`
- keywords: `editor-live, fswatch, visual change, pending_visual_changes, acknowledge_visual_change, commit:build`

## Decision
Add an `editor-live` session type for continuous visual-development workflows where the operator edits files in an external editor and the agent responds to each saved change. The session type is registered in the phase model (Decision 0014) with a novel loop topology.

1. **Session type**: `editor-live`. Registered in `_phase-helper.sh` as a session type in the Decision 0014 enum (17 types total).

2. **Phase sequence**:
   `init[agent] → build[agent] → commit[agent] → review[agent] → verify[agent] → op-review[operator] → close[agent]`

   No `plan` or `approval` phases — the operator's live edits are the plan. The agent enters `build` immediately after `init` and responds to file-change signals.

3. **Loops**: `commit:build` (return to build after committing to handle the next change), `verify:build` (QA failure triggers rebuild).

   The `commit:build` loop is a novel backward transition — the first in the system where the `commit` phase loops back to `build`. The `advance_phase` function handles this correctly: registered loop pairs bypass forward-only index validation (line ~419-433 in `_phase-helper.sh`).

4. **Automation tags**: All phases tagged `agent` except `op-review` → `operator`. The operator interacts through the external editor, not through phase-level approval gates.

5. **Gate profile**: A4 (safety) enforced per commit within the build-commit loop. Full gates (A5 cohesion + QA verification) enforced at the `review`/`verify` phases before close. This gives lightweight per-iteration safety with comprehensive final review.

6. **Signal mechanism**: Tracked status file + filesystem watcher. The MCP server writes a change record when the operator saves a file. The agent polls via `get_pending_visual_changes` MCP tool to detect new changes.
   - **macOS/Linux**: `fswatch` monitors the project directory for file saves
   - **Fallback**: `inotifywait` (Linux) when `fswatch` is unavailable
   - **Change record**: Status file in `.claude/.state/` tracks pending visual changes with file path, timestamp, and change type

7. **MCP integration**: Two MCP tools provide the agent-facing interface:
   - `get_pending_visual_changes` — returns list of files changed since last acknowledgment
   - `acknowledge_visual_change` — marks a change as processed, advancing the agent to respond to the next change

8. **Close signal**: The operator sends the structural keyword "close session" to signal the end of the editor-live session. The agent then advances through `review → verify → op-review → close`.

9. **Cycle advisory**: At 50 build-commit iterations, the agent emits an advisory suggesting the operator close the session to maintain context quality. Not a hard limit — the operator may continue.

10. **Operating mode**: Child mode only. Template mode has no product code to visually edit. Autonomous mode has no operator for live interaction.

11. **Plan gate**: `has_plan_gate("editor-live")` returns false (1) — no `approval` phase in the sequence. The plan-approval hook and plan-gate enforcement do not apply.

12. **Cross-platform**: `fswatch` is the primary watcher (available on macOS via Homebrew and Linux via package managers). `inotifywait` (from `inotify-tools`) serves as the Linux fallback. The MCP server detects availability at startup and selects the appropriate backend.

## Context
Standard build sessions require a plan-approval gate before entering the build phase. Editor-live sessions invert this: the operator works in an external editor (e.g., VS Code, Figma export, design tool), and the agent responds to each saved change. The plan is implicit in the operator's edits. The `commit:build` loop enables the agent to commit completed work and return to the build phase for the next change — a topology not needed by any existing session type.

The variant-within-standard approach was considered but rejected because the phase topology is fundamentally different (no plan gate, commit:build loop). The experiment session type was also considered but rejected because experiments lack review/verify at close and are scoped to `experiment/*` branches.

## Consequences
- `.claude/hooks/_phase-helper.sh` updated: `editor-live` added to `get_phases_for_type`, `get_loops_for_type`, `get_tag_for_phase`
- Decision 0014 amended: session type enum incremented to 17 (also added missing `ephemeral`), `editor-live` added to enum list and phase sequence documentation
- `.claude/agents/_agent-glossary.md` updated: `editor-live` phase definitions added to Phase Model section
- `docs/ai/decisions/t-manifest.txt` updated: `t-0023-editor-live-session-type.md` added
- `docs/ai/decisions/.a1-trigger-index` regenerated to include Decision 0023 triggers
- No new hooks, no new state files (uses existing `.claude/.state/` infrastructure)
- `write-guard.sh` updated: `editor-live` added to phase-exempt session types (Gate 2, Section 3) — allows edits in `init` phase without plan gate
- `_permission-allowlist.sh` updated: `fswatch`/`inotifywait` added to safe Bash command prefixes
- No changes to `bash-guard.sh` (`has_plan_gate` implicitly handles `editor-live` — no `approval` phase)
- `pre-commit-gates.sh` updated: editor-live detection with per-loop (A4 only) and close (full gates minus plan-approved) commit profiles

## Amendment 1 — Pause-Stop Semantics

**Status:** Accepted

Decision 0023 § 8 establishes that the *only* close signal is the "close session"
keyword. But the Stop hook (`session-close-check.sh`) fires on **every** agent
turn end, not only on close. Editor-live sessions Stop between build cycles for
ordinary reasons — the watcher times out, the operator interjects, or the
context window turns over. The hook previously treated each of these Stops as a
session close, running the full close sequence (state cleanup, branch seal, solo
merge) every time. This produced three coupled failures in interactive
(non-worktree) editor-live sessions, where `REPO_OS_SESSION_ID` is unset and
identity resolves from the `.claude/.session-id` file:

1. **Identity churn (primary).** `cleanup_session()` → `cleanup_session_files()`
   deletes `.claude/.session-id` on every Stop. The next turn mints a fresh
   timestamp id, so the per-session state directory
   (`.claude/.state/wt-sessions/{id}/`), the session-log filename
   (`session-{id}.md`), and the cycle counter all move — the prior build phase
   "disappears" and edits get re-blocked at init.
2. **Premature merge / seal.** Each Stop solo-merged mid-session cycle commits
   into main and sealed the `live-editor-N` branch before the session was done,
   contradicting the pause contract and stranding branches.
3. **Safety-valve misfire.** The 3-attempt counter accumulated across pauses, so
   the unconditional safety valve fired mid-session after three pauses.

**Resolution.** `session-close-check.sh` gains an editor-live **pause-Stop
guard**, placed before the 3-attempt counter and before any cleanup/seal/merge
exit path. On a Stop where the session type is `editor-live` AND the close
sequence has not begun, the hook exits 0 immediately — preserving `.session-id`,
the branch, and the attempt counter, and running no close work.

- **Close-initiated predicate:** `review` is in `phases_completed`, OR
  `current_phase` ∈ {`review`, `verify`, `op-review`, `close`}. This is the same
  predicate `pre-commit-gates.sh` uses to distinguish editor-live loop commits
  from close commits, so close detection is consistent across hooks.
- A real close (operator sent "close session" → agent advanced into
  `review → verify → op-review → close`) satisfies the predicate and falls
  through to the existing, unchanged close sequence.
- Only the `editor-live` session type is affected; all other types are
  untouched.

**Consequences (Amendment 1):**
- `.claude/hooks/session-close-check.sh` updated: editor-live pause-Stop guard
  added before the 3-attempt counter guard; new telemetry reason
  `editor_live_pause`.
- No new state files, no new hooks. Identity is preserved by *not* running
  cleanup on a pause — the cheapest correct fix without requiring the operator
  to set `REPO_OS_SESSION_ID` or run under worktree isolation.
- The reported fast-forward-only merge stranding (non-worktree solo merge) was
  already resolved independently — both merge paths fall back to `--no-ff` when
  `--ff-only` fails. With pause Stops no longer merging mid-session, the close
  merge runs once, where the `--no-ff` fallback handles a non-ancestor `main`.


## Amendment 2 — Durable Monotonic Counter

**Status:** Accepted

Decision 0023 § 2 and the editor-live appendix promise that `live-editor-N`
numbering is *monotonic across the repo lifetime* and *never resets*. The
original implementation (`next-live-editor-branch.sh`) derived the next number
solely by scanning live git refs (`git branch -a` for the highest
`live-editor-N`). That guarantee was therefore only as durable as the branches
themselves: once an editor-live session closed and its branch was deleted (the
normal end state), the scan lost the evidence and the counter reset toward `1`.
The closed-branches isolation ledger (Decision 0013) could not stand in for the
scan — it is gitignored (`.claude/local/`, dies on fresh clone) and historically
carried **zero** `live-editor-N` entries.

**Resolution — tracked high-water-mark.** A new tracked file
`.claude/live-editor-hwm` (a single integer, committed to `main`, deliberately
*outside* the gitignored `.claude/local/`) is the authoritative monotonic floor.
It survives branch deletion and fresh clones because it is part of the committed
tree on `main`.

- **Numbering** (`next-live-editor-branch.sh`):
  `NEXT_N = max(read_hwm, live-ref scan) + 1`. The live-ref scan is retained as a
  belt-and-suspenders backstop, but the HWM file is the source of truth. The
  read/compute/increment/create window is serialized with an `flock` guard
  (mirroring `record_closed_branch` in `_cleanup-helper.sh`). On a successful
  `git checkout -b live-editor-$NEXT_N`, the helper writes `NEXT_N` back to the
  HWM file and commits it **on the new branch**. On a checkout collision (race),
  it re-reads the HWM and retries once, so a number is never re-issued — a *gap*
  is acceptable, a *reset or duplicate* is not.
- **Bootstrap.** The HWM was seeded to `25` (operator-confirmed, above the
  historical ceiling) so the first post-fix session does not restart at `1`. The
  historical maximum was unrecoverable from refs/reflog/ledger (only test
  fixtures remained), so the seed was confirmed with the operator per the brief.
- **Redefined close.** Editor-live close persists the counter to `main` and
  seals the branch: the HWM commit (made on the `live-editor-N` branch at
  creation) rides the close-time solo-merge to `main`; the branch is recorded in
  the closed-branches ledger via the existing agent-merge / solo-merge paths;
  and the now-redundant `live-editor-N` ref is deleted by the new editor-live
  scoped `delete_merged_editor_live_branch` helper (`git branch -d`, merged-only,
  safe). **REQUIRE:** the editor-live close sequence must call
  `write_merge_signal "<live-editor-N>"` after merging to main — otherwise the
  Stop hook fires while `HEAD` is on `main`, where `record_closed_branch` skips
  `main` and the branch would never be sealed. This REQUIRE is now **backstopped
  by a hook-side fallback** (`seal_orphaned_editor_live_branches`): on an
  editor-live close where the branch is still unsealed and no merge signal was
  recorded, `session-close-check.sh` scans `git branch --merged main` for
  `live-editor-N` refs and seals + deletes each, so a forgotten
  `write_merge_signal` no longer strands the branch. Fresh clones read the
  committed HWM on `main` as the floor.

**Consequences (Amendment 2):**
- `.claude/live-editor-hwm` added (tracked) — authoritative monotonic floor.
- `.claude/hooks/next-live-editor-branch.sh` rewritten: HWM-aware numbering,
  `flock` guard, write-back + commit on branch, collision re-read/retry.
- `.claude/hooks/_cleanup-helper.sh`: new `delete_merged_editor_live_branch`
  helper (editor-live-scoped). `record_closed_branch`'s shared contract (used by
  feature/fix/hotfix/taskgroup branches) is **unchanged**.
- `.claude/hooks/session-close-check.sh`: deletes the merged `live-editor-N`
  branch after seal in the agent-merge and solo-merge paths (editor-live-scoped;
  no behavior change for other branch types). Adds a `seal_orphaned_editor_live_branches`
  fallback (in `_cleanup-helper.sh`) invoked on an editor-live close when the
  branch is still unsealed and no merge signal was recorded — backstops a
  forgotten `write_merge_signal`. `record_closed_branch` is **called, not
  modified**.
- The gitignored `closed-branches` ledger and its guard consumers
  (`bash-guard.sh`, `write-guard.sh`, `_phase-helper.sh` mtime cache) are
  untouched — additive design, no isolation-ledger migration (Decision 0013
  preserved).
- New/updated hook tests cover cold-start, HWM floor, reset-prevention after
  branch deletion, fresh-clone durability, scan backstop, and collision retry.
