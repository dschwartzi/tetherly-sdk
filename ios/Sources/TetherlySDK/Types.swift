import Foundation

// MARK: - Message Types

public struct TetherlyMessage: Codable {
    public let type: String
    public let payload: [String: AnyCodable]
    
    public init(type: String, payload: [String: AnyCodable] = [:]) {
        self.type = type
        self.payload = payload
    }
}

public struct MediaMessage: Codable {
    public let type: String
    public let mediaType: MediaType
    public let data: String // base64
    public let metadata: [String: AnyCodable]?
    
    public enum MediaType: String, Codable {
        case image
        case video
        case audio
    }
    
    public init(mediaType: MediaType, data: String, metadata: [String: AnyCodable]? = nil) {
        self.type = "media"
        self.mediaType = mediaType
        self.data = data
        self.metadata = metadata
    }
}

// MARK: - Sync Types

public struct SyncRecord: Codable {
    public let id: String
    public var data: [String: AnyCodable]
    public var version: Int
    public var updatedAt: TimeInterval
    public var deletedAt: TimeInterval?
    
    public init(id: String, data: [String: AnyCodable], version: Int = 1) {
        self.id = id
        self.data = data
        self.version = version
        self.updatedAt = Date().timeIntervalSince1970 * 1000
    }
}

public struct SyncMessage: Codable {
    public let type: SyncMessageType
    public let collection: String
    public var records: [SyncRecord]?
    public var since: TimeInterval?
    
    public enum SyncMessageType: String, Codable {
        case syncRequest = "sync-request"
        case syncResponse = "sync-response"
        case syncUpdate = "sync-update"
        case syncDelete = "sync-delete"
    }
}

// MARK: - AnyCodable Helper

public struct AnyCodable: Codable {
    public let value: Any
    
    public init(_ value: Any) {
        self.value = value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - Events Protocol

public protocol TetherlySDKDelegate: AnyObject {
    func tetherlyDidConnect(_ sdk: TetherlySDK)
    func tetherlyDidDisconnect(_ sdk: TetherlySDK)
    func tetherlyIsReconnecting(_ sdk: TetherlySDK)
    func tetherly(_ sdk: TetherlySDK, didReceiveMessage message: TetherlyMessage)
    func tetherly(_ sdk: TetherlySDK, didReceiveMedia media: MediaMessage)
    func tetherly(_ sdk: TetherlySDK, didSyncUpdate collection: String, record: SyncRecord)
}

// Default implementations
public extension TetherlySDKDelegate {
    func tetherlyDidConnect(_ sdk: TetherlySDK) {}
    func tetherlyDidDisconnect(_ sdk: TetherlySDK) {}
    func tetherlyIsReconnecting(_ sdk: TetherlySDK) {}
    func tetherly(_ sdk: TetherlySDK, didReceiveMessage message: TetherlyMessage) {}
    func tetherly(_ sdk: TetherlySDK, didReceiveMedia media: MediaMessage) {}
    func tetherly(_ sdk: TetherlySDK, didSyncUpdate collection: String, record: SyncRecord) {}
}
