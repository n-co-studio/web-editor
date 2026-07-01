import { WebSocketServer, type WebSocket } from 'ws';
import { readFile, writeFile, unlink, mkdir, rename, stat, readdir } from 'node:fs/promises';
import { join, dirname, resolve, relative, extname } from 'node:path';
import { createHash } from 'node:crypto';
import {
  PROTOCOL_VERSION,
  MessageType,
} from '@nco-studio/shared';
import type {
  VisualDiff,
  AttributeChange,
  PendingUpload,
  InsertChange,
  PropertyChange,
  VisualDiffBatchPayload,
  DesignToken,
  TokenSourceStatus,
  ProjectComponent,
  ComponentSourceStatus,
  ExtensionToServerMessage,
  ServerToExtensionMessage,
} from '@nco-studio/shared';
import { resolveToToken } from './tokens.js';
import type { ConnectedClient, PendingNote, PersistedQueue, SessionExport, DriftEntry, BatchSummary } from './types.js';

const PERSIST_DIR = '.nco-web-editor';
const PERSIST_FILE = 'pending-queue.json';
const LOCK_FILE = 'server.lock';

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
  private componentRegistry = new Map<string, ProjectComponent[]>();
  private componentSources: ComponentSourceStatus[] = [];
  private readonly driftMap = new Map<string, DriftEntry>();
  private driftTotalEdits = 0;
  private driftTokenMatches = 0;
  private lastToolCallAt: string | null = null;
  /** The batchId of the most recently ingested batch. Absent until first batch arrives. */
  private latestBatchId: string | null = null;
  private readonly persistPath: string;
  private readonly statusFilePath: string;
  private readonly lockPath: string;
  private lastStatusUpdate: string = new Date().toISOString();

  constructor(private readonly cwd: string) {
    this.persistPath = join(cwd, PERSIST_DIR, PERSIST_FILE);
    this.lockPath = join(cwd, PERSIST_DIR, LOCK_FILE);
    this.statusFilePath = process.env.VISUAL_BRIDGE_STATUS_FILE
      ? resolve(cwd, process.env.VISUAL_BRIDGE_STATUS_FILE)
      : join(cwd, 'editor-queue-status.yaml');
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
    if (!(await this.acquireLock())) {
      throw new Error(
        'Another nco-web-editor MCP server is already running in this project directory',
      );
    }

    try {
      const basePort = parseInt(process.env.NCO_WEB_EDITOR_PORT ?? '7890', 10);

      for (let port = basePort; port < basePort + 10; port++) {
        const bound = await this.tryPort(port);
        if (bound) {
          await this.restoreQueue();
          // Initialize status file — reflects restored queue state or clean start
          await this.writeStatusFile(this.pendingQueue.length > 0 ? 'active' : 'closed');
          console.error(`[nco-web-editor] WebSocket server listening on port ${port}`);
          return port;
        }
      }

      throw new Error(
        `Could not bind to any port in range ${basePort}–${basePort + 9}`,
      );
    } catch (err) {
      await this.releaseLock();
      throw err;
    }
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
    await this.releaseLock();
  }

  // -----------------------------------------------------------------------
  // Singleton lock — one server per project directory
  // -----------------------------------------------------------------------

  /** Acquire an exclusive lock file. Returns false if another live server holds it. */
  private async acquireLock(): Promise<boolean> {
    await mkdir(dirname(this.lockPath), { recursive: true });

    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        await writeFile(this.lockPath, String(process.pid), { flag: 'wx' });
        return true;
      } catch (err) {
        if (!isEexist(err)) throw err;
      }

      let holderPid = NaN;
      try {
        const raw = await readFile(this.lockPath, 'utf-8');
        holderPid = parseInt(raw.trim(), 10);
      } catch {
        // Lock file vanished between creation check and read — retry
        continue;
      }

      if (
        Number.isInteger(holderPid) &&
        holderPid > 0 &&
        holderPid !== process.pid &&
        isPidAlive(holderPid)
      ) {
        console.error(
          `[nco-web-editor] Another server is already running (PID ${holderPid}) ` +
            `in ${this.cwd}. Exiting. If you believe this is stale, delete ${this.lockPath}.`,
        );
        return false;
      }

      console.error(
        `[nco-web-editor] Removing stale lock file (PID ${holderPid || 'unknown'} not alive)`,
      );
      try {
        await unlink(this.lockPath);
      } catch {
        // Another process may have removed it — retry
      }
    }

    return false;
  }

  /** Release the lock file — only if we still own it. */
  private async releaseLock(): Promise<void> {
    try {
      const raw = await readFile(this.lockPath, 'utf-8');
      if (parseInt(raw.trim(), 10) !== process.pid) return;
      await unlink(this.lockPath);
    } catch {
      // Lock file already gone or unreadable — nothing to release
    }
  }

  // -----------------------------------------------------------------------
  // Pending queue operations (called by MCP tools)
  // -----------------------------------------------------------------------

  /** Get all pending diffs, notes, and batch summary; optionally filtered by tabId and/or batchId. */
  getPendingChanges(tabId?: string, batchId?: string): {
    diffs: VisualDiff[];
    notes: PendingNote[];
    batches: BatchSummary[];
  } {
    let diffs = tabId
      ? this.pendingQueue.filter((d) => d.context.tabId === tabId)
      : [...this.pendingQueue];
    if (batchId) {
      diffs = diffs.filter((d) => d.batchId === batchId);
    }
    return { diffs, notes: [...this.pendingNotes], batches: this.buildBatchesSummary() };
  }

  /** Derive the batches summary index from the pending queue. Ordered newest-first. */
  buildBatchesSummary(): BatchSummary[] {
    // Collect unique batchIds with earliest createdAt and diffCount
    const batchMap = new Map<string, { createdAt: string; diffCount: number }>();
    for (const diff of this.pendingQueue) {
      if (!diff.batchId) continue;
      const existing = batchMap.get(diff.batchId);
      if (!existing) {
        batchMap.set(diff.batchId, { createdAt: diff.timestamp, diffCount: 1 });
      } else {
        if (diff.timestamp < existing.createdAt) existing.createdAt = diff.timestamp;
        existing.diffCount++;
      }
    }
    // Correlate batchNotes to batchIds
    const noteByBatchId = new Map<string, string>();
    for (const note of this.pendingNotes) {
      if (note.batchId && !noteByBatchId.has(note.batchId)) {
        noteByBatchId.set(note.batchId, note.text);
      }
    }
    // Build summary array, newest-first
    const summaries: BatchSummary[] = [];
    for (const [bid, { createdAt, diffCount }] of batchMap) {
      summaries.push({
        batchId: bid,
        batchNote: noteByBatchId.get(bid),
        createdAt,
        diffCount,
      });
    }
    summaries.sort((a, b) => b.batchId.localeCompare(a.batchId) || b.createdAt.localeCompare(a.createdAt));
    return summaries;
  }

  /** Acknowledge a diff — remove from queue, add to tombstone, notify extension, persist. */
  acknowledgeDiff(diffId: string): boolean {
    const idx = this.pendingQueue.findIndex((d) => d.id === diffId);
    if (idx === -1) return false;

    const diff = this.pendingQueue[idx];
    this.pendingQueue.splice(idx, 1);
    this.processedIds.add(diffId);
    this.safePersistQueue();
    this.safeWriteStatusFile(this.pendingQueue.length > 0 ? 'active' : 'closed');

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
    console.error(`[nco-web-editor] Diff ${diffId} rejected: ${reason}`);
    this.pendingQueue.splice(idx, 1);
    this.processedIds.add(diffId);
    this.safePersistQueue();
    this.safeWriteStatusFile(this.pendingQueue.length > 0 ? 'active' : 'closed');

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
  // Component registry operations
  // -----------------------------------------------------------------------

  /** Set the full component registry (called at startup after discovery). */
  setComponentRegistry(
    components: Map<string, ProjectComponent[]>,
    sources: ComponentSourceStatus[],
  ): void {
    this.componentRegistry = components;
    this.componentSources = sources;
  }

  /**
   * Update a single component source — replaces (or removes when the file
   * was unlinked) that file's entries — and broadcasts COMPONENT_UPDATE to
   * every connected extension. Always sends the full current registry as
   * per the spec (per-file delta deferred).
   */
  updateComponents(
    sourceFile: string,
    components: ProjectComponent[],
    status: ComponentSourceStatus | null,
  ): void {
    if (status === null) {
      this.componentRegistry.delete(sourceFile);
      this.componentSources = this.componentSources.filter((s) => s.file !== sourceFile);
    } else {
      this.componentRegistry.set(sourceFile, components);
      const idx = this.componentSources.findIndex((s) => s.file === status.file);
      if (idx >= 0) {
        this.componentSources[idx] = status;
      } else {
        this.componentSources.push(status);
      }
    }

    const flat = this.getAllComponentsFlat();
    const { sourceCount, failedCount } = this.getComponentCounts();

    this.broadcast({
      type: MessageType.COMPONENT_UPDATE,
      version: PROTOCOL_VERSION,
      payload: { components: flat, sourceCount, failedCount },
    });
  }

  /** Get components, optionally filtered by a name substring (case-insensitive). */
  getComponents(nameFilter?: string): {
    components: ProjectComponent[];
    sourceCount: number;
    failedCount: number;
  } {
    let components = this.getAllComponentsFlat();
    if (nameFilter) {
      const needle = nameFilter.toLowerCase();
      components = components.filter((c) => c.componentName.toLowerCase().includes(needle));
    }
    const { sourceCount, failedCount } = this.getComponentCounts();
    return { components, sourceCount, failedCount };
  }

  private getAllComponentsFlat(): ProjectComponent[] {
    const all: ProjectComponent[] = [];
    for (const components of this.componentRegistry.values()) {
      all.push(...components);
    }
    return all;
  }

  private getComponentCounts(): { sourceCount: number; failedCount: number } {
    return {
      sourceCount: this.componentSources.length,
      failedCount: this.componentSources.filter((s) => s.status === 'error').length,
    };
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
    console.error('[nco-web-editor] Extension connected');

    ws.on('message', (data: Buffer) => {
      this.handleMessage(ws, data);
    });

    ws.on('close', () => {
      // Remove client from map
      for (const [tabId, client] of this.clients) {
        if (client.ws === ws) {
          this.clients.delete(tabId);
          console.error(`[nco-web-editor] Extension disconnected (tab: ${tabId})`);
          break;
        }
      }
    });

    ws.on('error', (error: Error) => {
      console.error(`[nco-web-editor] WebSocket error: ${error.message}`);
    });
  }

  private handleMessage(ws: WebSocket, data: Buffer): void {
    let msg: unknown;
    try {
      msg = JSON.parse(data.toString());
    } catch {
      console.error('[nco-web-editor] Invalid WebSocket message — not JSON');
      return;
    }

    // Validate basic message envelope (type + non-null payload)
    if (
      typeof msg !== 'object' || msg === null ||
      !('type' in msg) || !('payload' in msg) ||
      (msg as Record<string, unknown>).payload == null
    ) {
      console.error('[nco-web-editor] Invalid WebSocket message — missing type or payload');
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
          `[nco-web-editor] Extension error: ${typed.payload.code} — ${typed.payload.message}`,
        );
        break;

      default:
        console.error(`[nco-web-editor] Unknown message type: ${(typed as { type: string }).type}`);
    }
  }

  private handleExtensionHello(
    ws: WebSocket,
    payload: { tabId: string; pendingDiffIds: readonly string[] },
  ): void {
    const { tabId } = payload;

    // Register or update client
    this.clients.set(tabId, { ws, tabId });
    console.error(`[nco-web-editor] Extension hello from tab: ${tabId}`);

    // Respond with SERVER_HELLO — split pending and applied IDs
    // so the extension can distinguish server queue state from completed diffs
    const pendingDiffIds = this.pendingQueue.map((d) => d.id);
    const appliedDiffIds = [...this.processedIds];
    this.send(ws, {
      type: MessageType.SERVER_HELLO,
      version: PROTOCOL_VERSION,
      payload: { pendingDiffIds, appliedDiffIds, protocolVersion: PROTOCOL_VERSION },
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

    // Send full project-component registry
    const { sourceCount, failedCount } = this.getComponentCounts();
    this.send(ws, {
      type: MessageType.COMPONENT_DATA,
      version: PROTOCOL_VERSION,
      payload: {
        components: this.getAllComponentsFlat(),
        sourceCount,
        failedCount,
      },
    });
  }

  private handleDiffBatch(
    ws: WebSocket,
    payload: VisualDiffBatchPayload,
  ): void {
    // Acknowledge immediately so the extension doesn't wait on file I/O
    const diffIds = payload.diffs.map((d) => d.id);
    this.send(ws, {
      type: MessageType.DIFF_ACK,
      version: PROTOCOL_VERSION,
      payload: { diffIds },
    });

    // Process asynchronously (data URL extraction may involve disk writes)
    this.processDiffBatch(payload).catch((err) => {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`[nco-web-editor] Error processing diff batch: ${msg}`);
    });
  }

  private async processDiffBatch(payload: VisualDiffBatchPayload): Promise<void> {
    const { diffs, batchNote, batchId: envelopeBatchId } = payload;
    const existingIds = new Set(this.pendingQueue.map((d) => d.id));
    const newDiffs: VisualDiff[] = [];

    // Mint the legacy id once per payload (not per diff) so all diffs from a pre-batchId
    // extension in one payload share the same synthetic id and appear as one logical batch.
    const legacyId = !envelopeBatchId
      ? `batch-legacy-${new Date().toISOString().slice(0, 19).replace(/[-:T]/g, '')}`
      : null;

    for (const rawDiff of diffs) {
      // Skip diffs that are already pending or were previously processed
      if (existingIds.has(rawDiff.id) || this.processedIds.has(rawDiff.id)) {
        continue;
      }
      // Belt-and-suspenders: stamp batchId from envelope onto any diff missing it.
      // The extension stamps diffs at source, but the envelope batchId is the fallback.
      let diffToProcess = rawDiff;
      if (!diffToProcess.batchId && envelopeBatchId) {
        diffToProcess = { ...rawDiff, batchId: envelopeBatchId };
      } else if (!diffToProcess.batchId && legacyId) {
        // Pre-batchId extension — stamp the shared synthetic legacy id for this payload.
        diffToProcess = { ...rawDiff, batchId: legacyId };
      }
      // Extract data URLs in attribute changes → save as files
      const diff = await this.extractDataUrls(diffToProcess);
      this.pendingQueue.push(diff);
      newDiffs.push(diff);
    }

    // Determine the effective batchId for this payload
    const effectiveBatchId = envelopeBatchId ??
      (newDiffs.length > 0 ? newDiffs[0].batchId : undefined);

    // Track latest_batch_id (most recently received batch)
    if (effectiveBatchId) {
      this.latestBatchId = effectiveBatchId;
    }

    // Store batch note correlated to its batchId
    if (batchNote) {
      this.pendingNotes.push({
        text: batchNote,
        receivedAt: new Date().toISOString(),
        batchId: effectiveBatchId,
      });
      console.error(`[nco-web-editor] Received batch note (${batchNote.length} chars)`);
    }

    if (newDiffs.length > 0 || batchNote) {
      this.trackDrift(newDiffs);
      this.safePersistQueue();
      if (newDiffs.length > 0) {
        this.safeWriteStatusFile('active');
      }
    }

    console.error(
      `[nco-web-editor] Received ${diffs.length} diffs (${newDiffs.length} new, ${diffs.length - newDiffs.length} already known)`,
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
  // Queue status signal
  // -----------------------------------------------------------------------

  /** Get lightweight queue status (for the get_queue_status MCP tool). */
  getQueueStatus(): { status: 'active' | 'closed'; pending_count: number; updated_at: string; latest_batch_id?: string } {
    const result: { status: 'active' | 'closed'; pending_count: number; updated_at: string; latest_batch_id?: string } = {
      status: this.pendingQueue.length > 0 ? 'active' : 'closed',
      pending_count: this.pendingQueue.length,
      updated_at: this.lastStatusUpdate,
    };
    if (this.latestBatchId) result.latest_batch_id = this.latestBatchId;
    return result;
  }

  /** Write status: closed to the status file (for shutdown). */
  async writeShutdownStatus(): Promise<void> {
    await this.writeStatusFile('closed');
  }

  /** Atomically write the queue status file (temp + rename). */
  private async writeStatusFile(status: 'active' | 'closed'): Promise<void> {
    this.lastStatusUpdate = new Date().toISOString();
    const content =
      `status: ${status}\n` +
      `updated_at: ${this.lastStatusUpdate}\n` +
      `pending_count: ${this.pendingQueue.length}\n`;

    const tmpPath = this.statusFilePath + '.tmp';
    await writeFile(tmpPath, content);
    await rename(tmpPath, this.statusFilePath);
  }

  /** Fire-and-forget status file write with error logging. */
  private safeWriteStatusFile(status: 'active' | 'closed'): void {
    this.writeStatusFile(status).catch((error: unknown) => {
      const msg = error instanceof Error ? error.message : String(error);
      console.error(`[nco-web-editor] Failed to write status file: ${msg}`);
    });
  }

  // -----------------------------------------------------------------------
  // Persistence
  // -----------------------------------------------------------------------

  /** Fire-and-forget persistence with error logging (not process-fatal). */
  private safePersistQueue(): void {
    this.persistQueue().catch((error: unknown) => {
      const msg = error instanceof Error ? error.message : String(error);
      console.error(`[nco-web-editor] Failed to persist queue: ${msg}`);
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
            `[nco-web-editor] Skipped ${data.diffs.length - valid.length} invalid entries from persisted queue`,
          );
        }
        if (valid.length > 0) {
          console.error(
            `[nco-web-editor] Restored ${valid.length} pending diffs from disk`,
          );
          // Restore latest_batch_id from the most recently timestamped diff with a batchId
          for (const diff of [...valid].sort((a, b) => b.timestamp.localeCompare(a.timestamp))) {
            if (diff.batchId) {
              this.latestBatchId = diff.batchId;
              break;
            }
          }
        }
      }

      if (Array.isArray(data.notes) && data.notes.length > 0) {
        this.pendingNotes = data.notes.filter(
          (n): n is PendingNote => typeof n === 'object' && n !== null && typeof n.text === 'string',
        );
        if (this.pendingNotes.length > 0) {
          console.error(
            `[nco-web-editor] Restored ${this.pendingNotes.length} pending notes from disk`,
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

  // -----------------------------------------------------------------------
  // Data URL → file extraction (for attribute changes like src)
  // -----------------------------------------------------------------------

  private static readonly ASSET_DIR_FALLBACK = 'public/images';
  /**
   * Per-asset size cap (issue #28). An inline `data:` asset larger than this
   * that cannot be deduplicated to an already-committed file is truncated
   * (`assetTruncated: true`, empty value) rather than persisted/inlined — an
   * asset this large belongs in the repo, not pasted through a diff.
   */
  private static readonly MAX_INLINE_ASSET_BYTES = 4 * 1024 * 1024;
  /** Matches a single `data:` URI up to the first quote, paren, or whitespace. */
  private static readonly DATA_URL_RE = /data:[^"')\s]+/gi;
  private static readonly MIME_EXT: Record<string, string> = {
    'image/png': '.png',
    'image/jpeg': '.jpg',
    'image/gif': '.gif',
    'image/webp': '.webp',
    'image/avif': '.avif',
    'image/svg+xml': '.svg',
    'image/x-icon': '.ico',
    'video/mp4': '.mp4',
    'video/webm': '.webm',
    'video/ogg': '.ogg',
  };

  /** Extensions considered when scanning an asset directory for an existing identical file. */
  private static readonly DEDUP_EXTS = new Set([
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.avif', '.svg', '.ico',
    '.mp4', '.webm', '.ogg',
  ]);

  /**
   * Persist any inline assets carried by a diff and rewrite references to a
   * served path (issue #28). Base64 can enter a diff through more than one
   * carrier, so this scans every one:
   *   1. `attributeChanges` — a `data:` `toValue` (decode + save), or a
   *      `pendingUpload` file-picker reference (normalize the served path).
   *   2. `insertChanges[].outerHTML` — clone/paste markup may embed `data:` URIs.
   *   3. `changes` (`background-image` `PropertyChange.toValue`) — `url(data:…)`.
   * Returns a new diff with the rewritten carriers (or the original if none
   * matched). A single oversized/unresolvable asset is truncated rather than
   * inlined (see {@link saveDataUrl}).
   */
  private async extractDataUrls(diff: VisualDiff): Promise<VisualDiff> {
    let mutated = false;

    // 1. Attribute changes (src, etc.).
    let attributeChanges = diff.attributeChanges;
    if (attributeChanges && attributeChanges.length > 0) {
      const updated: AttributeChange[] = [];
      let anyChanged = false;
      for (const ac of attributeChanges) {
        const next = await this.resolveAttributeAsset(ac);
        if (next !== ac) anyChanged = true;
        updated.push(next);
      }
      if (anyChanged) { attributeChanges = updated; mutated = true; }
    }

    // 2. Insert changes — scan the serialized clone/paste markup for data: URIs.
    // Only `data:` is rewritten here. A `blob:` src can appear in outerHTML when
    // an element is duplicated right after a file-picker pick (the live DOM src is
    // the preview blob URL); a blob: URL is page-local and unresolvable server-side,
    // so it is a documented partial — the served path lives on the paired
    // AttributeChange.toValue, and Brief 2 (#29) carries a resolved assetPath on
    // element references to close it. See data-contracts § No base64 in diffs.
    let insertChanges = diff.insertChanges;
    if (insertChanges && insertChanges.length > 0) {
      const updated: InsertChange[] = [];
      let anyChanged = false;
      for (const ic of insertChanges) {
        if (ic.outerHTML && ic.outerHTML.includes('data:')) {
          const rewritten = await this.replaceDataUrlsInString(ic.outerHTML);
          if (rewritten !== ic.outerHTML) {
            updated.push({ ...ic, outerHTML: rewritten });
            anyChanged = true;
            continue;
          }
        }
        updated.push(ic);
      }
      if (anyChanged) { insertChanges = updated; mutated = true; }
    }

    // 3. background-image property changes — url(data:…).
    let changes = diff.changes;
    if (changes.some((c) => c.property === 'background-image' && c.toValue.includes('data:'))) {
      const updated: PropertyChange[] = [];
      for (const c of changes) {
        if (c.property === 'background-image' && c.toValue.includes('data:')) {
          const rewritten = await this.replaceDataUrlsInString(c.toValue);
          updated.push(rewritten !== c.toValue ? { ...c, toValue: rewritten } : c);
        } else {
          updated.push(c);
        }
      }
      changes = updated;
      mutated = true;
    }

    return mutated ? { ...diff, attributeChanges, insertChanges, changes } : diff;
  }

  /**
   * Resolve a single attribute change to a base64-free served path (issue #28):
   *   - `data:` `toValue` → decode + persist (or truncate if oversized).
   *   - a `pendingUpload` reference (blob-URL-backed pick) → normalize the
   *     provisional served path (strip a leading `/public`); the bytes were
   *     never transmitted, so an existing committed asset is the resolution and
   *     the provisional `/images/<name>` path is the graceful fallback.
   *   - anything else → unchanged.
   */
  private async resolveAttributeAsset(ac: AttributeChange): Promise<AttributeChange> {
    if (ac.toValue.startsWith('data:')) {
      try {
        const savedPath = await this.saveDataUrl(ac.toValue, ac.fromValue, ac.pendingUpload);
        if (savedPath === null) {
          console.error(`[nco-web-editor] Asset exceeded ${Bridge.MAX_INLINE_ASSET_BYTES}-byte cap — truncating`);
          return { ...ac, toValue: '', assetTruncated: true };
        }
        console.error(`[nco-web-editor] Saved data URL as ${savedPath}`);
        return { ...ac, toValue: savedPath };
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`[nco-web-editor] Failed to save data URL: ${msg}`);
        return ac; // keep original value as fallback
      }
    }

    if (ac.pendingUpload) {
      // File-picker pick (blob-URL-backed): the bytes were never transmitted, so
      // the provisional served path IS the resolution. Defensively strip a
      // leading `/public` so the emitted path is apply-correct (/images/<name>);
      // only mutate when the strip actually changes the value.
      const stripped = this.stripPublicPrefix(ac.toValue);
      return stripped !== ac.toValue ? { ...ac, toValue: stripped } : ac;
    }

    return ac;
  }

  /**
   * Replace every `data:` URI embedded in a string (e.g. `outerHTML`, a
   * `url(data:…)` value) with its persisted served path (issue #28). A URI that
   * is oversized/unresolvable is replaced with an empty reference rather than
   * left inline; a persistence failure leaves that URI untouched.
   */
  private async replaceDataUrlsInString(str: string): Promise<string> {
    const matches = str.match(Bridge.DATA_URL_RE);
    if (!matches) return str;

    let out = str;
    for (const dataUrl of new Set(matches)) {
      try {
        const saved = await this.saveDataUrl(dataUrl, '');
        // `null` = oversized/unresolvable → drop the inline blob (empty ref).
        out = out.split(dataUrl).join(saved ?? '');
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`[nco-web-editor] Failed to save embedded data URL: ${msg}`);
        // Leave this occurrence as-is; other matches still get a chance.
      }
    }
    return out;
  }

  /**
   * Strip a single leading `/public` segment from a served web path so it is
   * apply-correct (issue #28) — e.g. `/public/images/x.png` → `/images/x.png`
   * (Next.js / Vite serve `public/` at the web root). At most one segment is
   * removed; a path that does not start with `/public` is returned unchanged.
   */
  private stripPublicPrefix(webPath: string): string {
    if (webPath === '/public') return '/';
    if (webPath.startsWith('/public/')) return webPath.slice('/public'.length);
    return webPath;
  }

  /**
   * Decode a data URL, save the binary to the project, and return the served
   * web path (a leading `/public` is stripped so the path is apply-correct —
   * `/images/<name>`, issue #28). Infers the target directory from the original
   * src path (`fromValue`).
   *
   * Deduplication: if a byte-identical file already exists in the target asset
   * directory (e.g. the user picked an image already committed to the repo via the
   * media file picker), reference that file instead of writing a duplicate.
   *
   * Naming: when `pendingUpload.filename` is supplied it seeds a human-readable
   * name (`<stem>-<hash>.<ext>`); otherwise the content hash names the file
   * (`uploaded-<hash>.<ext>`). Either way the content hash is embedded so
   * re-selecting the same image is idempotent.
   *
   * Size cap: an asset larger than {@link MAX_INLINE_ASSET_BYTES} that cannot be
   * deduplicated to a committed file returns `null` (caller truncates) rather
   * than persisting/inlining a multi-MB blob.
   */
  private async saveDataUrl(
    dataUrl: string,
    fromValue: string,
    pendingUpload?: PendingUpload,
  ): Promise<string | null> {
    // Parse data URL: data:[<mime>][;base64],<data>. Capture the base64 flag so
    // a non-base64 (percent-encoded, e.g. `data:image/svg+xml,%3Csvg…`) payload
    // is decoded as text rather than mis-decoded as base64 into garbage bytes.
    const match = dataUrl.match(/^data:([^;,]*)(;base64)?,(.*)$/s);
    if (!match) throw new Error('Invalid data URL format');

    const mime = match[1] || 'application/octet-stream';
    const isBase64 = Boolean(match[2]);
    const payload = match[3];
    const buffer = isBase64
      ? Buffer.from(payload, 'base64')
      : Buffer.from(decodeURIComponent(payload), 'utf-8');

    // Determine file extension — prefer the picked filename's extension, then MIME.
    const ext = this.assetExt(mime, pendingUpload?.filename);

    // Determine target directory from the original src path
    const targetDir = await this.resolveAssetDir(fromValue);

    // Content hash drives both dedup matching and stable (idempotent) naming.
    const hash = createHash('sha256').update(buffer).digest('hex');

    // If a byte-identical file already exists in the target directory, reuse it
    // (regardless of size — it is already committed). Best-effort — any failure
    // falls back to the size-cap + write path below.
    try {
      const existing = await this.findExistingAsset(buffer, hash, targetDir);
      if (existing) {
        console.error(`[nco-web-editor] Reusing existing asset ${existing} (content match — no duplicate written)`);
        return this.stripPublicPrefix(existing);
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`[nco-web-editor] Asset dedup scan failed (${msg}) — writing new file`);
    }

    // Oversized and unresolvable — do not write a multi-MB new asset or inline it.
    if (buffer.length > Bridge.MAX_INLINE_ASSET_BYTES) return null;

    // Name the file, embedding the content hash so re-uploads are idempotent.
    const filename = this.assetFilename(hash, ext, pendingUpload?.filename);
    const absDir = resolve(this.cwd, targetDir);
    await mkdir(absDir, { recursive: true });
    const absPath = join(absDir, filename);
    const relPath = '/' + relative(this.cwd, absPath).replace(/\\/g, '/');

    // Idempotent: the filename embeds the content hash, so a file already present
    // at this path is the same image — skip the write. (size check is a sanity guard.)
    try {
      const s = await stat(absPath);
      if (s.isFile() && s.size === buffer.length) return this.stripPublicPrefix(relPath);
    } catch {
      // not present — fall through to write
    }

    await writeFile(absPath, buffer);

    // Return served web path with a leading `/public` stripped (apply-correct).
    return this.stripPublicPrefix(relPath);
  }

  /** Resolve the asset extension — prefer the picked filename's, else the MIME type. */
  private assetExt(mime: string, filename?: string): string {
    if (filename) {
      const dot = filename.lastIndexOf('.');
      if (dot > 0 && dot < filename.length - 1) {
        return filename.slice(dot).toLowerCase();
      }
    }
    return Bridge.MIME_EXT[mime] || this.guessExtFromMime(mime);
  }

  /**
   * Build the persisted asset filename. When a picked filename is supplied its
   * stem seeds a readable name (`<stem>-<hash>.<ext>`); otherwise the content
   * hash names it (`uploaded-<hash>.<ext>`). The hash is always embedded so
   * re-selecting the same bytes is idempotent.
   */
  private assetFilename(hash: string, ext: string, filename?: string): string {
    const shortHash = hash.slice(0, 12);
    if (filename) {
      const base = filename.split(/[\\/]/).pop() ?? '';
      const dot = base.lastIndexOf('.');
      const rawStem = dot > 0 ? base.slice(0, dot) : base;
      const stem = rawStem.replace(/[^A-Za-z0-9._-]/g, '-').replace(/-+/g, '-').replace(/^[-.]+/, '');
      if (stem) return `${stem}-${shortHash}${ext}`;
    }
    return `uploaded-${shortHash}${ext}`;
  }

  /**
   * Scan a single asset directory (non-recursive) for a file whose content is
   * byte-identical to `buffer`. Returns its project-relative web path, or null.
   * A cheap size pre-filter avoids hashing files that cannot match.
   */
  private async findExistingAsset(
    buffer: Buffer,
    hash: string,
    targetDir: string,
  ): Promise<string | null> {
    const absDir = resolve(this.cwd, targetDir);

    let entries;
    try {
      entries = await readdir(absDir, { withFileTypes: true });
    } catch {
      return null; // directory doesn't exist yet — nothing to dedup against
    }

    for (const entry of entries) {
      if (!entry.isFile()) continue;
      if (!Bridge.DEDUP_EXTS.has(extname(entry.name).toLowerCase())) continue;

      const absPath = join(absDir, entry.name);
      let candidate: Buffer;
      try {
        const s = await stat(absPath);
        if (s.size !== buffer.length) continue; // cheap pre-filter before hashing
        candidate = await readFile(absPath);
      } catch {
        continue; // unreadable / removed mid-scan — skip
      }

      const candidateHash = createHash('sha256').update(candidate).digest('hex');
      if (candidateHash === hash) {
        return '/' + relative(this.cwd, absPath).replace(/\\/g, '/');
      }
    }

    return null;
  }

  /**
   * Infer the asset directory from the original src URL.
   * e.g. "/images/hero.jpg" → "public/images" (or "images" if it exists directly)
   * Falls back to "public/images" if nothing can be inferred.
   */
  private async resolveAssetDir(fromValue: string): Promise<string> {
    if (!fromValue) return Bridge.ASSET_DIR_FALLBACK;

    // Strip origin and query string, get the directory part
    let urlPath = fromValue;
    try {
      const parsed = new URL(fromValue, 'http://localhost');
      urlPath = parsed.pathname;
    } catch {
      // already a path
    }

    const dirPart = dirname(urlPath).replace(/^\//, ''); // e.g. "images" or "assets/img"
    if (!dirPart || dirPart === '.') return Bridge.ASSET_DIR_FALLBACK;

    // Check common project structures: try "public/<dir>", "src/<dir>", then "<dir>" directly
    const candidates = [
      join('public', dirPart),
      dirPart,
      join('src', dirPart),
      join('src', 'assets', dirPart),
    ];

    for (const candidate of candidates) {
      const abs = resolve(this.cwd, candidate);
      try {
        const s = await stat(abs);
        if (s.isDirectory()) return candidate;
      } catch {
        // doesn't exist, try next
      }
    }

    // None exist — use the first candidate (public/<dir>) and create it
    return candidates[0];
  }

  private guessExtFromMime(mime: string): string {
    const sub = mime.split('/')[1];
    if (sub) return '.' + sub.replace(/\+.*$/, '');
    return '.bin';
  }

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

/** Probe whether a PID corresponds to a live process (signal 0 is a no-op probe). */
function isPidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function isEexist(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    (err as NodeJS.ErrnoException).code === 'EEXIST'
  );
}
