/**
 * Tetherly SDK - WebRTC Connection
 * Handles peer-to-peer connection for real-time messaging and media
 */
import { RTCPeerConnection, RTCSessionDescription, RTCIceCandidate, } from 'werift';
import { SignalingClient } from './signaling.js';
// STUN servers (fast, for local network)
const STUN_SERVERS = [
    { urls: 'stun:stun.l.google.com:19302' },
    { urls: 'stun:stun1.l.google.com:19302' },
    { urls: 'stun:stun.cloudflare.com:3478' },
];
// Fetch Cloudflare TURN credentials (they expire, so fetch fresh)
async function fetchCloudflareTurnServers(tokenId, apiToken) {
    if (!tokenId || !apiToken) {
        console.log('[SDK] No Cloudflare TURN credentials - mobile connections may fail');
        return [];
    }
    try {
        const response = await fetch(`https://rtc.live.cloudflare.com/v1/turn/keys/${tokenId}/credentials/generate`, {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${apiToken}`,
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({ ttl: 86400 }), // 24 hour TTL
        });
        if (!response.ok) {
            console.error(`[SDK] Cloudflare TURN API error: ${response.status}`);
            return [];
        }
        const data = await response.json();
        if (data.iceServers && data.iceServers.urls) {
            console.log(`[SDK] Got ${data.iceServers.urls.length} Cloudflare TURN URLs`);
            return data.iceServers.urls.map(url => ({
                urls: url,
                username: data.iceServers.username,
                credential: data.iceServers.credential,
            }));
        }
    }
    catch (error) {
        console.error(`[SDK] Failed to fetch Cloudflare TURN: ${error}`);
    }
    return [];
}
export class Connection {
    signaling;
    peerConnection = null;
    dataChannel = null;
    events;
    config;
    pendingCandidates = [];
    _isConnected = false;
    isConnecting = false; // Prevent concurrent connection attempts
    iceServers = STUN_SERVERS;
    turnRefreshInterval = null;
    healthCheckInterval = null;
    connectionTimeout = null;
    lastPeerActivity = Date.now();
    isResetting = false;
    lastTurnServers = [];
    static HEALTH_CHECK_INTERVAL_MS = 10000; // Check every 10s
    static PEER_TIMEOUT_MS = 120000; // Consider dead after 2 min no activity
    static CONNECTION_TIMEOUT_MS = 30000; // 30s to establish connection
    constructor(config, events) {
        this.config = config;
        this.events = events;
        this.signaling = new SignalingClient(config.signalingUrl, config.pairingCode, {
            onConnected: () => console.log('[SDK] Signaling connected'),
            onDisconnected: () => console.log('[SDK] Signaling disconnected'),
            onSignaling: (type, payload) => this.handleSignaling(type, payload),
        });
    }
    get isConnected() {
        return this._isConnected;
    }
    get isSignalingConnected() {
        return this.signaling.isConnected;
    }
    // Get the last fetched TURN servers (for sending to iOS)
    getLastTurnServers() {
        return this.lastTurnServers;
    }
    async connect() {
        // Fetch Cloudflare TURN servers if credentials provided
        if (this.config.cloudflareTurnTokenId && this.config.cloudflareTurnApiToken) {
            await this.refreshTurnServers();
            // Refresh TURN credentials every 12 hours (they expire after 24h)
            this.turnRefreshInterval = setInterval(async () => {
                console.log('[SDK] Refreshing TURN credentials...');
                await this.refreshTurnServers();
            }, 12 * 60 * 60 * 1000);
        }
        else {
            console.log('[SDK] No Cloudflare TURN configured - using STUN only');
        }
        // Start health check loop
        this.startHealthCheck();
        await this.signaling.connect();
    }
    startHealthCheck() {
        if (this.healthCheckInterval)
            return;
        this.healthCheckInterval = setInterval(() => {
            // Check signaling health
            if (!this.signaling.isConnected) {
                console.log('[SDK] Health check: signaling down, reconnecting...');
                this.signaling.connect().catch(e => console.error('[SDK] Reconnect failed:', e));
                return;
            }
            // Check if peer connection is stale (no activity for too long)
            if (this._isConnected) {
                const timeSinceActivity = Date.now() - this.lastPeerActivity;
                if (timeSinceActivity > Connection.PEER_TIMEOUT_MS) {
                    console.log(`[SDK] Health check: peer stale (${Math.round(timeSinceActivity / 1000)}s), resetting...`);
                    this.close();
                    // Signaling will trigger new peer-joined when iOS reconnects
                }
            }
        }, Connection.HEALTH_CHECK_INTERVAL_MS);
    }
    // Call this whenever we receive data from peer
    markPeerActivity() {
        this.lastPeerActivity = Date.now();
    }
    async refreshTurnServers() {
        const turnServers = await fetchCloudflareTurnServers(this.config.cloudflareTurnTokenId, this.config.cloudflareTurnApiToken);
        if (turnServers.length > 0) {
            this.iceServers = [...STUN_SERVERS, ...turnServers];
            // Store for sending to iOS
            this.lastTurnServers = turnServers.map(s => ({
                urls: s.urls,
                username: s.username || '',
                credential: s.credential || '',
            }));
            console.log(`[SDK] ICE servers: ${this.iceServers.length} total (${turnServers.length} TURN)`);
        }
        else {
            this.lastTurnServers = [];
        }
    }
    disconnect() {
        if (this.turnRefreshInterval) {
            clearInterval(this.turnRefreshInterval);
            this.turnRefreshInterval = null;
        }
        if (this.healthCheckInterval) {
            clearInterval(this.healthCheckInterval);
            this.healthCheckInterval = null;
        }
        this.close();
        this.signaling.disconnect();
    }
    send(message) {
        if (this.dataChannel?.readyState === 'open') {
            this.dataChannel.send(JSON.stringify(message));
        }
    }
    sendMedia(media) {
        this.send(media);
    }
    sendRaw(data) {
        if (this.dataChannel?.readyState === 'open') {
            this.dataChannel.send(data);
        }
    }
    async handleSignaling(type, payload) {
        try {
            switch (type) {
                case 'peer-joined':
                    if (this._isConnected && this.dataChannel) {
                        console.log('[SDK] Ignoring peer-joined - already connected');
                        return;
                    }
                    await this.handlePeerJoined();
                    break;
                case 'peer-left':
                    this.close();
                    break;
                case 'sdp-offer':
                    await this.handleOffer(payload);
                    break;
                case 'sdp-answer':
                    await this.handleAnswer(payload);
                    break;
                case 'ice-candidate':
                    await this.handleIceCandidate(payload);
                    break;
            }
        }
        catch (error) {
            console.error('[SDK] Signaling error:', error);
        }
    }
    async handlePeerJoined() {
        // Prevent concurrent connection attempts
        if (this.isConnecting) {
            console.log('[SDK] Already connecting - ignoring peer-joined');
            return;
        }
        console.log('[SDK] Peer joined - creating offer');
        this.isConnecting = true;
        try {
            this.close();
            this.createPeerConnection();
            this.startConnectionTimeout();
            await this.createOffer();
        }
        catch (error) {
            console.error('[SDK] Error in handlePeerJoined:', error);
        }
        finally {
            this.isConnecting = false;
        }
    }
    startConnectionTimeout() {
        this.clearConnectionTimeout();
        this.connectionTimeout = setTimeout(() => {
            if (!this._isConnected && this.peerConnection) {
                console.log('[SDK] Connection timeout - resetting for retry');
                this.safeReset();
            }
        }, Connection.CONNECTION_TIMEOUT_MS);
    }
    clearConnectionTimeout() {
        if (this.connectionTimeout) {
            clearTimeout(this.connectionTimeout);
            this.connectionTimeout = null;
        }
    }
    safeReset() {
        if (this.isResetting) {
            console.log('[SDK] Reset already in progress, skipping');
            return;
        }
        this.isResetting = true;
        this.close();
        setTimeout(() => {
            this.isResetting = false;
        }, 1000);
    }
    async handleOffer(payload) {
        console.log('[SDK] Received offer');
        if (!this.peerConnection) {
            this.createPeerConnection();
        }
        await this.peerConnection.setRemoteDescription(new RTCSessionDescription(payload.sdp, 'offer'));
        for (const candidate of this.pendingCandidates) {
            await this.peerConnection.addIceCandidate(candidate);
        }
        this.pendingCandidates = [];
        const answer = await this.peerConnection.createAnswer();
        await this.peerConnection.setLocalDescription(answer);
        this.signaling.send({
            type: 'sdp-answer',
            payload: { sdp: answer.sdp },
        });
    }
    async handleAnswer(payload) {
        console.log('[SDK] Received answer');
        if (!this.peerConnection)
            return;
        await this.peerConnection.setRemoteDescription(new RTCSessionDescription(payload.sdp, 'answer'));
        for (const candidate of this.pendingCandidates) {
            await this.peerConnection.addIceCandidate(candidate);
        }
        this.pendingCandidates = [];
    }
    async handleIceCandidate(payload) {
        const candidate = new RTCIceCandidate({
            candidate: payload.candidate,
            sdpMid: payload.sdpMid,
            sdpMLineIndex: payload.sdpMLineIndex,
        });
        if (this.peerConnection?.remoteDescription) {
            await this.peerConnection.addIceCandidate(candidate);
        }
        else {
            this.pendingCandidates.push(candidate);
        }
    }
    createPeerConnection() {
        const iceServers = this.config.iceServers || this.iceServers;
        const turnCount = iceServers.filter(s => String(s.urls).includes('turn')).length;
        console.log(`[SDK] Using ${iceServers.length} ICE servers (${turnCount} TURN)`);
        if (turnCount === 0) {
            console.warn('[SDK] WARNING: No TURN servers - mobile connections will likely fail!');
        }
        this.peerConnection = new RTCPeerConnection({
            iceServers: iceServers,
        });
        this.peerConnection.onIceCandidate.subscribe((candidate) => {
            if (candidate) {
                this.signaling.send({
                    type: 'ice-candidate',
                    payload: {
                        candidate: candidate.candidate,
                        sdpMid: candidate.sdpMid,
                        sdpMLineIndex: candidate.sdpMLineIndex,
                    },
                });
            }
        });
        this.peerConnection.connectionStateChange.subscribe((state) => {
            console.log('[SDK] Connection state:', state);
            if (state === 'connected') {
                this._isConnected = true;
                this.events.onConnected?.();
            }
            else if (state === 'failed' || state === 'closed') {
                if (this._isConnected) {
                    this._isConnected = false;
                    this.events.onDisconnected?.();
                }
            }
        });
        this.peerConnection.ondatachannel = (event) => {
            console.log('[SDK] Received data channel');
            this.setupDataChannel(event.channel);
        };
    }
    async createOffer() {
        const pc = this.peerConnection;
        if (!pc) {
            console.log('[SDK] No peer connection for createOffer');
            return;
        }
        this.dataChannel = pc.createDataChannel('tetherly', {
            ordered: true,
        });
        this.setupDataChannel(this.dataChannel);
        const offer = await pc.createOffer();
        // Check again in case connection was closed during async operation
        if (!this.peerConnection || this.peerConnection !== pc) {
            console.log('[SDK] Peer connection changed during offer creation');
            return;
        }
        await pc.setLocalDescription(offer);
        this.signaling.send({
            type: 'sdp-offer',
            payload: { sdp: offer.sdp },
        });
    }
    setupDataChannel(channel) {
        this.dataChannel = channel;
        channel.onopen = () => {
            console.log('[SDK] Data channel open');
            this.clearConnectionTimeout();
            this._isConnected = true;
            this.isResetting = false;
            this.events.onConnected?.();
        };
        channel.onclose = () => {
            console.log('[SDK] Data channel closed');
            if (this._isConnected) {
                this._isConnected = false;
                this.events.onDisconnected?.();
            }
        };
        channel.onmessage = (event) => {
            // Mark activity for health check
            this.markPeerActivity();
            const data = typeof event.data === 'string'
                ? event.data
                : event.data.toString('utf-8');
            try {
                const message = JSON.parse(data);
                if (message.type === 'media') {
                    this.events.onMedia?.(message);
                }
                else {
                    this.events.onMessage?.(message);
                }
            }
            catch {
                // Raw string message
                this.events.onMessage?.({ type: 'raw', payload: { data } });
            }
        };
    }
    close() {
        this.clearConnectionTimeout();
        try {
            this.dataChannel?.close();
        }
        catch (e) { /* ignore */ }
        this.dataChannel = null;
        try {
            this.peerConnection?.close();
        }
        catch (e) { /* ignore */ }
        this.peerConnection = null;
        this._isConnected = false;
        this.pendingCandidates = [];
    }
}
