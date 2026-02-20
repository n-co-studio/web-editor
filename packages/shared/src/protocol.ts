import type { VisualDiff, DesignToken } from './diff.js';

/** Current protocol version. */
export const PROTOCOL_VERSION = '0.1.0' as const;

export const MessageType = {
  EXTENSION_HELLO: 'EXTENSION_HELLO',
  SERVER_HELLO: 'SERVER_HELLO',
  VISUAL_DIFF_BATCH: 'VISUAL_DIFF_BATCH',
  DIFF_ACK: 'DIFF_ACK',
  TOKEN_DATA: 'TOKEN_DATA',
  TOKEN_UPDATE: 'TOKEN_UPDATE',
  KEEPALIVE: 'KEEPALIVE',
  ERROR: 'ERROR',
} as const;

export type MessageType = (typeof MessageType)[keyof typeof MessageType];

export interface ExtensionHelloPayload {
  readonly tabId: string;
  readonly pendingDiffIds: readonly string[];
}

export interface ServerHelloPayload {
  readonly knownDiffIds: readonly string[];
  readonly protocolVersion: string;
}

export interface VisualDiffBatchPayload {
  readonly diffs: readonly VisualDiff[];
  /** Optional operator note describing intent for this batch. */
  readonly batchNote?: string;
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

export interface KeepalivePayload {}

export interface ErrorPayload {
  readonly code: string;
  readonly message: string;
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
export type KeepaliveMessage = BaseMessage<typeof MessageType.KEEPALIVE, KeepalivePayload>;
export type ErrorMessage = BaseMessage<typeof MessageType.ERROR, ErrorPayload>;

/** Discriminated union of all WebSocket messages. */
export type WebSocketMessage =
  | ExtensionHelloMessage
  | ServerHelloMessage
  | VisualDiffBatchMessage
  | DiffAckMessage
  | TokenDataMessage
  | TokenUpdateMessage
  | KeepaliveMessage
  | ErrorMessage;

/** Messages sent from extension to server. */
export type ExtensionToServerMessage =
  | ExtensionHelloMessage
  | VisualDiffBatchMessage
  | KeepaliveMessage
  | ErrorMessage;

/** Messages sent from server to extension. */
export type ServerToExtensionMessage =
  | ServerHelloMessage
  | DiffAckMessage
  | TokenDataMessage
  | TokenUpdateMessage
  | ErrorMessage;
