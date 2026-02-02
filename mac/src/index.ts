/**
 * Tetherly SDK for Mac
 * Real-time connection and sync between iOS and Mac
 * No LLM dependencies - pure infrastructure
 */

import { Connection, ConnectionConfig } from './connection.js';
import { TetherlySyncStore } from './sync-store.js';
import type { Message, MediaMessage, SyncRecord, SyncMessage, TetherlyEvents } from './types.js';

export interface TetherlySDKConfig {
  signalingUrl: string;
  pairingCode: string;
  storePath?: string;
  iceServers?: Array<{ urls: string | string[]; username?: string; credential?: string }>;
  // Cloudflare TURN credentials (recommended for mobile network support)
  cloudflareTurnTokenId?: string;
  cloudflareTurnApiToken?: string;
}

export class TetherlySDK {
  private connection: Connection;
  private syncStore: TetherlySyncStore;
  private events: TetherlyEvents;

  constructor(config: TetherlySDKConfig, events: TetherlyEvents = {}) {
    this.events = events;

    // Initialize sync store
    const storePath = config.storePath || './tetherly-sync.json';
    this.syncStore = new TetherlySyncStore(storePath);

    // Initialize connection
    this.connection = new Connection(
      {
        signalingUrl: config.signalingUrl,
        pairingCode: config.pairingCode,
        iceServers: config.iceServers,
        cloudflareTurnTokenId: config.cloudflareTurnTokenId,
        cloudflareTurnApiToken: config.cloudflareTurnApiToken,
      },
      {
        onConnected: () => {
          console.log('[SDK] Connected');
          // Request sync on connect
          this.syncStore.requestSync();
          this.events.onConnected?.();
        },
        onDisconnected: () => {
          console.log('[SDK] Disconnected');
          this.events.onDisconnected?.();
        },
        onMessage: (message) => {
          // Check if it's a sync message
          if (this.isSyncMessage(message)) {
            this.syncStore.handleSyncMessage(message as unknown as SyncMessage);
          } else {
            this.events.onMessage?.(message);
          }
        },
        onMedia: (media) => {
          this.events.onMedia?.(media);
        },
        onSyncUpdate: (collection, record) => {
          this.events.onSyncUpdate?.(collection, record);
        },
      }
    );

    // Wire up sync store to send via connection
    this.syncStore.setSyncHandler((message) => {
      this.connection.send(message as unknown as Message);
    });

    this.syncStore.setUpdateHandler((collection, record) => {
      this.events.onSyncUpdate?.(collection, record);
    });
  }

  // Connection methods
  async connect(): Promise<void> {
    await this.connection.connect();
  }

  disconnect(): void {
    this.connection.disconnect();
  }

  get isConnected(): boolean {
    return this.connection.isConnected;
  }

  // Messaging methods
  send(message: Message): void {
    this.connection.send(message);
  }

  sendMedia(media: MediaMessage): void {
    this.connection.sendMedia(media);
  }

  sendRaw(data: string): void {
    this.connection.sendRaw(data);
  }

  // Sync store methods
  get store(): TetherlySyncStore {
    return this.syncStore;
  }

  syncGet(collection: string, id: string): SyncRecord | undefined {
    return this.syncStore.get(collection, id);
  }

  syncGetAll(collection: string): SyncRecord[] {
    return this.syncStore.getAll(collection);
  }

  syncSet(collection: string, id: string, data: Record<string, unknown>): SyncRecord {
    return this.syncStore.set(collection, id, data);
  }

  syncDelete(collection: string, id: string): void {
    this.syncStore.delete(collection, id);
  }

  private isSyncMessage(message: Message): boolean {
    return ['sync-request', 'sync-response', 'sync-update', 'sync-delete'].includes(message.type);
  }
}

// Re-export types
export type { 
  Message, 
  MediaMessage, 
  SyncRecord, 
  SyncMessage, 
  TetherlyEvents,
  // Session data model
  MessageRole,
  MessageType,
  ContentCategory,
  MessageMetadata,
  SessionMessage,
  Session,
} from './types.js';
export { Connection } from './connection.js';
export { TetherlySyncStore } from './sync-store.js';
