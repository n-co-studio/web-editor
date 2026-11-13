import { PACKAGE_VERSION } from '../version.js';

const HELP_TEXT = `
nco-web-editor-mcp — MCP server bridge for AI Agent Visual Editor

USAGE
  npx --yes @nco-studio/web-editor-mcp@^0   (add to .mcp.json)
  nco-web-editor-mcp                         (after global install)
  nco-web-editor-mcp --version
  nco-web-editor-mcp --help

CLAUDE CODE CONFIG SNIPPET
  Add this to .mcp.json at your project root:

  {
    "mcpServers": {
      "nco-web-editor": {
        "command": "npx",
        "args": ["--yes", "@nco-studio/web-editor-mcp@^0"]
      }
    }
  }

  Tip: For faster startup (avoids npx registry check), install globally:
    npm install -g @nco-studio/web-editor-mcp
  Then use:
    { "command": "nco-web-editor-mcp", "args": [] }

ENVIRONMENT VARIABLES
  NCO_WEB_EDITOR_PORT   WebSocket port (default: 7890; tries 7890-7899)

MCP TOOLS EXPOSED TO CLAUDE CODE
  get_pending_visual_changes   Return queued visual diffs from the extension
  acknowledge_visual_change    Mark a diff as applied and remove from queue
  reject_visual_change         Reject a diff and remove it from the queue
  get_design_tokens            Return parsed design tokens from project files
  resolve_to_token             Map a CSS value to the nearest design token
  get_token_drift_report       Report design token drift across pending diffs
  export_session               Export session state (queue + tokens) to a file
  import_session               Restore session state from an exported file
  get_project_components       Return the project-local React component registry

PERSISTENCE
  Pending queue: .nco-web-editor/pending-queue.json
  Add .nco-web-editor/ to your project .gitignore

SECURITY
  All traffic is localhost-only. No telemetry. No accounts.
  Token discovery evaluates tailwind.config.* via esbuild - runs in the
  project trust context. See SECURITY.md in the source repository.
`.trimStart();

const args = process.argv.slice(2);

if (args.includes('--version') || args.includes('-v')) {
  process.stdout.write(PACKAGE_VERSION + '\n');
  process.exit(0);
}

if (args.includes('--help') || args.includes('-h')) {
  process.stdout.write(HELP_TEXT);
  process.exit(0);
}

// Early startup banner on stderr so MCP hosts see stdio activity within
// the first ~100 ms and do not time out the process during async init.
process.stderr.write(`[nco-web-editor] MCP server starting (v${PACKAGE_VERSION})...\n`);

import('../server.js').then(({ createServer }) => {
  return createServer();
}).catch((error: unknown) => {
  process.stderr.write(`[nco-web-editor] Fatal error: ${String(error)}\n`);
  process.exit(1);
});
