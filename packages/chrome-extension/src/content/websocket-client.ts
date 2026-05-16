import {
  PROTOCOL_VERSION,
  MessageType,
} from '@frontend-editor/shared';
import type {
  VisualDiff,
  ServerHelloPayload,
  DiffAckPayload,
  DiffAppliedPayload,
  TokenDataPayload,
  TokenUpdatePayload,
  ComponentDataPayload,
  ComponentUpdatePayload,
  StatusResponsePayload,
  ErrorPayload,
  ExtensionToServerMessage,
  ServerToExtensionMessage,
} from '@frontend-editor/shared';
import {
  WS_PORT_BASE,
  WS_PORT_RANGE,
  WS_BACKOFF_BASE_MS,
  WS_BACKOFF_MAX_MS,
  WS_MAX_RETRIES,
  WS_KEEPALIVE_INTERVAL_MS,
} from '../shared/constants';
import type { ConnectionStatus } from '../shared/types';
import { isDemoMode } from './web-env';

// ---------------------------------------------------------------------------
// Public interface
// ---------------------------------------------------------------------------

export interface WebSocketClientCallbacks {
  readonly tabId: string;
  getPendingDiffIds(): string[];
  onStatusChange(status: ConnectionStatus): void;
  onServerHello(payload: ServerHelloPayload): void;
  onDiffAck(payload: DiffAckPayload): void;
  onDiffApplied(payload: DiffAppliedPayload): void;
  onTokenData(payload: TokenDataPayload): void;
  onTokenUpdate(payload: TokenUpdatePayload): void;
  onComponentData(payload: ComponentDataPayload): void;
  onComponentUpdate(payload: ComponentUpdatePayload): void;
  onStatusResponse(payload: StatusResponsePayload): void;
  onError(payload: ErrorPayload): void;
}

// ---------------------------------------------------------------------------
// WebSocketClient
// ---------------------------------------------------------------------------

export class WebSocketClient {
  private ws: WebSocket | null = null;
  private keepaliveTimer: ReturnType<typeof setInterval> | null = null;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  private retryCount = 0;
  private destroyed = false;
  private _status: ConnectionStatus = 'disconnected';

  constructor(private readonly cb: WebSocketClientCallbacks) {}

  get status(): ConnectionStatus {
    return this._status;
  }

  /** Start the connection attempt (port scan → handshake). */
  connect(): void {
    if (this.destroyed) return;
    if (isDemoMode()) {
      // Demo mode: no local MCP server to reach. Stay disconnected so the
      // UI naturally disables Apply-Changes without spamming port scans.
      this.setStatus('disconnected');
      return;
    }
    this.setStatus('connecting');
    this.scanPorts(WS_PORT_BASE);
  }

  /** Send a batch of diffs over the WebSocket. */
  sendDiffBatch(diffs: readonly VisualDiff[], batchNote?: string): boolean {
    if (isDemoMode()) return false;
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false;
    this.send({
      type: MessageType.VISUAL_DIFF_BATCH,
      version: PROTOCOL_VERSION,
      payload: batchNote ? { diffs, batchNote } : { diffs },
    });
    return true;
  }

  /** Send a STATUS_REQUEST to query server queue state. */
  sendStatusRequest(): boolean {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false;
    this.send({
      type: MessageType.STATUS_REQUEST,
      version: PROTOCOL_VERSION,
      payload: {},
    });
    return true;
  }

  /** Tear down the client (page unload / deactivation). */
  destroy(): void {
    this.destroyed = true;
    this.clearTimers();
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
    this.setStatus('disconnected');
  }

  // -----------------------------------------------------------------------
  // Port scanning
  // -----------------------------------------------------------------------

  private scanPorts(port: number): void {
    if (this.destroyed || port >= WS_PORT_BASE + WS_PORT_RANGE) {
      // Exhausted all ports in this scan cycle
      this.scheduleRetry();
      return;
    }

    const ws = new WebSocket(`ws://localhost:${port}`);
    let settled = false;

    const timeout = setTimeout(() => {
      if (!settled) {
        settled = true;
        ws.close();
        this.scanPorts(port + 1);
      }
    }, 2_000);

    ws.addEventListener('open', () => {
      if (settled || this.destroyed) {
        ws.close();
        return;
      }
      settled = true;
      clearTimeout(timeout);
      this.handleOpen(ws, port);
    });

    ws.addEventListener('error', () => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      ws.close();
      this.scanPorts(port + 1);
    });
  }

  // -----------------------------------------------------------------------
  // Connection lifecycle
  // -----------------------------------------------------------------------

  private handleOpen(ws: WebSocket, port: number): void {
    this.ws = ws;
    this.retryCount = 0;
    this.setStatus('connected');

    console.log(`[frontend-editor] Connected to WebSocket on port ${port}`);

    // Send EXTENSION_HELLO
    this.send({
      type: MessageType.EXTENSION_HELLO,
      version: PROTOCOL_VERSION,
      payload: {
        tabId: this.cb.tabId,
        pendingDiffIds: this.cb.getPendingDiffIds(),
      },
    });

    // Start keepalive ping
    this.keepaliveTimer = setInterval(() => {
      this.send({
        type: MessageType.KEEPALIVE,
        version: PROTOCOL_VERSION,
        payload: {},
      });
    }, WS_KEEPALIVE_INTERVAL_MS);

    ws.addEventListener('message', (event) => this.handleMessage(event));

    ws.addEventListener('close', () => {
      console.log('[frontend-editor] WebSocket connection closed');
      this.ws = null;
      this.clearTimers();
      if (!this.destroyed) {
        this.setStatus('disconnected');
        this.scheduleRetry();
      }
    });

    ws.addEventListener('error', (event) => {
      console.error('[frontend-editor] WebSocket error:', event);
    });
  }

  private handleMessage(event: MessageEvent): void {
    let msg: unknown;
    try {
      msg = JSON.parse(String(event.data));
    } catch {
      console.error('[frontend-editor] Invalid WebSocket message — not JSON');
      return;
    }

    if (
      typeof msg !== 'object' ||
      msg === null ||
      !('type' in msg) ||
      !('payload' in msg)
    ) {
      console.error('[frontend-editor] Invalid WebSocket message — missing type or payload');
      return;
    }

    const typed = msg as ServerToExtensionMessage;

    switch (typed.type) {
      case MessageType.SERVER_HELLO:
        this.cb.onServerHello(typed.payload);
        break;
      case MessageType.DIFF_ACK:
        this.cb.onDiffAck(typed.payload);
        break;
      case MessageType.DIFF_APPLIED:
        this.cb.onDiffApplied(typed.payload);
        break;
      case MessageType.TOKEN_DATA:
        this.cb.onTokenData(typed.payload);
        break;
      case MessageType.TOKEN_UPDATE:
        this.cb.onTokenUpdate(typed.payload);
        break;
      case MessageType.COMPONENT_DATA:
        this.cb.onComponentData(typed.payload);
        break;
      case MessageType.COMPONENT_UPDATE:
        this.cb.onComponentUpdate(typed.payload);
        break;
      case MessageType.STATUS_RESPONSE:
        this.cb.onStatusResponse(typed.payload);
        break;
      case MessageType.ERROR:
        this.cb.onError(typed.payload);
        break;
      default:
        console.warn(
          `[frontend-editor] Unknown message type: ${(typed as { type: string }).type}`,
        );
    }
  }

  // -----------------------------------------------------------------------
  // Reconnection
  // -----------------------------------------------------------------------

  private scheduleRetry(): void {
    if (this.destroyed) return;

    this.retryCount++;
    // WS_MAX_RETRIES === 0 means unlimited retries
    if (WS_MAX_RETRIES > 0 && this.retryCount > WS_MAX_RETRIES) {
      console.error(
        `[frontend-editor] Failed to connect after ${WS_MAX_RETRIES} attempts`,
      );
      this.setStatus('error');
      return;
    }

    const delay = Math.min(
      WS_BACKOFF_BASE_MS * Math.pow(2, this.retryCount - 1),
      WS_BACKOFF_MAX_MS,
    );
    console.log(
      `[frontend-editor] Reconnecting in ${delay}ms (attempt ${this.retryCount})`,
    );

    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      this.connect();
    }, delay);
  }

  /** Reset retry counter and attempt immediate reconnect. */
  retryNow(): void {
    this.clearTimers();
    this.retryCount = 0;
    this.connect();
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  private send(msg: ExtensionToServerMessage): void {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    }
  }

  private setStatus(status: ConnectionStatus): void {
    if (this._status === status) return;
    this._status = status;
    this.cb.onStatusChange(status);
  }

  private clearTimers(): void {
    if (this.keepaliveTimer != null) {
      clearInterval(this.keepaliveTimer);
      this.keepaliveTimer = null;
    }
    if (this.retryTimer != null) {
      clearTimeout(this.retryTimer);
      this.retryTimer = null;
    }
  }
}
