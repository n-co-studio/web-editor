import type { VisualDiff } from '@frontend-editor/shared';
import type { WebSocket } from 'ws';

/** A connected Chrome extension tab. */
export interface ConnectedClient {
  readonly ws: WebSocket;
  readonly tabId: string;
}

/** A batch note stored alongside pending diffs. */
export interface PendingNote {
  readonly text: string;
  readonly receivedAt: string;
}

/** Serializable shape for .frontend-editor/pending-queue.json. */
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
