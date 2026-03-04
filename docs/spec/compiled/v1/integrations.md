# Integrations & External Services

## Third-Party Services

None. Frontend Editor - Repo OS is fully local with no external service dependencies.

---

## MCP Connections

### Frontend Editor MCP Server (this project)

- **Purpose**: Bridge between Chrome extension and Claude Code — receives visual diffs from the extension and exposes them as MCP tools
- **Server**: `@frontend-editor/mcp-server` (npm package)
- **Configuration in target project's `.claude/settings.json`**:
```json
{
  "mcpServers": {
    "frontend-editor": {
      "command": "npx",
      "args": ["--yes", "@frontend-editor/mcp-server"]
    }
  }
}
```
Alternative for faster startup: `npm install -g @frontend-editor/mcp-server` then use `"command": "frontend-editor-mcp"` (avoids npx registry check on each launch).
- **What it provides**: `get_pending_visual_changes`, `acknowledge_visual_change`, `reject_visual_change`, `get_queue_status`, `get_design_tokens`, `resolve_to_token`, `get_token_drift_report`, `export_session`, `import_session` MCP tools
- **Requires**: `@frontend-editor/dev-plugin` as devDependency in the target project + Chrome extension installed
- **Relationship**: Companion tool to the repo-OS template — designed to work with any repo-OS project that has a front-end UI

---

## Environment Variables

| Variable | Purpose | Required |
|----------|---------|----------|
| FRONTEND_EDITOR_PORT | WebSocket port for extension connection | no (default: 7890) |
| VISUAL_BRIDGE_STATUS_FILE | Path to queue status file for fswatch-based idle listening | no (default: `editor-queue-status.yaml` in project root) |
