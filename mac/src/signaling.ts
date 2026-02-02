/**
 * Tetherly SDK - Signaling Client
 * Handles WebSocket connection to signaling server for WebRTC setup
 */

import WebSocket from 'ws';

export interface SignalingEvents {
  onConnected: () => void;
  onDisconnected: () => void;
  onSignaling: (type: string, payload: unknown) => void;
}

export class SignalingClient {
  private ws: WebSocket | null = null;
  private signalingUrl: string;
  private pairingCode: string;
  private events: SignalingEvents;
  private reconnectTimeout: NodeJS.Timeout | null = null;
  private pingInterval: NodeJS.Timeout | null = null;
  private isConnecting = false;

  constructor(signalingUrl: string, pairingCode: string, events: SignalingEvents) {
    this.signalingUrl = signalingUrl;
    this.pairingCode = pairingCode;
    this.events = events;
  }

  connect(): Promise<void> {
    if (this.isConnecting) return Promise.resolve();
    this.isConnecting = true;

    this.stopPing();
    this.clearReconnect();

    const fullUrl = `${this.signalingUrl}?pairingCode=${this.pairingCode}`;

    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(fullUrl);

      this.ws.on('open', () => {
        this.isConnecting = false;
        this.events.onConnected();
        this.startPing();
        resolve();
      });

      this.ws.on('message', (data: string) => {
        try {
          const parsed = JSON.parse(data);
          if (parsed.type === 'ping') {
            this.send({ type: 'pong' });
          } else {
            this.events.onSignaling(parsed.type, parsed.payload);
          }
        } catch (e) {
          console.error('[SDK] Failed to parse signaling message:', e);
        }
      });

      this.ws.on('close', () => {
        this.isConnecting = false;
        this.events.onDisconnected();
        this.scheduleReconnect();
      });

      this.ws.on('error', (error: Error) => {
        console.error('[SDK] Signaling error:', error.message);
        this.isConnecting = false;
        this.ws?.close();
        reject(error);
      });
    });
  }

  disconnect(): void {
    this.stopPing();
    this.clearReconnect();
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
  }

  send(message: unknown): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(message));
    }
  }

  private scheduleReconnect(): void {
    this.clearReconnect();
    this.reconnectTimeout = setTimeout(() => {
      this.connect().catch((e) => console.error('[SDK] Reconnect failed:', e));
    }, 5000);
  }

  private clearReconnect(): void {
    if (this.reconnectTimeout) {
      clearTimeout(this.reconnectTimeout);
      this.reconnectTimeout = null;
    }
  }

  private startPing(): void {
    this.stopPing();
    this.pingInterval = setInterval(() => {
      if (this.ws?.readyState === WebSocket.OPEN) {
        this.send({ type: 'ping' });
      }
    }, 30000);
  }

  private stopPing(): void {
    if (this.pingInterval) {
      clearInterval(this.pingInterval);
      this.pingInterval = null;
    }
  }
}
