/**
 * Tetherly SDK Types
 * No LLM dependencies - pure connection, messaging, and sync
 */
export interface TetherlyConfig {
    signalingUrl: string;
    pairingCode: string;
    storePath?: string;
}
export interface Message {
    type: string;
    payload: Record<string, unknown>;
}
export interface MediaMessage {
    type: 'media';
    mediaType: 'image' | 'video' | 'audio';
    data: string;
    metadata?: Record<string, unknown>;
}
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
export type MessageRole = 'user' | 'assistant' | 'system';
export type MessageType = 'text' | 'image' | 'audio' | 'video' | 'file';
export type ContentCategory = 'general' | 'receipt' | 'note' | 'document' | 'media' | 'location' | 'code';
export interface MessageMetadata {
    mediaRef?: string;
    mimeType?: string;
    category?: ContentCategory;
    subcategory?: string;
    confidence?: number;
    skills?: string[];
    extractedText?: string;
    extractedEntities?: Record<string, unknown>;
    summary?: string;
    inputTokens?: number;
    outputTokens?: number;
    projectId?: string;
    uiSessionId?: string;
}
export interface SessionMessage {
    id: string;
    timestamp: number;
    role: MessageRole;
    type: MessageType;
    content: string;
    metadata?: MessageMetadata;
}
export interface Session {
    id: string;
    createdAt: number;
    updatedAt: number;
    projectId?: string;
    projectName?: string;
    messageCount: number;
    historySummary?: string;
    historyTokens?: number;
}
export interface TetherlyEvents {
    onConnected?: () => void;
    onDisconnected?: () => void;
    onMessage?: (message: Message) => void;
    onMedia?: (media: MediaMessage) => void;
    onSyncUpdate?: (collection: string, record: SyncRecord) => void;
    onSessionMessage?: (message: SessionMessage) => void;
}
