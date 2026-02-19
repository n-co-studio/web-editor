export type {
  BoundingRect,
  ElementInfo,
  PropertyChange,
  PageContext,
  DiffStatus,
  VisualDiff,
  TokenCategory,
  DesignToken,
} from './diff.js';

export { PROTOCOL_VERSION, MessageType } from './protocol.js';

export type {
  ExtensionHelloPayload,
  ServerHelloPayload,
  VisualDiffBatchPayload,
  DiffAckPayload,
  TokenSourceStatus,
  TokenDataPayload,
  TokenUpdatePayload,
  KeepalivePayload,
  ErrorPayload,
  ExtensionHelloMessage,
  ServerHelloMessage,
  VisualDiffBatchMessage,
  DiffAckMessage,
  TokenDataMessage,
  TokenUpdateMessage,
  KeepaliveMessage,
  ErrorMessage,
  WebSocketMessage,
  ExtensionToServerMessage,
  ServerToExtensionMessage,
} from './protocol.js';
