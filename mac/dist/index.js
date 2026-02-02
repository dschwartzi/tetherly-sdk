/**
 * Tetherly SDK for Mac
 * Real-time connection and sync between iOS and Mac
 * No LLM dependencies - pure infrastructure
 */
import { Connection } from './connection.js';
import { TetherlySyncStore } from './sync-store.js';
export class TetherlySDK {
    connection;
    syncStore;
    events;
    constructor(config, events = {}) {
        this.events = events;
        // Initialize sync store
        const storePath = config.storePath || './tetherly-sync.json';
        this.syncStore = new TetherlySyncStore(storePath);
        // Initialize connection
        this.connection = new Connection({
            signalingUrl: config.signalingUrl,
            pairingCode: config.pairingCode,
            iceServers: config.iceServers,
        }, {
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
                    this.syncStore.handleSyncMessage(message);
                }
                else {
                    this.events.onMessage?.(message);
                }
            },
            onMedia: (media) => {
                this.events.onMedia?.(media);
            },
            onSyncUpdate: (collection, record) => {
                this.events.onSyncUpdate?.(collection, record);
            },
        });
        // Wire up sync store to send via connection
        this.syncStore.setSyncHandler((message) => {
            this.connection.send(message);
        });
        this.syncStore.setUpdateHandler((collection, record) => {
            this.events.onSyncUpdate?.(collection, record);
        });
    }
    // Connection methods
    async connect() {
        await this.connection.connect();
    }
    disconnect() {
        this.connection.disconnect();
    }
    get isConnected() {
        return this.connection.isConnected;
    }
    // Messaging methods
    send(message) {
        this.connection.send(message);
    }
    sendMedia(media) {
        this.connection.sendMedia(media);
    }
    sendRaw(data) {
        this.connection.sendRaw(data);
    }
    // Sync store methods
    get store() {
        return this.syncStore;
    }
    syncGet(collection, id) {
        return this.syncStore.get(collection, id);
    }
    syncGetAll(collection) {
        return this.syncStore.getAll(collection);
    }
    syncSet(collection, id, data) {
        return this.syncStore.set(collection, id, data);
    }
    syncDelete(collection, id) {
        this.syncStore.delete(collection, id);
    }
    isSyncMessage(message) {
        return ['sync-request', 'sync-response', 'sync-update', 'sync-delete'].includes(message.type);
    }
}
export { Connection } from './connection.js';
export { TetherlySyncStore } from './sync-store.js';
