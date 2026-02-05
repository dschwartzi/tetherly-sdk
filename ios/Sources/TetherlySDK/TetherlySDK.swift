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
    private var signalingSession: URLSession?  // Must retain session to keep WebSocket alive
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private let syncStore: TetherlySyncStore

    private var pendingCandidates: [RTCIceCandidate] = []
    private var isInitiator = false
    private var iceServers: [RTCIceServer] = []
    private var connectionTimeout: Timer?
    private var connectingTimeout: Timer?  // Timeout for stuck "connecting" state
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var isResetting = false
    private var isConnecting = false  // Prevent concurrent connection attempts
    private var reconnectAttempts = 0
    private static let connectionTimeoutSeconds: TimeInterval = 30.0
    private static let connectingTimeoutSeconds: TimeInterval = 15.0  // Max time to stay in "connecting"
    private static let pingIntervalSeconds: TimeInterval = 15.0
    private static let maxReconnectAttempts = 10
    private static let reconnectBaseDelay: TimeInterval = 0.5  // Start fast, then backoff

    // Default signaling server URL
    private static let defaultSignalingUrl = "wss://itq5lu6nq9.execute-api.us-east-1.amazonaws.com/prod"

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

    deinit {
        NSLog("[TetherlySDK] DEINIT - SDK is being deallocated!")
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
        clearConnectingTimeout()
        stopPingTimer()
        stopReconnectTimer()
        reconnectAttempts = 0
        cleanupPeerConnection()
        signalingConnection?.cancel(with: .goingAway, reason: nil)
        signalingConnection = nil
        isSignalingConnected = false
    }

    /// Force reconnection - useful when app returns from background
    public func reconnect() {
        NSLog("[TetherlySDK] reconnect() called - forcing new connection")
        reconnectAttempts = 0  // Reset counter for manual reconnect
        stopReconnectTimer()

        if !isSignalingConnected {
            // Signaling is down, reconnect everything
            NSLog("[TetherlySDK] Signaling down - reconnecting...")
            connectToSignaling()
        } else if !isConnected {
            // Signaling is up but WebRTC is down
            NSLog("[TetherlySDK] WebRTC down - requesting new connection...")
            cleanupPeerConnection()
            sendSignalingMessage(["type": "ready"])
        } else {
            NSLog("[TetherlySDK] Already connected - no reconnect needed")
        }
    }

    /// Check connection health and reconnect if needed (call when app wakes/foregrounds)
    public func checkConnectionHealth() {
        NSLog("[TetherlySDK] Health check: signaling=\(isSignalingConnected), connected=\(isConnected), connecting=\(isConnecting)")

        // Always verify WebSocket is actually alive with a ping
        // iOS may have killed the connection while backgrounded
        if let connection = signalingConnection {
            NSLog("[TetherlySDK] Health check: verifying WebSocket with ping...")
            connection.sendPing { [weak self] error in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if let error = error {
                        NSLog("[TetherlySDK] Health check: WebSocket dead (ping failed: \(error.localizedDescription))")
                        // WebSocket is dead - force full reconnect
                        self.isSignalingConnected = false
                        self.isConnected = false
                        self.signalingConnection?.cancel(with: .goingAway, reason: nil)
                        self.signalingConnection = nil
                        self.cleanupPeerConnection()
                        self.reconnectAttempts = 0
                        self.delegate?.tetherlyIsReconnecting(self)
                        self.connectToSignaling()
                    } else {
                        NSLog("[TetherlySDK] Health check: WebSocket alive")
                        // WebSocket is alive, check WebRTC
                        if !self.isConnected {
                            if self.isConnecting {
                                NSLog("[TetherlySDK] Health check: already connecting, resetting to retry")
                                self.isConnecting = false
                                self.cleanupPeerConnection()
                            }
                            NSLog("[TetherlySDK] Health check: WebRTC disconnected, requesting new connection...")
                            self.reconnectAttempts = 0
                            self.requestNewConnection()
                        } else {
                            NSLog("[TetherlySDK] Health check: connection healthy")
                        }
                    }
                }
            }
        } else {
            NSLog("[TetherlySDK] Health check: no WebSocket connection, reconnecting...")
            reconnectAttempts = 0
            connect()
        }
    }

    private func stopReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func startConnectingTimeout() {
        clearConnectingTimeout()
        connectingTimeout = Timer.scheduledTimer(withTimeInterval: Self.connectingTimeoutSeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.isConnecting && !self.isConnected {
                NSLog("[TetherlySDK] Connecting timeout - stuck in connecting state, resetting")
                self.isConnecting = false
                self.cleanupPeerConnection()
                // Notify delegate we're reconnecting
                self.delegate?.tetherlyIsReconnecting(self)
                self.requestNewConnection()
            }
        }
    }

    private func clearConnectingTimeout() {
        connectingTimeout?.invalidate()
        connectingTimeout = nil
    }

    /// Request a new WebRTC connection by sending 'ready' message
    private func requestNewConnection() {
        guard isSignalingConnected else {
            NSLog("[TetherlySDK] Cannot request new connection - signaling not connected")
            delegate?.tetherlyDidDisconnect(self)
            return
        }

        guard reconnectAttempts < Self.maxReconnectAttempts else {
            NSLog("[TetherlySDK] Max reconnect attempts (\(Self.maxReconnectAttempts)) reached - giving up")
            delegate?.tetherlyDidDisconnect(self)
            return
        }

        // Exponential backoff with jitter
        let delay = Self.reconnectBaseDelay * pow(1.5, Double(reconnectAttempts)) + Double.random(in: 0...1)
        reconnectAttempts += 1

        NSLog("[TetherlySDK] Scheduling reconnect attempt \(reconnectAttempts) in \(String(format: "%.1f", delay))s")

        stopReconnectTimer()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            guard !self.isConnected else {
                NSLog("[TetherlySDK] Already connected - skipping reconnect")
                self.reconnectAttempts = 0
                return
            }

            NSLog("[TetherlySDK] Sending 'ready' to request new WebRTC connection")
            self.sendSignalingMessage(["type": "ready"])
        }
    }

    private func startPingTimer() {
        stopPingTimer()
        pingTimer = Timer.scheduledTimer(withTimeInterval: Self.pingIntervalSeconds, repeats: true) { [weak self] _ in
            self?.sendSignalingMessage(["type": "ping"])
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
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

    /// Cancel audio capture - discard buffer without sending (swipe-to-cancel)
    public func cancelAudioCapture() {
        print("[TetherlySDK] Cancelling audio capture (discarding buffer)")
    }

    // MARK: - Private - Signaling

    private func connectToSignaling() {
        // URL with type=mobile to identify as iOS client
        let urlString = "\(signalingUrl)?pairingCode=\(pairingCode)&type=mobile"
        guard let url = URL(string: urlString) else {
            NSLog("[TetherlySDK] ERROR: Invalid signaling URL: \(urlString)")
            return
        }

        NSLog("[TetherlySDK] ========== CONNECTING TO SIGNALING ==========")
        NSLog("[TetherlySDK] URL: \(url.absoluteString)")
        NSLog("[TetherlySDK] Pairing code: \(pairingCode.prefix(20))...")

        // Use shared session - it's guaranteed to stay alive
        signalingConnection = URLSession.shared.webSocketTask(with: url)
        NSLog("[TetherlySDK] WebSocket task state BEFORE resume: \(signalingConnection?.state.rawValue ?? -1)")
        signalingConnection?.resume()
        NSLog("[TetherlySDK] WebSocket task state AFTER resume: \(signalingConnection?.state.rawValue ?? -1)")

        // Test WebSocket-level ping after a short delay to let connection establish
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            NSLog("[TetherlySDK] Testing WebSocket ping after 1s delay...")
            NSLog("[TetherlySDK] Connection state: \(self.signalingConnection?.state.rawValue ?? -1)")
            self.signalingConnection?.sendPing { error in
                if let error = error {
                    NSLog("[TetherlySDK] WebSocket PING FAILED: \(error.localizedDescription)")
                    NSLog("[TetherlySDK] Error type: \(type(of: error))")
                    // Connection failed - schedule retry with backoff
                    DispatchQueue.main.async {
                        self.isSignalingConnected = false
                        self.signalingConnection?.cancel(with: .goingAway, reason: nil)
                        self.signalingConnection = nil

                        // Schedule retry if under max attempts
                        self.reconnectAttempts += 1
                        if self.reconnectAttempts <= Self.maxReconnectAttempts {
                            let delay = Self.reconnectBaseDelay * pow(1.5, Double(self.reconnectAttempts)) + Double.random(in: 0...1)
                            NSLog("[TetherlySDK] Scheduling signaling reconnect attempt \(self.reconnectAttempts) in \(String(format: "%.1f", delay))s")
                            self.delegate?.tetherlyIsReconnecting(self)
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                                guard let self = self, !self.isSignalingConnected else { return }
                                self.connectToSignaling()
                            }
                        } else {
                            NSLog("[TetherlySDK] Max reconnect attempts reached - giving up")
                            self.delegate?.tetherlyDidDisconnect(self)
                        }
                    }
                } else {
                    NSLog("[TetherlySDK] WebSocket PING SUCCEEDED!")
                    self.isSignalingConnected = true
                    self.reconnectAttempts = 0  // Reset on success
                }
            }
        }

        // Also check connection state after 5 seconds (fallback if ping check didn't trigger)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            NSLog("[TetherlySDK] 5s connection check: signaling=\(self.isSignalingConnected), connected=\(self.isConnected), attempts=\(self.reconnectAttempts)")
            NSLog("[TetherlySDK] WebSocket state: \(self.signalingConnection?.state.rawValue ?? -1)")
            if !self.isSignalingConnected && !self.isConnected && self.reconnectAttempts < Self.maxReconnectAttempts {
                NSLog("[TetherlySDK] Connection stuck - retrying...")
                self.signalingConnection?.cancel(with: .goingAway, reason: nil)
                self.signalingConnection = nil
                self.reconnectAttempts += 1
                self.delegate?.tetherlyIsReconnecting(self)
                self.connectToSignaling()
            }
        }

        // Set up receive callback immediately
        receiveSignalingMessage()
        
        // Test connection with a ping first
        sendSignalingMessage(["type": "ping"])
        NSLog("[TetherlySDK] Sent test ping to verify connection")

        // Send ready message to request a WebRTC connection
        sendSignalingMessage(["type": "ready"])
        NSLog("[TetherlySDK] Sent 'ready' message to signaling server")
    }

    private func receiveSignalingMessage() {
        NSLog("[TetherlySDK] ========== SETTING UP RECEIVE ==========")
        NSLog("[TetherlySDK] Connection object: \(String(describing: signalingConnection))")
        NSLog("[TetherlySDK] Connection state: \(signalingConnection?.state.rawValue ?? -1)")
        signalingConnection?.receive { [weak self] result in
            // Move ALL processing to main thread to avoid threading issues
            DispatchQueue.main.async {
                NSLog("[TetherlySDK] Receive callback fired on main thread")
                guard let self = self else {
                    NSLog("[TetherlySDK] self is nil in receive callback")
                    return
                }

                switch result {
                case .success(let message):
                    NSLog("[TetherlySDK] Received message successfully!")
                    let wasSignalingConnected = self.isSignalingConnected
                    if !wasSignalingConnected {
                        self.isSignalingConnected = true
                        NSLog("[TetherlySDK] Signaling connected (first message)")
                        self.startPingTimer()

                        // If WebRTC is not connected, request a new connection
                        if !self.isConnected && self.peerConnection == nil {
                            NSLog("[TetherlySDK] Signaling reconnected but no WebRTC - sending ready")
                            self.sendSignalingMessage(["type": "ready"])
                        }
                    }

                    switch message {
                    case .string(let text):
                        self.handleSignalingMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleSignalingMessage(text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveSignalingMessage()

                case .failure(let error):
                    NSLog("[TetherlySDK] Signaling RECEIVE ERROR: \(error.localizedDescription)")
                    NSLog("[TetherlySDK] Error details: \(error)")
                    let wasSignalingConnected = self.isSignalingConnected
                    let wasWebRTCConnected = self.isConnected
                    self.isSignalingConnected = false
                    self.isConnected = false
                    self.stopPingTimer()
                    self.stopReconnectTimer()

                    // Also clean up WebRTC if signaling dies
                    if wasSignalingConnected {
                        self.cleanupPeerConnection()
                    }

                    // Notify that we're reconnecting (not disconnected - we'll auto-reconnect)
                    if wasWebRTCConnected {
                        self.delegate?.tetherlyIsReconnecting(self)
                    }

                    // Schedule reconnect after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self = self else { return }
                        // Only reconnect if not already connected
                        if !self.isSignalingConnected {
                            NSLog("[TetherlySDK] Attempting signaling reconnect...")
                            self.reconnectAttempts = 0  // Reset for fresh reconnect
                            self.connectToSignaling()
                        }
                    }
                }
            }
        }
    }

    private func handleSignalingMessage(_ message: String) {
        // Log ALL raw signaling messages for debugging
        NSLog("[TetherlySDK] RAW signaling message: \(message)")

        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            NSLog("[TetherlySDK] ERROR: Failed to parse signaling message")
            return
        }

        let payload = json["payload"] as? [String: Any]

        // Log all messages except pong
        if type != "pong" {
            NSLog("[TetherlySDK] Signaling message: \(type), json keys: \(json.keys)")
        }

        DispatchQueue.main.async {
            switch type {
            case "pong":
                // Ping response - connection is healthy
                break

            case "peer-joined":
                NSLog("[TetherlySDK] PEER-JOINED received!")

                // Prevent concurrent connection attempts
                if self.isConnecting {
                    NSLog("[TetherlySDK] Ignoring peer-joined - already connecting")
                    return
                }

                NSLog("[TetherlySDK] isConnected: \(self.isConnected), dataChannel: \(String(describing: self.dataChannel)), readyState: \(self.dataChannel?.readyState.rawValue ?? -1)")
                if self.isConnected && self.dataChannel?.readyState == .open {
                    NSLog("[TetherlySDK] Ignoring peer-joined - already connected")
                    return
                }

                // Mark as connecting to prevent race conditions
                self.isConnecting = true
                self.startConnectingTimeout()  // Fail-safe for stuck connecting state

                // isInitiator can be at top level or in payload depending on signaling server version
                let topLevelInitiator = json["isInitiator"] as? Bool
                let payloadInitiator = payload?["isInitiator"] as? Bool
                let isInitiator = topLevelInitiator ?? payloadInitiator ?? false
                NSLog("[TetherlySDK] Peer joined - isInitiator: \(isInitiator), starting connection...")
                self.cleanupPeerConnection()
                self.createPeerConnection()
                self.startConnectionTimeout()
                if isInitiator {
                    NSLog("[TetherlySDK] Creating offer (we are initiator)")
                    self.createOffer()
                } else {
                    NSLog("[TetherlySDK] Waiting for offer (peer is initiator)")
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
                NSLog("[TetherlySDK] Received TURN config from Mac")
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

        // Check connection state
        if signalingConnection == nil {
            NSLog("[TetherlySDK] ERROR: signalingConnection is nil!")
            return
        }
        let state = signalingConnection!.state
        NSLog("[TetherlySDK] Sending \(message["type"] ?? "unknown"), connection state: \(state.rawValue)")

        signalingConnection?.send(.string(string)) { [weak self] error in
            if let error = error {
                NSLog("[TetherlySDK] SEND ERROR: \(error.localizedDescription)")
                // Send failed - WebSocket is likely dead, trigger reconnect
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if self.isSignalingConnected {
                        NSLog("[TetherlySDK] Send failed - marking signaling as disconnected and reconnecting")
                        self.isSignalingConnected = false
                        self.isConnected = false
                        self.stopPingTimer()
                        self.cleanupPeerConnection()
                        self.signalingConnection?.cancel(with: .goingAway, reason: nil)
                        self.signalingConnection = nil
                        self.delegate?.tetherlyIsReconnecting(self)
                        // Reconnect after a short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            guard let self = self, !self.isSignalingConnected else { return }
                            self.reconnectAttempts = 0
                            self.connectToSignaling()
                        }
                    }
                }
            } else {
                NSLog("[TetherlySDK] Message sent successfully: \(message["type"] ?? "unknown")")
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
        NSLog("[TetherlySDK] createOffer() called")
        guard let pc = peerConnection else {
            NSLog("[TetherlySDK] ERROR: No peer connection for createOffer")
            return
        }
        NSLog("[TetherlySDK] Have peer connection, creating data channel...")

        // Create data channel before creating offer
        let config = RTCDataChannelConfiguration()
        config.isOrdered = true
        config.channelId = 0
        dataChannel = pc.dataChannel(forLabel: "tetherly", configuration: config)
        dataChannel?.delegate = self
        NSLog("[TetherlySDK] Data channel created")
        
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
        isConnecting = false
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
        NSLog("[TetherlySDK] ICE connection state changed: \(newState.rawValue)")
        DispatchQueue.main.async {
            switch newState {
            case .connected, .completed:
                NSLog("[TetherlySDK] ICE CONNECTED")
                self.clearConnectionTimeout()
                self.clearConnectingTimeout()
                self.stopReconnectTimer()
                self.reconnectAttempts = 0  // Reset on successful connection
                self.isConnecting = false   // Connection attempt complete
                self.isConnected = true
                self.delegate?.tetherlyDidConnect(self)
                self.syncStore.requestSync()
            case .failed, .closed, .disconnected:
                NSLog("[TetherlySDK] ICE \(newState.rawValue), isConnected was: \(self.isConnected)")
                let wasConnected = self.isConnected
                self.isConnecting = false  // Connection attempt complete (failed)
                self.isConnected = false
                // Clean up the old peer connection
                self.cleanupPeerConnection()
                // Automatically request a new connection if signaling is still up
                if self.isSignalingConnected {
                    NSLog("[TetherlySDK] Signaling still connected - requesting new WebRTC connection")
                    // Notify delegate we're reconnecting (not disconnected)
                    if wasConnected {
                        self.delegate?.tetherlyIsReconnecting(self)
                    }
                    self.requestNewConnection()
                } else if wasConnected {
                    // Only notify disconnect if we can't auto-reconnect
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
        NSLog("[TetherlySDK] Data channel state changed: \(dataChannel.readyState.rawValue)")
        DispatchQueue.main.async {
            if dataChannel.readyState == .open {
                NSLog("[TetherlySDK] Data channel open - connection complete")
                self.clearConnectionTimeout()
                self.clearConnectingTimeout()
                self.stopReconnectTimer()
                self.reconnectAttempts = 0  // Reset on successful connection
                self.isConnecting = false
                self.isConnected = true
                self.delegate?.tetherlyDidConnect(self)
                self.syncStore.requestSync()
            } else if dataChannel.readyState == .closed || dataChannel.readyState == .closing {
                NSLog("[TetherlySDK] Data channel closed/closing, isConnected was: \(self.isConnected)")
                let wasConnected = self.isConnected
                if wasConnected {
                    self.isConnected = false

                    // Data channel closed - cleanup and request new connection
                    NSLog("[TetherlySDK] Data channel closed while connected - triggering reconnect")
                    self.cleanupPeerConnection()
                    if self.isSignalingConnected {
                        // Notify delegate we're reconnecting (not disconnected)
                        self.delegate?.tetherlyIsReconnecting(self)
                        self.requestNewConnection()
                    } else {
                        // Only notify disconnect if we can't auto-reconnect
                        self.delegate?.tetherlyDidDisconnect(self)
                    }
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
