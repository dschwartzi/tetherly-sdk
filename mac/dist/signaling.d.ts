/**
 * Tetherly SDK - Signaling Client
 * Handles WebSocket connection to signaling server for WebRTC setup
 */
export interface SignalingEvents {
    onConnected: () => void;
    onDisconnected: () => void;
    onSignaling: (type: string, payload: unknown) => void;
}
export declare class SignalingClient {
    private ws;
    private signalingUrl;
    private pairingCode;
    private events;
    private reconnectTimeout;
    private pingInterval;
    private isConnecting;
    constructor(signalingUrl: string, pairingCode: string, events: SignalingEvents);
    connect(): Promise<void>;
    disconnect(): void;
    send(message: unknown): void;
    private scheduleReconnect;
    private clearReconnect;
    private startPing;
    private stopPing;
}
