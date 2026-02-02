/**
 * Tetherly SDK Types
 * No LLM dependencies - pure connection, messaging, and sync
 */

export interface TetherlyConfig {
  signalingUrl: string;
  pairingCode: string;
  storePath?: string;
}

// Real-time messaging
export interface Message {
  type: string;
  payload: Record<string, unknown>;
}

export interface MediaMessage {
  type: 'media';
  mediaType: 'image' | 'video' | 'audio';
  data: string; // base64
  metadata?: Record<string, unknown>;
}

// Sync types
export interface SyncRecord {
  id: string;
  data: Record<string, unknown>;
  version: number;
  updatedAt: number;
  deletedAt?: number;
}

export interface SyncStore {
  [collection: string]: {
    [id: string]: SyncRecord;
  };
}

export interface SyncMessage {
  type: 'sync-request' | 'sync-response' | 'sync-update' | 'sync-delete';
  collection: string;
  records?: SyncRecord[];
  since?: number;
}

// Event handlers
export interface TetherlyEvents {
  onConnected?: () => void;
  onDisconnected?: () => void;
  onMessage?: (message: Message) => void;
  onMedia?: (media: MediaMessage) => void;
  onSyncUpdate?: (collection: string, record: SyncRecord) => void;
}
