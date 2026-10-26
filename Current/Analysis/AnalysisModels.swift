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
    var profile: ObjectiveProfile? = nil
    var version = "native-acoustic-v1"
    // Semantic tags/embedding need a separately validated model. Never derive them from loudness/BPM.
}

enum AnalysisState: String, Codable {
    case queued, readingMetadata, readingLyrics, fetching, analyzing, completed, failed
    var title: String {
        switch self {
        case .queued: return "等待分析"
        case .readingMetadata: return "获取网易云百科"
        case .readingLyrics: return "分析歌词"
        case .fetching: return "获取音频"
        case .analyzing: return "分析听感中"
        case .completed: return "分析完成"
        case .failed: return "分析失败"
        }
    }
    var active: Bool { self == .readingMetadata || self == .readingLyrics || self == .fetching || self == .analyzing }
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
    var remoteRequestID: UUID?
    var remotePending: Bool?
    var needsReanalysis: Bool?
    var features: AcousticFeatures?
    var semantic: SemanticFeatures?
    var genres: GenreAnalysis?
    var wikiBPM: WikiBPM?
    var wikiMetadata: SongWikiMetadata?
    var lyrics: LyricsSummary?
    var lyricsFailure: Bool?
    var needsLyricsReindex: Bool?
    var lyricsReturnState: AnalysisState?
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

/// Versioned evidence, not subjective mood scores. No raw audio is persisted.
struct ObjectiveProfile: Codable, Equatable {
    static let currentVersion = "objective-v1"
    var version = currentVersion
    let duration: Double
    let decodedFraction: Double
    let activeSeconds: Int
    let loudnessSpreadDB: Double
    let spectralChange: Double?
    let spectralPeak: Double?
    let largestRiseDB: Double
    let rises: [LoudnessRise]
    let vocalWindows: Int
    let classifiedWindows: Int
    let uncertainVocalWindows: Int
    let soundLabels: [DetectedSound]
    let classifierAvailable: Bool
    var vocalDescription: String {
        guard classifierAvailable, classifiedWindows > 0 else { return "无法判断" }
        let ratio = Double(vocalWindows) / Double(classifiedWindows)
        if Double(uncertainVocalWindows) / Double(classifiedWindows) > 0.25 { return "人声分布不确定" }
        if ratio >= 0.7 { return "人声持续出现" }
        if ratio >= 0.2 { return "部分片段有人声" }
        if vocalWindows > 0 { return "少量片段有人声" }
        return "未明确检测到人声"
    }
    var steadiness: String {
        guard decodedFraction >= 0.98, activeSeconds >= 8 else { return "音频覆盖不足" }
        if loudnessSpreadDB <= 5 && largestRiseDB < 6 { return "响度较平稳" }
        if loudnessSpreadDB >= 10 || largestRiseDB >= 9 { return "响度起伏明显" }
        return "有一定响度变化"
    }
}
struct LoudnessRise: Codable, Equatable {
    let second: Int
    let decibels: Double
}
struct DetectedSound: Codable, Equatable {
    let label: String
    let windows: Int
}

/// Independent multi-label activations, not exclusive choices or calibrated probabilities.
struct GenreMatch: Codable, Equatable, Identifiable {
    let index: Int
    let family: String
    let style: String
    let score: Double
    var id: Int { index }
    var title: String { GenreNames.translate(style) }
    var familyTitle: String { GenreNames.translate(family) }
}
struct GenreAnalysis: Codable, Equatable {
    static let currentVersion = "discogs-effnet-400-v1"
    var version = currentVersion
    let matches: [GenreMatch]
    let windows: Int
    let duration: Double
    let analyzedAt: Date
    var compatible: Bool { version == Self.currentVersion }
    static func summarize(scores: [Double], labels: [String], windows: Int, duration: Double) throws -> Self {
        guard scores.count == 400, labels.count == 400, Set(labels).count == 400,
              scores.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              windows > 0, duration.isFinite, duration > 0 else { throw GenreError.invalidOutput }
        let matches = try scores.indices.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
            .prefix(5).map { index -> GenreMatch in
                let parts = labels[index].components(separatedBy: "---")
                guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { throw GenreError.invalidOutput }
                return GenreMatch(index: index, family: parts[0], style: parts[1], score: scores[index])
            }
        return Self(matches: matches, windows: windows, duration: duration, analyzedAt: Date())
    }
}

extension RecommendationGenre {
    /// Conservative retrieval policy, not calibrated probabilities. Do not sum correlated labels.
    /// Require both absolute support and proximity to the strongest competing style.
    func hasEvidence(in analysis: GenreAnalysis?) -> Bool {
        guard let analysis, analysis.compatible,
              !analysis.matches.isEmpty,
              analysis.matches.allSatisfy({ $0.score.isFinite && (0...1).contains($0.score) }),
              let strongest = analysis.matches.map(\.score).max() else { return false }
        let support = analysis.matches.filter { match in
            switch self {
            case .house:
                return match.family == "Electronic" && Self.houseStyles.contains(match.style)
            case .rock:
                return match.family == "Rock"
            }
        }.map(\.score).max() ?? 0
        return support >= 0.2 && support >= strongest * 0.75
    }

    private static let houseStyles: Set<String> = [
        "Acid House", "Deep House", "Electro House", "Euro House", "Garage House", "Ghetto House",
        "Hard House", "Hip-House", "House", "Italo House", "Progressive House", "Tech House",
        "Tribal House", "Tropical House"
    ]
}

extension GenreAnalysis {
    var supportedMatches: [GenreMatch] {
        guard compatible, matches.allSatisfy({ $0.score.isFinite && (0...1).contains($0.score) }),
              let strongest = matches.map(\.score).max() else { return [] }
        return matches.filter { $0.score >= 0.2 && $0.score >= strongest * 0.75 }
    }
    var filterFamilies: Set<String> { Set(supportedMatches.map(\.familyTitle)) }
    var filterStyles: Set<String> {
        var values = Set(supportedMatches.map(\.title))
        if RecommendationGenre.house.hasEvidence(in: self) { values.insert("House") }
        return values
    }
    var filterLabels: Set<String> { filterFamilies.union(filterStyles) }
}

extension RecommendationQuery {
    func matchesGenres(_ analysis: GenreAnalysis?, wiki: Set<String> = []) -> Bool {
        let required = preferences.filter { $0.isGenre && $0.requirement == .required }
        let positive = required.filter { $0.direction == .prefer }
        let negative = required.filter { $0.direction == .avoid }
        return (positive.isEmpty || positive.contains { $0.matchesGenre(analysis, wiki: wiki) })
            && !negative.contains { $0.matchesGenre(analysis, wiki: wiki) }
    }
}

extension RecommendationQuery.Preference {
    func matchesGenre(_ analysis: GenreAnalysis?, wiki: Set<String>) -> Bool {
        if let genre { return genre.hasEvidence(in: analysis) }
        guard let reference = genreReference else { return false }
        switch reference.source {
        case .encyclopedia: return wiki.contains(reference.value)
        case .audioFamily: return analysis?.supportedMatches.contains { $0.family == reference.value } == true
        case .audioStyle: return analysis?.supportedMatches.contains { "\($0.family)---\($0.style)" == reference.value } == true
        }
    }
}

extension PoolSong {
    var wikiGenreLabels: Set<String> {
        guard let wikiMetadata, wikiMetadata.songID == track.id else { return [] }
        return wikiMetadata.genreLabels
    }
    func matchesGenreFilters(audio: Set<String>, encyclopedia: Set<String>) -> Bool {
        (audio.isEmpty && encyclopedia.isEmpty)
            || (!audio.isEmpty && !audio.isDisjoint(with: genres?.filterLabels ?? []))
            || (!encyclopedia.isEmpty && !encyclopedia.isDisjoint(with: wikiGenreLabels))
    }
}
enum GenreError: LocalizedError, SafeLogError {
    case missingModel, incompatible, invalidOutput, tooShort, inference
    var errorDescription: String? {
        switch self {
        case .missingModel: return "风格模型文件缺失或损坏，请重新安装 App"
        case .incompatible: return "风格模型版本不兼容，请更新 App"
        case .invalidOutput: return "风格分析结果无效，请重新分析"
        case .tooShort: return "有效音频不足，无法识别风格"
        case .inference: return "风格分析失败，请重试"
        }
    }
    var logFailure: LogFailure {
        switch self {
        case .missingModel: return .genreModel
        case .incompatible: return .genreVersion
        case .invalidOutput: return .genreOutput
        case .tooShort: return .tooShort
        case .inference: return .genreInference
        }
    }
}
enum GenreNames {
    // Unknown Discogs names stay in the original language, rather than inventing translations.
    static func translate(_ value: String) -> String { names[value] ?? value }
    private static let names: [String: String] = [
        "Rock":"摇滚", "Pop":"流行", "Electronic":"电子", "Hip Hop":"嘻哈", "Jazz":"爵士",
        "Funk / Soul":"放克 / 灵魂", "Folk, World, & Country":"民谣 / 世界 / 乡村", "Latin":"拉丁",
        "Blues":"布鲁斯", "Classical":"古典", "Reggae":"雷鬼", "Stage & Screen":"影视配乐",
        "Ballad":"抒情曲", "Vocal":"人声", "Lounge":"休闲氛围", "J-pop":"日系流行", "K-pop":"韩系流行",
        "Funk":"放克", "Soul":"灵魂", "Folk":"民谣", "Indie Rock":"独立摇滚", "Alternative Rock":"另类摇滚",
        "Synth-pop":"合成器流行", "Electro":"电子舞曲", "Acoustic":"原声", "Neofolk":"新民谣",
        "Downtempo":"慢拍电子", "Jazzy Hip-Hop":"爵士嘻哈", "Instrumental":"器乐", "Post Rock":"后摇",
        "Shoegaze":"盯鞋", "Post-Punk":"后朋克", "Dream Pop":"梦幻流行", "Noise":"噪音", "Indie Pop":"独立流行",
        "Experimental":"实验", "Ambient":"氛围", "Pop Rock":"流行摇滚", "New Wave":"新浪潮", "Lo-Fi":"低保真",
        "Soft Rock":"软摇滚", "Psychedelic Rock":"迷幻摇滚", "Disco":"迪斯科", "House":"House",
        "Art Rock":"艺术摇滚", "Garage Rock":"车库摇滚", "Hard Rock":"硬摇滚", "Punk":"朋克",
        "Chanson":"香颂", "City Pop":"城市流行", "Math Rock":"数学摇滚", "Post-Metal":"后金属",
        "Deep House":"Deep House", "Tropical House":"Tropical House", "Heavy Metal":"重金属",
        "Techno":"Techno", "Trip Hop":"Trip Hop", "Classic Rock":"经典摇滚", "Country":"乡村"
    ]
}
