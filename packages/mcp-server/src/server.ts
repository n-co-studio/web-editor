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
import {
  discoverComponents,
  parseComponentFile,
  watchComponentSources,
} from './components.js';

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

  // 4. Discover and parse project-local React components, then start watcher
  const componentResult = await discoverComponents(cwd);
  bridge.setComponentRegistry(componentResult.components, componentResult.statuses);
  const componentWatcher = watchComponentSources(cwd, componentResult.roots, async (event) => {
    if (event.kind === 'unlink') {
      bridge.updateComponents(event.file, [], null);
      return;
    }
    const result = await parseComponentFile(cwd, event.file);
    bridge.updateComponents(event.file, result.components, result.status);
  });

  // 5. Create MCP server
  const server = new McpServer({
    name: 'nco-web-editor',
    version: '0.1.0',
  });

  // 6. Register all tools
  registerTools(server, bridge);

  // 7. Connect stdio transport
  const transport = new StdioServerTransport();
  await server.connect(transport);

  console.error(`[nco-web-editor] MCP server running (WebSocket port: ${port})`);

  // Graceful shutdown
  const shutdown = async () => {
    await bridge.writeShutdownStatus();
    await watcher.close();
    await componentWatcher.close();
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
        'Each PropertyChange in `changes` may carry a `source` field identifying the existing ' +
        'CSS rule that currently owns the property — including its selector, sourceHref ' +
        '(stylesheet URL), specificity, and any enclosing @media / @layer scope. When `source` ' +
        'is present, edit the existing declaration in-place inside its original scope (preserve ' +
        'the @media / @layer wrapper) — do NOT append a new override declaration, which would ' +
        'produce redundant CSS and shadow the responsive rule. When `source` is absent, the ' +
        'property has no current rule and a new declaration should be written at an appropriate ' +
        'site (typically the file in `element.sourceFile`). The diff `context.breakpoint` and ' +
        '`context.viewport` indicate which breakpoint was active when the edit was made; if the ' +
        '`source.mediaQuery` matches that breakpoint, the edit is breakpoint-scoped; if ' +
        '`source` is absent at a non-default breakpoint, consider whether the new declaration ' +
        'should be wrapped in an @media block matching `context.breakpointValue`. ' +
        'When `reorderChanges` is present with empty `changes`, the intent is ' +
        'to physically reorder children in the source file at `element.sourceFile:element.sourceLine`, ' +
        'not to add a CSS `order` property. Each reorder change includes fromIndex, toIndex, ' +
        'siblingSelectors (original child order), containerSelector, and containerDirection. ' +
        'When `insertChanges` is present, the intent is to create a new element in the source file. ' +
        'Each insert change includes tagName, insertIndex, containerSelector, and a sibling bracket ' +
        '(prevSibling/nextSibling with sourceFile+sourceLine) indicating the exact JSX insertion point. ' +
        'sameSiblingSource=true means siblings share a .map() call; crossFileInsertion=true means the ' +
        'container and siblings are from different source files. ' +
        'When `removeChanges` is present, the intent is to delete the element from the source file at ' +
        '`element.sourceFile:element.sourceLine` — physically remove the JSX node, not hide it via CSS ' +
        '(do not add `display: none` or any visibility style). Each remove change includes tagName, ' +
        'containerSelector, and removedIndex (the original position within the container). ' +
        'When `groupChanges` is present, the intent is to wrap the elements identified by ' +
        '`wrappedSelectors` in a new wrapper element at the specified position in the container. ' +
        'Each group change includes wrapperTagName, wrapperInitialStyles (display:flex etc.), ' +
        'containerSelector, insertIndex, wrappedSelectors[], and a sibling bracket ' +
        '(prevSibling/nextSibling) indicating the JSX insertion point for the wrapper. ' +
        'When `attributeChanges` is present, the intent is to modify HTML attributes ' +
        '(e.g. src, alt) on the element. Each attribute change includes attribute name, ' +
        'fromValue, and toValue. When the user selects an image via the file picker, ' +
        'the server automatically saves it to the project (in the same directory as the ' +
        'original image, or public/images/ as fallback) and the toValue will be a ' +
        'project-relative file path (e.g. /public/images/uploaded-xyz.png). ' +
        'Update the source code to reference this path. ' +
        'Each PropertyChange may also carry an `allBreakpointSources` array of ' +
        'rules that define the same property at OTHER viewport breakpoints — ' +
        'rules collected by walking @media bodies regardless of whether they ' +
        'match the current viewport. Each entry carries the same fields as ' +
        '`source` plus `matchesCurrentViewport: boolean` to distinguish the ' +
        'active subset (true) from the dormant subset (false). The cascade ' +
        'winner already in `source` is excluded so the same rule never appears ' +
        'twice. `allBreakpointSources` is context-only: the active edit applies ' +
        'ONLY to the breakpoint identified by `context.breakpoint` / ' +
        '`context.breakpointValue` and the rule in `source`. Do NOT modify ' +
        "rules listed in `allBreakpointSources` unless the operator's " +
        'instruction explicitly asks for changes at those other breakpoints — ' +
        'they are surfaced so you can reason about responsive variants without ' +
        'switching viewports, not as edit targets. ' +
        'When `stylesheetChanges` is present (feature-009 parallax editor), the diff ' +
        'carries document-level CSS rules that cannot be expressed inline — `@keyframes`, ' +
        '`@supports`, and `@media` blocks. For each StylesheetChange, write every ' +
        '`rules[].cssText` verbatim into the stylesheet that owns the target element ' +
        '(the CSS module / global sheet / styled-block adjacent to `element.sourceFile`), ' +
        'preserving rule order — `@supports` fallbacks and `@media` overrides must follow ' +
        'the base rules they qualify. Dedupe `@keyframes` by `rules[].name` so re-applying ' +
        'an edit does not duplicate the keyframes. Then apply `elementChanges` (animation-name, ' +
        'animation-timeline, etc.) to the element’s existing rule in-place, using each ' +
        'PropertyChange `source` when present (exactly as for ordinary PropertyChanges). ' +
        'Every CSS parallax mechanism (fixed, transform-3d, scroll-driven) emits a ' +
        '`reduced-motion-zeroing` StylesheetChange whose `@media (prefers-reduced-motion: ' +
        'reduce)` rule zeroes the effect (WCAG 2.3.3) — always write it. The js-scroll ' +
        'mechanism emits no such StylesheetChange; its generated handler short-circuits on ' +
        '`matchMedia` instead (see `respectsReducedMotion` below). When `scriptChanges` is ' +
        'present, the diff carries a declarative ' +
        '`ScriptBehaviorChange` (the only one in v1 is `behavior: "parallax-scroll"`); it ' +
        'does NOT contain literal JS. Author an idempotent scroll handler from `descriptor` + ' +
        '`params` in the module that owns `sourceFile` (e.g. a `useEffect` keyed by ' +
        '`targetSelector`). The handler MUST batch updates with `requestAnimationFrame` ' +
        '(`params.throttle: "raf"`) and MUST short-circuit when ' +
        "`matchMedia('(prefers-reduced-motion: reduce)').matches` (`respectsReducedMotion`); " +
        're-application replaces the prior handler rather than stacking listeners. ' +
        'CRITICAL: attach the scroll listener to `params.scrollSource` — `"window"` for ' +
        'page/viewport scroll, otherwise the CSS selector of the scroll container (an inner ' +
        'overlay or `<main>` that scrolls while `body` does not). Do NOT assume `window`; a ' +
        'window listener never fires for a nested scroll container, so the effect would be dead. ' +
        'Compute the offset from that source’s scroll position. The pure-CSS `scroll-driven` ' +
        'mechanism encodes the same choice in its `animation-timeline` (`scroll(root)` for the ' +
        'page vs `scroll()` for the nearest container) inside the StylesheetChange. Reject any ' +
        '`behavior` value other than `"parallax-scroll"`. ' +
        'Optionally filter by tab session ID. ' +
        'The `batches` index groups pending diffs by logical Apply-Changes click: ' +
        '`[{ batchId, batchNote?, createdAt, diffCount }]`, newest-first. ' +
        'Diffs without a `batchId` (legacy) are omitted from `batches` but appear in `changes`. ' +
        'Pass `batchId` to filter `changes` to a single batch. ' +
        'Use `get_queue_status.latest_batch_id` to identify the most recently submitted batch.',
      inputSchema: z.object({
        tabId: z
          .string()
          .optional()
          .describe('Optional tab session ID to filter by'),
        batchId: z
          .string()
          .optional()
          .describe('Optional batch ID to filter changes to a single batch'),
      }),
    },
    async ({ tabId, batchId }) => {
      bridge.recordToolCall();
      const { diffs, notes, batches } = bridge.getPendingChanges(tabId, batchId);
      return {
        content: [{ type: 'text' as const, text: JSON.stringify({ changes: diffs, notes, batches }, null, 2) }],
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
            'Output file path (defaults to .nco-web-editor/session-export.json)',
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

  // 8. get_queue_status
  server.registerTool(
    'get_queue_status',
    {
      title: 'Get Queue Status',
      description:
        'Returns lightweight queue status: active/closed, pending count, last update timestamp, ' +
        'and `latest_batch_id` (the batchId of the most recently ingested batch — absent until ' +
        'the first batch arrives). Use this instead of get_pending_visual_changes when you only ' +
        'need to check whether diffs are waiting or to identify the most recent batch.',
      inputSchema: z.object({}),
    },
    async () => {
      bridge.recordToolCall();
      const status = bridge.getQueueStatus();
      return {
        content: [{ type: 'text' as const, text: JSON.stringify(status) }],
      };
    },
  );

  // 9. import_session
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

  // 10. get_project_components
  server.registerTool(
    'get_project_components',
    {
      title: 'Get Project Components',
      description:
        "Returns the project's discovered local React components (JSX/TSX) — " +
        'each entry includes componentName, workspace-relative importPath, ' +
        'exportType (named or default), and props ([] in v1; prop schema is ' +
        'reserved for v1.1). Components are discovered from convention-gated ' +
        'roots (src/components, src/ui, components — overridable via ' +
        'nco-web-editor.componentRoots in the target project package.json). ' +
        'Optionally filter by a case-insensitive substring of componentName. ' +
        'Used to resolve InsertChange.componentInsert descriptors emitted by ' +
        'the extension into source-level JSX usages + imports.',
      inputSchema: z.object({
        nameFilter: z
          .string()
          .optional()
          .describe('Case-insensitive substring filter on componentName'),
      }),
    },
    async ({ nameFilter }) => {
      bridge.recordToolCall();
      const result = bridge.getComponents(nameFilter);
      return {
        content: [{ type: 'text' as const, text: JSON.stringify(result, null, 2) }],
      };
    },
  );
}

