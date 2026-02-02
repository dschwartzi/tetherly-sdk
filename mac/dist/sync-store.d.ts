/**
 * Tetherly SDK - Sync Store
 * Local storage with bidirectional sync support
 */
import type { SyncRecord, SyncMessage } from './types.js';
export declare class TetherlySyncStore {
    private store;
    private storePath;
    private onSyncUpdate?;
    private sendSync?;
    constructor(storePath: string);
    setSyncHandler(sendSync: (message: SyncMessage) => void): void;
    setUpdateHandler(handler: (collection: string, record: SyncRecord) => void): void;
    get(collection: string, id: string): SyncRecord | undefined;
    getAll(collection: string): SyncRecord[];
    set(collection: string, id: string, data: Record<string, unknown>): SyncRecord;
    delete(collection: string, id: string): void;
    handleSyncMessage(message: SyncMessage): void;
    requestSync(): void;
    private handleSyncRequest;
    private handleSyncUpdate;
    private load;
    private save;
}
