/**
 * Tetherly SDK - Sync Store
 * Local storage with bidirectional sync support
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { dirname } from 'path';
import type { SyncRecord, SyncStore, SyncMessage } from './types.js';

export class TetherlySyncStore {
  private store: SyncStore = {};
  private storePath: string;
  private onSyncUpdate?: (collection: string, record: SyncRecord) => void;
  private sendSync?: (message: SyncMessage) => void;

  constructor(storePath: string) {
    this.storePath = storePath;
    this.load();
  }

  setSyncHandler(sendSync: (message: SyncMessage) => void): void {
    this.sendSync = sendSync;
  }

  setUpdateHandler(handler: (collection: string, record: SyncRecord) => void): void {
    this.onSyncUpdate = handler;
  }

  // Get a record
  get(collection: string, id: string): SyncRecord | undefined {
    return this.store[collection]?.[id];
  }

  // Get all records in a collection
  getAll(collection: string): SyncRecord[] {
    const coll = this.store[collection];
    if (!coll) return [];
    return Object.values(coll).filter(r => !r.deletedAt);
  }

  // Set a record (creates or updates)
  set(collection: string, id: string, data: Record<string, unknown>): SyncRecord {
    if (!this.store[collection]) {
      this.store[collection] = {};
    }

    const existing = this.store[collection][id];
    const record: SyncRecord = {
      id,
      data,
      version: (existing?.version || 0) + 1,
      updatedAt: Date.now(),
    };

    this.store[collection][id] = record;
    this.save();

    // Send sync update to peer
    this.sendSync?.({
      type: 'sync-update',
      collection,
      records: [record],
    });

    return record;
  }

  // Delete a record (soft delete)
  delete(collection: string, id: string): void {
    const existing = this.store[collection]?.[id];
    if (!existing) return;

    existing.deletedAt = Date.now();
    existing.version++;
    existing.updatedAt = Date.now();
    this.save();

    this.sendSync?.({
      type: 'sync-delete',
      collection,
      records: [existing],
    });
  }

  // Handle incoming sync message from peer
  handleSyncMessage(message: SyncMessage): void {
    switch (message.type) {
      case 'sync-request':
        this.handleSyncRequest(message);
        break;
      case 'sync-response':
      case 'sync-update':
        this.handleSyncUpdate(message);
        break;
      case 'sync-delete':
        this.handleSyncUpdate(message);
        break;
    }
  }

  // Request full sync from peer
  requestSync(): void {
    // Get the latest updatedAt across all collections
    let since = 0;
    for (const collection of Object.keys(this.store)) {
      for (const record of Object.values(this.store[collection])) {
        if (record.updatedAt > since) {
          since = record.updatedAt;
        }
      }
    }

    this.sendSync?.({
      type: 'sync-request',
      collection: '*',
      since: since > 0 ? since - 60000 : 0, // Request from 1 minute before latest
    });
  }

  private handleSyncRequest(message: SyncMessage): void {
    const since = message.since || 0;
    const records: SyncRecord[] = [];

    const collections = message.collection === '*'
      ? Object.keys(this.store)
      : [message.collection];

    for (const collection of collections) {
      const coll = this.store[collection];
      if (!coll) continue;

      for (const record of Object.values(coll)) {
        if (record.updatedAt > since) {
          records.push(record);
        }
      }

      if (records.length > 0) {
        this.sendSync?.({
          type: 'sync-response',
          collection,
          records,
        });
      }
    }
  }

  private handleSyncUpdate(message: SyncMessage): void {
    if (!message.records) return;

    for (const record of message.records) {
      if (!this.store[message.collection]) {
        this.store[message.collection] = {};
      }

      const existing = this.store[message.collection][record.id];

      // Only update if incoming is newer
      if (!existing || record.version > existing.version) {
        this.store[message.collection][record.id] = record;
        this.onSyncUpdate?.(message.collection, record);
      }
    }

    this.save();
  }

  private load(): void {
    try {
      if (existsSync(this.storePath)) {
        const data = readFileSync(this.storePath, 'utf-8');
        this.store = JSON.parse(data);
      }
    } catch (e) {
      console.error('[SDK] Failed to load store:', e);
      this.store = {};
    }
  }

  private save(): void {
    try {
      const dir = dirname(this.storePath);
      if (!existsSync(dir)) {
        mkdirSync(dir, { recursive: true });
      }
      writeFileSync(this.storePath, JSON.stringify(this.store, null, 2));
    } catch (e) {
      console.error('[SDK] Failed to save store:', e);
    }
  }
}
