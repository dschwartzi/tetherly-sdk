import Foundation
import WebRTC

public class TetherlySDK: NSObject {
    
    // MARK: - Properties
    
    public weak var delegate: TetherlySDKDelegate?
    public private(set) var isConnected = false
    public private(set) var isSignalingConnected = false
    
    private let signalingUrl: String
    private let pairingCode: String
    private var signalingConnection: URLSessionWebSocketTask?
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private let syncStore: TetherlySyncStore
    
    private var pendingCandidates: [RTCIceCandidate] = []
    private var isInitiator = false
    private var iceServers: [RTCIceServer] = []
    private var connectionTimeout: Timer?
    private var isResetting = false
    private static let connectionTimeoutSeconds: TimeInterval = 30.0
    
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
    }()
    
    // MARK: - Initialization
    
    public init(signalingUrl: String, pairingCode: String, storePath: URL? = nil, iceServers: [RTCIceServer]? = nil) {
        self.signalingUrl = signalingUrl
        self.pairingCode = pairingCode
        self.syncStore = TetherlySyncStore(storePath: storePath)
        
        // Default to Google STUN if no servers provided
        self.iceServers = iceServers ?? [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"]),
        ]
        
        super.init()
        
        syncStore.setSyncHandler { [weak self] message in
            self?.sendSyncMessage(message)
        }
        
        syncStore.onSyncUpdate = { [weak self] collection, record in
            guard let self = self else { return }
            self.delegate?.tetherly(self, didSyncUpdate: collection, record: record)
        }
    }
    
    // MARK: - ICE Server Configuration
    
    /// Update ICE servers (call before connect, or will take effect on next connection)
    public func setIceServers(_ servers: [RTCIceServer]) {
        self.iceServers = servers
        print("[SDK] ICE servers updated: \(servers.count) servers")
    }
    
    /// Add TURN servers received from Mac daemon
    public func addTurnServers(_ turnServers: [[String: String]]) {
        for server in turnServers {
            if let urls = server["urls"],
               let username = server["username"],
               let credential = server["credential"] {
                iceServers.append(RTCIceServer(
                    urlStrings: [urls],
                    username: username,
                    credential: credential
                ))
            }
        }
        print("[SDK] Added \(turnServers.count) TURN servers")
    }
    
    // MARK: - Connection
    
    public func connect() {
        connectToSignaling()
    }
    
    public func disconnect() {
        clearConnectionTimeout()
        cleanupPeerConnection()
        signalingConnection?.cancel(with: .goingAway, reason: nil)
        signalingConnection = nil
        isSignalingConnected = false
    }
    
    // MARK: - Messaging
    
    public func send(_ message: TetherlyMessage) {
        guard let data = try? JSONEncoder().encode(message),
              let string = String(data: data, encoding: .utf8) else { return }
        sendRaw(string)
    }
    
    public func sendMedia(_ media: MediaMessage) {
        guard let data = try? JSONEncoder().encode(media),
              let string = String(data: data, encoding: .utf8) else { return }
        sendRaw(string)
    }
    
    public func sendRaw(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        let buffer = RTCDataBuffer(data: data, isBinary: false)
        dataChannel?.sendData(buffer)
    }
    
    // MARK: - Sync Store Access
    
    public var store: TetherlySyncStore {
        return syncStore
    }
    
    public func syncGet(collection: String, id: String) -> SyncRecord? {
        return syncStore.get(collection: collection, id: id)
    }
    
    public func syncGetAll(collection: String) -> [SyncRecord] {
        return syncStore.getAll(collection: collection)
    }
    
    public func syncSet(collection: String, id: String, data: [String: AnyCodable]) -> SyncRecord {
        return syncStore.set(collection: collection, id: id, data: data)
    }
    
    public func syncDelete(collection: String, id: String) {
        syncStore.delete(collection: collection, id: id)
    }
    
    // MARK: - Private - Signaling
    
    private func connectToSignaling() {
        guard let url = URL(string: "\(signalingUrl)?pairingCode=\(pairingCode)") else { return }
        
        let session = URLSession(configuration: .default)
        signalingConnection = session.webSocketTask(with: url)
        signalingConnection?.resume()
        
        print("[SDK] Connecting to signaling...")
        receiveSignalingMessage()
    }
    
    private func receiveSignalingMessage() {
        signalingConnection?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleSignalingMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self?.handleSignalingMessage(text)
                    }
                @unknown default:
                    break
                }
                self?.receiveSignalingMessage()
                
            case .failure(let error):
                print("[SDK] Signaling error: \(error)")
            }
        }
    }
    
    private func handleSignalingMessage(_ message: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        
        let payload = json["payload"] as? [String: Any]
        
        DispatchQueue.main.async {
            switch type {
            case "peer-joined":
                if self.isConnected && self.dataChannel?.readyState == .open {
                    print("[SDK] Ignoring peer-joined - already connected")
                    return
                }
                self.cleanupPeerConnection()
                self.createPeerConnection()
                // Wait for offer from Mac
                
            case "sdp-offer":
                if let sdp = payload?["sdp"] as? String {
                    self.handleOffer(sdp: sdp)
                }
                
            case "sdp-answer":
                if let sdp = payload?["sdp"] as? String {
                    self.handleAnswer(sdp: sdp)
                }
                
            case "ice-candidate":
                if let candidate = payload?["candidate"] as? String,
                   let sdpMid = payload?["sdpMid"] as? String,
                   let sdpMLineIndex = payload?["sdpMLineIndex"] as? Int32 {
                    self.handleIceCandidate(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)
                }
                
            default:
                break
            }
        }
    }
    
    private func sendSignalingMessage(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let string = String(data: data, encoding: .utf8) else { return }
        signalingConnection?.send(.string(string)) { error in
            if let error = error {
                print("[SDK] Failed to send signaling: \(error)")
            }
        }
    }
    
    // MARK: - Private - WebRTC
    
    private func createPeerConnection() {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        
        let turnCount = iceServers.filter { server in
            server.urlStrings.contains { $0.contains("turn") }
        }.count
        print("[SDK] Creating peer connection with \(iceServers.count) ICE servers (\(turnCount) TURN)")
        
        if turnCount == 0 {
            print("[SDK] WARNING: No TURN servers - mobile connections may fail!")
        }
        
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)
        
        startConnectionTimeout()
    }
    
    private func startConnectionTimeout() {
        clearConnectionTimeout()
        connectionTimeout = Timer.scheduledTimer(withTimeInterval: Self.connectionTimeoutSeconds, repeats: false) { [weak self] _ in
            guard let self = self, !self.isConnected, self.peerConnection != nil else { return }
            print("[SDK] Connection timeout - resetting for retry")
            self.safeReset()
        }
    }
    
    private func clearConnectionTimeout() {
        connectionTimeout?.invalidate()
        connectionTimeout = nil
    }
    
    private func safeReset() {
        guard !isResetting else {
            print("[SDK] Reset already in progress, skipping")
            return
        }
        isResetting = true
        cleanupPeerConnection()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.isResetting = false
        }
    }
    
    private func handleOffer(sdp: String) {
        if peerConnection == nil {
            createPeerConnection()
        }
        
        let sessionDescription = RTCSessionDescription(type: .offer, sdp: sdp)
        peerConnection?.setRemoteDescription(sessionDescription) { [weak self] error in
            if let error = error {
                print("[SDK] Failed to set remote description: \(error)")
                return
            }
            
            // Add pending candidates
            for candidate in self?.pendingCandidates ?? [] {
                self?.peerConnection?.add(candidate) { _ in }
            }
            self?.pendingCandidates.removeAll()
            
            // Create answer
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            self?.peerConnection?.answer(for: constraints) { answer, error in
                guard let answer = answer else {
                    print("[SDK] Failed to create answer: \(error?.localizedDescription ?? "")")
                    return
                }
                
                self?.peerConnection?.setLocalDescription(answer) { error in
                    if let error = error {
                        print("[SDK] Failed to set local description: \(error)")
                        return
                    }
                    
                    self?.sendSignalingMessage([
                        "type": "sdp-answer",
                        "payload": ["sdp": answer.sdp]
                    ])
                }
            }
        }
    }
    
    private func handleAnswer(sdp: String) {
        let sessionDescription = RTCSessionDescription(type: .answer, sdp: sdp)
        peerConnection?.setRemoteDescription(sessionDescription) { [weak self] error in
            if let error = error {
                print("[SDK] Failed to set remote description: \(error)")
                return
            }
            
            for candidate in self?.pendingCandidates ?? [] {
                self?.peerConnection?.add(candidate) { _ in }
            }
            self?.pendingCandidates.removeAll()
        }
    }
    
    private func handleIceCandidate(candidate: String, sdpMid: String, sdpMLineIndex: Int32) {
        let iceCandidate = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        
        if peerConnection?.remoteDescription != nil {
            peerConnection?.add(iceCandidate) { _ in }
        } else {
            pendingCandidates.append(iceCandidate)
        }
    }
    
    private func cleanupPeerConnection() {
        clearConnectionTimeout()
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        isConnected = false
        pendingCandidates.removeAll()
    }
    
    private func sendSyncMessage(_ message: SyncMessage) {
        guard let data = try? JSONEncoder().encode(message),
              let string = String(data: data, encoding: .utf8) else { return }
        sendRaw(string)
    }
}

// MARK: - RTCPeerConnectionDelegate

extension TetherlySDK: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("[SDK] ICE state: \(newState.rawValue)")
        
        DispatchQueue.main.async {
            switch newState {
            case .connected, .completed:
                self.isConnected = true
                self.delegate?.tetherlyDidConnect(self)
                self.syncStore.requestSync()
            case .failed, .closed:
                if self.isConnected {
                    self.isConnected = false
                    self.delegate?.tetherlyDidDisconnect(self)
                }
            case .disconnected:
                // Temporary - don't update UI
                print("[SDK] ICE temporarily disconnected")
            default:
                break
            }
        }
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        sendSignalingMessage([
            "type": "ice-candidate",
            "payload": [
                "candidate": candidate.sdp,
                "sdpMid": candidate.sdpMid ?? "",
                "sdpMLineIndex": candidate.sdpMLineIndex
            ]
        ])
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("[SDK] Data channel opened")
        self.dataChannel = dataChannel
        dataChannel.delegate = self
    }
}

// MARK: - RTCDataChannelDelegate

extension TetherlySDK: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        print("[SDK] Data channel state: \(dataChannel.readyState.rawValue)")
        
        DispatchQueue.main.async {
            if dataChannel.readyState == .open {
                self.isConnected = true
                self.delegate?.tetherlyDidConnect(self)
                self.syncStore.requestSync()
            } else if dataChannel.readyState == .closed {
                if self.isConnected {
                    self.isConnected = false
                    self.delegate?.tetherlyDidDisconnect(self)
                }
            }
        }
    }
    
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let string = String(data: buffer.data, encoding: .utf8) else { return }
        
        DispatchQueue.main.async {
            self.handleIncomingMessage(string)
        }
    }
    
    private func handleIncomingMessage(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        
        // Try to decode as sync message first
        if let syncMessage = try? JSONDecoder().decode(SyncMessage.self, from: data) {
            syncStore.handleSyncMessage(syncMessage)
            return
        }
        
        // Try media message
        if let mediaMessage = try? JSONDecoder().decode(MediaMessage.self, from: data) {
            delegate?.tetherly(self, didReceiveMedia: mediaMessage)
            return
        }
        
        // Try regular message
        if let message = try? JSONDecoder().decode(TetherlyMessage.self, from: data) {
            delegate?.tetherly(self, didReceiveMessage: message)
            return
        }
        
        // Raw message
        delegate?.tetherly(self, didReceiveMessage: TetherlyMessage(type: "raw", payload: ["data": AnyCodable(string)]))
    }
}
