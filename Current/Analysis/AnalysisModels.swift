import Foundation

struct AcousticFeatures: Codable, Equatable {
    let bpm: Double?
    /// Autocorrelation strength, not a calibrated probability.
    let rhythmStrength: Double
    let rmsDBFS: Double
    let peakDBFS: Double
    let dynamicSpreadDB: Double
    let zeroCrossingsPerSecond: Double
    let sampleStart: Double
    let sampleDuration: Double
    let elapsedSeconds: Double
    var version = "native-acoustic-v1"
    // Semantic tags/embedding need a separately validated model. Never derive them from loudness/BPM.
}

enum AnalysisState: String, Codable {
    case queued, readingMetadata, fetching, analyzing, completed, failed
    var title: String {
        switch self {
        case .queued: return "等待分析"
        case .readingMetadata: return "获取网易云 BPM"
        case .fetching: return "获取音频"
        case .analyzing: return "分析听感中"
        case .completed: return "分析完成"
        case .failed: return "分析失败"
        }
    }
    var active: Bool { self == .readingMetadata || self == .fetching || self == .analyzing }
}

enum BPMSource: String, Codable {
    case neteaseWiki, localAnalysis
    var title: String { self == .neteaseWiki ? "网易云音乐百科" : "本地音频估计" }
}
enum BPMLookupState: String, Codable {
    case available, missing, failed
    var title: String {
        switch self {
        case .available: return "已获取"
        case .missing: return "未提供 BPM"
        case .failed: return "本次获取失败"
        }
    }
}
struct WikiBPM: Codable, Equatable {
    let value: Double
    let fetchedAt: Date
    var version = "netease-song-wiki-v1"
}

struct PoolSong: Identifiable, Codable {
    let id: UUID
    let track: Track
    let account: String
    var sources: [String]
    var state: AnalysisState = .queued
    var needsReanalysis: Bool?
    var features: AcousticFeatures?
    var semantic: SemanticFeatures?
    var wikiBPM: WikiBPM?
    var bpmLookup: BPMLookupState?
    var bpmCheckedAt: Date?
    var resolvedBPM: Double? { wikiBPM?.value ?? features?.bpm }
    var bpmSource: BPMSource? {
        if wikiBPM != nil { return .neteaseWiki }
        return features?.bpm != nil ? .localAnalysis : nil
    }
    var canBackfillBPM: Bool { state == .completed && !track.isDemo && wikiBPM == nil }
    var failure: String?
    let addedAt: Date
    var finishedAt: Date?
    /// Eligibility depends on the query: basic measurements never satisfy semantic requests.
    var semanticReady: Bool { semantic?.compatible == true && needsReanalysis != true && state == .completed }
}

struct PoolCatalog: Codable {
    var songs: [PoolSong] = []
    mutating func enqueue(_ tracks: [Track], account: String, source: String) -> Int {
        var count = 0
        var lookup = Dictionary(songs.indices.map { ("\(songs[$0].account):\(songs[$0].track.id)", $0) }, uniquingKeysWith: { first, _ in first })
        for track in tracks {
            let key = "\(account):\(track.id)"
            if let index = lookup[key] {
                if !songs[index].sources.contains(source) { songs[index].sources.append(source) }
            } else {
                lookup[key] = songs.count
                songs.append(PoolSong(id: UUID(), track: track, account: account, sources: [source], addedAt: Date()))
                count += 1
            }
        }
        return count
    }
    mutating func recoverInterrupted() {
        for index in songs.indices where songs[index].state.active { songs[index].state = .queued }
    }
}
