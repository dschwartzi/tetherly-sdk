/**
 * Tetherly SDK - WebRTC Connection
 * Handles peer-to-peer connection for real-time messaging and media
 */
import { RTCPeerConnection, RTCSessionDescription, RTCIceCandidate, } from 'werift';
import { SignalingClient } from './signaling.js';
export class Connection {
    signaling;
    peerConnection = null;
    dataChannel = null;
    events;
    config;
    pendingCandidates = [];
    _isConnected = false;
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
    async connect() {
        await this.signaling.connect();
    }
    disconnect() {
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
        console.log('[SDK] Peer joined - creating offer');
        this.close();
        this.createPeerConnection();
        await this.createOffer();
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
        const iceServers = this.config.iceServers || [
            { urls: 'stun:stun.l.google.com:19302' },
        ];
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
        if (!this.peerConnection)
            return;
        this.dataChannel = this.peerConnection.createDataChannel('tetherly', {
            ordered: true,
        });
        this.setupDataChannel(this.dataChannel);
        const offer = await this.peerConnection.createOffer();
        await this.peerConnection.setLocalDescription(offer);
        this.signaling.send({
            type: 'sdp-offer',
            payload: { sdp: offer.sdp },
        });
    }
    setupDataChannel(channel) {
        this.dataChannel = channel;
        channel.onopen = () => {
            console.log('[SDK] Data channel open');
            this._isConnected = true;
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
        this.dataChannel?.close();
        this.dataChannel = null;
        this.peerConnection?.close();
        this.peerConnection = null;
        this._isConnected = false;
        this.pendingCandidates = [];
    }
}
