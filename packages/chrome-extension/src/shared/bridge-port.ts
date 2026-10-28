/**
 * Messages on the chrome.runtime Port between the content script and the
 * service worker, which owns the WebSocket to the MCP server (KL-4).
 *
 * Nothing here carries a tab identity. The service worker derives the tab from
 * `port.sender.tab.id` and ignores any `tabId` that appears in a message.
 */

import type {
  VisualDiff,
  StructuredNote,
  ServerHelloPayload,
  DiffAckPayload,
  DiffAppliedPayload,
  TokenDataPayload,
  TokenUpdatePayload,
  ComponentDataPayload,
  ComponentUpdatePayload,
  StatusResponsePayload,
  ErrorPayload,
} from '@nco-studio/shared';
import type { ConnectionStatus } from './types';

export const BRIDGE_PORT_NAME = 'nco-bridge';

/** Content script -> service worker. */
export type ProxyToWorker =
  | { readonly kind: 'connect' }
  | { readonly kind: 'retry' }
  | { readonly kind: 'status-request' }
  | {
      readonly kind: 'send-batch';
      /** Echoed in the worker's `send-result`; the proxy resolves its promise on it. */
      readonly reqId: number;
      readonly diffs: readonly VisualDiff[];
      readonly batchNote?: string;
      readonly batchId?: string;
      readonly notes?: readonly StructuredNote[];
    }
  | { readonly kind: 'pending-ids'; readonly reqId: number; readonly ids: readonly string[] };

/** Server events relayed to the content script, keyed by callback name. */
export type RelayedEvent =
  | { readonly event: 'onServerHello'; readonly payload: ServerHelloPayload }
  | { readonly event: 'onDiffAck'; readonly payload: DiffAckPayload }
  | { readonly event: 'onDiffApplied'; readonly payload: DiffAppliedPayload }
  | { readonly event: 'onTokenData'; readonly payload: TokenDataPayload }
  | { readonly event: 'onTokenUpdate'; readonly payload: TokenUpdatePayload }
  | { readonly event: 'onComponentData'; readonly payload: ComponentDataPayload }
  | { readonly event: 'onComponentUpdate'; readonly payload: ComponentUpdatePayload }
  | { readonly event: 'onStatusResponse'; readonly payload: StatusResponsePayload }
  | { readonly event: 'onError'; readonly payload: ErrorPayload };

/** Service worker -> content script. */
export type WorkerToProxy =
  | { readonly kind: 'status'; readonly status: ConnectionStatus; readonly everConnected: boolean }
  | { readonly kind: 'need-pending-ids'; readonly reqId: number }
  /** The socket's real answer to a send-batch: true only if the frame went to a confirmed peer. */
  | { readonly kind: 'send-result'; readonly reqId: number; readonly ok: boolean }
  | ({ readonly kind: 'event' } & RelayedEvent);
