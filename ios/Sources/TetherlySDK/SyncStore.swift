import Foundation

public class TetherlySyncStore {
    private var store: [String: [String: SyncRecord]] = [:]
    private let storePath: URL
    private var sendSync: ((SyncMessage) -> Void)?
    public var onSyncUpdate: ((String, SyncRecord) -> Void)?
    
    public init(storePath: URL? = nil) {
        if let path = storePath {
            self.storePath = path
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.storePath = docs.appendingPathComponent("tetherly-sync.json")
        }
        load()
    }
    
    public func setSyncHandler(_ handler: @escaping (SyncMessage) -> Void) {
        self.sendSync = handler
    }
    
    // MARK: - CRUD Operations
    
    public func get(collection: String, id: String) -> SyncRecord? {
        return store[collection]?[id]
    }
    
    public func getAll(collection: String) -> [SyncRecord] {
        guard let coll = store[collection] else { return [] }
        return Array(coll.values).filter { $0.deletedAt == nil }
    }
    
    public func set(collection: String, id: String, data: [String: AnyCodable]) -> SyncRecord {
        if store[collection] == nil {
            store[collection] = [:]
        }
        
        let existing = store[collection]?[id]
        var record = SyncRecord(
            id: id,
            data: data,
            version: (existing?.version ?? 0) + 1
        )
        record.updatedAt = Date().timeIntervalSince1970 * 1000
        
        store[collection]![id] = record
        save()
        
        // Send sync update
        sendSync?(SyncMessage(
            type: .syncUpdate,
            collection: collection,
            records: [record]
        ))
        
        return record
    }
    
    public func delete(collection: String, id: String) {
        guard var record = store[collection]?[id] else { return }
        
        record.deletedAt = Date().timeIntervalSince1970 * 1000
        record.version += 1
        record.updatedAt = Date().timeIntervalSince1970 * 1000
        store[collection]![id] = record
        save()
        
        sendSync?(SyncMessage(
            type: .syncDelete,
            collection: collection,
            records: [record]
        ))
    }
    
    // MARK: - Sync Handling
    
    public func handleSyncMessage(_ message: SyncMessage) {
        switch message.type {
        case .syncRequest:
            handleSyncRequest(message)
        case .syncResponse, .syncUpdate, .syncDelete:
            handleSyncUpdate(message)
        }
    }
    
    public func requestSync() {
        var since: TimeInterval = 0
        for (_, records) in store {
            for (_, record) in records {
                if record.updatedAt > since {
                    since = record.updatedAt
                }
            }
        }
        
        sendSync?(SyncMessage(
            type: .syncRequest,
            collection: "*",
            since: since > 0 ? since - 60000 : 0
        ))
    }
    
    private func handleSyncRequest(_ message: SyncMessage) {
        let since = message.since ?? 0
        
        let collections = message.collection == "*" ? Array(store.keys) : [message.collection]
        
        for collection in collections {
            guard let coll = store[collection] else { continue }
            
            let records = coll.values.filter { $0.updatedAt > since }
            if !records.isEmpty {
                sendSync?(SyncMessage(
                    type: .syncResponse,
                    collection: collection,
                    records: Array(records)
                ))
            }
        }
    }
    
    private func handleSyncUpdate(_ message: SyncMessage) {
        guard let records = message.records else { return }
        
        for record in records {
            if store[message.collection] == nil {
                store[message.collection] = [:]
            }
            
            let existing = store[message.collection]?[record.id]
            
            if existing == nil || record.version > existing!.version {
                store[message.collection]![record.id] = record
                onSyncUpdate?(message.collection, record)
            }
        }
        
        save()
    }
    
    // MARK: - Persistence
    
    private func load() {
        do {
            if FileManager.default.fileExists(atPath: storePath.path) {
                let data = try Data(contentsOf: storePath)
                store = try JSONDecoder().decode([String: [String: SyncRecord]].self, from: data)
            }
        } catch {
            print("[SDK] Failed to load store: \(error)")
            store = [:]
        }
    }
    
    private func save() {
        do {
            let data = try JSONEncoder().encode(store)
            try data.write(to: storePath)
        } catch {
            print("[SDK] Failed to save store: \(error)")
        }
    }
}
