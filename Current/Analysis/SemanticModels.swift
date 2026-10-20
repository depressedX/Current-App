import Foundation

enum SemanticSpace {
    // Change when the audio weights, paired text encoder or frontend changes.
    static let id = "dclap-epoch36-text-v1-slaney48k-v1"
    static let dimensions = 512
    static let catalogVersion = "listening-concepts-v1"
}
enum SemanticError: LocalizedError {
    case missingResource, incompatible, invalidVector, inference, storage, tooShort
    var errorDescription: String? {
        switch self {
        case .tooShort: return "听感分析需要至少 10 秒有效音频"
        case .missingResource: return "听感模型或概念资源缺失，请重新安装 App"
        case .incompatible: return "听感数据版本不兼容，请重新分析"
        case .invalidVector: return "听感向量无效，请重新分析"
        case .inference: return "听感分析失败，请重试"
        case .storage: return "听感结果保存或读取失败，请检查可用空间后重新分析"
        }
    }
}
enum EmbeddingMath {
    static func unit(_ values: [Float]) throws -> [Float] {
        guard values.count == SemanticSpace.dimensions, values.allSatisfy(\.isFinite) else { throw SemanticError.invalidVector }
        let norm = sqrt(values.reduce(Double(0)) { $0 + Double($1) * Double($1) })
        guard norm > 1e-8 else { throw SemanticError.invalidVector }
        return values.map { Float(Double($0) / norm) }
    }
    static func cosine(_ lhs: [Float], _ rhs: [Float]) throws -> Double {
        let a = try unit(lhs), b = try unit(rhs)
        return max(-1, min(1, zip(a, b).reduce(0) { $0 + Double($1.0) * Double($1.1) }))
    }
}
struct ListeningConcept: Codable, Identifiable {
    let id: String
    let label: String
    let definition: String
    let vector: [Float]
}
struct ConceptMatch: Codable, Identifiable {
    let id: String
    let label: String
    let similarity: Double
}
struct ConceptCatalog: Codable {
    let schemaVersion: Int
    let spaceID: String
    let catalogVersion: String
    let concepts: [ListeningConcept]
    static func load(url: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1, value.spaceID == SemanticSpace.id,
              value.catalogVersion == SemanticSpace.catalogVersion, !value.concepts.isEmpty,
              Set(value.concepts.map(\.id)).count == value.concepts.count else { throw SemanticError.incompatible }
        for concept in value.concepts { _ = try EmbeddingMath.unit(concept.vector) }
        return value
    }
    static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource: "concept-vectors", withExtension: "json", subdirectory: "Semantics") else {
            throw SemanticError.missingResource
        }
        return try load(url: url)
    }
    func matches(_ vector: [Float], limit: Int = 6) throws -> [ConceptMatch] {
        try concepts.map { ConceptMatch(id: $0.id, label: $0.label, similarity: try EmbeddingMath.cosine(vector, $0.vector)) }
            .sorted { $0.similarity == $1.similarity ? $0.id < $1.id : $0.similarity > $1.similarity }.prefix(limit).map { $0 }
    }
}
struct SemanticFeatures: Codable {
    let recordID: UUID
    let spaceID: String
    let catalogVersion: String
    let matches: [ConceptMatch]
    let windowStarts: [Double]
    let windowSeconds: Double
    let elapsedSeconds: Double
    let analyzedAt: Date
    var compatible: Bool { spaceID == SemanticSpace.id && catalogVersion == SemanticSpace.catalogVersion }
}
struct SemanticAnalysis: Sendable {
    let vector: [Float]
    let windowStarts: [Double]
    let elapsedSeconds: Double
}
struct SemanticRecord: Codable {
    let schemaVersion: Int
    let account: String
    let songID: UUID
    let spaceID: String
    let vector: [Float]
}
/// Explicit test seam for a future LLM intent resolver. Input text is intentionally unused.
struct ListeningIntent: Sendable {
    let spaceID: String
    let vector: [Float]
    let label: String
}
protocol ListeningIntentResolving: Sendable {
    func resolve(text: String, catalog: ConceptCatalog) async throws -> ListeningIntent
}
struct MockListeningIntentResolver: ListeningIntentResolving {
    func resolve(text: String, catalog: ConceptCatalog) async throws -> ListeningIntent {
        try Task.checkCancellation()
        guard let anchor = catalog.concepts.randomElement() else { throw SemanticError.incompatible }
        return ListeningIntent(spaceID: catalog.spaceID, vector: anchor.vector, label: anchor.label)
    }
}

/// Permanent results survive audio cache eviction. Immutable records make failed reanalysis preserve old results.
actor SemanticDisk {
    private let directory: URL
    init(directory: URL) { self.directory = directory }
    func save(_ result: SemanticAnalysis, songID: UUID, account: String, catalog: ConceptCatalog) throws -> SemanticFeatures {
        let vector = try EmbeddingMath.unit(result.vector), recordID = UUID()
        let record = SemanticRecord(schemaVersion: 1, account: account, songID: songID, spaceID: SemanticSpace.id, vector: vector)
        let matches = try catalog.matches(vector)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: path(recordID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { throw SemanticError.storage }
        return SemanticFeatures(recordID: recordID, spaceID: SemanticSpace.id, catalogVersion: catalog.catalogVersion,
                                matches: matches, windowStarts: result.windowStarts, windowSeconds: 10,
                                elapsedSeconds: result.elapsedSeconds, analyzedAt: Date())
    }
    func load(_ features: SemanticFeatures, songID: UUID, account: String) throws -> [Float] {
        guard features.compatible else { throw SemanticError.incompatible }
        let record: SemanticRecord
        do { record = try JSONDecoder().decode(SemanticRecord.self, from: Data(contentsOf: path(features.recordID))) }
        catch { throw SemanticError.storage }
        guard record.schemaVersion == 1, record.account == account, record.songID == songID,
              record.spaceID == SemanticSpace.id else { throw SemanticError.incompatible }
        return try EmbeddingMath.unit(record.vector)
    }
    func remove(_ features: SemanticFeatures) throws {
        let url = path(features.recordID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func path(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("json") }
}

// Fixed diagnostic categories, never the model path, input text or raw ORT error string.
extension SemanticError: SafeLogError {
    var logFailure: LogFailure {
        switch self {
        case .missingResource: return .semanticModel
        case .incompatible: return .semanticVersion
        case .invalidVector: return .semanticVector
        case .inference: return .semanticInference
        case .storage: return .semanticStorage
        case .tooShort: return .tooShort
        }
    }
}
