import Foundation
import Combine

/// Transport double: exercise the real AppStore without audio hardware or network playback.
@MainActor final class PlaybackController: ObservableObject {
    @Published var playing = false
    var position: Double = 0
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onLike: (() -> Void)?
    func load(_ song: Track, api: NetEaseAPI, next: Track? = nil) async { playing = true }
    func pause() { playing = false }
    func seek(_ time: Double) { position = time }
    func stop() { playing = false; position = 0 }
}

@main struct PlaybackQueueChecks {
    struct Archive: Codable { var sessions: [ListeningSession]; var feedback: [Feedback] = [] }
    @MainActor static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ranked = (0..<29).map { Track(id: -100 - $0, title: "Fixture \($0)", artist: "Fixture", album: "Fixture",
                                         artwork: nil, duration: 24, demoIndex: 0) }
        let initial = ListeningSession(prompt: "same intent", tracks: Array(ranked.prefix(12)), createdAt: Date(),
                                       listenerID: nil, rankedCandidates: ranked,
                                       recommendationQuery: RecommendationQuery(summary: "House", bpmMinimum: nil,
                                           bpmMaximum: nil, bpmRequired: true,
                                           preferences: [.init(concept: "house", direction: .prefer, weight: 1)], unsupported: [], bpmTarget: 120))
        let archiveURL = folder.appendingPathComponent("history.json")
        try JSONEncoder().encode(Archive(sessions: [initial])).write(to: archiveURL)
        let store = AppStore(archiveURL: archiveURL)
        store.enterDemo(); store.replay(store.visibleSessions[0])
        precondition(store.activeRecommendationSummary?.contains("110–130 BPM") == true)
        precondition(store.queue == ranked && store.canRepeatRecommendation)
        store.play(at: 25); store.player.onNext?()
        precondition(store.currentIndex == 26 && store.queue == ranked)
        store.continueWithRepeats()
        precondition(store.currentIndex == 26 && store.queue.count == 29)
        store.play(at: 28); store.player.onNext?()
        precondition(store.queueEnded && !store.player.playing && store.currentIndex == 28)
        store.player.onNext?(); precondition(store.queue.count == 29)
        store.continueWithRepeats()
        precondition(!store.queueEnded && store.currentIndex == 0 && store.queue == ranked)
        let saved = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: archiveURL))
        precondition(saved.sessions[0].id == initial.id && saved.sessions[0].tracks == ranked)
        precondition(saved.sessions[0].rankedCandidates == nil && saved.sessions[0].issuedCandidateIDs == nil)
        precondition(saved.sessions[0].recommendationQuery?.preferences.first?.requirement == .required)
        let restored = AppStore(archiveURL: archiveURL)
        restored.enterDemo(); restored.replay(restored.visibleSessions[0])
        precondition(restored.queue == ranked && restored.activeRecommendationSummary == store.activeRecommendationSummary)
        precondition(RecommendationPlaylist(candidates: ranked + ranked).tracks == ranked)
        print("PASS full playlist: all 29 tracks immediately, no refill, end/explicit restart without growth, legacy batched migration, query/history persistence and deduplication")

        let legacy = ListeningSession(prompt: "legacy", tracks: [ranked[0]], createdAt: Date(), listenerID: nil)
        store.replay(legacy); store.player.onNext?(); store.continueWithRepeats()
        precondition(store.activeRecommendationSummary == nil)
        precondition(store.queue == legacy.tracks && store.queueEnded && !store.canRepeatRecommendation)
        store.replay(ListeningSession(prompt: "other account", tracks: ranked, createdAt: Date(), listenerID: 123,
                                     rankedCandidates: ranked))
        precondition(store.activePrompt == "legacy" && store.queue == legacy.tracks)
        let single = ListeningSession(prompt: "single", tracks: [ranked[0]], createdAt: Date(), listenerID: nil,
                                      rankedCandidates: [ranked[0]])
        store.replay(single); store.player.onNext?(); store.continueWithRepeats()
        precondition(store.queue.count == 1 && store.currentIndex == 0 && !store.queueEnded)
        store.player.onNext?()
        precondition(store.queueEnded)
        let oldURL = folder.appendingPathComponent("old-batched.json")
        let oldBatch = ListeningSession(prompt: "old batch without query", tracks: [ranked[0]], createdAt: Date(), listenerID: nil,
                                       rankedCandidates: Array(ranked.prefix(2)))
        try JSONEncoder().encode(Archive(sessions: [oldBatch])).write(to: oldURL)
        let upgraded = AppStore(archiveURL: oldURL)
        upgraded.enterDemo(); upgraded.replay(upgraded.visibleSessions[0])
        let reopened = AppStore(archiveURL: oldURL)
        reopened.enterDemo(); reopened.replay(reopened.visibleSessions[0])
        precondition(reopened.queue.count == 2 && reopened.canRepeatRecommendation)
        reopened.play(at: 1); reopened.next(); reopened.continueWithRepeats()
        precondition(reopened.currentIndex == 0 && reopened.queue.count == 2)
        print("PASS AppStore: legacy finite history, account isolation and single-candidate repeat")
    }
}
