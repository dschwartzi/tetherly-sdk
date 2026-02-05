# TetherlySDK

Open-source WebRTC P2P bridge for iOS-to-Mac communication.

TetherlySDK provides a peer-to-peer data channel between an iOS device and a Mac over WebRTC, with signaling handled via a simple WebSocket relay server. No data passes through any server once the P2P connection is established.

**Used by [Agently](https://agently.dev)** - the mobile cockpit for AI agents on your Mac.

## Why Open Source?

We believe users should be able to verify that their data stays private. TetherlySDK is the communication layer - it handles the P2P connection, not the AI features. By open-sourcing it, we provide full transparency:

- All data flows directly between your phone and your Mac (P2P)
- The signaling server only relays connection setup messages (SDP offers/answers and ICE candidates)
- No user data, messages, or files pass through any server
- You can inspect every line of the networking code

## Architecture

```
iOS App                  Signaling Server              Mac App
(TetherlySDK iOS)        (WebSocket relay)        (TetherlySDK Mac)
      |                        |                        |
      |--- WebSocket connect --|-- WebSocket connect ---|
      |--- ready ------------->|--- peer-joined ------->|
      |<-- peer-joined --------|<------------------------|
      |                        |                        |
      |--- SDP offer --------->|--- SDP offer --------->|
      |<-- SDP answer ---------|<-- SDP answer ---------|
      |--- ICE candidates ---->|--- ICE candidates ---->|
      |<-- ICE candidates -----|<-- ICE candidates -----|
      |                        |                        |
      |<========= WebRTC P2P Data Channel =============>|
      |          (direct, no server involved)            |
```

## Packages

### iOS (`ios/`)

Swift Package for iOS 15+ and macOS 13+.

```swift
import TetherlySDK

let sdk = TetherlySDK(
    signalingUrl: "wss://your-signaling-server.com",
    pairingCode: "your-pairing-code"
)
sdk.delegate = self
sdk.connect()
```

**Dependencies:** [WebRTC](https://github.com/stasel/WebRTC.git) (v125.0.0)

### Mac (`mac/`)

TypeScript/Node.js package for Mac applications.

```typescript
import { TetherlySDK } from '@tetherly/sdk-mac';

const sdk = new TetherlySDK({
    signalingUrl: 'wss://your-signaling-server.com',
    pairingCode: 'your-pairing-code',
});

sdk.on('connected', () => console.log('P2P connected'));
sdk.on('message', (msg) => console.log('Received:', msg));
sdk.connect();
```

**Dependencies:** [werift](https://github.com/nicktogo/werift-webrtc) (WebRTC), [ws](https://github.com/websockets/ws) (WebSocket)

### Signaling Server (`signaling/`)

Reference implementation for the WebSocket signaling relay. Deploy your own or use the hosted version.

## Features

- **P2P Data Channel** - Direct communication, no server in the middle
- **Auto-reconnect** - Exponential backoff with configurable max attempts
- **NAT Traversal** - STUN/TURN support including Cloudflare TURN
- **Sync Store** - Built-in key-value sync with version-based conflict resolution
- **Connection Health** - Automatic ping/pong, connection timeouts, health checks
- **Media Streaming** - Chunked binary transfer over the data channel

## Data Channel Protocol

Messages are JSON objects sent over the WebRTC data channel:

```json
{
  "type": "your-message-type",
  "payload": { ... },
  "timestamp": 1707177600000
}
```

The SDK reserves these message types for internal use:
- `sync-request`, `sync-response`, `sync-update`, `sync-delete` (sync store)
- `turn-config` (TURN server credential sharing)

All other message types are passed through to your application.

## Building

### iOS
```bash
cd ios
swift build
```

### Mac
```bash
cd mac
npm install
npm run build
```

## Signaling Server Protocol

The signaling server is a simple WebSocket relay. It needs to:

1. Accept WebSocket connections with `?pairingCode=XXX&type=mobile|agent` query params
2. When both peers are connected, send `peer-joined` with `isInitiator` flag
3. Relay messages with types: `sdp-offer`, `sdp-answer`, `ice-candidate`

Any WebSocket server that implements this protocol will work. See `signaling/` for a reference implementation using AWS API Gateway.

## License

MIT License - see [LICENSE](LICENSE)
