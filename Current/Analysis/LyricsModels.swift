import Foundation
import CryptoKit

enum LyricsSpace {
    static let id = "bge-small-zh-v1.5-int8-cls-v1"
    static let preprocessing = "chinese-lrc-4lines-hop2-v1"
    static let dimensions = 512
}
enum LyricsSource: String, Codable, Sendable {
    case original, translation
    var title: String { self == .original ? "中文原词" : "网易云中文译词" }
}
enum LyricsStatus: String, Codable, Sendable {
    case indexed, noUsableText, noChineseText
    var title: String {
        switch self {
        case .indexed: return "歌词已索引"
        case .noUsableText: return "暂无可用歌词"
        case .noChineseText: return "暂无可用中文原词或译词"
        }
    }
}
struct LyricsLine: Codable, Equatable, Sendable {
    let text: String
    let second: Double?
}
struct LyricsChunk: Codable, Equatable, Sendable {
    let source: LyricsSource
    let lines: [LyricsLine]
    var text: String { lines.map(\.text).joined(separator: "\n") }
}
struct LyricsPreparation: Sendable {
    let chunks: [LyricsChunk]
    let status: LyricsStatus
    let contentHash: String
}
struct LyricsVectorChunk: Codable, Sendable {
    let chunk: LyricsChunk
    let vector: [Float]
}
struct LyricsAnalysis: Codable, Sendable {
    let status: LyricsStatus
    let contentHash: String
    let chunks: [LyricsVectorChunk]
    let fetchedAt: Date
}
struct LyricsSummary: Codable, Equatable, Sendable {
    let recordID: UUID?
    let spaceID: String
    let preprocessing: String
    let contentHash: String
    let status: LyricsStatus
    let chunkCount: Int
    let sources: [LyricsSource]
    let fetchedAt: Date
    var compatible: Bool { spaceID == LyricsSpace.id && preprocessing == LyricsSpace.preprocessing }
}
struct LyricsRecord: Codable {
    let schemaVersion: Int
    let account: String
    let songID: UUID
    let spaceID: String
    let preprocessing: String
    let contentHash: String
    let chunks: [LyricsVectorChunk]
}
struct LyricsSearchEntry {
    let songID: UUID
    let track: Track
    let summary: LyricsSummary
}
struct LyricsSearchMatch: Identifiable {
    let id: UUID
    let track: Track
    let source: LyricsSource
    let lines: [LyricsLine]
    let similarity: Double
}
struct LyricsSearchResults {
    let matches: [LyricsSearchMatch]
    let unavailableCount: Int
    let indexedSongs: Int
}
enum LyricsError: Error, LocalizedError, SafeLogError {
    case model, incompatible, invalidVector, inference, storage, tooLong
    var errorDescription: String? {
        switch self {
        case .model: return "歌词模型缺失或损坏，请重新安装 App"
        case .incompatible: return "歌词索引版本不兼容，请更新歌词索引"
        case .invalidVector: return "歌词向量无效，请更新歌词索引"
        case .inference: return "歌词分析失败，请重试"
        case .storage: return "歌词索引无法读取或保存，请重试"
        case .tooLong: return "文本过长，请缩短后重试"
        }
    }
    var logFailure: LogFailure {
        switch self {
        case .model: return .lyricsModel
        case .incompatible: return .lyricsVersion
        case .invalidVector: return .lyricsVector
        case .inference: return .lyricsInference
        case .storage: return .lyricsStorage
        case .tooLong: return .tooLarge
        }
    }
}
enum LyricsMath {
    static func unit(_ vector: [Float]) throws -> [Float] {
        guard vector.count == LyricsSpace.dimensions, vector.allSatisfy(\.isFinite) else { throw LyricsError.invalidVector }
        let length = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard length > 1e-8 else { throw LyricsError.invalidVector }
        return vector.map { Float(Double($0) / length) }
    }
}
enum LyricsParser {
    static func prepare(_ document: LyricsDocument) throws -> LyricsPreparation {
        guard document.original.utf8.count + document.translation.utf8.count <= 256_000 else { throw LyricsError.tooLong }
        var chunks: [LyricsChunk] = [], unsupported = false
        for source in [LyricsSource.original, .translation] {
            let lines = parse(source == .original ? document.original : document.translation)
            let scalars = lines.map(\.text).joined().unicodeScalars
            let han = scalars.filter { (0x4e00...0x9fff).contains($0.value) }.count
            let letters = scalars.filter { (65...90).contains($0.value) || (97...122).contains($0.value) || (0x4e00...0x9fff).contains($0.value) || (0x3040...0x30ff).contains($0.value) }.count
            let kana = scalars.contains { (0x3040...0x30ff).contains($0.value) }
            guard han >= 2, Double(han) / Double(max(1, letters)) >= 0.5, !kana else {
                if !lines.isEmpty { unsupported = true }; continue
            }
            var seen: Set<String> = []
            for start in stride(from: 0, to: lines.count, by: 2) {
                let chunk = LyricsChunk(source: source, lines: Array(lines[start..<min(start + 4, lines.count)]))
                if chunk.text.count >= 5 && seen.insert(chunk.text).inserted { chunks.append(chunk) }
            }
        }
        guard chunks.count <= 512 else { throw LyricsError.tooLong }
        let payload = chunks.map { $0.source.rawValue + "\n" + $0.text + "\n" + $0.lines.map { $0.second.map(String.init(describing:)) ?? "" }.joined(separator: ",") }.joined(separator: "\n---\n")
        let hash = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        return LyricsPreparation(chunks: chunks, status: chunks.isEmpty ? (unsupported ? .noChineseText : .noUsableText) : .indexed, contentHash: hash)
    }
    static func parse(_ text: String) -> [LyricsLine] {
        let timestamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        let tags = try! NSRegularExpression(pattern: #"\[[^\]]*\]"#)
        let credits = try! NSRegularExpression(pattern: #"^(作词|作曲|编曲|制作|录音|混音|母带|出品|发行|版权|翻译|译者|演唱|吉他|贝斯|鼓|人声|键盘|摇铃|小号|合成器|词|曲|音乐监制|监制|统筹|封面|设计|鸣谢|Lyrics|Composer|Producer|Vocal)[^:：]{0,20}[:：]"#, options: .caseInsensitive)
        return text.components(separatedBy: .newlines).compactMap { raw in
            let range = NSRange(raw.startIndex..., in: raw)
            let time = timestamp.firstMatch(in: raw, range: range)
            let clean = tags.stringByReplacingMatches(in: raw, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, credits.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)) == nil,
                  !["纯音乐，请欣赏", "纯音乐,请欣赏", "此歌曲为没有填词", "未经许可", "版权所有"].contains(where: clean.contains) else { return nil }
            var second: Double?
            if let time, let m = Range(time.range(at: 1), in: raw), let s = Range(time.range(at: 2), in: raw),
               let minutes = Double(raw[m]), let seconds = Double(raw[s]), seconds < 60 {
                let value = minutes * 60 + seconds
                if value.isFinite && value <= 86_400 { second = value }
            }
            return LyricsLine(text: clean, second: second)
        }
    }
}

/// Immutable, account-scoped records. No lyrics or vectors enter the pool catalogue or diagnostics.
actor LyricsDisk {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func save(_ analysis: LyricsAnalysis, songID: UUID, account: String) throws -> LyricsSummary {
        guard analysis.chunks.count <= 512, (analysis.status == .indexed) == !analysis.chunks.isEmpty else { throw LyricsError.invalidVector }
        for item in analysis.chunks { _ = try LyricsMath.unit(item.vector) }
        let recordID = analysis.chunks.isEmpty ? nil : UUID()
        if let recordID {
            let record = LyricsRecord(schemaVersion: 1, account: account, songID: songID, spaceID: LyricsSpace.id,
                                      preprocessing: LyricsSpace.preprocessing, contentHash: analysis.contentHash, chunks: analysis.chunks)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(record).write(to: path(recordID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { throw LyricsError.storage }
        }
        return LyricsSummary(recordID: recordID, spaceID: LyricsSpace.id, preprocessing: LyricsSpace.preprocessing,
                             contentHash: analysis.contentHash, status: analysis.status, chunkCount: analysis.chunks.count,
                             sources: [LyricsSource.original, .translation].filter { source in analysis.chunks.contains { $0.chunk.source == source } }, fetchedAt: analysis.fetchedAt)
    }
    func load(_ summary: LyricsSummary, songID: UUID, account: String) throws -> LyricsRecord {
        guard summary.compatible, summary.status == .indexed, let id = summary.recordID else { throw LyricsError.incompatible }
        let record: LyricsRecord
        do { record = try JSONDecoder().decode(LyricsRecord.self, from: Data(contentsOf: path(id))) }
        catch { throw LyricsError.storage }
        guard record.schemaVersion == 1, record.account == account, record.songID == songID,
              record.spaceID == summary.spaceID, record.preprocessing == summary.preprocessing,
              record.contentHash == summary.contentHash, record.chunks.count == summary.chunkCount else { throw LyricsError.incompatible }
        for item in record.chunks { _ = try LyricsMath.unit(item.vector) }
        return record
    }
    func search(_ vector: [Float], entries: [LyricsSearchEntry], account: String) throws -> LyricsSearchResults {
        let query = try LyricsMath.unit(vector)
        var matches: [LyricsSearchMatch] = [], unavailable = 0
        for entry in entries {
            try Task.checkCancellation()
            do {
                let record = try load(entry.summary, songID: entry.songID, account: account)
                var best: (LyricsVectorChunk, Double)?
                for item in record.chunks {
                    let normalized = try LyricsMath.unit(item.vector)
                    let similarity = max(-1, min(1, zip(query, normalized).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }))
                    if best == nil || similarity > best!.1 { best = (item, similarity) }
                }
                if let best { matches.append(LyricsSearchMatch(id: entry.songID, track: entry.track, source: best.0.chunk.source, lines: best.0.chunk.lines, similarity: best.1)) }
            } catch is CancellationError { throw CancellationError() }
            catch { unavailable += 1 }
        }
        matches.sort { $0.similarity == $1.similarity ? $0.track.id < $1.track.id : $0.similarity > $1.similarity }
        return LyricsSearchResults(matches: Array(matches.prefix(10)), unavailableCount: unavailable, indexedSongs: entries.count)
    }
    private func path(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("json") }
}
