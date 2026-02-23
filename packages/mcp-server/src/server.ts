import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { Bridge } from './bridge.js';
import {
  discoverTokens,
  watchTokenSources,
  resolveToToken,
  parseTokenSource,
} from './tokens.js';

/**
 * Create and start the MCP server with WebSocket bridge.
 */
export async function createServer(): Promise<void> {
  const cwd = process.cwd();
  const bridge = new Bridge(cwd);

  // 1. Start WebSocket server (port fallback 7890–7899)
  const port = await bridge.start();

  // 2. Discover and parse design tokens
  const { tokens, sources, discovered } = await discoverTokens(cwd);
  bridge.setTokenRegistry(tokens, sources);

  // 3. Start file watchers for ALL discovered token sources
  //    (including error-status sources, so a fix-and-save triggers re-parse)
  const watcher = watchTokenSources(discovered, async (file, type) => {
    const result = await parseTokenSource(file, type);
    bridge.updateTokens(file, result.tokens, result.status);
  });

  // 4. Create MCP server
  const server = new McpServer({
    name: 'frontend-editor',
    version: '0.1.0',
  });

  // 5. Register all tools
  registerTools(server, bridge);

  // 6. Connect stdio transport
  const transport = new StdioServerTransport();
  await server.connect(transport);

  console.error(`[frontend-editor] MCP server running (WebSocket port: ${port})`);

  // Graceful shutdown
  const shutdown = async () => {
    await watcher.close();
    await bridge.stop();
    process.exit(0);
  };

  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

// ---------------------------------------------------------------------------
// Tool registration
// ---------------------------------------------------------------------------

function registerTools(server: McpServer, bridge: Bridge): void {
  // 1. get_pending_visual_changes
  server.registerTool(
    'get_pending_visual_changes',
    {
      title: 'Get Pending Visual Changes',
      description:
        'Returns all visual diffs and operator notes queued by the Chrome extension. ' +
        'Diffs may include CSS property changes (in `changes`), element reorder operations ' +
        '(in `reorderChanges`), and/or element insertion operations (in `insertChanges`). ' +
        'When `reorderChanges` is present with empty `changes`, the intent is ' +
        'to physically reorder children in the source file at `element.sourceFile:element.sourceLine`, ' +
        'not to add a CSS `order` property. Each reorder change includes fromIndex, toIndex, ' +
        'siblingSelectors (original child order), containerSelector, and containerDirection. ' +
        'When `insertChanges` is present, the intent is to create a new element in the source file. ' +
        'Each insert change includes tagName, insertIndex, containerSelector, and a sibling bracket ' +
        '(prevSibling/nextSibling with sourceFile+sourceLine) indicating the exact JSX insertion point. ' +
        'sameSiblingSource=true means siblings share a .map() call; crossFileInsertion=true means the ' +
        'container and siblings are from different source files. ' +
        'When `groupChanges` is present, the intent is to wrap the elements identified by ' +
        '`wrappedSelectors` in a new wrapper element at the specified position in the container. ' +
        'Each group change includes wrapperTagName, wrapperInitialStyles (display:flex etc.), ' +
        'containerSelector, insertIndex, wrappedSelectors[], and a sibling bracket ' +
        '(prevSibling/nextSibling) indicating the JSX insertion point for the wrapper. ' +
        'Optionally filter by tab session ID.',
      inputSchema: z.object({
        tabId: z
          .string()
          .optional()
          .describe('Optional tab session ID to filter by'),
      }),
    },
    async ({ tabId }) => {
      bridge.recordToolCall();
      const { diffs, notes } = bridge.getPendingChanges(tabId);
      return {
        content: [{ type: 'text' as const, text: JSON.stringify({ changes: diffs, notes }, null, 2) }],
      };
    },
  );

  // 2. acknowledge_visual_change
  server.registerTool(
    'acknowledge_visual_change',
    {
      title: 'Acknowledge Visual Change',
      description:
        'Marks a visual diff as applied and removes it from the pending queue.',
      inputSchema: z.object({
        diffId: z.string().describe('The unique ID of the diff to acknowledge'),
      }),
    },
    async ({ diffId }) => {
      bridge.recordToolCall();
      const success = bridge.acknowledgeDiff(diffId);
      return {
        content: [{ type: 'text' as const, text: JSON.stringify({ success }) }],
      };
    },
  );

  // 3. reject_visual_change
  server.registerTool(
    'reject_visual_change',
    {
      title: 'Reject Visual Change',
      description:
        'Marks a visual diff as rejected and removes it from the pending queue.',
      inputSchema: z.object({
        diffId: z.string().describe('The unique ID of the diff to reject'),
        reason: z.string().describe('Reason for rejecting the change'),
      }),
    },
    async ({ diffId, reason }) => {
      bridge.recordToolCall();
      const success = bridge.rejectDiff(diffId, reason);
      return {
        content: [{ type: 'text' as const, text: JSON.stringify({ success }) }],
      };
    },
  );

  // 4. clear_notes
  server.registerTool(
    'clear_notes',
    {
      title: 'Clear Operator Notes',
      description:
        'Clears all pending operator notes after they have been read and processed.',
      inputSchema: z.object({}),
    },
    async () => {
      bridge.recordToolCall();
      const cleared = bridge.clearNotes();
      return {
        content: [{ type: 'text' as const, text: JSON.stringify({ cleared }) }],
      };
    },
  );

  // 5. get_design_tokens
  server.registerTool(
    'get_design_tokens',
    {
      title: 'Get Design Tokens',
      description:
        "Returns the project's parsed design tokens. Optionally filter by category (spacing, typography, colors, radii, shadows, breakpoints).",
      inputSchema: z.object({
        category: z
          .string()
          .optional()
          .describe('Token category to filter by'),
      }),
    },
    async ({ category }) => {
      bridge.recordToolCall();
      const result = bridge.getTokens(category);
      return {
        content: [{ type: 'text' as const, text: JSON.stringify(result, null, 2) }],
      };
    },
  );

  // 5. resolve_to_token
  server.registerTool(
    'resolve_to_token',
    {
      title: 'Resolve to Token',
      description:
        'Maps a CSS value to the nearest design token for a given property.',
      inputSchema: z.object({
        property: z
          .string()
          .describe('CSS property name (e.g., "font-size", "color")'),
        value: z
          .string()
          .describe('CSS value to resolve (e.g., "16px", "#3b82f6")'),
      }),
    },
    async ({ property, value }) => {
      bridge.recordToolCall();
      const allTokens = bridge.getAllTokensFlat();
      const result = resolveToToken(property, value, allTokens);
      return {
        content: [{ type: 'text' as const, text: JSON.stringify(result) }],
      };
    },
  );

  // 6. get_token_drift_report
  server.registerTool(
    'get_token_drift_report',
    {
      title: 'Get Token Drift Report',
      description:
        'Returns a session-scoped report of custom value usage — values that did not match any design token.',
      inputSchema: z.object({}),
    },
    async () => {
      bridge.recordToolCall();
      const report = bridge.getDriftReport();
      return {
        content: [{ type: 'text' as const, text: JSON.stringify(report, null, 2) }],
      };
    },
  );

  // 7. export_session
  server.registerTool(
    'export_session',
    {
      title: 'Export Session',
      description:
        'Exports the pending queue to a JSON file for archival or handoff.',
      inputSchema: z.object({
        outputPath: z
          .string()
          .optional()
          .describe(
            'Output file path (defaults to .frontend-editor/session-export.json)',
          ),
      }),
    },
    async ({ outputPath }) => {
      bridge.recordToolCall();
      const result = await bridge.exportSession(outputPath);
      return {
        content: [{ type: 'text' as const, text: JSON.stringify(result) }],
      };
    },
  );

  // 8. import_session
  server.registerTool(
    'import_session',
    {
      title: 'Import Session',
      description:
        'Loads a previously exported session file into the pending queue.',
      inputSchema: z.object({
        inputPath: z
          .string()
          .describe('Path to the session export JSON file'),
      }),
    },
    async ({ inputPath }) => {
      bridge.recordToolCall();
      const result = await bridge.importSession(inputPath);
      return {
        content: [{ type: 'text' as const, text: JSON.stringify(result) }],
      };
    },
  );
}

