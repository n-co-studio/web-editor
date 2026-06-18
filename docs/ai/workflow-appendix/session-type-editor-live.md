# Session Type: Editor Live

Continuous visual-development session type for operator-driven editing workflows (Decision 0023). The operator edits files in an external editor and the agent responds to each saved change. Child mode only.

- **Branch naming**: `live-editor-{N}` where N is monotonic across the repo lifetime and **never resets** (Decision 0023 Amendment 2). The authoritative floor is the tracked file `.claude/live-editor-hwm` (a single integer committed to `main`, outside the gitignored `.claude/local/`), so the counter survives branch deletion and fresh clones. `.claude/hooks/next-live-editor-branch.sh` computes `NEXT_N = max(read_hwm, live-ref scan) + 1` under an `flock` guard, creates the branch, then writes `NEXT_N` back to the HWM file and commits it on the new branch (riding the close-time merge to `main`). On a collision it re-reads the HWM and retries once — a gap is acceptable, a reset/duplicate is not. Replaces `feature/<description>` for this session type only
- **Phase sequence**: `init → build → commit → review → verify → op-review → close`
- **Loops**: `commit→build` (next change iteration), `verify→build` (QA failure)
- **No plan gate**: The operator's live edits are the plan. `has_plan_gate("editor-live")` returns false
- **Gate profile**: A4 safety per-loop commit; full gates (minus `plan-approved`) at close when `review` is in `phases_completed`
- **Signal mechanism**: Tracked status file + filesystem watcher (`.claude/hooks/editor-watch.sh`). The MCP server writes change records when the operator saves. The agent polls via `get_pending_visual_changes` MCP tool
- **Watcher**: `fswatch` (preferred, macOS + Linux) or `inotifywait` (Linux fallback). 5-minute timeout per watch cycle. When neither is available, falls back to operator message trigger
- **Close signal**: Structural keyword "close session" (Decision 0004 mechanical enforcement). When detected, agent advances through review → verify → op-review → close
- **Pause vs close Stop** (Decision 0023 Amendment 1): The Stop hook fires on every turn end, but editor-live Stops between cycles (watcher timeout, operator interjection, context-window turnover) are **pauses**, not closes. `session-close-check.sh` detects a pause — session type `editor-live` AND the close sequence not yet begun (`review` not in `phases_completed` and `current_phase` not in review/verify/op-review/close) — and exits early without running cleanup, branch seal, or solo merge. This preserves `.claude/.session-id` (so the session identity, per-session state dir, log filename, and cycle counter stay stable across pauses) and avoids merging mid-session cycle commits to main. The full close sequence runs only once "close session" has advanced the agent into the close phases
- **Close (durable counter, Decision 0023 Amendment 2)**: at close, after merging the `live-editor-N` branch to `main`, the agent calls `write_merge_signal "<live-editor-N>"` so `session-close-check.sh` records the branch in the closed-branches ledger (the Stop hook otherwise fires on `main`, where `record_closed_branch` skips `main`). The HWM commit rides the merge onto `main`, and the merged `live-editor-N` ref is then deleted (`delete_merged_editor_live_branch`, `git branch -d`, merged-only). This is the mechanism that makes the counter durable across branch deletion and fresh clones
- **MCP tools**: `get_pending_visual_changes`, `acknowledge_visual_change`, optionally `get_design_tokens` and `resolve_to_token`
- **Commit convention**: `feat: <description> (editor-live cycle N)` — each commit carries the cycle number
- **Cycle advisory**: At 50 iterations, agent emits advisory suggesting close. Advisory only — operator may continue
- **Cross-platform**: `fswatch` available via Homebrew (macOS) or package manager (Linux). `inotifywait` from `inotify-tools` (Linux). Pre-flight check at init warns when neither is installed

See `docs/ai/prompts/prompt-e-editor-live.md` for the full prompt definition.
