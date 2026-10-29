import Foundation
import Combine

/// Transport double: exercise the real AppStore without audio hardware or network playback.
@MainActor final class PlaybackController: ObservableObject {
    @Published var playing = false
    var position: Double = 0
    private(set) var loadedTrack: Track?
    private(set) var loadCount = 0
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onLike: (() -> Void)?
    func load(_ song: Track, next: Track? = nil, resolve: @escaping (Track) async throws -> URL) async { loadedTrack = song; loadCount += 1; playing = true }
    func updateUpcomingTrack(_ next: Track?) {}
    func pause() { playing = false }
    func seek(_ time: Double) { position = time }
    func stop() { playing = false; position = 0 }
}

@main struct PlaybackQueueChecks {
    struct Archive: Codable { var sessions: [ListeningSession]; var feedback: [Feedback] = [] }
    @MainActor static func main() async throws {
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

        let preview = AppStore(archiveURL: folder.appendingPathComponent("preview/history.json"))
        preview.enterDemo()
        let query = initial.recommendationQuery!
        try preview.stageRecommendation(prompt: "first", tracks: ranked + ranked, query: query)
        precondition(preview.generatedPlaylist?.tracks == ranked && preview.queue.isEmpty)
        precondition(preview.currentTrack == nil && preview.player.loadCount == 0 && !preview.player.playing)
        precondition(preview.message == nil && !preview.generatedPlaylistIsActive)
        preview.playGeneratedPlaylist(at: 7)
        await Task.yield()
        precondition(preview.queue == ranked && preview.currentIndex == 7 && preview.generatedPlaylistIsActive)
        precondition(preview.activePrompt == "first" && preview.canRepeatRecommendation)
        while preview.player.loadedTrack == nil { await Task.yield() }
        preview.player.position = 12
        let loads = preview.player.loadCount
        let activeTrack = preview.player.loadedTrack
        let second = Array(ranked.suffix(3))
        try preview.stageRecommendation(prompt: "second", tracks: second, query: query)
        precondition(preview.generatedPlaylist?.tracks == second && !preview.generatedPlaylistIsActive)
        precondition(preview.queue == ranked && preview.currentIndex == 7 && preview.activePrompt == "first")
        precondition(preview.player.playing && preview.player.position == 12 && preview.player.loadedTrack == activeTrack)
        precondition(preview.player.loadCount == loads && preview.message == nil)
        precondition(preview.activeRecommendationSummary?.contains("110–130 BPM") == true)
        do {
            try preview.stageRecommendation(prompt: "empty", tracks: [], query: query)
            fatalError("empty playlist accepted")
        } catch CurrentError.message {}
        precondition(preview.generatedPlaylist?.prompt == "second" && preview.currentIndex == 7)
        preview.playGeneratedPlaylist(at: 999)
        precondition(preview.queue == ranked && preview.currentIndex == 7)
        preview.cancelGeneration()
        precondition(preview.generatedPlaylist?.prompt == "second" && preview.queue == ranked)
        preview.playGeneratedPlaylist()
        precondition(preview.queue == second && preview.currentIndex == 0 && preview.generatedPlaylistIsActive)
        preview.play(at: second.count - 1); preview.next(); preview.continueWithRepeats()
        precondition(preview.queue == second && preview.currentIndex == 0 && !preview.queueEnded)
        let previewArchive = try JSONDecoder().decode(Archive.self,
            from: Data(contentsOf: folder.appendingPathComponent("preview/history.json")))
        precondition(previewArchive.sessions.count == 2 && previewArchive.sessions.first?.tracks == second)
        precondition(previewArchive.sessions.last?.tracks == ranked)
        await preview.signOut()
        precondition(preview.generatedPlaylist == nil && preview.generationError == nil && preview.queue.isEmpty)
        preview.playGeneratedPlaylist()
        precondition(preview.queue.isEmpty)
        print("PASS generated playlist preview: no autoplay/toast, unchanged active audio and feedback context, explicit row/all playback, empty/invalid guards, persistence, repeat, cancellation and logout cleanup")

        store.replay(initial, startingAt: 7)
        while store.player.loadedTrack != ranked[7] { await Task.yield() }
        let beforeShuffle = store.player.loadCount
        store.setShuffleEnabled(true)
        let order = store.playbackOrder
        precondition(order.first == 7 && Set(order) == Set(ranked.indices) && order.count == ranked.count)
        precondition(store.currentIndex == 7 && store.player.loadCount == beforeShuffle)
        store.next(); precondition(store.currentIndex == order[1])
        store.player.position = 0
        store.previous(); precondition(store.currentIndex == 7)
        for expected in order.dropFirst() { store.next(); precondition(store.currentIndex == expected) }
        store.next(); precondition(store.queueEnded)
        store.continueWithRepeats(); precondition(!store.queueEnded && store.queue == ranked)
        store.setShuffleEnabled(false)
        precondition(store.playbackOrder == Array(ranked.indices))
        store.play(at: 7); store.next(); precondition(store.currentIndex == 8)
        print("PASS shuffle: stable permutation, current track preserved without reload, next/previous, finite end, repeat and sequential restoration")

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

        let libraryFolder = folder.appendingPathComponent("library")
        let libraryStore = AppStore(archiveURL: libraryFolder.appendingPathComponent("history.json"))
        var catalog = PoolCatalog()
        _ = catalog.enqueue(Array(ranked.prefix(3)), account: "demo", source: "library check")
        for index in 0..<2 { catalog.songs[index].state = .completed }
        let poolFolder = libraryFolder.appendingPathComponent("UITestSongPool")
        try FileManager.default.createDirectory(at: poolFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(catalog).write(to: poolFolder.appendingPathComponent("song-pool.json"))
        while libraryStore.pool.loading { await Task.yield() }
        libraryStore.pool.activate(account: "demo")
        let selection = [catalog.songs[1].id, catalog.songs[0].id]
        libraryStore.playLibrary(selection, account: "demo")
        precondition(libraryStore.queue.isEmpty, "Logged-out playback must be ignored")
        libraryStore.enterDemo()
        libraryStore.replay(initial)
        libraryStore.play(at: 28); libraryStore.next()
        libraryStore.playLibrary(selection, account: "demo")
        await Task.yield()
        precondition(libraryStore.queue == [ranked[1], ranked[0]] && libraryStore.currentIndex == 0)
        precondition(libraryStore.player.playing && !libraryStore.queueEnded && !libraryStore.canRepeatRecommendation)
        precondition(libraryStore.activeRecommendationSummary == nil && libraryStore.activePrompt == "曲库筛选")
        libraryStore.playLibrary([], account: "demo")
        libraryStore.playLibrary(selection, account: "netease:123")
        libraryStore.playLibrary([UUID()], account: "demo")
        libraryStore.playLibrary([catalog.songs[2].id], account: "demo")
        precondition(libraryStore.queue == [ranked[1], ranked[0]])
        libraryStore.playLibrary([catalog.songs[0].id], account: "demo")
        precondition(libraryStore.queue == [ranked[0]] && libraryStore.currentIndex == 0)
        print("PASS library play-all: ordered replacement, first-track playback, recommendation reset, empty/stale/account guards and repeated replacement")
        let unavailableTrack = libraryStore.pool.songs[0].track
        let availableTrack = libraryStore.pool.songs[1].track
        libraryStore.pool.markUnavailable(trackID: unavailableTrack.id, reason: .noResource)
        try libraryStore.stageRecommendation(prompt: "filter unavailable", tracks: [unavailableTrack, availableTrack], query: query)
        precondition(libraryStore.generatedPlaylist?.tracks == [availableTrack])
        let oldSession = ListeningSession(prompt: "old", tracks: [unavailableTrack, availableTrack], createdAt: Date(), listenerID: nil)
        libraryStore.replay(oldSession)
        precondition(libraryStore.queue == [availableTrack])
        print("PASS unavailable songs are filtered from generated previews and historical playback")
    }
}
