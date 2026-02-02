/**
 * Tetherly SDK for Mac
 * Real-time connection and sync between iOS and Mac
 * No LLM dependencies - pure infrastructure
 */
import { TetherlySyncStore } from './sync-store.js';
import type { Message, MediaMessage, SyncRecord, TetherlyEvents } from './types.js';
export interface TetherlySDKConfig {
    signalingUrl: string;
    pairingCode: string;
    storePath?: string;
    iceServers?: Array<{
        urls: string | string[];
        username?: string;
        credential?: string;
    }>;
}
export declare class TetherlySDK {
    private connection;
    private syncStore;
    private events;
    constructor(config: TetherlySDKConfig, events?: TetherlyEvents);
    connect(): Promise<void>;
    disconnect(): void;
    get isConnected(): boolean;
    send(message: Message): void;
    sendMedia(media: MediaMessage): void;
    sendRaw(data: string): void;
    get store(): TetherlySyncStore;
    syncGet(collection: string, id: string): SyncRecord | undefined;
    syncGetAll(collection: string): SyncRecord[];
    syncSet(collection: string, id: string, data: Record<string, unknown>): SyncRecord;
    syncDelete(collection: string, id: string): void;
    private isSyncMessage;
}
export type { Message, MediaMessage, SyncRecord, SyncMessage, TetherlyEvents } from './types.js';
export { Connection } from './connection.js';
export { TetherlySyncStore } from './sync-store.js';
