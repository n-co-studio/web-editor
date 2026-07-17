import {
  PROTOCOL_VERSION,
  MessageType,
} from '@nco-studio/shared';
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
} from '@nco-studio/shared';
import {
  WS_PORT_BASE,
  WS_PORT_RANGE,
  WS_BACKOFF_BASE_MS,
  WS_BACKOFF_MAX_MS,
  WS_MAX_RETRIES,
  WS_KEEPALIVE_INTERVAL_MS,
  WS_HANDSHAKE_TIMEOUT_MS,
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
  // HACK-008: a candidate connection is not "confirmed" until the peer proves it
  // speaks the MCP protocol. No identifiers are sent before confirmation.
  private handshakeConfirmed = false;
  private handshakeTimer: ReturnType<typeof setTimeout> | null = null;

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
  sendDiffBatch(diffs: readonly VisualDiff[], batchNote?: string, batchId?: string): boolean {
    if (isDemoMode()) return false;
    // HACK-008: never send diffs to a peer we have not confirmed as the MCP server.
    if (!this.handshakeConfirmed) return false;
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false;
    const payload: { diffs: readonly VisualDiff[]; batchNote?: string; batchId?: string } = { diffs };
    if (batchNote) payload.batchNote = batchNote;
    if (batchId) payload.batchId = batchId;
    this.send({
      type: MessageType.VISUAL_DIFF_BATCH,
      version: PROTOCOL_VERSION,
      payload,
    });
    return true;
  }

  /** Send a STATUS_REQUEST to query server queue state. */
  sendStatusRequest(): boolean {
    // HACK-008: don't message a peer we haven't confirmed as the MCP server
    // (parity with sendDiffBatch). The handshake probe is sent separately.
    if (!this.handshakeConfirmed) return false;
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
    this.handshakeConfirmed = false;

    console.log(`[nco-web-editor] Socket open on port ${port} — probing for MCP server`);

    ws.addEventListener('message', (event) => this.handleMessage(event));

    ws.addEventListener('close', () => {
      console.log('[nco-web-editor] WebSocket connection closed');
      const wasConfirmed = this.handshakeConfirmed;
      this.ws = null;
      this.clearTimers();
      if (!this.destroyed) {
        this.setStatus('disconnected');
        if (wasConfirmed) {
          // A confirmed MCP connection dropped — reconnect with backoff.
          this.scheduleRetry();
        } else {
          // Port was occupied by something that never identified as the MCP
          // server — keep scanning the remaining ports in this cycle.
          this.scanPorts(port + 1);
        }
      }
    });

    ws.addEventListener('error', (event) => {
      console.error('[nco-web-editor] WebSocket error:', event);
    });

    // HACK-008: do NOT disclose tabId/pendingDiffIds yet. Send an identifier-free
    // probe and wait for the peer to prove it speaks the MCP protocol. Old servers
    // answer STATUS_REQUEST with STATUS_RESPONSE; new servers additionally send a
    // proactive SERVER_HELLO on connect. Either confirms; on timeout we abandon
    // the port without ever having leaked the identifiers.
    this.send({
      type: MessageType.STATUS_REQUEST,
      version: PROTOCOL_VERSION,
      payload: {},
    });
    this.handshakeTimer = setTimeout(() => {
      if (!this.handshakeConfirmed && this.ws === ws) {
        console.warn(`[nco-web-editor] No MCP handshake on port ${port} — abandoning`);
        ws.close(); // close handler continues the scan (scanPorts(port + 1))
      }
    }, WS_HANDSHAKE_TIMEOUT_MS);
  }

  /**
   * HACK-008: promote an unconfirmed candidate connection once the peer proves it
   * is the MCP server. Only now do we disclose tabId/pendingDiffIds and go live.
   * Idempotent — safe if both a proactive SERVER_HELLO and a probe STATUS_RESPONSE
   * arrive.
   */
  private confirmHandshake(): void {
    if (this.handshakeConfirmed) return;
    this.handshakeConfirmed = true;
    if (this.handshakeTimer != null) {
      clearTimeout(this.handshakeTimer);
      this.handshakeTimer = null;
    }
    this.setStatus('connected');

    // Now that the peer is confirmed, disclose the identifiers.
    this.send({
      type: MessageType.EXTENSION_HELLO,
      version: PROTOCOL_VERSION,
      payload: {
        tabId: this.cb.tabId,
        pendingDiffIds: this.cb.getPendingDiffIds(),
      },
    });

    this.keepaliveTimer = setInterval(() => {
      this.send({
        type: MessageType.KEEPALIVE,
        version: PROTOCOL_VERSION,
        payload: {},
      });
    }, WS_KEEPALIVE_INTERVAL_MS);
  }

  /**
   * Whether a server message proves the peer speaks the MCP protocol: a proactive
   * SERVER_HELLO (carries a string protocolVersion) or a STATUS_RESPONSE to our
   * probe (carries numeric counts). Shape-checked to reject trivial non-MCP replies.
   * NOTE: not cryptographic authentication — a process that speaks the protocol can
   * still spoof this. Full peer authentication needs a shared secret (deferred
   * follow-up); this closes the leak to squatters that do not speak MCP.
   */
  private isMcpIdentification(msg: ServerToExtensionMessage): boolean {
    if (msg.type === MessageType.SERVER_HELLO) {
      const p = msg.payload as Partial<ServerHelloPayload>;
      return typeof p?.protocolVersion === 'string';
    }
    if (msg.type === MessageType.STATUS_RESPONSE) {
      const p = msg.payload as Partial<StatusResponsePayload>;
      return typeof p?.pendingCount === 'number' && typeof p?.deliveredCount === 'number';
    }
    return false;
  }

  private handleMessage(event: MessageEvent): void {
    let msg: unknown;
    try {
      msg = JSON.parse(String(event.data));
    } catch {
      console.error('[nco-web-editor] Invalid WebSocket message — not JSON');
      return;
    }

    if (
      typeof msg !== 'object' ||
      msg === null ||
      !('type' in msg) ||
      !('payload' in msg) ||
      (msg as Record<string, unknown>).payload == null
    ) {
      // Reject a null/absent payload too (parity with the server envelope check) —
      // a spoofing peer that passes the handshake could otherwise deliver
      // `{ type, payload: null }` and throw inside a payload-reading callback.
      console.error('[nco-web-editor] Invalid WebSocket message — missing type or payload');
      return;
    }

    const typed = msg as ServerToExtensionMessage;

    // HACK-008: until the peer is confirmed as the MCP server, ignore everything
    // except a valid identification message. That message confirms the peer (and
    // is consumed here, not double-processed — the authoritative queue state
    // arrives in the SERVER_HELLO sent after our EXTENSION_HELLO).
    if (!this.handshakeConfirmed) {
      if (this.isMcpIdentification(typed)) {
        this.confirmHandshake();
      }
      return;
    }

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
          `[nco-web-editor] Unknown message type: ${(typed as { type: string }).type}`,
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
        `[nco-web-editor] Failed to connect after ${WS_MAX_RETRIES} attempts`,
      );
      this.setStatus('error');
      return;
    }

    const delay = Math.min(
      WS_BACKOFF_BASE_MS * Math.pow(2, this.retryCount - 1),
      WS_BACKOFF_MAX_MS,
    );
    console.log(
      `[nco-web-editor] Reconnecting in ${delay}ms (attempt ${this.retryCount})`,
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
    if (this.handshakeTimer != null) {
      clearTimeout(this.handshakeTimer);
      this.handshakeTimer = null;
    }
  }
}
