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
    constructor(config: ConnectionConfig, events: TetherlyEvents);
    get isConnected(): boolean;
    connect(): Promise<void>;
    private refreshTurnServers;
    disconnect(): void;
    send(message: Message): void;
    sendMedia(media: MediaMessage): void;
    sendRaw(data: string): void;
    private handleSignaling;
    private handlePeerJoined;
    private handleOffer;
    private handleAnswer;
    private handleIceCandidate;
    private createPeerConnection;
    private createOffer;
    private setupDataChannel;
    private close;
}
export {};
