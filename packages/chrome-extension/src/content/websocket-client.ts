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
import type { ConnectionStatus } from '../shared/types';
import { BRIDGE_PORT_NAME } from '../shared/bridge-port';
import type { ProxyToWorker, WorkerToProxy } from '../shared/bridge-port';
import { isDemoMode } from './web-env';

// ---------------------------------------------------------------------------
// Public interface
// ---------------------------------------------------------------------------

export interface WebSocketClientCallbacks {
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

/** Delay before reopening the Port after the service worker went away. */
export const PORT_RECONNECT_BASE_MS = 250;
export const PORT_RECONNECT_MAX_MS = 30_000;
/** A send with no answer from the worker in this long counts as failed. */
export const SEND_RESULT_TIMEOUT_MS = 5_000;

// ---------------------------------------------------------------------------
// WebSocketClient — a thin proxy
//
// The real socket lives in the service worker (service-worker/bridge-socket.ts)
// so a script on the page cannot open it and the server sees the extension's
// origin (KL-4). This class keeps the surface the rest of the content script
// already uses and forwards it over a chrome.runtime Port.
//
// It carries no tab identity: the service worker takes that from
// `port.sender.tab.id`.
// ---------------------------------------------------------------------------

export class WebSocketClient {
  private port: chrome.runtime.Port | null = null;
  private _status: ConnectionStatus = 'disconnected';
  private everConnected = false;
  private destroyed = false;
  /** connect() was called — the Port is reopened if the worker restarts. */
  private wanted = false;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private reconnectDelay = PORT_RECONNECT_BASE_MS;
  private nextSendReq = 0;
  private readonly pendingSends = new Map<number, { resolve: (ok: boolean) => void; timer: ReturnType<typeof setTimeout> }>();

  constructor(private readonly cb: WebSocketClientCallbacks) {}

  get status(): ConnectionStatus {
    return this._status;
  }

  /**
   * True once a peer has completed the MCP handshake in this page session.
   * Sticky across service-worker restarts: the worker's own flag resets when it
   * does, but "was connected, then dropped" is still what the UI should say.
   */
  get hasEverConnected(): boolean {
    return this.everConnected;
  }

  /** Start the connection attempt. */
  connect(): void {
    if (this.destroyed) return;
    if (isDemoMode()) {
      // Demo mode: no local MCP server to reach. Stay disconnected so the
      // UI naturally disables Apply-Changes.
      this.setStatus('disconnected');
      return;
    }
    this.wanted = true;
    this.openPort();
  }

  /**
   * Send a batch of diffs. Resolves true only when the service worker reports
   * its socket actually sent the frame to a confirmed peer; false on a refusal,
   * a Port disconnect mid-send, or no answer within SEND_RESULT_TIMEOUT_MS. The
   * caller must not clear the designer's notes on anything but true.
   */
  sendDiffBatch(
    diffs: readonly VisualDiff[],
    batchNote?: string,
    batchId?: string,
    notes?: readonly StructuredNote[],
  ): Promise<boolean> {
    if (isDemoMode()) return Promise.resolve(false);
    if (!this.port || this._status !== 'connected') return Promise.resolve(false);
    return new Promise<boolean>((resolve) => {
      const reqId = ++this.nextSendReq;
      const timer = setTimeout(() => {
        if (this.pendingSends.delete(reqId)) resolve(false);
      }, SEND_RESULT_TIMEOUT_MS);
      this.pendingSends.set(reqId, { resolve, timer });
      if (!this.post({ kind: 'send-batch', reqId, diffs, batchNote, batchId, notes })) {
        this.settleSend(reqId, false);
      }
    });
  }

  private settleSend(reqId: number, ok: boolean): void {
    const p = this.pendingSends.get(reqId);
    if (!p) return;
    this.pendingSends.delete(reqId);
    clearTimeout(p.timer);
    p.resolve(ok);
  }

  private failAllSends(): void {
    for (const reqId of [...this.pendingSends.keys()]) this.settleSend(reqId, false);
  }

  /** Ask the server for its queue state. */
  sendStatusRequest(): boolean {
    if (!this.port || this._status !== 'connected') return false;
    return this.post({ kind: 'status-request' });
  }

  /** Reset the retry schedule and attempt to reconnect now. */
  retryNow(): void {
    if (this.destroyed) return;
    if (this.port) {
      this.post({ kind: 'retry' });
      return;
    }
    this.clearReconnectTimer();
    this.reconnectDelay = PORT_RECONNECT_BASE_MS;
    if (this.wanted) this.openPort();
  }

  /** Tear down (page unload / deactivation). Disconnecting the Port closes the worker's socket. */
  destroy(): void {
    this.destroyed = true;
    this.clearReconnectTimer();
    const port = this.port;
    this.port = null;
    this.failAllSends();
    if (port) {
      try {
        port.disconnect();
      } catch {
        // already gone
      }
    }
    this.setStatus('disconnected');
  }

  // -----------------------------------------------------------------------
  // Port lifecycle
  // -----------------------------------------------------------------------

  private openPort(): void {
    if (this.destroyed || this.port) return;

    let port: chrome.runtime.Port;
    try {
      port = chrome.runtime.connect({ name: BRIDGE_PORT_NAME });
    } catch (err) {
      // Typically "Extension context invalidated" after the extension was
      // updated or reloaded. Nothing to talk to; keep trying slowly in case the
      // context comes back, and show it as disconnected.
      console.warn('[nco-web-editor] Cannot reach the extension service worker:', err);
      this.setStatus('disconnected');
      this.scheduleReconnect();
      return;
    }

    this.port = port;
    port.onMessage.addListener((msg: unknown) => {
      if (this.port !== port) return;
      this.reconnectDelay = PORT_RECONNECT_BASE_MS;
      this.handleWorkerMessage(msg);
    });
    port.onDisconnect.addListener(() => {
      if (this.port !== port) return;
      this.port = null;
      this.failAllSends();
      if (this.destroyed) return;
      // The worker went away (idle teardown, crash, extension reload). Its
      // socket went with it, so say so and reopen; the new worker connects a
      // fresh socket and reports status again.
      this.setStatus('disconnected');
      if (this.wanted) this.scheduleReconnect();
    });

    this.setStatus('connecting');
    this.post({ kind: 'connect' });
  }

  private scheduleReconnect(): void {
    if (this.destroyed || this.reconnectTimer != null) return;
    const delay = this.reconnectDelay;
    this.reconnectDelay = Math.min(this.reconnectDelay * 2, PORT_RECONNECT_MAX_MS);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.openPort();
    }, delay);
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer != null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  private post(msg: ProxyToWorker): boolean {
    if (!this.port) return false;
    try {
      this.port.postMessage(msg);
      return true;
    } catch {
      return false;
    }
  }

  // -----------------------------------------------------------------------
  // Worker -> content
  // -----------------------------------------------------------------------

  private handleWorkerMessage(raw: unknown): void {
    if (typeof raw !== 'object' || raw === null) return;
    const msg = raw as WorkerToProxy;
    switch (msg.kind) {
      case 'status':
        if (msg.everConnected) this.everConnected = true;
        this.setStatus(msg.status);
        return;
      case 'send-result':
        if (typeof msg.reqId === 'number') this.settleSend(msg.reqId, msg.ok === true);
        return;
      case 'need-pending-ids':
        this.post({ kind: 'pending-ids', reqId: msg.reqId, ids: this.cb.getPendingDiffIds() });
        return;
      case 'event':
        this.dispatchEvent(msg);
        return;
      default:
        return;
    }
  }

  private dispatchEvent(msg: Extract<WorkerToProxy, { kind: 'event' }>): void {
    switch (msg.event) {
      case 'onServerHello': this.cb.onServerHello(msg.payload); break;
      case 'onDiffAck': this.cb.onDiffAck(msg.payload); break;
      case 'onDiffApplied': this.cb.onDiffApplied(msg.payload); break;
      case 'onTokenData': this.cb.onTokenData(msg.payload); break;
      case 'onTokenUpdate': this.cb.onTokenUpdate(msg.payload); break;
      case 'onComponentData': this.cb.onComponentData(msg.payload); break;
      case 'onComponentUpdate': this.cb.onComponentUpdate(msg.payload); break;
      case 'onStatusResponse': this.cb.onStatusResponse(msg.payload); break;
      case 'onError': this.cb.onError(msg.payload); break;
      default: break;
    }
  }

  private setStatus(status: ConnectionStatus): void {
    if (this._status === status) return;
    this._status = status;
    this.cb.onStatusChange(status);
  }
}
