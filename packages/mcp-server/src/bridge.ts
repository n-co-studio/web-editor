import { WebSocketServer, type WebSocket } from 'ws';
import { readFile, writeFile, unlink, mkdir, rename, stat, readdir, realpath, lstat } from 'node:fs/promises';
import nodePath, { join, dirname, resolve, relative, extname } from 'node:path';
import { createHash } from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
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
  NoteRef,
  DesignToken,
  TokenSourceStatus,
  ProjectComponent,
  ComponentSourceStatus,
  ExtensionToServerMessage,
  ServerToExtensionMessage,
} from '@nco-studio/shared';
import { resolveToToken } from './tokens.js';
import type { ConnectedClient, PendingNote, PersistedQueue, SessionExport, DriftEntry, BatchSummary, AgentNote } from './types.js';

const PERSIST_DIR = '.nco-web-editor';
const PERSIST_FILE = 'pending-queue.json';
const LOCK_FILE = 'server.lock';

/**
 * Write a file but refuse to follow a symlink at the final component (ELOOP).
 * The state-directory check covers the directory; this covers a link planted at
 * the file itself, such as `pending-queue.json` or a `.tmp` name. O_NOFOLLOW is
 * a no-op on Windows, where creating a link needs elevated rights anyway.
 */
function writeFileNoFollow(path: string, data: string): Promise<void> {
  const flag =
    fsConstants.O_WRONLY | fsConstants.O_CREAT | fsConstants.O_TRUNC | (fsConstants.O_NOFOLLOW ?? 0);
  return writeFile(path, data, { flag });
}

/**
 * One writer per file. `schedule()` marks the file dirty and starts a loop if
 * none is running; the loop writes until nothing is dirty. A request that
 * arrives during a write therefore produces exactly one more write, however
 * many requests there were, and the writes never overlap — so a shared `.tmp`
 * name cannot be renamed out from under a concurrent writer (ENOENT), and the
 * last write always reflects the latest state. This is a coalescer, not a
 * promise chain: the body runs at call time and builds its content then, so a
 * queued request never writes stale state.
 */
class CoalescingWriter {
  private dirty = false;
  private loop: Promise<void> | null = null;
  private stopped = false;

  constructor(
    private readonly label: string,
    private readonly write: () => Promise<void>,
  ) {}

  schedule(): void {
    if (this.stopped) return;
    this.dirty = true;
    if (!this.loop) this.loop = this.run();
  }

  /** Resolves when no loop is running and nothing is dirty. */
  async drain(): Promise<void> {
    while (this.loop) await this.loop;
  }

  /** After this, `schedule()` does nothing. Does not interrupt a running loop. */
  stop(): void {
    this.stopped = true;
  }

  private async run(): Promise<void> {
    try {
      while (this.dirty) {
        this.dirty = false;
        try {
          await this.write();
        } catch (error) {
          const msg = error instanceof Error ? error.message : String(error);
          console.error(`[nco-web-editor] Failed to write ${this.label}: ${msg}`);
        }
      }
    } finally {
      this.loop = null;
    }
  }
}

/** Upper bound on how long `stop()` waits for the writers to finish. */
const DRAIN_TIMEOUT_MS = 5000;

/** The published Chrome Web Store extension — the only peer allowed by default. */
export const PUBLISHED_EXTENSION_ID = 'aifpecjojmlgdhgnkmkaobmfipdmppea';
/** Extra extension IDs (unpacked/dev builds), comma-separated. Each must be 32 chars a-p. */
export const EXTENSION_IDS_ENV = 'NCO_WEB_EDITOR_EXTENSION_IDS';
const EXTENSION_ID_RE = /^[a-p]{32}$/;
/** A page on a local dev origin — what a pre-0.3.1 extension connected as. */
const PAGE_ORIGIN_RE = /^https?:\/\/(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?$/i;

/** Caps on the structured-note fields that reach the agent (KL-6). */
export const MAX_NOTES_PER_BATCH = 50;
export const MAX_REFS_PER_NOTE = 100;
/** Total pending notes held, live or restored. */
export const MAX_PENDING_NOTES = 200;
/** Cap on diffs restored from pending-queue.json. */
export const MAX_RESTORED_DIFFS = 5000;
/** The extension mints `batch-YYYYMMDD-HHMMSS-xxxx`; allow that shape family only. */
const BATCH_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/;
export const MAX_REF_TAGNAME_CHARS = 32;
export const MAX_REF_SELECTOR_CHARS = 512;
export const MAX_REF_TEXTCONTENT_CHARS = 200;
export const MAX_REF_ASSETPATH_CHARS = 512;

/**
 * True when `child` is `root` or lies beneath it. `relative()` returns an
 * absolute path across Windows drives and UNC shares (`C:\proj` → `D:\x` is
 * `D:\x`), which a `startsWith('..')` test accepts, so absoluteness is part of
 * the test. `..foo` is a legal directory name and must not be mistaken for a
 * parent reference. `p` lets tests exercise `path.win32` on any platform.
 */
export function isInside(root: string, child: string, p: typeof nodePath = nodePath): boolean {
  const rel = p.relative(root, child);
  return rel === '' || (!p.isAbsolute(rel) && rel !== '..' && !rel.startsWith('..' + p.sep));
}

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
  /** Set once shutdown begins: the status file then reads `closed` whatever the queue holds. */
  private closing = false;
  /** Ingests in flight, so `stop()` can wait for the diffs they are about to queue. */
  private readonly inFlightIngests = new Set<Promise<void>>();
  // The callbacks resolve the write body when the loop runs, not when they are
  // built, so the body is always the current one.
  private readonly queueWriter = new CoalescingWriter('queue file', () => this.persistQueue());
  private readonly statusWriter = new CoalescingWriter('status file', () => this.writeStatusFile());

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
      Bridge.logAcceptedExtensionIds();
      const basePort = parseInt(process.env.NCO_WEB_EDITOR_PORT ?? '7890', 10);

      for (let port = basePort; port < basePort + 10; port++) {
        const bound = await this.tryPort(port);
        if (bound) {
          await this.restoreQueue();
          // Initialize status file — reflects restored queue state or clean start
          this.statusWriter.schedule();
          await this.statusWriter.drain();
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

  /**
   * Stop the server. Order matters: stop taking input, let the ingests already
   * running queue their diffs, flush both files, and only then give up the
   * lock — releasing it first would let a second server start while this one
   * is still writing. Works on a Bridge that was never started.
   */
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
    await Promise.allSettled([...this.inFlightIngests]);

    let timer: NodeJS.Timeout | undefined;
    const timedOut = new Promise<'timeout'>((resolve) => {
      timer = setTimeout(() => resolve('timeout'), DRAIN_TIMEOUT_MS);
      timer.unref?.();
    });
    const drained = Promise.all([this.queueWriter.drain(), this.statusWriter.drain()]);
    if ((await Promise.race([drained, timedOut])) === 'timeout') {
      console.error(`[nco-web-editor] Timed out after ${DRAIN_TIMEOUT_MS}ms flushing writes at shutdown`);
    }
    if (timer) clearTimeout(timer);

    this.queueWriter.stop();
    this.statusWriter.stop();
    await this.releaseLock();
  }

  // -----------------------------------------------------------------------
  // Singleton lock — one server per project directory
  // -----------------------------------------------------------------------

  /** Acquire an exclusive lock file. Returns false if another live server holds it. */
  private async acquireLock(): Promise<boolean> {
    // The lock is the server's first write, and the lock, the persisted queue
    // and the default export all live in this directory: a committed
    // `.nco-web-editor -> elsewhere` link would redirect all three. Checked
    // once, here (the queue file and the status file's temp name are also
    // opened without following a link at the file itself, see writeFileNoFollow).
    // This throws rather than returning false, because false is
    // reported to the operator as "another server holds the lock".
    try {
      await this.assertRealInside(dirname(this.lockPath));
    } catch {
      throw new Error(
        `${PERSIST_DIR} resolves outside the project (symlink?) — refusing to start. Remove or replace the link.`,
      );
    }
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
    // Count notes per batch. Never carry note text here: it would reach the
    // agent without the trust label `notes` gives it.
    const noteCountByBatchId = new Map<string, number>();
    for (const note of this.pendingNotes) {
      if (!note.batchId) continue;
      noteCountByBatchId.set(note.batchId, (noteCountByBatchId.get(note.batchId) ?? 0) + 1);
    }
    // Build summary array, newest-first
    const summaries: BatchSummary[] = [];
    for (const [bid, { createdAt, diffCount }] of batchMap) {
      summaries.push({
        batchId: bid,
        noteCount: noteCountByBatchId.get(bid) ?? 0,
        createdAt: Bridge.isIsoDate(createdAt) ? createdAt : '',
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
    this.safeWriteStatusFile();

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
    this.safeWriteStatusFile();

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

  /**
   * Export the pending queue to a file.
   *
   * The path is confined to the project directory, which on its own is not
   * enough: confineToProject is lexical, so `CLAUDE.md` or `.claude/agents/x.md`
   * were both accepted and overwritten with JSON containing page-controlled
   * strings. This is agent-triggered, which is precisely the hop a sourceFile
   * or note injection aims at, so it gets the same restrictions as an asset
   * write — no dot-directories, and a `.json` name only.
   */
  async exportSession(outputPath?: string): Promise<{ path: string; diffCount: number }> {
    if (outputPath !== undefined) {
      const segs = outputPath.split(/[\\/]/);
      if (segs.some((seg) => seg.startsWith('.') && seg !== '.')) {
        throw new Error('export path must not contain a dot-directory');
      }
      if (!outputPath.toLowerCase().endsWith('.json')) {
        throw new Error('export path must end in .json');
      }
      // A colon in a segment is an NTFS alternate data stream (`x.json:stream`)
      // on Windows, which writes hidden data to an existing file. Refused on
      // every platform so behaviour does not depend on where the server runs.
      if (segs.some((seg) => seg.includes(':'))) {
        throw new Error('export path must not contain a colon');
      }
      // The `.json` rule still left every real `.json` in the repo writable —
      // package.json and tsconfig.json included — and this tool is reachable
      // by an agent that an injected hint has steered. Refuse to clobber an
      // existing file; re-exporting to the same name is only allowed inside
      // the tool's own directory.
      const abs = this.confineToProject(outputPath);
      // Before the stat below, which would otherwise follow a symlinked
      // directory and report on a file outside the project.
      await this.assertRealInside(dirname(abs));
      const inPersistDir = isInside(join(this.cwd, PERSIST_DIR), abs);
      if (!inPersistDir) {
        try {
          await stat(abs);
          throw new Error(
            `refusing to overwrite an existing file: ${outputPath} — export to a new name, or omit the path to write the default session file`,
          );
        } catch (err) {
          // ENOENT is the good case: the target does not exist yet.
          if ((err as NodeJS.ErrnoException)?.code !== 'ENOENT') throw err;
        }
      }
    }
    const outPath = outputPath
      ? this.confineToProject(outputPath)
      : join(this.cwd, PERSIST_DIR, 'session-export.json');

    const data: SessionExport = {
      version: PROTOCOL_VERSION,
      exportedAt: new Date().toISOString(),
      diffs: this.pendingQueue,
    };

    // A caller-chosen path was checked above. The default path was not, and
    // the check must precede mkdir either way: `mkdir -p` through a link
    // creates directories outside the project before anything else can object.
    if (!outputPath) await this.assertRealInside(dirname(outPath));
    await mkdir(dirname(outPath), { recursive: true });
    // 'wx' for a caller-chosen path: export had no symlink resolution at all,
    // so a committed `linkdir -> ../outside` or a dangling `x.json -> outside`
    // wrote through it. The default path inside PERSIST_DIR is ours and is
    // meant to be overwritten — but `w` follows a link planted at the file
    // name, so refuse that one case.
    if (!outputPath) {
      try {
        if ((await lstat(outPath)).isSymbolicLink()) {
          throw new Error('refusing to write the default session file: it is a symlink');
        }
      } catch (err) {
        if ((err as NodeJS.ErrnoException)?.code !== 'ENOENT') throw err;
      }
    }
    const exportFlag = outputPath ? 'wx' : 'w';
    await writeFile(outPath, JSON.stringify(data, null, 2), { flag: exportFlag });

    return { path: outPath, diffCount: this.pendingQueue.length };
  }

  /** Import a session file into the pending queue. Path is confined to project directory. */
  async importSession(
    inputPath: string,
  ): Promise<{ imported: number; skipped: number; warnings: string[] }> {
    // Same dot-directory rule as export. Import also used to echo a parse
    // failure, which leaked the first characters of whatever file it read.
    if (inputPath.split(/[\\/]/).some((seg) => seg.startsWith('.') && seg !== '.')) {
      throw new Error('import path must not contain a dot-directory');
    }
    const absPath = this.confineToProject(inputPath);
    // A symlinked file or directory in the project would otherwise let import
    // read a JSON file from outside it.
    await this.assertRealInside(absPath);
    const raw = await readFile(absPath, 'utf-8');
    let data: unknown;
    try {
      data = JSON.parse(raw);
    } catch {
      // Deliberately does not include the parser's message: it quotes the
      // first bytes of the file, which turned a failed import into a read
      // oracle for any in-project file.
      throw new Error(`not a valid JSON session file: ${inputPath}`);
    }

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

    // Same ceiling as restore: a session file can be arbitrarily large.
    if (session.diffs.length > MAX_RESTORED_DIFFS) {
      warnings.push(`Session has ${session.diffs.length} diffs; importing only the first ${MAX_RESTORED_DIFFS}`);
      skipped += session.diffs.length - MAX_RESTORED_DIFFS;
    }

    for (const diff of session.diffs.slice(0, MAX_RESTORED_DIFFS)) {
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
      // Same source-path screening as the live ingest path. A session file is
      // just as attacker-reachable as a diff off the wire — more so, since it
      // can be written by anything with filesystem access and is replayed
      // wholesale — and this path previously skipped the check entirely.
      // Re-validate after screening, not only before. The screen rebuilds the
      // object, so a shape that passed on the way in is not proof about what
      // comes out.
      let screened;
      try {
        screened = Bridge.withCleanBatchId(Bridge.withCheckedSourcePath(diff));
      } catch (err) {
        warnings.push(`Skipped diff: ${err instanceof Error ? err.message : 'screening failed'}`);
        skipped++;
        continue;
      }
      if (!isValidDiff(screened)) {
        warnings.push('Skipped diff that failed validation after screening');
        skipped++;
        continue;
      }
      this.pendingQueue.push(screened);
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
      // Bind to loopback only and accept upgrades only from the pinned
      // extension origin (see isAllowedOrigin). The bridge writes files into
      // the project directory, so it must not be drivable by a script on a
      // page: the extension's service worker opens the socket, and a browser
      // always sends the truthful Origin on a WebSocket upgrade, which a page
      // script cannot change.
      //
      // Residual risk, stated plainly. Origin is only a browser guarantee: a
      // local process can send any Origin header it likes, so this does not
      // stop a hostile local process from connecting. And nothing here
      // authenticates the SERVER to the extension: a process that binds
      // 127.0.0.1 on one of these ports first still passes the extension's
      // shape-only handshake (HACK-008). Closing either needs a shared secret
      // (pairing), which is deliberately not part of this change.
      const wss = new WebSocketServer({
        port,
        host: '127.0.0.1',
        verifyClient: (info: { origin?: string }) => {
          const allowed = Bridge.isAllowedOrigin(info.origin);
          if (!allowed) this.noteRefusedOrigin(info.origin);
          return allowed;
        },
        // ws defaults to 100 MiB per frame. A legitimate batch is bounded by
        // MAX_INLINE_ASSET_BYTES (4 MiB) per asset plus base64 inflation, so
        // 32 MiB is generous for a real payload and well short of letting a
        // client reserve 100 MiB per connection (HACK-013).
        maxPayload: 32 * 1024 * 1024,
      });

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

  /**
   * Allowlist for WebSocket Origin headers: exactly the published extension's
   * origin, plus any IDs in NCO_WEB_EDITOR_EXTENSION_IDS (unpacked builds).
   * Localhost page origins, other extensions, moz-extension and a missing
   * Origin are all refused, so a script on a dev page cannot open the socket.
   *
   * What this does NOT do: Origin is enforced by the browser, not by the
   * protocol. A local process can forge any Origin header, so this does not
   * keep a hostile local process out. Peer authentication beyond that would
   * need a shared secret.
   */
  private static isAllowedOrigin(origin: string | undefined): boolean {
    if (!origin) return false;
    const prefix = 'chrome-extension://';
    if (!origin.startsWith(prefix)) return false;
    return Bridge.allowedExtensionIds().has(origin.slice(prefix.length));
  }

  /** Pinned ID plus well-formed IDs from the environment. */
  private static allowedExtensionIds(): Set<string> {
    const ids = new Set<string>([PUBLISHED_EXTENSION_ID]);
    for (const raw of (process.env[EXTENSION_IDS_ENV] ?? '').split(',')) {
      const id = raw.trim();
      if (!id) continue;
      if (EXTENSION_ID_RE.test(id)) {
        ids.add(id);
      } else if (!Bridge.warnedBadIds.has(id)) {
        if (Bridge.warnedBadIds.size < 20) Bridge.warnedBadIds.add(id);
        console.error(
          `[nco-web-editor] Ignoring malformed entry in ${EXTENSION_IDS_ENV}: ${Bridge.forLog(id)} (must be 32 characters a-p)`,
        );
      }
    }
    return ids;
  }
  private static readonly warnedBadIds = new Set<string>();

  /** Log extra accepted extension IDs once, at startup. */
  private static logAcceptedExtensionIds(): void {
    const extras = [...Bridge.allowedExtensionIds()].filter((id) => id !== PUBLISHED_EXTENSION_ID);
    if (extras.length > 0) {
      console.error(
        `[nco-web-editor] Also accepting extension ID(s) from ${EXTENSION_IDS_ENV}: ${extras.join(', ')}`,
      );
    }
  }

  private readonly refusedPageOrigins = new Set<string>();

  /**
   * An extension older than 0.3.1 opened this socket from the page itself, so
   * it arrives with an http(s) localhost Origin. It is refused now; say so once
   * per origin so the developer knows to update rather than seeing a silent
   * "disconnected".
   */
  private noteRefusedOrigin(origin: string | undefined): void {
    if (!origin || !PAGE_ORIGIN_RE.test(origin)) return;
    if (this.refusedPageOrigins.has(origin) || this.refusedPageOrigins.size >= 50) return;
    this.refusedPageOrigins.add(origin);
    console.error(
      `[nco-web-editor] Refused a connection from the page origin ${Bridge.forLog(origin)}. ` +
        'An outdated extension (pre-0.3.1) connects from the page and must be updated; ' +
        'a script on the page is also refused by design.',
    );
  }

  private handleConnection(ws: WebSocket): void {
    console.error('[nco-web-editor] Extension connected');

    // HACK-008: identify ourselves proactively so a new extension can confirm this
    // is the real MCP server before disclosing tab/diff identifiers. Old extensions
    // ignore this extra hello and speak first (EXTENSION_HELLO) as before; the full
    // SERVER_HELLO + token/component data still follows registration.
    this.send(ws, {
      type: MessageType.SERVER_HELLO,
      version: PROTOCOL_VERSION,
      payload: {
        pendingDiffIds: this.pendingQueue.map((d) => d.id),
        appliedDiffIds: [...this.processedIds],
        protocolVersion: PROTOCOL_VERSION,
      },
    });

    // HACK-013: handleMessage dispatches into handlers that index into payload
    // fields the envelope check does not verify, so a malformed message throws
    // from inside an event-emitter callback. Unhandled, that takes the whole
    // process down and the agent silently loses its tools. Any client that
    // passes the origin check can send one, so this is a one-packet kill.
    // Contain it here: a bad message closes nothing and the server stays up.
    ws.on('message', (data: Buffer) => {
      try {
        this.handleMessage(ws, data);
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`[nco-web-editor] Dropped malformed WebSocket message: ${msg}`);
      }
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
    // The envelope check upstream only proves `payload` is non-null, so the
    // shape is still unverified here (HACK-013). Reject rather than throw.
    if (!Array.isArray(payload?.diffs)) {
      console.error('[nco-web-editor] Ignoring VISUAL_DIFF_BATCH — payload.diffs is not an array');
      return;
    }

    // Acknowledge immediately so the extension doesn't wait on file I/O
    const diffIds = payload.diffs.filter((d) => d && typeof d === 'object').map((d) => d.id);
    this.send(ws, {
      type: MessageType.DIFF_ACK,
      version: PROTOCOL_VERSION,
      payload: { diffIds },
    });

    // Process asynchronously (data URL extraction may involve disk writes).
    // Tracked so stop() can wait for the diffs this is about to queue.
    const inFlight: Promise<void> = this.processDiffBatch(payload)
      .catch((err) => {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`[nco-web-editor] Error processing diff batch: ${msg}`);
      })
      .finally(() => {
        this.inFlightIngests.delete(inFlight);
      });
    this.inFlightIngests.add(inFlight);
  }

  private async processDiffBatch(payload: VisualDiffBatchPayload): Promise<void> {
    const { diffs, batchNote } = payload;
    const structured = Bridge.screenStructuredNotes(payload.notes);
    // Stamped onto diffs below and then sorted with localeCompare, so a
    // non-string envelope batchId poisons the queue exactly as a per-diff one
    // does. Drop it rather than propagate it.
    const envelopeBatchId = Bridge.cleanBatchId(payload.batchId);
    const existingIds = new Set(this.pendingQueue.map((d) => d.id));
    const newDiffs: VisualDiff[] = [];

    // Mint the legacy id once per payload (not per diff) so all diffs from a pre-batchId
    // extension in one payload share the same synthetic id and appear as one logical batch.
    const legacyId = !envelopeBatchId
      ? `batch-legacy-${new Date().toISOString().slice(0, 19).replace(/[-:T]/g, '')}`
      : null;

    for (const rawDiff of diffs) {
      // Validate shape before anything indexes into it. Only the import and
      // restore paths used to do this, so a diff arriving over the bridge
      // reached the queue unchecked and later threw in getPendingChanges or
      // acknowledgeDiff (HACK-013).
      if (!isValidDiff(rawDiff)) {
        console.error('[nco-web-editor] Dropping malformed diff from batch');
        continue;
      }
      // Skip diffs that are already pending or were previously processed
      if (existingIds.has(rawDiff.id) || this.processedIds.has(rawDiff.id)) {
        continue;
      }
      // Belt-and-suspenders: stamp batchId from envelope onto any diff missing it.
      // The extension stamps diffs at source, but the envelope batchId is the fallback.
      let diffToProcess = Bridge.withCleanBatchId(rawDiff);
      if (!diffToProcess.batchId && envelopeBatchId) {
        diffToProcess = { ...diffToProcess, batchId: envelopeBatchId };
      } else if (!diffToProcess.batchId && legacyId) {
        // Pre-batchId extension — stamp the shared synthetic legacy id for this payload.
        diffToProcess = { ...diffToProcess, batchId: legacyId };
      }
      // Per-diff containment. extractDataUrls and the source screen both index
      // or recurse into fields isValidDiff does not type-check, so one crafted
      // entry used to throw and abandon the rest of the batch — after DIFF_ACK
      // had already gone back for all of them, and with earlier diffs queued
      // but never persisted. The screen has to be inside this try, not above
      // it: a deeply nested diff throws in the walk, and a previous attempt
      // left that call one line outside and so kept the original bug.
      try {
        // sourceFile reaches the agent as a place to edit, but it is copied
        // straight out of a data-source-file attribute the page controls
        // (HACK-012). Drop anything that is not a plausible in-project path.
        const diff = await this.extractDataUrls(Bridge.withCheckedSourcePath(diffToProcess));
        this.pendingQueue.push(diff);
        newDiffs.push(diff);
      } catch (err) {
        console.error(
          `[nco-web-editor] Skipped diff ${Bridge.forLog(diffToProcess.id)} — ${Bridge.forLog(err instanceof Error ? err.message : err)}`,
        );
      }
    }

    // Determine the effective batchId for this payload
    const effectiveBatchId = envelopeBatchId ??
      (newDiffs.length > 0 ? newDiffs[0].batchId : undefined);

    // Track latest_batch_id (most recently received batch)
    if (effectiveBatchId) {
      this.latestBatchId = effectiveBatchId;
    }

    // Store notes correlated to their batchId.
    //
    // Structured notes (protocol 0.5.0): the designer's words and the
    // page-derived element references arrive as separate fields, so each is
    // screened on its own terms and the agent can be told which to follow and
    // which to verify. When `notes` is present the legacy `batchNote` is
    // ignored outright — it is the same content in blended form, so honouring
    // it would let page-derived text ride in as if it were the designer's.
    //
    // Legacy `batchNote` (pre-0.5.0 extension, or an old queue file): one
    // blended string that carries page-derived text. Stored, but labelled
    // `legacy` so the agent treats the whole of it as untrusted. batchNote is
    // slated for removal in a later protocol version.
    const receivedAt = new Date().toISOString();
    let notesAdded = false;
    if (structured !== null) {
      for (const note of structured) {
        if (this.pendingNotes.length >= MAX_PENDING_NOTES) break;
        this.pendingNotes.push({
          text: note.text,
          receivedAt,
          batchId: effectiveBatchId,
          source: 'structured',
          elementRefs: note.elementRefs,
        });
        notesAdded = true;
      }
      console.error(`[nco-web-editor] Received ${structured.length} structured note(s)`);
    } else if (typeof batchNote === 'string' && batchNote.length > 0 && this.pendingNotes.length < MAX_PENDING_NOTES) {
      const text = Bridge.sanitizeNote(batchNote);
      this.pendingNotes.push({ text, receivedAt, batchId: effectiveBatchId, source: 'legacy' });
      notesAdded = true;
      console.error(`[nco-web-editor] Received legacy batch note (${text.length} chars)`);
    } else if (batchNote !== undefined && batchNote !== null) {
      console.error('[nco-web-editor] Ignoring non-string batchNote');
    }

    if (newDiffs.length > 0 || notesAdded) {
      // trackDrift walks change values and can throw on a crafted one. It ran
      // before the persist and the status write, so a throw left diffs queued
      // in memory, absent from disk, and the status file still reading
      // `closed` — which is the file the agent is told to watch. Persisting
      // first, and isolating drift tracking, keeps the queue and the status
      // file honest regardless.
      this.safePersistQueue();
      if (newDiffs.length > 0) {
        this.safeWriteStatusFile();
      }
      try {
        this.trackDrift(newDiffs);
      } catch (err) {
        console.error(
          `[nco-web-editor] Drift tracking failed — ${Bridge.forLog(err instanceof Error ? err.message : err)}`,
        );
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

  /**
   * Write status: closed to the status file (for shutdown). The latch makes
   * every write from here on read `closed`, so an `active` request still
   * pending cannot land after this one.
   */
  async writeShutdownStatus(): Promise<void> {
    this.closing = true;
    this.statusWriter.schedule();
    await this.statusWriter.drain();
  }

  /**
   * Atomically write the queue status file (temp + rename). Builds its content
   * when it runs: the status is derived from the queue as it is now, not as it
   * was when the write was requested.
   */
  private async writeStatusFile(): Promise<void> {
    const status = !this.closing && this.pendingQueue.length > 0 ? 'active' : 'closed';
    this.lastStatusUpdate = new Date().toISOString();
    const content =
      `status: ${status}\n` +
      `updated_at: ${this.lastStatusUpdate}\n` +
      `pending_count: ${this.pendingQueue.length}\n`;

    const tmpPath = this.statusFilePath + '.tmp';
    await writeFileNoFollow(tmpPath, content);
    await rename(tmpPath, this.statusFilePath);
  }

  /** Request a status file write; errors are logged by the writer. */
  private safeWriteStatusFile(): void {
    this.statusWriter.schedule();
  }

  // -----------------------------------------------------------------------
  // Persistence
  // -----------------------------------------------------------------------

  /** Request a queue file write; errors are logged by the writer (not process-fatal). */
  private safePersistQueue(): void {
    this.queueWriter.schedule();
  }

  /**
   * The queue writer's body: builds its content when it runs, writes a temp
   * file and renames it over the queue file. Only the writer calls it, so no
   * two runs overlap and the fixed `.tmp` name is safe.
   */
  private async persistQueue(): Promise<void> {
    // The state directory was checked once, when the lock was taken. A link
    // created after that would redirect this write (and the mkdir below), so
    // check again on every write. A throw skips the write.
    await this.assertRealInside(dirname(this.persistPath));

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
    // Compact, not indented. Indentation is quadratic in nesting depth, which
    // is what turned a small deep payload into a multi-hundred-megabyte queue
    // file. Nothing reads this by hand.
    // Temp + rename, so a crash mid-write cannot leave a truncated queue file.
    // The temp is opened without following a link; the rename replaces a link
    // planted at the queue file's own name instead of writing through it.
    const tmpPath = this.persistPath + '.tmp';
    try {
      await writeFileNoFollow(tmpPath, JSON.stringify(data));
      await rename(tmpPath, this.persistPath);
    } catch (err) {
      try {
        await unlink(tmpPath);
      } catch {
        // Best effort — nothing to clean up if the temp was never created
      }
      throw err;
    }
  }

  private async restoreQueue(): Promise<void> {
    try {
      const raw = await readFile(this.persistPath, 'utf-8');
      const data = JSON.parse(raw) as PersistedQueue;

      if (Array.isArray(data.diffs)) {
        // Screened again on restore, not just on ingest: the queue file sits in
        // the project and survives restarts, so anything that reached it once
        // would otherwise be replayed unchecked for the life of the project.
        const valid = data.diffs
          .slice(0, MAX_RESTORED_DIFFS)
          .filter(isValidDiff)
          .map((d) => {
            // A persisted queue is as untrusted as anything off the wire: it
            // lives in the target project and can arrive with a clone.
            try {
              return Bridge.withCleanBatchId(Bridge.withCheckedSourcePath(d));
            } catch {
              return null;
            }
          })
          .filter((d): d is VisualDiff => d !== null)
          .filter(isValidDiff); // re-check: the screen rebuilds the object
        this.pendingQueue = valid;
        if (data.diffs.length > MAX_RESTORED_DIFFS) {
          console.error(`[nco-web-editor] Persisted queue has ${data.diffs.length} diffs; restoring only the first ${MAX_RESTORED_DIFFS}`);
        }
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
        // Notes get the same screening on restore as on receipt. Diffs
        // were re-screened here and notes were not, which mattered once the
        // framing started telling the agent to follow notes: a queue file
        // committed into the target project, or arriving with a clone, was an
        // uncapped and unscreened instruction channel. The persisted shape is
        // rebuilt field by field, so a file cannot claim trust it was not
        // given: structured notes come back as `restored` (text untrusted, refs
        // screened) and anything else as `legacy`.
        this.pendingNotes = data.notes
          .slice(0, MAX_PENDING_NOTES)
          .filter(
            (n): n is PendingNote => typeof n === 'object' && n !== null && typeof n.text === 'string',
          )
          .map((n): PendingNote => {
            const base = {
              receivedAt: Bridge.isIsoDate(n.receivedAt) ? n.receivedAt : new Date().toISOString(),
              batchId: Bridge.cleanBatchId(n.batchId),
            };
            // Never 'structured' from disk: the file is as untrusted as a clone.
            if (n.source === 'structured' || n.source === 'restored') {
              return {
                ...base,
                text: Bridge.sanitizeNote(n.text),
                source: 'restored',
                elementRefs: Bridge.screenRefs((n as { elementRefs?: unknown }).elementRefs),
              };
            }
            return { ...base, text: Bridge.sanitizeNote(n.text), source: 'legacy' };
          });
        // Same per-batch cap as live ingest.
        const perBatch = new Map<string, number>();
        this.pendingNotes = this.pendingNotes.filter((n) => {
          const key = n.batchId ?? '';
          const c = (perBatch.get(key) ?? 0) + 1;
          perBatch.set(key, c);
          return c <= MAX_NOTES_PER_BATCH;
        });
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
   * that cannot be deduplicated to an already-committed file is refused and
   * the attribute change is truncated (`assetTruncated: true`, empty value)
   * rather than persisted/inlined — an asset this large belongs in the repo,
   * not pasted through a diff. Size is one of several refusal causes; each one
   * logs its own reason in {@link saveDataUrl}.
   */
  private static readonly MAX_INLINE_ASSET_BYTES = 4 * 1024 * 1024;
  /** Cap on a single batch note. It lands in the agent's context verbatim. */
  private static readonly MAX_NOTE_CHARS = 4000;
  /** Maximum object nesting accepted in a diff. Real diffs are a few levels. */
  private static readonly MAX_DIFF_DEPTH = 64;
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
   *   - `data:` `toValue` → decode + persist (or truncate if the asset is refused).
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
          console.error('[nco-web-editor] Asset not saved (reason logged above) — truncating');
          return { ...ac, toValue: '', assetTruncated: true };
        }
        console.error(`[nco-web-editor] Saved data URL as ${savedPath}`);
        return { ...ac, toValue: savedPath };
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`[nco-web-editor] Failed to save data URL: ${msg} — truncating`);
        // Never fall back to the original: a `data:` URL that skipped the size
        // cap, MIME allowlist and magic-byte checks would reach the agent
        // unscreened, up to the full payload size.
        return { ...ac, toValue: '', assetTruncated: true };
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
   * Refusals return `null` (the caller truncates), and each logs its own cause:
   * a non-asset MIME type, SVG, bytes that do not match the declared type, an
   * asset directory outside the project, a symlink at the target, or an asset
   * larger than {@link MAX_INLINE_ASSET_BYTES} that cannot be deduplicated to a
   * committed file (rather than persisting/inlining a multi-MB blob).
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

    // HACK-011: an asset write is only ever a raster image or a video.
    // Everything below is reachable from a page-controlled `src` or
    // `background-image`, so the declared type and the actual bytes must agree
    // with the allowlist before anything touches the project directory.
    //
    // The extension is derived from the MIME type and never from the caller's
    // filename. Binding the two is what stops `image/png` + `q.svg` writing
    // HTML under an `.svg` name — the first review's fix checked each half
    // separately and let the mismatch through.
    const normalizedMime = mime.trim().toLowerCase();
    // Object.hasOwn, not truthiness: MIME_EXT is a plain object, so `constructor`,
    // `__proto__`, `toString` and friends are inherited and test truthy.
    if (!Object.hasOwn(Bridge.MIME_EXT, normalizedMime)) {
      console.error(`[nco-web-editor] Refusing asset with non-asset MIME type: ${Bridge.forLog(mime)}`);
      return null;
    }
    const ext = Bridge.MIME_EXT[normalizedMime];
    // SVG is refused over the bridge (HACK-011). It is the one allowlisted type
    // that is a script-capable document rather than inert bytes, and screening
    // it with regexes does not work: namespace prefixes (`<s:script>`), entity
    // declarations, entity- or tab-obfuscated `javascript:`, and a UTF-16 BOM
    // all slip past a textual check while the browser still executes them. An
    // SVG written into `public/` is served from the dev origin, so that is
    // stored XSS on the page being edited. Screening it properly needs an XML
    // parser and an element allowlist — tracked as KL-5. Until then, refuse:
    // SVGs can be added to the repo directly, which is outside this boundary.
    if (ext === '.svg') {
      console.error('[nco-web-editor] Refusing SVG asset — SVG cannot be safely screened here (KL-5); add it to the repo directly');
      return null;
    }
    if (!Bridge.matchesMagic(ext, buffer)) {
      console.error(`[nco-web-editor] Refusing asset — bytes do not match declared type ${ext}`);
      return null;
    }

    // Determine target directory from the original src path
    const targetDir = await this.resolveAssetDir(fromValue);

    // Confine the write to the project directory. `targetDir` is inferred from a
    // page-controlled `src` attribute (resolveAssetDir), so without this a crafted
    // `../` value could steer writes outside cwd — parity with the export/import
    // paths that already call confineToProject.
    const absDir = this.confineToProject(targetDir);
    // confineToProject is lexical, so a symlinked asset directory committed in
    // the repo (`public/media -> ../../elsewhere`) passed it and the write
    // landed outside the project. This resolves symlinks before anything is
    // read, scanned or created — the dedup scan below would otherwise read
    // through the link, and `mkdir -p` would create directories beyond it.
    try {
      await this.assertRealInside(absDir);
    } catch {
      console.error(`[nco-web-editor] Refusing asset — ${Bridge.forLog(targetDir)} resolves outside the project`);
      return null;
    }

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
    if (buffer.length > Bridge.MAX_INLINE_ASSET_BYTES) {
      console.error(`[nco-web-editor] Refusing asset — over the ${Bridge.MAX_INLINE_ASSET_BYTES}-byte cap`);
      return null;
    }

    // Name the file, embedding the content hash so re-uploads are idempotent.
    const filename = this.assetFilename(hash, ext, pendingUpload?.filename);
    await mkdir(absDir, { recursive: true });
    const absPath = join(absDir, filename);
    const relPath = '/' + relative(this.cwd, absPath).replace(/\\/g, '/');

    // Idempotent: the filename embeds the content hash, so a file already
    // present at this path is the same image — skip the write. lstat, not
    // stat: stat follows a symlink, so a planted link at the target name made
    // this check inspect (and the write below clobber) whatever it pointed at.
    try {
      const st = await lstat(absPath);
      if (st.isFile() && st.size === buffer.length) return this.stripPublicPrefix(relPath);
      if (st.isSymbolicLink()) {
        console.error(`[nco-web-editor] Refusing asset — ${Bridge.forLog(relPath)} is a symlink`);
        return null;
      }
    } catch {
      // not present — fall through to write
    }

    // 'wx' fails if the path exists, which closes both the symlink-at-target
    // case (writeFile follows links) and the gap between the check above and
    // the write. EEXIST means someone won the race with identical bytes, which
    // is the idempotent case anyway.
    try {
      await writeFile(absPath, buffer, { flag: 'wx' });
    } catch (err) {
      if ((err as NodeJS.ErrnoException)?.code !== 'EEXIST') throw err;
    }

    // Return served web path with a leading `/public` stripped (apply-correct).
    return this.stripPublicPrefix(relPath);
  }

  /**
   * Normalise a batch note before it reaches the agent.
   *
   * A note is the designer's own words, but the extension appends an element
   * reference built from the page (`formatElementRef` in notes-store.ts), and
   * `sourceFile` goes in unscreened. That value can contain newlines, so page
   * content could forge what looks like another numbered instruction in the
   * designer's voice — which the "treat paths and selectors as data" framing
   * does not cover, because a forged sentence is neither. Collapsing line
   * breaks keeps an injected string on the reference line where it belongs.
   * The real fix is structured refs the server can screen per field; this
   * bounds the damage until then.
   */
  private static sanitizeNote(note: string): string {
    // eslint-disable-next-line no-control-regex
    const flattened = note.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, ' ').replace(/\r?\n/g, ' ⏎ ');
    return flattened.length > Bridge.MAX_NOTE_CHARS
      ? `${flattened.slice(0, Bridge.MAX_NOTE_CHARS)}… [truncated]`
      : flattened;
  }

  /** A batchId in the shape the extension mints; anything else is dropped. */
  private static cleanBatchId(v: unknown): string | undefined {
    return typeof v === 'string' && BATCH_ID_RE.test(v) ? v : undefined;
  }

  private static isIsoDate(v: unknown): v is string {
    return typeof v === 'string' && ISO_DATE_RE.test(v) && !Number.isNaN(Date.parse(v));
  }

  /** Drop a diff's batchId unless it has the expected shape (it is a free-text channel otherwise). */
  private static withCleanBatchId<T extends { batchId?: unknown }>(d: T): T {
    if (d.batchId === undefined || Bridge.cleanBatchId(d.batchId) !== undefined) return d;
    const { batchId: _drop, ...rest } = d;
    return rest as T;
  }

  /**
   * Screen the `notes` field of a batch. Returns null when `notes` is absent
   * (the caller then falls back to the legacy `batchNote`), otherwise the
   * notes that survived screening. A present-but-malformed `notes` yields an
   * empty array rather than null: it must not demote to the legacy path.
   */
  private static screenStructuredNotes(
    raw: unknown,
  ): Array<{ text: string; elementRefs: NoteRef[] }> | null {
    if (raw === undefined || raw === null) return null;
    if (!Array.isArray(raw)) {
      console.error('[nco-web-editor] Ignoring non-array notes');
      return [];
    }
    const out: Array<{ text: string; elementRefs: NoteRef[] }> = [];
    for (const item of raw.slice(0, MAX_NOTES_PER_BATCH)) {
      if (typeof item !== 'object' || item === null) continue;
      const rec = item as { text?: unknown; elements?: unknown };
      if (typeof rec.text !== 'string' || rec.text.trim() === '') continue;
      out.push({ text: Bridge.sanitizeNote(rec.text), elementRefs: Bridge.screenRefs(rec.elements) });
    }
    return out;
  }

  /** Screen a list of element references field by field. */
  private static screenRefs(raw: unknown): NoteRef[] {
    if (!Array.isArray(raw)) return [];
    const out: NoteRef[] = [];
    for (const item of raw.slice(0, MAX_REFS_PER_NOTE)) {
      const ref = Bridge.screenRef(item);
      if (ref) out.push(ref);
    }
    return out;
  }

  private static screenRef(raw: unknown): NoteRef | null {
    if (typeof raw !== 'object' || raw === null) return null;
    const r = raw as Record<string, unknown>;
    if (typeof r.tagName !== 'string' || typeof r.selector !== 'string') return null;
    const ref: {
      tagName: string;
      selector: string;
      textContent?: string;
      sourceFile?: string;
      sourceLine?: number;
      assetPath?: string;
    } = {
      // Kept as data, capped, with control characters and newlines flattened
      // so a value cannot start a new line of "instruction" in the output.
      tagName: Bridge.clampField(r.tagName, MAX_REF_TAGNAME_CHARS),
      selector: Bridge.clampField(r.selector, MAX_REF_SELECTOR_CHARS),
    };
    if (typeof r.textContent === 'string' && r.textContent !== '') {
      ref.textContent = Bridge.clampField(r.textContent, MAX_REF_TEXTCONTENT_CHARS);
    }
    // sourceFile is a place the agent is told to edit — the strict screen the
    // diffs get (HACK-012), not just a cap.
    if (typeof r.sourceFile === 'string' && r.sourceFile !== '') {
      if (Bridge.isPlausibleSourcePath(r.sourceFile)) {
        ref.sourceFile = r.sourceFile;
        if (typeof r.sourceLine === 'number' && Number.isInteger(r.sourceLine) && r.sourceLine >= 0 && r.sourceLine < 10_000_000) {
          ref.sourceLine = r.sourceLine;
        }
      } else {
        console.error(`[nco-web-editor] Dropping implausible note sourceFile: ${Bridge.forLog(r.sourceFile)}`);
      }
    }
    if (typeof r.assetPath === 'string' && r.assetPath !== '') {
      if (Bridge.isPlausibleAssetPath(r.assetPath)) {
        ref.assetPath = r.assetPath;
      } else {
        console.error(`[nco-web-editor] Dropping implausible note assetPath: ${Bridge.forLog(r.assetPath)}`);
      }
    }
    return ref;
  }

  /** A served asset path: root-relative, no scheme, no traversal, no odd characters. */
  private static isPlausibleAssetPath(p: string): boolean {
    if (p.length > MAX_REF_ASSETPATH_CHARS) return false;
    if (!/^\/[A-Za-z0-9_\-./@+%()[\]]*$/.test(p)) return false;
    if (p.startsWith('//')) return false; // protocol-relative URL
    // Re-check after percent-decoding (twice, to catch %252e): `/%2e%2e/x` is a
    // traversal segment to anything that decodes the path later.
    let cur = p;
    for (let i = 0; i < 3; i++) {
      if (cur.split('/').some((seg) => seg === '..')) return false;
      if (cur.includes('\\') || cur.startsWith('//')) return false;
      // eslint-disable-next-line no-control-regex
      if (/[\u0000-\u001f\u007f]/.test(cur)) return false;
      if (!cur.includes('%')) break;
      try {
        cur = decodeURIComponent(cur);
      } catch {
        return false;
      }
    }
    return true;
  }

  private static clampField(value: string, max: number): string {
    // eslint-disable-next-line no-control-regex
    const flat = value.replace(/[\u0000-\u001f\u007f\u2028\u2029]/g, ' ');
    return flat.length > max ? `${flat.slice(0, max)}…` : flat;
  }

  /**
   * Clamp an attacker-influenced string before it reaches a log line, so a
   * crafted MIME type or source path cannot inject newlines or flood stderr.
   */
  private static forLog(value: unknown): string {
    return String(value).replace(/[\r\n\t]/g, ' ').slice(0, 120);
  }

  /**
   * Check the leading bytes against the declared type's signature.
   *
   * This is a prefix check, not content validation: a real PNG header followed
   * by arbitrary bytes passes, and the `ftyp`-at-offset-4 test for mp4/avif is
   * especially loose. It is a cheap filter against an obviously mislabelled
   * payload. The control that actually matters is the extension being derived
   * from an allowlisted MIME type, so whatever is written is named as — and
   * served as — a media file.
   */
  private static matchesMagic(ext: string, buf: Buffer): boolean {
    const startsWith = (...bytes: number[]): boolean =>
      buf.length >= bytes.length && bytes.every((b, i) => buf[i] === b);
    const ascii = (off: number, str: string): boolean =>
      buf.length >= off + str.length
      && buf.subarray(off, off + str.length).toString('latin1') === str;

    switch (ext) {
      case '.png':  return startsWith(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a);
      case '.jpg':
      case '.jpeg': return startsWith(0xff, 0xd8, 0xff);
      case '.gif':  return ascii(0, 'GIF87a') || ascii(0, 'GIF89a');
      case '.webp': return ascii(0, 'RIFF') && ascii(8, 'WEBP');
      case '.avif':
      case '.mp4':  return ascii(4, 'ftyp');
      case '.webm': return startsWith(0x1a, 0x45, 0xdf, 0xa3);
      case '.ogg':  return ascii(0, 'OggS');
      case '.ico':  return startsWith(0x00, 0x00, 0x01, 0x00);
      default:      return false;
    }
  }


  /**
   * Build the persisted asset filename. When a picked filename is supplied its
   * stem seeds a readable name (`<stem>-<hash>.<ext>`); otherwise the content
   * hash names it (`uploaded-<hash>.<ext>`). The hash is always embedded so
   * re-selecting the same bytes is idempotent.
   */
  private assetFilename(hash: string, ext: string, filename?: unknown): string {
    const shortHash = hash.slice(0, 12);
    // `filename` arrives over the wire, so its type is the sender's claim. A
    // non-string used to throw here, and the throw skipped the size cap, MIME
    // allowlist and magic-byte checks on the way out (see resolveAttributeAsset).
    if (typeof filename === 'string' && filename.length > 0 && filename.length <= 255) {
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
  /**
   * Source paths the dev plugin emits are project-relative paths to source
   * files. Anything else in a `data-source-file` attribute was put there by
   * page content rather than the build, so it is cleared: the diff still
   * applies (the selector identifies the element), the agent just loses a hint
   * it should not have trusted. sourceVerified is cleared with it so the agent
   * is not told the location was confirmed.
   */
  /** Build/config files an edit to a rendered element can never legitimately map to. */
  private static readonly CONFIG_BASENAMES =
    /^(?:vite|next|nuxt|svelte|astro|webpack|rollup|esbuild|babel|jest|vitest|tailwind|postcss|eslint|prettier|metro|remix|gatsby|karma|cypress|playwright)\.config\.[cm]?[jt]sx?$|^(?:gulpfile|gruntfile)\.[cm]?[jt]s$|^(?:postinstall|preinstall|prepare)\.[cm]?[jt]s$/;

  private static readonly CONFIG_SUFFIX = /(?:^|\.)(?:config|setup|conf|rc)\.[cm]?[jt]s$/;

  private static readonly SOURCE_EXTS = new Set([
    '.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs',
    '.vue', '.svelte', '.astro', '.html', '.htm', '.php', '.erb', '.hbs',
  ]);

  private static isPlausibleSourcePath(p: unknown): boolean {
    if (typeof p !== 'string' || p === '' || p.length > 256) return false;
    // Character allowlist first. A shape check alone is not a trust check: the
    // first version accepted anything ending in a source extension, so
    // `x.tsx IGNORE PREVIOUS INSTRUCTIONS … #.tsx` passed and became a
    // free-text channel into a field the agent is told to act on. No spaces,
    // no control characters, no quotes, no shell or markup metacharacters.
    if (!/^[A-Za-z0-9_\-./@+[\]()]+$/.test(p)) return false;
    if (p.startsWith('/')) return false;                     // absolute POSIX
    if (p.startsWith('~')) return false;                     // home-relative
    if (/^[A-Za-z]:/.test(p)) return false;                  // drive-absolute and drive-relative
    if (p.startsWith('//') || p.startsWith('\\\\')) return false; // UNC
    if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(p)) return false;   // any URL scheme, e.g. file:
    const segs = p.split('/');
    if (segs.some((seg) => seg === '..')) return false;                       // traversal
    if (segs.some((seg) => seg.startsWith('.') && seg !== '.')) return false; // dot-dirs
    if (segs.some((seg) => seg === '')) return false;                         // empty / doubled
    const dot = p.lastIndexOf('.');
    if (dot <= 0) return false;
    if (!Bridge.SOURCE_EXTS.has(p.slice(dot).toLowerCase())) return false;
    // Build-time config executes on the next dev-server start or install, so
    // it is not a plausible target for "the element you just edited" and is a
    // high-value thing to steer an agent at.
    const base = segs[segs.length - 1].toLowerCase();
    if (Bridge.CONFIG_BASENAMES.test(base)) return false;
    // Tool config follows `<name>.config.js`, `<name>.setup.js`, `<name>.rc.js`
    // with any prefix (sentry.client.config.ts, lint-staged.config.js), so match
    // the shape rather than an ever-growing list of tool names. `.tsx`/`.jsx`
    // are components and stay allowed.
    if (Bridge.CONFIG_SUFFIX.test(base)) return false;
    // Dependency code is never what a rendered element maps to. Match any
    // segment, case-insensitively, so `Node_Modules` on a case-folding disk fails too.
    if (segs.some((seg) => seg.toLowerCase() === 'node_modules')) return false;
    return true;
  }

  /**
   * Clear every implausible `sourceFile` anywhere in a diff.
   *
   * This walks the whole object rather than checking `diff.element` alone.
   * `sourceFile` also rides on sibling anchors, child snapshots, note element
   * refs and script-behaviour changes — and the tool description tells the
   * agent to use the sibling ones as "the exact JSX insertion point", so
   * checking only the top-level element left the same channel open one field
   * over. Enumerating carriers invites the next one to be missed; the shape of
   * the data is what should decide.
   */
  private static withCheckedSourcePath<T>(value: T): T {
    let cleared = false;

    const walk = (node: unknown, depth: number): unknown => {
      // Depth cap. The walk is recursive and isValidDiff is shallow, so a diff
      // nested a few thousand levels deep threw RangeError here and took the
      // whole batch with it. Deep nesting is also quadratic under
      // JSON.stringify's indentation, which turned a 300 KB payload into a
      // 251 MB queue file and an unreadable tool response. A real diff is a
      // handful of levels; anything near this limit is not one.
      if (depth > Bridge.MAX_DIFF_DEPTH) {
        throw new Error(`diff nesting exceeds ${Bridge.MAX_DIFF_DEPTH} levels`);
      }
      if (Array.isArray(node)) return node.map((n) => walk(n, depth + 1));
      if (typeof node !== 'object' || node === null) return node;

      const out: Record<string, unknown> = {};
      for (const [key, val] of Object.entries(node as Record<string, unknown>)) {
        // Drop prototype-mutating keys. JSON.parse makes `__proto__` an *own*
        // property, but `out[key] = …` runs the Object.prototype setter, so the
        // value became the prototype of the cleaned copy. isValidDiff had
        // already passed on the raw object (where batchId was undefined) and
        // the poisoned batchId then resolved through the chain — reopening the
        // exact HACK-013 poison pill on the import and restore paths. Found by
        // a second review, in the walk added to fix HACK-012.
        if (key === '__proto__' || key === 'constructor' || key === 'prototype') continue;
        if (key === 'sourceFile' && !Bridge.isPlausibleSourcePath(val)) {
          // '' is the project's own "unknown source" value, so downstream code
          // already copes with it; the alternative is deleting the key and
          // breaking the type.
          if (val !== '' && val !== undefined) {
            console.error(
              `[nco-web-editor] Clearing implausible sourceFile: ${Bridge.forLog(val)}`,
            );
            cleared = true;
          }
          out[key] = '';
        } else {
          out[key] = walk(val, depth + 1);
        }
      }
      return out;
    };

    const result = walk(value, 0) as T & { sourceVerified?: boolean };
    // Do not tell the agent a location was verified when it has just been
    // thrown away.
    if (cleared && typeof result === 'object' && result !== null && 'sourceVerified' in result) {
      return { ...result, sourceVerified: false };
    }
    return result;
  }

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
    // Reject traversal segments — a page-controlled src must not steer the write
    // dir outside the inferred asset tree (defense-in-depth with confineToProject).
    const segments = dirPart.split(/[\\/]/);
    if (segments.includes('..')) return Bridge.ASSET_DIR_FALLBACK;
    // Reject dot-directories (HACK-011). confineToProject keeps the write inside
    // the repo, which is not the same as keeping it harmless: a workflow file
    // runs on push with repo secrets, and agent-config directories are read as
    // instructions on a later session. A page-controlled `src` must never select
    // one, and no legitimate asset tree is a dot-directory.
    if (segments.some((seg) => seg.startsWith('.'))) return Bridge.ASSET_DIR_FALLBACK;

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

  // guessExtFromMime was removed with HACK-011. It derived an extension from
  // the MIME sub-type, so `text/html` became `.html` and `application/php`
  // became `.php` — it was the mechanism that let a non-asset type name a file
  // written into the project. Extensions now come only from the MIME_EXT
  // allowlist. It also split on the raw sub-type, so a backslash-bearing value
  // escaped the directory confinement on Windows; that goes with it.

  // -----------------------------------------------------------------------

  /** Resolve a path and ensure it stays within the project directory. */
  private confineToProject(inputPath: string): string {
    const resolved = resolve(this.cwd, inputPath);
    if (!isInside(this.cwd, resolved)) {
      throw new Error(`Path escapes project directory: ${inputPath}`);
    }
    return resolved;
  }

  /**
   * Refuse a target that resolves outside the project once symlinks are
   * followed. {@link confineToProject} is lexical and cannot see a link.
   *
   * Walks up to the nearest ancestor that exists, so it works before the
   * target (or its directories) have been created — which is the point: it
   * must run before `mkdir -p`, which would otherwise create directories
   * beyond a link. Both sides are resolved, because the project root can sit
   * behind a link itself (on macOS `/var` is `/private/var`, so every tmpdir
   * does). A dangling link fails `realpath` and is refused.
   *
   * The message never includes the resolved path: import treats an echoed
   * path as a read oracle.
   *
   * Residual: a component swapped for a symlink between this check and the
   * open is not closed — Node has no `openat`. It needs a concurrent local
   * writer. The final component is covered separately by `wx` / `lstat`.
   */
  private async assertRealInside(absTarget: string): Promise<void> {
    let probe = absTarget;
    for (;;) {
      try {
        await lstat(probe);
        break;
      } catch (err) {
        const code = (err as NodeJS.ErrnoException)?.code;
        if (code !== 'ENOENT' && code !== 'ENOTDIR') throw err;
        const parent = dirname(probe);
        if (parent === probe) break;
        probe = parent;
      }
    }
    let realProbe: string;
    let realRoot: string;
    try {
      realProbe = await realpath(probe);
      realRoot = await realpath(this.cwd);
    } catch {
      throw new Error('escapes project after symlink resolution');
    }
    if (!isInside(realRoot, realProbe)) {
      throw new Error('escapes project after symlink resolution');
    }
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
    // Every element is indexed by extractDataUrls and trackDrift. A null or
    // primitive entry threw there, aborting the rest of the batch silently.
    d.changes.every((c) => typeof c === 'object' && c !== null) &&
    typeof d.context === 'object' && d.context !== null &&
    typeof d.status === 'string' &&
    typeof d.sourceVerified === 'boolean' &&
    // batchId must be a string when present: buildBatchesSummary sorts with
    // `b.batchId.localeCompare(a.batchId)`, so a numeric one throws there and
    // takes get_pending_visual_changes down. The queue is persisted and
    // restoreQueue used the same check, so a single poisoned diff broke the
    // main tool permanently, across restarts. Found reviewing the first fix.
    (d.batchId === undefined || typeof d.batchId === 'string')
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

/**
 * Shape a stored note for the agent. A structured note keeps the designer's
 * words (`designerText`, follow) apart from the page-derived `elementRefs`
 * (verify before acting). A legacy note is one blended string and is labelled
 * as such: nothing in it is the designer's voice we can vouch for.
 */
export function toAgentNote(note: PendingNote): AgentNote {
  if (note.source === 'structured') {
    return {
      designerText: note.text,
      elementRefs: note.elementRefs ?? [],
      receivedAt: note.receivedAt,
      batchId: note.batchId,
    };
  }
  if (note.source === 'restored') {
    return {
      untrustedRestoredText: note.text,
      elementRefs: note.elementRefs ?? [],
      receivedAt: note.receivedAt,
      batchId: note.batchId,
    };
  }
  return { untrustedLegacyText: note.text, receivedAt: note.receivedAt, batchId: note.batchId };
}
