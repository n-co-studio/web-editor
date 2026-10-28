import type { VisualDiff, DesignToken, PropDefault } from './diff.js';

/** Current protocol version. */
export const PROTOCOL_VERSION = '0.5.0' as const;

export const MessageType = {
  EXTENSION_HELLO: 'EXTENSION_HELLO',
  SERVER_HELLO: 'SERVER_HELLO',
  VISUAL_DIFF_BATCH: 'VISUAL_DIFF_BATCH',
  DIFF_ACK: 'DIFF_ACK',
  DIFF_APPLIED: 'DIFF_APPLIED',
  TOKEN_DATA: 'TOKEN_DATA',
  TOKEN_UPDATE: 'TOKEN_UPDATE',
  COMPONENT_DATA: 'COMPONENT_DATA',
  COMPONENT_UPDATE: 'COMPONENT_UPDATE',
  KEEPALIVE: 'KEEPALIVE',
  STATUS_REQUEST: 'STATUS_REQUEST',
  STATUS_RESPONSE: 'STATUS_RESPONSE',
  ERROR: 'ERROR',
} as const;

export type MessageType = (typeof MessageType)[keyof typeof MessageType];

export interface ExtensionHelloPayload {
  readonly tabId: string;
  readonly pendingDiffIds: readonly string[];
}

export interface ServerHelloPayload {
  readonly pendingDiffIds: readonly string[];
  readonly appliedDiffIds: readonly string[];
  readonly protocolVersion: string;
}

/**
 * One element a designer's note points at. Everything except the designer's
 * own `text` is read out of the page DOM, so the server screens each field
 * separately (KL-6) instead of receiving one blended string.
 */
export interface NoteRef {
  readonly tagName: string;
  readonly selector: string;
  readonly textContent?: string;
  readonly sourceFile?: string;
  readonly sourceLine?: number;
  /** Root-relative served asset path (e.g. /images/a.jpg). */
  readonly assetPath?: string;
}

/** A designer note: their own words plus the elements it refers to. */
export interface StructuredNote {
  readonly text: string;
  readonly elements: readonly NoteRef[];
}

export interface VisualDiffBatchPayload {
  readonly diffs: readonly VisualDiff[];
  /**
   * LEGACY. One blended string of the designer's words plus page-derived
   * element references. Kept only so a pre-0.5.0 server still receives notes;
   * slated for removal in a later protocol version. A 0.5.0+ server ignores it
   * whenever `notes` is present, and treats it as wholly page-derived
   * (untrusted) when it is the only note field.
   */
  readonly batchNote?: string;
  /**
   * Structured notes (protocol 0.5.0). Additive-optional: the designer's words
   * (`text`) are kept apart from the page-derived `elements` so the server can
   * screen each field and the agent can be told which to follow and which to
   * verify.
   */
  readonly notes?: readonly StructuredNote[];
  /**
   * Batch identity shared by all diffs in this dispatch. Matches the
   * `batchId` stamped on each `VisualDiff` in `diffs`. Additive-optional;
   * absent from pre-batchId extension versions. No WS_PROTOCOL_VERSION bump.
   */
  readonly batchId?: string;
}

export interface DiffAckPayload {
  readonly diffIds: readonly string[];
}

export interface TokenSourceStatus {
  readonly file: string;
  readonly status: 'parsed' | 'error' | 'not_found';
  readonly error?: string;
  readonly tokenCount: number;
}

export interface TokenDataPayload {
  readonly tokens: readonly DesignToken[];
  readonly sources: readonly TokenSourceStatus[];
}

export interface TokenUpdatePayload {
  readonly tokens: readonly DesignToken[];
  readonly sources?: readonly TokenSourceStatus[];
}

/**
 * A project-local React component discovered by the MCP server.
 * Pushed to extensions via COMPONENT_DATA / COMPONENT_UPDATE and returned
 * by the `get_project_components` MCP tool.
 */
export interface ProjectComponent {
  readonly componentName: string;
  readonly importPath: string;
  readonly exportType: 'named' | 'default';
  readonly props: readonly PropDefault[];
  readonly source: 'local';
}

export interface ComponentSourceStatus {
  readonly file: string;
  readonly status: 'parsed' | 'error';
  readonly error?: string;
  readonly componentCount: number;
}

export interface ComponentDataPayload {
  readonly components: readonly ProjectComponent[];
  readonly sourceCount: number;
  readonly failedCount: number;
}

export interface ComponentUpdatePayload {
  readonly components: readonly ProjectComponent[];
  readonly sourceCount: number;
  readonly failedCount: number;
}

export interface KeepalivePayload {}

export interface ErrorPayload {
  readonly code: string;
  readonly message: string;
}

export interface DiffAppliedPayload {
  readonly diffIds: readonly string[];
}

export interface StatusRequestPayload {}

export interface DiffServerStatus {
  readonly id: string;
  readonly serverStatus: 'pending' | 'delivered' | 'applied' | 'rejected';
}

export interface StatusResponsePayload {
  readonly pendingCount: number;
  readonly deliveredCount: number;
  readonly lastToolCallAt: string | null;
  readonly perDiff: readonly DiffServerStatus[];
}

interface BaseMessage<T extends MessageType, P> {
  readonly type: T;
  readonly version: string;
  readonly payload: P;
}

export type ExtensionHelloMessage = BaseMessage<typeof MessageType.EXTENSION_HELLO, ExtensionHelloPayload>;
export type ServerHelloMessage = BaseMessage<typeof MessageType.SERVER_HELLO, ServerHelloPayload>;
export type VisualDiffBatchMessage = BaseMessage<typeof MessageType.VISUAL_DIFF_BATCH, VisualDiffBatchPayload>;
export type DiffAckMessage = BaseMessage<typeof MessageType.DIFF_ACK, DiffAckPayload>;
export type TokenDataMessage = BaseMessage<typeof MessageType.TOKEN_DATA, TokenDataPayload>;
export type TokenUpdateMessage = BaseMessage<typeof MessageType.TOKEN_UPDATE, TokenUpdatePayload>;
export type ComponentDataMessage = BaseMessage<typeof MessageType.COMPONENT_DATA, ComponentDataPayload>;
export type ComponentUpdateMessage = BaseMessage<typeof MessageType.COMPONENT_UPDATE, ComponentUpdatePayload>;
export type KeepaliveMessage = BaseMessage<typeof MessageType.KEEPALIVE, KeepalivePayload>;
export type ErrorMessage = BaseMessage<typeof MessageType.ERROR, ErrorPayload>;
export type DiffAppliedMessage = BaseMessage<typeof MessageType.DIFF_APPLIED, DiffAppliedPayload>;
export type StatusRequestMessage = BaseMessage<typeof MessageType.STATUS_REQUEST, StatusRequestPayload>;
export type StatusResponseMessage = BaseMessage<typeof MessageType.STATUS_RESPONSE, StatusResponsePayload>;

/** Discriminated union of all WebSocket messages. */
export type WebSocketMessage =
  | ExtensionHelloMessage
  | ServerHelloMessage
  | VisualDiffBatchMessage
  | DiffAckMessage
  | DiffAppliedMessage
  | TokenDataMessage
  | TokenUpdateMessage
  | ComponentDataMessage
  | ComponentUpdateMessage
  | KeepaliveMessage
  | StatusRequestMessage
  | StatusResponseMessage
  | ErrorMessage;

/** Messages sent from extension to server. */
export type ExtensionToServerMessage =
  | ExtensionHelloMessage
  | VisualDiffBatchMessage
  | KeepaliveMessage
  | StatusRequestMessage
  | ErrorMessage;

/** Messages sent from server to extension. */
export type ServerToExtensionMessage =
  | ServerHelloMessage
  | DiffAckMessage
  | DiffAppliedMessage
  | TokenDataMessage
  | TokenUpdateMessage
  | ComponentDataMessage
  | ComponentUpdateMessage
  | StatusResponseMessage
  | ErrorMessage;
