import Foundation
import CryptoKit
import Security
import Network

/// Network messages only. Credentials are never written with task archives.
enum CompanionProtocol {
    static let service = "_current-an._tcp"
    // Separate instances of the same declared service type, rather than a second Bonjour permission.
    static func pairingName(_ serviceID: String) -> String { String(serviceID.prefix(57)) + "-pair" }
    static let version = 2
    static let signature = "\(SemanticSpace.id)|\(SemanticSpace.catalogVersion)|\(GenreAnalysis.currentVersion)|\(LyricsSpace.id)|\(LyricsSpace.preprocessing)|\(ObjectiveProfile.currentVersion)"
    static let maxFrame = 16 * 1024 * 1024
}
struct CompanionPair: Codable {
    let service: String
    let secret: String
    var device: String
}
struct CompanionAuthorization: Codable {
    let account: String
    let cookies: [String: String]
}
struct CompanionResult: Codable {
    var requestID: UUID? = nil
    let jobID: UUID
    let trackID: Int
    let account: String
    let signature: String
    let features: AcousticFeatures
    let genres: GenreAnalysis
    let vector: [Float]
    let windowStarts: [Double]
    let semanticElapsed: Double
    let lyrics: LyricsAnalysis?
    let wiki: SongWikiMetadata?
    func validate() throws {
        guard signature == CompanionProtocol.signature, features.version == "native-acoustic-v1",
              features.profile?.version == ObjectiveProfile.currentVersion, genres.compatible,
              genres.matches.count <= 400, genres.matches.allSatisfy({ $0.score.isFinite && (0...1).contains($0.score) }),
              windowStarts.count <= 1000, windowStarts.allSatisfy({ $0.isFinite && $0 >= 0 }),
              semanticElapsed.isFinite else { throw CurrentError.message("两端分析版本不兼容，请更新 App") }
        _ = try EmbeddingMath.unit(vector)
        if let lyrics {
            guard lyrics.chunks.count <= 512, (lyrics.status == .indexed) == !lyrics.chunks.isEmpty else { throw LyricsError.invalidVector }
            for chunk in lyrics.chunks { _ = try LyricsMath.unit(chunk.vector) }
        }
    }
}
enum CompanionJobState: String, Codable {
    case queued, fetching, analyzing, completed, synced, failed, authorizationRequired, unavailable
    var title: String {
        switch self {
        case .queued: return "等待分析"
        case .fetching: return "获取音频与歌词"
        case .analyzing: return "正在分析"
        case .completed: return "等待同步"
        case .synced: return "已同步"
        case .failed: return "分析失败"
        case .unavailable: return "音源不可用"
        case .authorizationRequired: return "等待更新授权"
        }
    }
}
struct CompanionJob: Codable, Identifiable {
    let id: UUID
    let track: Track
    let account: String
    var requestID: UUID? = nil
    var state: CompanionJobState = .queued
    var failure: String?
    var unavailability: TrackUnavailability?
    var result: CompanionResult?
}
struct CompanionJobStatus: Codable, Identifiable {
    let id: UUID
    let track: Track
    let state: CompanionJobState
    let failure: String?
    var requestID: UUID? = nil
    var unavailability: TrackUnavailability? = nil
}
struct CompanionMessage: Codable {
    enum Kind: String, Codable { case pairRequest, pairWaiting, pairAccepted, pairCancel, pairStart, pairChallenge, pairProof, pairComplete, hello, welcome, unpair, goodbye, authorize, session, submit, status, result, acknowledge, control, cancel, revoke, error, poll }
    let kind: Kind
    var version = CompanionProtocol.version
    var signature = CompanionProtocol.signature
    var device: String?
    var name: String?
    var account: String?
    var cookies: [String: String]?
    var ids: [UUID]?
    var jobs: [CompanionJob]?
    var statuses: [CompanionJobStatus]?
    var result: CompanionResult?
    var analysisPaused: Bool?
    var syncPaused: Bool?
    var text: String?
    var force: Bool?
    var requestID: UUID?
    var publicKey: Data?
    var salt: Data?
    var proof: Data?
    var sealedSecret: Data?
    var authorizationAvailable: Bool?
}

/// Both platforms keep pairing and account secrets exclusively in Keychain.
enum CompanionSecrets {
    static func load<T: Decodable>(_ key: String, as: T.Type) -> T? {
        var query = base(key); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var output: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &output) == errSecSuccess, let data = output as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    static func save<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(base(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(base(key).merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw CurrentError.message("无法保存配对凭据") }
        } else if status != errSecSuccess { throw CurrentError.message("无法更新配对凭据") }
    }
    static func delete(_ key: String) { SecItemDelete(base(key) as CFDictionary) }
    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.liupenghao.current.companion", kSecAttrAccount as String: key]
    }
    static func identifier(_ key: String) -> String {
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = UUID().uuidString; UserDefaults.standard.set(value, forKey: key); return value
    }
}

/// Testable secret storage; production always uses the system Keychain.
protocol CompanionVault {
    func load<T: Decodable>(_ key: String, as: T.Type) -> T?
    func save<T: Encodable>(_ value: T, key: String) throws
    func delete(_ key: String)
}
struct KeychainCompanionVault: CompanionVault {
    func load<T: Decodable>(_ key: String, as: T.Type) -> T? { CompanionSecrets.load(key, as: T.self) }
    func save<T: Encodable>(_ value: T, key: String) throws { try CompanionSecrets.save(value, key: key) }
    func delete(_ key: String) { CompanionSecrets.delete(key) }
}

/// Discovery identity is independent of a route, interface, or Bonjour conflict suffix.
struct CompanionComputer: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    let pairingName: String
    let routeRank: String
    static func parse(serviceName: String, endpoint: NWEndpoint, values: [String: String], interfaces: [NWInterface] = []) -> Self? {
        guard values["role"] == "desktop", let id = values["id"], !id.isEmpty, id.count <= 128,
              let name = values["name"], !name.isEmpty,
              let pairing = values["pair"], !pairing.isEmpty, pairing.utf8.count <= 63 else { return nil }
        // A discovered service's interface is a link-local scope, not a permanent USB preference.
        // Preserve it; when a link disappears the caller re-browses instead of reusing this record.
        let available = interfaces.filter { $0.type != .loopback }.sorted {
            let a = interfaceRank($0), b = interfaceRank($1)
            return a == b ? $0.index < $1.index : a < b
        }
        let interface = endpoint.interface ?? available.first
        let scoped: NWEndpoint
        if case .service(let host, let type, let domain, _) = endpoint {
            scoped = .service(name: host, type: type, domain: domain, interface: interface)
        } else { scoped = endpoint }
        return Self(id: id, name: String(name.prefix(64)), endpoint: scoped, pairingName: pairing,
                    routeRank: "\(interfaceRank(interface))|" + (serviceName == id ? "0|" : "1|") + scoped.debugDescription)
    }
    private static func interfaceRank(_ interface: NWInterface?) -> Int {
        guard let interface else { return 4 }
        if interface.name.hasPrefix("awdl") { return 0 }
        switch interface.type {
        case .wiredEthernet: return 1
        case .wifi: return 2
        default: return 3
        }
    }
    var pairingEndpoint: NWEndpoint? {
        guard case .service(_, let type, let domain, let interface) = endpoint else { return nil }
        return .service(name: pairingName, type: type, domain: domain, interface: interface)
    }
    static func unique(_ records: [Self]) -> [Self] {
        var devices: [String: Self] = [:]
        for record in records {
            if let existing = devices[record.id], existing.routeRank <= record.routeRank { continue }
            devices[record.id] = record
        }
        return devices.values.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }
}

/// Bounded browsing and capped retry intervals avoid leaving peer-to-peer radios scanning indefinitely.
enum CompanionDiscoveryPolicy {
    static func retryDelay(attempt: Int, base: TimeInterval = 5) -> TimeInterval {
        min(60, base * pow(2, Double(min(4, max(0, attempt)))))
    }
}
