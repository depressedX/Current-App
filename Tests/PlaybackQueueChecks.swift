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
                                       listenerID: nil, rankedCandidates: ranked)
        let archiveURL = folder.appendingPathComponent("history.json")
        try JSONEncoder().encode(Archive(sessions: [initial])).write(to: archiveURL)
        let store = AppStore(archiveURL: archiveURL)
        store.enterDemo(); store.replay(store.visibleSessions[0])
        precondition(store.queue.count == 12)
        store.play(at: 7)
        precondition(store.queue.count == 12)
        store.player.onNext?()
        precondition(store.currentIndex == 8 && store.queue.count == 24)
        store.play(at: 8)
        precondition(store.queue.count == 24)
        store.play(at: 20)
        precondition(store.queue == ranked && store.recommendationExhausted)
        store.continueWithRepeats()
        precondition(store.queue.count == 29 && !store.queueEnded)
        store.play(at: 28); store.player.onNext?()
        precondition(store.queueEnded && !store.player.playing && store.currentIndex == 28)
        store.player.onNext?()
        precondition(store.queue.count == 29)
        store.continueWithRepeats()
        precondition(!store.queueEnded && store.currentIndex == 29 && store.queue.count == 41)
        precondition(Array(store.queue.suffix(12)) == Array(ranked.prefix(12)) && store.activePrompt == "same intent")
        store.continueWithRepeats()
        precondition(store.queue.count == 41)
        let saved = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: archiveURL))
        precondition(saved.sessions[0].id == initial.id && saved.sessions[0].tracks == store.queue)
        precondition(saved.sessions[0].rankedCandidates == ranked && saved.sessions[0].issuedCandidateIDs == Set(ranked.prefix(12).map(\.id)))
        let restored = AppStore(archiveURL: archiveURL)
        restored.enterDemo(); restored.replay(restored.visibleSessions[0])
        restored.play(at: 37)
        precondition(restored.queue.count == 53) // Restore the current repeat pass, not the exhausted previous pass.
        precondition(Array(restored.queue.suffix(12)) == Array(ranked[12..<24]))
        print("PASS AppStore: auto-next, 12/12/5 batches, no duplicate refill, stop, explicit repeat, persistence and restore")

        let legacy = ListeningSession(prompt: "legacy", tracks: [ranked[0]], createdAt: Date(), listenerID: nil)
        store.replay(legacy); store.player.onNext?(); store.continueWithRepeats()
        precondition(store.queue == legacy.tracks && store.queueEnded && !store.recommendationExhausted)
        store.replay(ListeningSession(prompt: "other account", tracks: ranked, createdAt: Date(), listenerID: 123,
                                     rankedCandidates: ranked))
        precondition(store.activePrompt == "legacy" && store.queue == legacy.tracks)
        let single = ListeningSession(prompt: "single", tracks: [ranked[0]], createdAt: Date(), listenerID: nil,
                                      rankedCandidates: [ranked[0]])
        store.replay(single); store.player.onNext?(); store.continueWithRepeats()
        precondition(store.queue.count == 2 && store.currentIndex == 1 && !store.queueEnded)
        store.player.onNext?()
        precondition(store.queueEnded)
        print("PASS AppStore: legacy finite history, account isolation and single-candidate repeat")
    }
}
