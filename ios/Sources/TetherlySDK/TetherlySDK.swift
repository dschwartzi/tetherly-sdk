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

    // Default signaling server URL
    private static let defaultSignalingUrl = "wss://fnzo0svi94.execute-api.us-east-1.amazonaws.com/prod"

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
    }()

    // MARK: - Initialization

    public init(signalingUrl: String? = nil, pairingCode: String, storePath: URL? = nil, iceServers: [RTCIceServer]? = nil) {
        self.signalingUrl = signalingUrl ?? Self.defaultSignalingUrl
        self.pairingCode = pairingCode
        self.syncStore = TetherlySyncStore(storePath: storePath)

        // Default ICE servers: STUN + Cloudflare TURN for NAT traversal
        self.iceServers = iceServers ?? [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun.cloudflare.com:3478"]),
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
        print("[TetherlySDK] ICE servers updated: \(servers.count) servers")
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
        print("[TetherlySDK] Added \(turnServers.count) TURN servers")
    }
    
    /// Add TURN servers from Mac daemon (handles urls as string or array)
    private func addTurnServersFromMac(_ servers: [[String: Any]]) {
        var addedCount = 0
        for server in servers {
            var urlStrings: [String] = []
            
            // Handle urls as string or array
            if let urlString = server["urls"] as? String {
                urlStrings = [urlString]
            } else if let urlArray = server["urls"] as? [String] {
                urlStrings = urlArray
            }
            
            guard !urlStrings.isEmpty,
                  let username = server["username"] as? String,
                  let credential = server["credential"] as? String else {
                continue
            }
            
            iceServers.append(RTCIceServer(
                urlStrings: urlStrings,
                username: username,
                credential: credential
            ))
            addedCount += 1
        }
        print("[TetherlySDK] Added \(addedCount) TURN servers from Mac, total ICE servers: \(iceServers.count)")
    }

    // MARK: - Connection

    public func connect() {
        NSLog("[TetherlySDK] connect() called - signalingUrl: \(signalingUrl), pairingCode: \(pairingCode.prefix(20))...")
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

    // MARK: - Audio Capture (Placeholder for real implementation)

    public func startAudioCapture() {
        print("[TetherlySDK] Starting audio capture")
    }

    public func stopAudioCapture() {
        print("[TetherlySDK] Stopping audio capture")
    }

    // MARK: - Private - Signaling

    private func connectToSignaling() {
        // URL with type=mobile to identify as iOS client
        let urlString = "\(signalingUrl)?pairingCode=\(pairingCode)&type=mobile"
        guard let url = URL(string: urlString) else {
            NSLog("[TetherlySDK] ERROR: Invalid signaling URL: \(urlString)")
            return
        }

        NSLog("[TetherlySDK] Connecting to signaling: \(url.absoluteString)")

        let session = URLSession(configuration: .default)
        signalingConnection = session.webSocketTask(with: url)
        signalingConnection?.resume()

        // IMPORTANT: Set up listener FIRST, then send ready
        receiveSignalingMessage()
        
        // Send ready message
        sendSignalingMessage(["type": "ready"])
        NSLog("[TetherlySDK] Sent 'ready' message to signaling server")
    }

    private func receiveSignalingMessage() {
        signalingConnection?.receive { [weak self] result in
            switch result {
            case .success(let message):
                if !(self?.isSignalingConnected ?? false) {
                    self?.isSignalingConnected = true
                    print("[TetherlySDK] Signaling connected")
                }

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
                print("[TetherlySDK] Signaling error: \(error.localizedDescription)")
            }
        }
    }

    private func handleSignalingMessage(_ message: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        let payload = json["payload"] as? [String: Any]

        print("[TetherlySDK] Signaling message: \(type)")

        DispatchQueue.main.async {
            switch type {
            case "peer-joined":
                if self.isConnected && self.dataChannel?.readyState == .open {
                    print("[TetherlySDK] Ignoring peer-joined - already connected")
                    return
                }
                // isInitiator can be at top level or in payload depending on signaling server version
                let isInitiator = (json["isInitiator"] as? Bool) ?? (payload?["isInitiator"] as? Bool) ?? false
                print("[TetherlySDK] Peer joined, isInitiator: \(isInitiator)")
                self.cleanupPeerConnection()
                self.createPeerConnection()
                self.startConnectionTimeout()
                if isInitiator {
                    print("[TetherlySDK] Creating offer (we are initiator)")
                    self.createOffer()
                } else {
                    print("[TetherlySDK] Waiting for offer (peer is initiator)")
                }

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

            case "turn-config":
                print("[TetherlySDK] Received TURN config from Mac")
                if let servers = payload?["servers"] as? [[String: Any]] {
                    self.addTurnServersFromMac(servers)
                }

            default:
                break
            }
        }
    }

    private func sendSignalingMessage(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let string = String(data: data, encoding: .utf8) else { 
            NSLog("[TetherlySDK] ERROR: Failed to serialize signaling message")
            return 
        }
        NSLog("[TetherlySDK] Sending signaling message: \(message["type"] ?? "unknown")")
        signalingConnection?.send(.string(string)) { error in
            if let error = error {
                print("[TetherlySDK] Failed to send signaling: \(error)")
            }
        }
    }

    // MARK: - Private - WebRTC

    private func createPeerConnection() {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.bundlePolicy = .maxBundle

        let turnCount = iceServers.filter { server in
            server.urlStrings.contains { $0.contains("turn") }
        }.count
        print("[TetherlySDK] Creating peer connection with \(iceServers.count) ICE servers (\(turnCount) TURN)")

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        peerConnection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)

        startConnectionTimeout()
    }

    private func startConnectionTimeout() {
        clearConnectionTimeout()
        connectionTimeout = Timer.scheduledTimer(withTimeInterval: Self.connectionTimeoutSeconds, repeats: false) { [weak self] _ in
            guard let self = self, !self.isConnected, self.peerConnection != nil else { return }
            print("[TetherlySDK] Connection timeout - resetting")
            self.safeReset()
        }
    }

    private func clearConnectionTimeout() {
        connectionTimeout?.invalidate()
        connectionTimeout = nil
    }

    private func safeReset() {
        guard !isResetting else { return }
        isResetting = true
        cleanupPeerConnection()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.isResetting = false
        }
    }

    private func createOffer() {
        guard let pc = peerConnection else {
            print("[TetherlySDK] ERROR: No peer connection for createOffer")
            return
        }
        
        // Create data channel before creating offer
        let config = RTCDataChannelConfiguration()
        config.isOrdered = true
        config.channelId = 0
        dataChannel = pc.dataChannel(forLabel: "tetherly", configuration: config)
        dataChannel?.delegate = self
        print("[TetherlySDK] Data channel created")
        
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
                "OfferToReceiveVideo": "false"
            ],
            optionalConstraints: nil
        )
        
        pc.offer(for: constraints) { [weak self] offer, error in
            guard let self = self, let offer = offer else {
                print("[TetherlySDK] ERROR: Failed to create offer: \(error?.localizedDescription ?? "unknown")")
                return
            }
            
            pc.setLocalDescription(offer) { error in
                if let error = error {
                    print("[TetherlySDK] ERROR: Failed to set local description: \(error)")
                    return
                }
                
                print("[TetherlySDK] Sending SDP offer...")
                self.sendSignalingMessage([
                    "type": "sdp-offer",
                    "payload": ["sdp": offer.sdp, "type": "offer"]
                ])
            }
        }
    }
    
    private func handleOffer(sdp: String) {
        // If we already have a local description (we created an offer), ignore incoming offers
        // This handles race conditions where both sides try to create offers
        if peerConnection?.localDescription != nil {
            print("[TetherlySDK] Ignoring incoming offer - we already have local description (we are initiator)")
            return
        }
        
        if peerConnection == nil {
            createPeerConnection()
        }

        guard peerConnection != nil else { return }

        let sessionDescription = RTCSessionDescription(type: .offer, sdp: sdp)
        peerConnection?.setRemoteDescription(sessionDescription) { [weak self] error in
            if let error = error {
                print("[TetherlySDK] Failed to set remote description: \(error)")
                return
            }

            // Add pending candidates
            for candidate in self?.pendingCandidates ?? [] {
                self?.peerConnection?.add(candidate) { _ in }
            }
            self?.pendingCandidates.removeAll()

            // Create answer
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: [
                    "OfferToReceiveAudio": "false",
                    "OfferToReceiveVideo": "false"
                ],
                optionalConstraints: nil
            )
            self?.peerConnection?.answer(for: constraints) { answer, error in
                guard let answer = answer else { return }

                self?.peerConnection?.setLocalDescription(answer) { error in
                    if let error = error {
                        print("[TetherlySDK] Failed to set local description: \(error)")
                        return
                    }

                    self?.sendSignalingMessage([
                        "type": "sdp-answer",
                        "payload": ["sdp": answer.sdp, "type": "answer"]
                    ])
                }
            }
        }
    }

    private func handleAnswer(sdp: String) {
        let sessionDescription = RTCSessionDescription(type: .answer, sdp: sdp)
        peerConnection?.setRemoteDescription(sessionDescription) { [weak self] error in
            if let error = error {
                print("[TetherlySDK] Failed to set remote description: \(error)")
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
        self.dataChannel = dataChannel
        dataChannel.delegate = self
    }
}

// MARK: - RTCDataChannelDelegate

extension TetherlySDK: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
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

// MARK: - SDK Errors

public enum TetherlySDKError: LocalizedError {
    case connectionFailed
    case notConnected
    case invalidMessage
    case timeout

    public var errorDescription: String? {
        switch self {
        case .connectionFailed: return "Failed to establish connection"
        case .notConnected: return "Not connected to server"
        case .invalidMessage: return "Invalid message format"
        case .timeout: return "Connection timed out"
        }
    }
}
