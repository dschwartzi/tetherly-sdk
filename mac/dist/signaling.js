/**
 * Tetherly SDK - Signaling Client
 * Handles WebSocket connection to signaling server for WebRTC setup
 */
import WebSocket from 'ws';
export class SignalingClient {
    ws = null;
    signalingUrl;
    pairingCode;
    events;
    reconnectTimeout = null;
    pingInterval = null;
    isConnecting = false;
    constructor(signalingUrl, pairingCode, events) {
        this.signalingUrl = signalingUrl;
        this.pairingCode = pairingCode;
        this.events = events;
    }
    connect() {
        if (this.isConnecting)
            return Promise.resolve();
        this.isConnecting = true;
        this.stopPing();
        this.clearReconnect();
        const fullUrl = `${this.signalingUrl}?pairingCode=${this.pairingCode}&type=agent`;
        return new Promise((resolve, reject) => {
            this.ws = new WebSocket(fullUrl);
            this.ws.on('open', () => {
                this.isConnecting = false;
                // Send ready message - required by signaling server before it forwards peer notifications
                this.send({ type: 'ready' });
                this.events.onConnected();
                this.startPing();
                resolve();
            });
            this.ws.on('message', (data) => {
                try {
                    const parsed = JSON.parse(data);
                    if (parsed.type === 'ping') {
                        this.send({ type: 'pong' });
                    }
                    else {
                        this.events.onSignaling(parsed.type, parsed.payload);
                    }
                }
                catch (e) {
                    console.error('[SDK] Failed to parse signaling message:', e);
                }
            });
            this.ws.on('close', () => {
                this.isConnecting = false;
                this.events.onDisconnected();
                this.scheduleReconnect();
            });
            this.ws.on('error', (error) => {
                console.error('[SDK] Signaling error:', error.message);
                this.isConnecting = false;
                this.ws?.close();
                reject(error);
            });
        });
    }
    disconnect() {
        this.stopPing();
        this.clearReconnect();
        if (this.ws) {
            this.ws.close();
            this.ws = null;
        }
    }
    send(message) {
        if (this.ws?.readyState === WebSocket.OPEN) {
            this.ws.send(JSON.stringify(message));
        }
    }
    scheduleReconnect() {
        this.clearReconnect();
        this.reconnectTimeout = setTimeout(() => {
            this.connect().catch((e) => console.error('[SDK] Reconnect failed:', e));
        }, 5000);
    }
    clearReconnect() {
        if (this.reconnectTimeout) {
            clearTimeout(this.reconnectTimeout);
            this.reconnectTimeout = null;
        }
    }
    startPing() {
        this.stopPing();
        this.pingInterval = setInterval(() => {
            if (this.ws?.readyState === WebSocket.OPEN) {
                this.send({ type: 'ping' });
            }
        }, 30000);
    }
    stopPing() {
        if (this.pingInterval) {
            clearInterval(this.pingInterval);
            this.pingInterval = null;
        }
    }
}
