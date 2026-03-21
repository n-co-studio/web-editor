import type { ElementInfo, VisualDiff } from '@frontend-editor/shared';

// ---------------------------------------------------------------------------
// Extension state
// ---------------------------------------------------------------------------

export type ExtensionMode = 'inactive' | 'selecting' | 'editing' | 'paused';

export type ConnectionStatus = 'disconnected' | 'connecting' | 'connected' | 'error';

export type EditMode = 'cursor' | 'spacing' | 'dimensions' | 'typography' | 'colors' | 'border-radius' | 'position' | 'reorder' | 'reparent' | 'insert' | 'text' | 'media' | 'effects' | 'appearance';

export type InsertState = 'scanning' | 'configuring' | 'committed';

export type InspectorMode = 'devtools';

// ---------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------

export type SelectionState =
  | { kind: 'none' }
  | { kind: 'hovering'; element: Element; rect: DOMRect }
  | { kind: 'selected'; element: Element; info: ElementInfo; rect: DOMRect }
  | { kind: 'stale'; info: ElementInfo; lastRect: DOMRect };

export interface PanelPosition {
  readonly x: number;
  readonly y: number;
}

// ---------------------------------------------------------------------------
// Editor state (top-level)
// ---------------------------------------------------------------------------

export interface EditorState {
  mode: ExtensionMode;
  selection: SelectionState;
  activeEditMode: EditMode | null;
  connectionStatus: ConnectionStatus;
  pendingCount: number;
  tokensLoaded: boolean;
  panelPosition: PanelPosition | null;
}

// ---------------------------------------------------------------------------
// Batching
// ---------------------------------------------------------------------------

export type DiffLifecycle = 'pending' | 'sent' | 'applied';

export interface PendingEdit {
  readonly diffId: string;
  readonly diff: VisualDiff;
  removedAt?: number;
  lifecycleStatus?: DiffLifecycle;
  sentAt?: number;
  copiedToClipboard?: boolean;
  copiedAt?: number;
}

// ---------------------------------------------------------------------------
// Chrome messaging (content ↔ service-worker)
// ---------------------------------------------------------------------------

export type ChromeMessageType = 'TOGGLE_EXTENSION' | 'GET_STATE' | 'UPDATE_BADGE' | 'CAPTURE_VIEWPORT';

export interface ChromeMessage {
  readonly type: ChromeMessageType;
  readonly payload?: unknown;
}
