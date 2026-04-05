---
title: "Integrations & External Services"
scope_modules: []
keywords: []
spec_type: core
---

# Integrations & External Services

## Third-Party Services
<!-- One section per service. -->

### [Service Name]

- **Purpose**: [Why this service is used]
- **Auth method**: [API key / OAuth / JWT / etc.]
- **Key operations**: [What we use from this service]
- **Failure handling**: [What happens if this service is unavailable]

---

## MCP Connections

### Figma MCP (if applicable)

- **Figma file URL**: [URL]
- **MCP server**: [figma-context-mcp / official Figma MCP]
- **What to extract**: [Design tokens / component specs / screen layouts]

### [Other MCP Server] (if applicable)

- **Purpose**: [What it provides]
- **Server**: [Name / URL]

### Visual Bridge MCP (if applicable)

<!-- Optional: Enable visual editing in the browser with deterministic source mapping. -->

- **Purpose**: Visual editing of live front-end UI → structured diffs to Claude Code
- **Server**: `@visual-bridge/mcp-server` (npm, via `npx`)
- **Requires**: `@visual-bridge/dev-plugin` as devDependency + Chrome extension installed
- **What it provides**: `get_pending_visual_changes`, `get_design_tokens`, `resolve_to_token` MCP tools

---

## Environment Variables
<!-- List all required env vars. Do NOT include actual values or secrets. -->

| Variable | Purpose | Required |
|----------|---------|----------|
| [VAR_NAME] | [What it's for] | yes / no |
