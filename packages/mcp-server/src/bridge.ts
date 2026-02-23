import { WebSocketServer, type WebSocket } from 'ws';
import { readFile, writeFile, unlink, mkdir } from 'node:fs/promises';
import { join, dirname, resolve, relative } from 'node:path';
import {
  PROTOCOL_VERSION,
  MessageType,
} from '@frontend-editor/shared';
import type {
  VisualDiff,
  VisualDiffBatchPayload,
  DesignToken,
  TokenSourceStatus,
  ExtensionToServerMessage,
  ServerToExtensionMessage,
} from '@frontend-editor/shared';
import { resolveToToken } from './tokens.js';
import type { ConnectedClient, PendingNote, PersistedQueue, SessionExport, DriftEntry } from './types.js';

const PERSIST_DIR = '.frontend-editor';
const PERSIST_FILE = 'pending-queue.json';

export class Bridge {
  private wss: WebSocketServer | null = null;
  private readonly clients = new Map<string, ConnectedClient>();
  private pendingQueue: VisualDiff[] = [];
  private pendingNotes: PendingNote[] = [];
  /** Tombstone set — IDs of diffs that were acknowledged or rejected.
   *  Prevents re-ingestion after extension reconnect. Session-scoped. */
  private readonly processedIds = new Set<string>();
  private tokenRegistry = new Map<string, DesignToken[]>();
  private tokenSources: TokenSourceStatus[] = [];
  private readonly driftMap = new Map<string, DriftEntry>();
  private driftTotalEdits = 0;
  private driftTokenMatches = 0;
  private lastToolCallAt: string | null = null;
  private readonly persistPath: string;

  constructor(private readonly cwd: string) {
    this.persistPath = join(cwd, PERSIST_DIR, PERSIST_FILE);
  }

  /** Record that an MCP tool was called (updates lastToolCallAt for STATUS_RESPONSE). */
  recordToolCall(): void {
    this.lastToolCallAt = new Date().toISOString();
  }

  // -----------------------------------------------------------------------
  // Lifecycle
  // -----------------------------------------------------------------------

  /** Start the WebSocket server. Tries ports from base to base+9. */
  async start(): Promise<number> {
    const basePort = parseInt(process.env.FRONTEND_EDITOR_PORT ?? '7890', 10);

    for (let port = basePort; port < basePort + 10; port++) {
      const bound = await this.tryPort(port);
      if (bound) {
        await this.restoreQueue();
        console.error(`[frontend-editor] WebSocket server listening on port ${port}`);
        return port;
      }
    }

    throw new Error(
      `Could not bind to any port in range ${basePort}–${basePort + 9}`,
    );
  }

  /** Stop the WebSocket server. */
  async stop(): Promise<void> {
    if (this.wss) {
      for (const client of this.clients.values()) {
        client.ws.close();
      }
      this.clients.clear();
      await new Promise<void>((resolve) => {
        this.wss!.close(() => resolve());
      });
      this.wss = null;
    }
  }

  // -----------------------------------------------------------------------
  // Pending queue operations (called by MCP tools)
  // -----------------------------------------------------------------------

  /** Get all pending diffs and notes, optionally filtered by tabId. */
  getPendingChanges(tabId?: string): { diffs: VisualDiff[]; notes: PendingNote[] } {
    const diffs = tabId
      ? this.pendingQueue.filter((d) => d.context.tabId === tabId)
      : [...this.pendingQueue];
    return { diffs, notes: [...this.pendingNotes] };
  }

  /** Acknowledge a diff — remove from queue, add to tombstone, notify extension, persist. */
  acknowledgeDiff(diffId: string): boolean {
    const idx = this.pendingQueue.findIndex((d) => d.id === diffId);
    if (idx === -1) return false;

    const diff = this.pendingQueue[idx];
    this.pendingQueue.splice(idx, 1);
    this.processedIds.add(diffId);
    this.safePersistQueue();

    // Push DIFF_APPLIED to the originating extension tab (best-effort)
    this.pushDiffApplied(diff.context.tabId, [diffId]);

    return true;
  }

  /** Clear all pending notes. Called after Claude Code has read them. */
  clearNotes(): number {
    const count = this.pendingNotes.length;
    this.pendingNotes = [];
    this.safePersistQueue();
    return count;
  }

  /** Reject a diff — remove from queue, add to tombstone, notify extension, persist. */
  rejectDiff(diffId: string, reason: string): boolean {
    const idx = this.pendingQueue.findIndex((d) => d.id === diffId);
    if (idx === -1) return false;

    const diff = this.pendingQueue[idx];
    console.error(`[frontend-editor] Diff ${diffId} rejected: ${reason}`);
    this.pendingQueue.splice(idx, 1);
    this.processedIds.add(diffId);
    this.safePersistQueue();

    // Push DIFF_APPLIED to the originating extension tab (best-effort)
    // Uses the same message type — the diff is no longer pending regardless of reason
    this.pushDiffApplied(diff.context.tabId, [diffId]);

    return true;
  }

  // -----------------------------------------------------------------------
  // Token operations
  // -----------------------------------------------------------------------

  /** Set the full token registry (called at startup after discovery). */
  setTokenRegistry(
    tokenMap: Map<string, DesignToken[]>,
    sources: TokenSourceStatus[],
  ): void {
    this.tokenRegistry = tokenMap;
    this.tokenSources = sources;
  }

  /** Update a single token source and broadcast to connected clients. */
  updateTokens(
    sourceFile: string,
    tokens: DesignToken[],
    status: TokenSourceStatus,
  ): void {
    this.tokenRegistry.set(sourceFile, tokens);

    // Update sources array
    const idx = this.tokenSources.findIndex((s) => s.file === status.file);
    if (idx >= 0) {
      this.tokenSources[idx] = status;
    } else {
      this.tokenSources.push(status);
    }

    // Broadcast TOKEN_UPDATE to all connected clients
    this.broadcast({
      type: MessageType.TOKEN_UPDATE,
      version: PROTOCOL_VERSION,
      payload: { tokens, sources: [status] },
    });
  }

  /** Get tokens, optionally filtered by category. */
  getTokens(category?: string): { tokens: DesignToken[]; sources: TokenSourceStatus[] } {
    let tokens = this.getAllTokensFlat();
    if (category) {
      tokens = tokens.filter((t) => t.category === category);
    }
    return { tokens, sources: [...this.tokenSources] };
  }

  /** Get all tokens flattened from the registry. */
  getAllTokensFlat(): DesignToken[] {
    const all: DesignToken[] = [];
    for (const tokens of this.tokenRegistry.values()) {
      all.push(...tokens);
    }
    return all;
  }

  // -----------------------------------------------------------------------
  // Drift tracking
  // -----------------------------------------------------------------------

  /** Get the drift report. */
  getDriftReport(): {
    escapes: DriftEntry[];
    summary: { totalEdits: number; tokenMatches: number; customValues: number };
  } {
    const escapes = Array.from(this.driftMap.values());
    const customValues = escapes.reduce((sum, e) => sum + e.count, 0);
    return {
      escapes,
      summary: {
        totalEdits: this.driftTotalEdits,
        tokenMatches: this.driftTokenMatches,
        customValues,
      },
    };
  }

  // -----------------------------------------------------------------------
  // Session export/import
  // -----------------------------------------------------------------------

  /** Export the pending queue to a file. Path is confined to project directory. */
  async exportSession(outputPath?: string): Promise<{ path: string; diffCount: number }> {
    const outPath = outputPath
      ? this.confineToProject(outputPath)
      : join(this.cwd, PERSIST_DIR, 'session-export.json');

    const data: SessionExport = {
      version: PROTOCOL_VERSION,
      exportedAt: new Date().toISOString(),
      diffs: this.pendingQueue,
    };

    await mkdir(dirname(outPath), { recursive: true });
    await writeFile(outPath, JSON.stringify(data, null, 2));

    return { path: outPath, diffCount: this.pendingQueue.length };
  }

  /** Import a session file into the pending queue. Path is confined to project directory. */
  async importSession(
    inputPath: string,
  ): Promise<{ imported: number; skipped: number; warnings: string[] }> {
    const absPath = this.confineToProject(inputPath);
    const raw = await readFile(absPath, 'utf-8');
    const data: unknown = JSON.parse(raw);

    const warnings: string[] = [];
    let imported = 0;
    let skipped = 0;

    if (typeof data !== 'object' || data === null || !('diffs' in data)) {
      warnings.push('Invalid session file format — missing "diffs" field');
      return { imported, skipped, warnings };
    }

    const session = data as SessionExport;

    if (!Array.isArray(session.diffs)) {
      warnings.push('Invalid session file — "diffs" is not an array');
      return { imported, skipped, warnings };
    }

    const existingIds = new Set(this.pendingQueue.map((d) => d.id));

    for (const diff of session.diffs) {
      // Validate required VisualDiff fields before importing
      if (!isValidDiff(diff)) {
        warnings.push(`Skipped invalid diff entry (missing required fields)`);
        skipped++;
        continue;
      }
      if (existingIds.has(diff.id) || this.processedIds.has(diff.id)) {
        skipped++;
        continue;
      }
      this.pendingQueue.push(diff);
      imported++;
    }

    if (imported > 0) {
      this.safePersistQueue();
    }

    return { imported, skipped, warnings };
  }

  // -----------------------------------------------------------------------
  // WebSocket internals
  // -----------------------------------------------------------------------

  private tryPort(port: number): Promise<boolean> {
    return new Promise((resolve) => {
      const wss = new WebSocketServer({ port });

      wss.on('listening', () => {
        this.wss = wss;
        wss.on('connection', (ws: WebSocket) => this.handleConnection(ws));
        resolve(true);
      });

      wss.on('error', () => {
        wss.close();
        resolve(false);
      });
    });
  }

  private handleConnection(ws: WebSocket): void {
    console.error('[frontend-editor] Extension connected');

    ws.on('message', (data: Buffer) => {
      this.handleMessage(ws, data);
    });

    ws.on('close', () => {
      // Remove client from map
      for (const [tabId, client] of this.clients) {
        if (client.ws === ws) {
          this.clients.delete(tabId);
          console.error(`[frontend-editor] Extension disconnected (tab: ${tabId})`);
          break;
        }
      }
    });

    ws.on('error', (error: Error) => {
      console.error(`[frontend-editor] WebSocket error: ${error.message}`);
    });
  }

  private handleMessage(ws: WebSocket, data: Buffer): void {
    let msg: unknown;
    try {
      msg = JSON.parse(data.toString());
    } catch {
      console.error('[frontend-editor] Invalid WebSocket message — not JSON');
      return;
    }

    // Validate basic message envelope (type + non-null payload)
    if (
      typeof msg !== 'object' || msg === null ||
      !('type' in msg) || !('payload' in msg) ||
      (msg as Record<string, unknown>).payload == null
    ) {
      console.error('[frontend-editor] Invalid WebSocket message — missing type or payload');
      return;
    }

    const typed = msg as ExtensionToServerMessage;

    switch (typed.type) {
      case MessageType.EXTENSION_HELLO:
        this.handleExtensionHello(ws, typed.payload);
        break;

      case MessageType.VISUAL_DIFF_BATCH:
        this.handleDiffBatch(ws, typed.payload);
        break;

      case MessageType.KEEPALIVE:
        // No response needed
        break;

      case MessageType.STATUS_REQUEST:
        this.handleStatusRequest(ws);
        break;

      case MessageType.ERROR:
        console.error(
          `[frontend-editor] Extension error: ${typed.payload.code} — ${typed.payload.message}`,
        );
        break;

      default:
        console.error(`[frontend-editor] Unknown message type: ${(typed as { type: string }).type}`);
    }
  }

  private handleExtensionHello(
    ws: WebSocket,
    payload: { tabId: string; pendingDiffIds: readonly string[] },
  ): void {
    const { tabId } = payload;

    // Register or update client
    this.clients.set(tabId, { ws, tabId });
    console.error(`[frontend-editor] Extension hello from tab: ${tabId}`);

    // Respond with SERVER_HELLO — include both pending and processed IDs
    // so the extension knows which diffs the server has already seen
    const knownDiffIds = [
      ...this.pendingQueue.map((d) => d.id),
      ...this.processedIds,
    ];
    this.send(ws, {
      type: MessageType.SERVER_HELLO,
      version: PROTOCOL_VERSION,
      payload: { knownDiffIds, protocolVersion: PROTOCOL_VERSION },
    });

    // Send full token data
    this.send(ws, {
      type: MessageType.TOKEN_DATA,
      version: PROTOCOL_VERSION,
      payload: {
        tokens: this.getAllTokensFlat(),
        sources: [...this.tokenSources],
      },
    });
  }

  private handleDiffBatch(
    ws: WebSocket,
    payload: VisualDiffBatchPayload,
  ): void {
    const { diffs, batchNote } = payload;
    const existingIds = new Set(this.pendingQueue.map((d) => d.id));
    const newDiffs: VisualDiff[] = [];

    for (const diff of diffs) {
      // Skip diffs that are already pending or were previously processed
      if (existingIds.has(diff.id) || this.processedIds.has(diff.id)) {
        continue;
      }
      this.pendingQueue.push(diff);
      newDiffs.push(diff);
    }

    // Store batch note if provided
    if (batchNote) {
      this.pendingNotes.push({ text: batchNote, receivedAt: new Date().toISOString() });
      console.error(`[frontend-editor] Received batch note (${batchNote.length} chars)`);
    }

    if (newDiffs.length > 0 || batchNote) {
      this.trackDrift(newDiffs);
      this.safePersistQueue();
    }

    // Acknowledge all diff IDs from the batch
    const diffIds = diffs.map((d) => d.id);
    this.send(ws, {
      type: MessageType.DIFF_ACK,
      version: PROTOCOL_VERSION,
      payload: { diffIds },
    });

    console.error(
      `[frontend-editor] Received ${diffs.length} diffs (${newDiffs.length} new, ${diffs.length - newDiffs.length} already known)`,
    );
  }

  private handleStatusRequest(ws: WebSocket): void {
    const perDiff = this.pendingQueue.map((d) => ({
      id: d.id,
      serverStatus: 'pending' as const,
    }));

    this.send(ws, {
      type: MessageType.STATUS_RESPONSE,
      version: PROTOCOL_VERSION,
      payload: {
        pendingCount: this.pendingQueue.length,
        deliveredCount: this.processedIds.size,
        lastToolCallAt: this.lastToolCallAt,
        perDiff,
      },
    });
  }

  /** Push DIFF_APPLIED to the originating tab's WebSocket (best-effort). */
  private pushDiffApplied(tabId: string, diffIds: string[]): void {
    const client = this.clients.get(tabId);
    if (!client) return;
    this.send(client.ws, {
      type: MessageType.DIFF_APPLIED,
      version: PROTOCOL_VERSION,
      payload: { diffIds },
    });
  }

  private trackDrift(diffs: readonly VisualDiff[]): void {
    const allTokens = this.getAllTokensFlat();

    for (const diff of diffs) {
      for (const change of diff.changes) {
        this.driftTotalEdits++;

        if (change.toToken) {
          // Value matched a token at the extension layer
          this.driftTokenMatches++;
        } else {
          // Custom value — track as drift
          const key = `${change.property}::${change.toValue}`;
          const existing = this.driftMap.get(key);

          if (existing) {
            existing.count++;
          } else {
            const resolved = resolveToToken(change.property, change.toValue, allTokens);
            this.driftMap.set(key, {
              property: change.property,
              value: change.toValue,
              count: 1,
              nearestToken: resolved.token,
            });
          }
        }
      }
    }
  }

  private send(ws: WebSocket, msg: ServerToExtensionMessage): void {
    if (ws.readyState === ws.OPEN) {
      ws.send(JSON.stringify(msg));
    }
  }

  private broadcast(msg: ServerToExtensionMessage): void {
    for (const client of this.clients.values()) {
      this.send(client.ws, msg);
    }
  }

  // -----------------------------------------------------------------------
  // Persistence
  // -----------------------------------------------------------------------

  /** Fire-and-forget persistence with error logging (not process-fatal). */
  private safePersistQueue(): void {
    this.persistQueue().catch((error: unknown) => {
      const msg = error instanceof Error ? error.message : String(error);
      console.error(`[frontend-editor] Failed to persist queue: ${msg}`);
    });
  }

  private async persistQueue(): Promise<void> {
    if (this.pendingQueue.length === 0 && this.pendingNotes.length === 0) {
      try {
        await unlink(this.persistPath);
      } catch {
        // Ignore ENOENT
      }
      return;
    }

    const data: PersistedQueue = {
      version: PROTOCOL_VERSION,
      diffs: this.pendingQueue,
      notes: this.pendingNotes.length > 0 ? this.pendingNotes : undefined,
      savedAt: new Date().toISOString(),
    };

    await mkdir(dirname(this.persistPath), { recursive: true });
    await writeFile(this.persistPath, JSON.stringify(data, null, 2));
  }

  private async restoreQueue(): Promise<void> {
    try {
      const raw = await readFile(this.persistPath, 'utf-8');
      const data = JSON.parse(raw) as PersistedQueue;

      if (Array.isArray(data.diffs)) {
        const valid = data.diffs.filter(isValidDiff);
        this.pendingQueue = valid;
        if (valid.length < data.diffs.length) {
          console.error(
            `[frontend-editor] Skipped ${data.diffs.length - valid.length} invalid entries from persisted queue`,
          );
        }
        if (valid.length > 0) {
          console.error(
            `[frontend-editor] Restored ${valid.length} pending diffs from disk`,
          );
        }
      }

      if (Array.isArray(data.notes) && data.notes.length > 0) {
        this.pendingNotes = data.notes.filter(
          (n): n is PendingNote => typeof n === 'object' && n !== null && typeof n.text === 'string',
        );
        if (this.pendingNotes.length > 0) {
          console.error(
            `[frontend-editor] Restored ${this.pendingNotes.length} pending notes from disk`,
          );
        }
      }
    } catch {
      // No persisted queue — start fresh
    }
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  /** Resolve a path and ensure it stays within the project directory. */
  private confineToProject(inputPath: string): string {
    const resolved = resolve(this.cwd, inputPath);
    const rel = relative(this.cwd, resolved);
    if (rel.startsWith('..') || resolve(this.cwd, rel) !== resolved) {
      throw new Error(`Path escapes project directory: ${inputPath}`);
    }
    return resolved;
  }
}

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------

/** Minimal shape check for imported VisualDiff objects. */
function isValidDiff(obj: unknown): obj is VisualDiff {
  if (typeof obj !== 'object' || obj === null) return false;
  const d = obj as Record<string, unknown>;
  return (
    typeof d.id === 'string' &&
    typeof d.timestamp === 'string' &&
    typeof d.element === 'object' && d.element !== null &&
    Array.isArray(d.changes) &&
    typeof d.context === 'object' && d.context !== null &&
    typeof d.status === 'string' &&
    typeof d.sourceVerified === 'boolean'
  );
}
