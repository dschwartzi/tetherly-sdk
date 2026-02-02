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

// ============ Session Data Model ============
// This is the core data structure for all conversation data
// Both iOS and Mac use these types - SDK is the single source of truth

export type MessageRole = 'user' | 'assistant' | 'system';
export type MessageType = 'text' | 'image' | 'audio' | 'video' | 'file';
export type ContentCategory = 'general' | 'receipt' | 'note' | 'document' | 'media' | 'location' | 'code';

export interface MessageMetadata {
  // Media handling
  mediaRef?: string;           // Reference to stored media file
  mimeType?: string;           // e.g., "image/jpeg", "audio/wav"
  
  // Classification & processing
  category?: ContentCategory;
  subcategory?: string;        // e.g., "grocery", "restaurant" for receipts
  confidence?: number;         // Classification confidence 0-1
  skills?: string[];           // Skills that processed this ["ocr", "classifier"]
  
  // Extracted data
  extractedText?: string;      // OCR result
  extractedEntities?: Record<string, unknown>; // Structured data from entity-extract
  summary?: string;            // Summarized content (for compression)
  
  // Token tracking
  inputTokens?: number;
  outputTokens?: number;
  
  // Session context
  projectId?: string;          // For pinned project sessions
  uiSessionId?: string;        // Groups messages by UI "reset" - for display only
}

export interface SessionMessage {
  id: string;                  // UUID
  timestamp: number;           // Unix ms
  role: MessageRole;
  type: MessageType;
  content: string;             // The actual text/summary
  metadata?: MessageMetadata;
}

// Session container - represents a conversation stream
export interface Session {
  id: string;                  // Session UUID
  createdAt: number;
  updatedAt: number;
  projectId?: string;          // If pinned to a project
  projectName?: string;
  messageCount: number;
  
  // For compression - summarized history
  historySummary?: string;
  historyTokens?: number;
}

// ============ Event handlers ============

export interface TetherlyEvents {
  onConnected?: () => void;
  onDisconnected?: () => void;
  onMessage?: (message: Message) => void;
  onMedia?: (media: MediaMessage) => void;
  onSyncUpdate?: (collection: string, record: SyncRecord) => void;
  onSessionMessage?: (message: SessionMessage) => void;
}
