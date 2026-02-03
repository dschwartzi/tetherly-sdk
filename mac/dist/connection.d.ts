/**
 * Tetherly SDK - WebRTC Connection
 * Handles peer-to-peer connection for real-time messaging and media
 */
import type { Message, MediaMessage, TetherlyEvents } from './types.js';
export interface ConnectionConfig {
    signalingUrl: string;
    pairingCode: string;
    iceServers?: RTCIceServer[];
    cloudflareTurnTokenId?: string;
    cloudflareTurnApiToken?: string;
}
interface RTCIceServer {
    urls: string | string[];
    username?: string;
    credential?: string;
}
export declare class Connection {
    private signaling;
    private peerConnection;
    private dataChannel;
    private events;
    private config;
    private pendingCandidates;
    private _isConnected;
    private isConnecting;
    private iceServers;
    private turnRefreshInterval;
    private healthCheckInterval;
    private connectionTimeout;
    private lastPeerActivity;
    private isResetting;
    private lastTurnServers;
    private static readonly HEALTH_CHECK_INTERVAL_MS;
    private static readonly PEER_TIMEOUT_MS;
    private static readonly CONNECTION_TIMEOUT_MS;
    constructor(config: ConnectionConfig, events: TetherlyEvents);
    get isConnected(): boolean;
    get isSignalingConnected(): boolean;
    getLastTurnServers(): {
        urls: string;
        username: string;
        credential: string;
    }[];
    connect(): Promise<void>;
    private startHealthCheck;
    private markPeerActivity;
    private refreshTurnServers;
    disconnect(): void;
    send(message: Message): void;
    sendMedia(media: MediaMessage): void;
    sendRaw(data: string): void;
    private handleSignaling;
    private handlePeerJoined;
    private startConnectionTimeout;
    private clearConnectionTimeout;
    private safeReset;
    private handleOffer;
    private handleAnswer;
    private handleIceCandidate;
    private createPeerConnection;
    private createOffer;
    private setupDataChannel;
    private close;
}
export {};
