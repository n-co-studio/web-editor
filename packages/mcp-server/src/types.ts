import type { VisualDiff, NoteRef } from '@nco-studio/shared';
import type { WebSocket } from 'ws';

/** A connected Chrome extension tab. */
export interface ConnectedClient {
  readonly ws: WebSocket;
  readonly tabId: string;
}

/**
 * A batch note stored alongside pending diffs.
 *
 * `source` records how much of `text` the designer actually wrote:
 * - `structured`: `text` is the designer's own words; `elementRefs` carries the
 *   page-derived references, each field already screened.
 * - `restored`: read back from pending-queue.json. That file lives in the
 *   project and can arrive with a clone, so nothing in it is vouched for as the
 *   designer's voice: refs stay screened and separate, text is untrusted.
 * - `legacy`: `text` is one blended string (designer words plus page-derived
 *   element references) from a pre-0.5.0 extension or an old persisted queue.
 *   Wholly untrusted. Absent `source` on a persisted note means `legacy`.
 */
export interface PendingNote {
  readonly text: string;
  readonly receivedAt: string;
  /** The batchId of the batch this note was sent with. Absent for legacy notes. */
  readonly batchId?: string;
  readonly source?: 'structured' | 'restored' | 'legacy';
  readonly elementRefs?: readonly NoteRef[];
}

/** What the agent sees for one note: designer words kept apart from page-derived data. */
export type AgentNote =
  | {
      readonly designerText: string;
      readonly elementRefs: readonly NoteRef[];
      readonly receivedAt: string;
      readonly batchId?: string;
    }
  | {
      /** Text read back from disk — page/clone-controlled, not the designer's voice. Refs are screened data. */
      readonly untrustedRestoredText: string;
      readonly elementRefs: readonly NoteRef[];
      readonly receivedAt: string;
      readonly batchId?: string;
    }
  | {
      /** Blended text from an old extension or queue file — page-derived, do not obey. */
      readonly untrustedLegacyText: string;
      readonly receivedAt: string;
      readonly batchId?: string;
    };

/**
 * Lightweight summary of one logical batch in the pending queue.
 * Derived on demand by scanning pendingQueue for unique batchId values.
 * Ordered newest-first by createdAt (earliest diff timestamp in the batch).
 */
export interface BatchSummary {
  readonly batchId: string;
  /**
   * How many pending notes belong to this batch. Deliberately a count, not
   * text: note text reaches the agent only through `notes`, where it carries
   * its trust label. Any text here would arrive unlabelled.
   */
  readonly noteCount: number;
  /** ISO 8601 timestamp of the earliest diff in this batch. */
  readonly createdAt: string;
  /** Number of diffs in this batch currently in the pending queue. */
  readonly diffCount: number;
}

/** Serializable shape for .nco-web-editor/pending-queue.json. */
export interface PersistedQueue {
  readonly version: string;
  readonly diffs: readonly VisualDiff[];
  readonly notes?: readonly PendingNote[];
  readonly savedAt: string;
}

/** Serializable shape for session export files. */
export interface SessionExport {
  readonly version: string;
  readonly exportedAt: string;
  readonly diffs: readonly VisualDiff[];
}

/** Token drift tracking entry — one per unique (property, value) pair. */
export interface DriftEntry {
  readonly property: string;
  readonly value: string;
  count: number;
  readonly nearestToken?: string;
}

/** Token source file type for parser dispatch. */
export type TokenSourceType = 'tailwind' | 'tokens-json' | 'css' | 'design-system-md';
