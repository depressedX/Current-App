import Foundation

struct Listener: Codable, Equatable {
    let id: Int
    let name: String
    let avatar: URL?
}

struct Track: Identifiable, Codable, Equatable {
    let id: Int
    let title: String
    let artist: String
    let album: String
    let artwork: URL?
    let duration: Double
    let demoIndex: Int?
    var isDemo: Bool { demoIndex != nil }
}

struct UserPlaylist: Identifiable, Equatable {
    let id: Int
    let title: String
    let count: Int
    let artwork: URL?
}

enum FeedbackKind: String, Codable, CaseIterable, Identifiable {
    // Current-only preference signals. Never translate these into NetEase favorite/like mutations.
    case fits, notNow, wrongMood, wrongStyle, tired, snooze, dislike
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fits: return "很合此刻"
        case .notNow: return "不适合此刻"
        case .wrongMood: return "情绪不太对"
        case .wrongStyle: return "风格不太对"
        case .tired: return "听腻了"
        case .snooze: return "暂时不想听"
        case .dislike: return "不喜欢这首"
        }
    }
    var symbol: String {
        switch self {
        case .fits: return "heart.fill"
        case .notNow: return "forward.end"
        case .wrongMood: return "cloud"
        case .wrongStyle: return "slider.horizontal.3"
        case .tired: return "moon.zzz"
        case .snooze: return "clock"
        case .dislike: return "hand.thumbsdown"
        }
    }
}

struct Feedback: Identifiable, Codable {
    var id = UUID()
    let trackID: Int
    let trackTitle: String
    let prompt: String
    var kind: FeedbackKind
    let date: Date
    let listenerID: Int?
}

struct ListeningSession: Identifiable, Codable {
    var id = UUID()
    let prompt: String
    let tracks: [Track]
    let createdAt: Date
    let listenerID: Int?
}

/// Deliberately ignores musical meaning. This MVP validates the interaction, not recommendation quality.
enum QueueComposer {
    static func compose(catalog: [Track], limit: Int = 12, excluding: Set<Int> = []) -> [Track] {
        var seen = Set<Int>()
        return Array(catalog.filter { !excluding.contains($0.id) && seen.insert($0.id).inserted }
            .shuffled().prefix(max(0, limit)))
    }
}

enum DemoCatalog {
    static let tracks: [Track] = [
        ("暮色缓流", "Evening current"), ("沿着海岸", "Coastline"),
        ("房间里的雨", "Rain in the room"), ("夜行信号", "Night signal"),
        ("留白", "A little space"), ("日光散步", "Daylight walk"),
        ("微小引力", "Small gravity"), ("远处的回声", "Distant echoes")
    ].enumerated().map { index, item in
        Track(id: -(index + 1), title: item.0, artist: "Current Studio",
              album: "原创交互演示 · \(item.1)", artwork: nil, duration: 24, demoIndex: index)
    }
}
