# Session Type: Editor Live

Continuous visual-development session type for operator-driven editing workflows (Decision 0023). The operator edits files in an external editor and the agent responds to each saved change. Child mode only.

- **Phase sequence**: `init → build → commit → review → verify → op-review → close`
- **Loops**: `commit→build` (next change iteration), `verify→build` (QA failure)
- **No plan gate**: The operator's live edits are the plan. `has_plan_gate("editor-live")` returns false
- **Gate profile**: A4 safety per-loop commit; full gates (minus `plan-approved`) at close when `review` is in `phases_completed`
- **Signal mechanism**: Tracked status file + filesystem watcher (`.claude/hooks/editor-watch.sh`). The MCP server writes change records when the operator saves. The agent polls via `get_pending_visual_changes` MCP tool
- **Watcher**: `fswatch` (preferred, macOS + Linux) or `inotifywait` (Linux fallback). 5-minute timeout per watch cycle. When neither is available, falls back to operator message trigger
- **Close signal**: Structural keyword "close session" (Decision 0004 mechanical enforcement). When detected, agent advances through review → verify → op-review → close
- **MCP tools**: `get_pending_visual_changes`, `acknowledge_visual_change`, optionally `get_design_tokens` and `resolve_to_token`
- **Commit convention**: `feat: <description> (editor-live cycle N)` — each commit carries the cycle number
- **Cycle advisory**: At 50 iterations, agent emits advisory suggesting close. Advisory only — operator may continue
- **Cross-platform**: `fswatch` available via Homebrew (macOS) or package manager (Linux). `inotifywait` from `inotify-tools` (Linux). Pre-flight check at init warns when neither is installed

See `docs/ai/prompts/prompt-e-editor-live.md` for the full prompt definition.
