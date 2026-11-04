import SwiftUI
import Combine

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()
    let pool: SongPoolStore
    let api: NetEaseAPI
    let player = PlaybackController()
    #if os(iOS)
    lazy var companion: CompanionClient = {
        let value = CompanionClient(); value.attach(pool: pool, api: api); return value
    }()
    #endif
    @Published private(set) var listener: Listener?
    @Published private(set) var demoMode = false
    @Published private(set) var restoring = false
    @Published private(set) var playlists: [UserPlaylist] = []
    @Published private(set) var libraryTracks: [Track] = []
    @Published var selectedPlaylistID: Int?
    @Published private(set) var queue: [Track] = [] {
        didSet { rebuildPlaybackOrder(keeping: nil) }
    }
    @Published private(set) var shuffleEnabled = false
    @Published private(set) var playbackOrder: [Int] = []

    func setShuffleEnabled(_ enabled: Bool) {
        guard shuffleEnabled != enabled else { return }
        shuffleEnabled = enabled
        rebuildPlaybackOrder(keeping: currentIndex)
        player.updateUpcomingTrack(nextPlaybackIndex.map { queue[$0] })
        persistPlayback()
    }
    private func rebuildPlaybackOrder(keeping index: Int?) {
        let indices = Array(queue.indices)
        if shuffleEnabled {
            let rest = indices.filter { $0 != index }.shuffled()
            playbackOrder = index.flatMap { queue.indices.contains($0) ? [$0] + rest : nil } ?? rest
        } else { playbackOrder = indices }
    }
    private var nextPlaybackIndex: Int? {
        guard let offset = playbackOrder.firstIndex(of: currentIndex) else { return nil }
        return playbackOrder.dropFirst(offset + 1).first { pool.isAvailable(queue[$0]) }
    }
    @Published private(set) var currentIndex = 0
    @Published private(set) var activePrompt = ""
    @Published private(set) var sessions: [ListeningSession] = []
    @Published private(set) var feedback: [Feedback] = []
    @Published private(set) var generatedPlaylist: ListeningSession?
    @Published private(set) var generationError: String?
    @Published private(set) var generating = false
    @Published private(set) var deepSeekConfigured = DeepSeekKeyStore.hasKey
    @Published private(set) var canRepeatRecommendation = false
    @Published private(set) var queueEnded = false
    @Published private(set) var libraryLoading = false
    @Published var message: String?
    @Published var error: String?
    private var restored = false
    private var accountEpoch = UUID()
    private var generationTask: Task<Void, Never>?
    private var generationID = UUID()
    private var playbackTask: Task<Void, Never>?
    private var activeRecommendation: ListeningSession?
    private var loadingPlaylists = false
    private var cancellables = Set<AnyCancellable>()
    private let historyURL: URL
    private var playbackURL: URL { historyURL.deletingPathExtension().appendingPathExtension("playback.json") }
    private var playbackAccount: String? { listener.map { "netease:\($0.id)" } ?? (demoMode ? "demo" : nil) }
    var currentTrack: Track? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }
    var accountLabel: String { listener?.name ?? (demoMode ? "演示空间" : "尚未登录") }
    var scope: Int? { listener?.id }
    var visibleSessions: [ListeningSession] { sessions.filter { $0.listenerID == scope }.sorted { $0.createdAt > $1.createdAt } }
    var visibleFeedback: [Feedback] { feedback.filter { $0.listenerID == scope }.reversed() }
    var activeRecommendationSummary: String? {
        guard let session = activeRecommendation, session.listenerID == scope,
              let query = session.recommendationQuery else { return nil }
        return query.displaySummary(concepts: pool.intentConcepts)
    }
    init(archiveURL: URL? = nil) {
        let testing = archiveURL != nil || ProcessInfo.processInfo.arguments.contains("-ui-testing")
        api = NetEaseAPI(ephemeral: testing)
        let poolAPI = api
        let folder = archiveURL?.deletingLastPathComponent() ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Current")
        let testPool = folder.appendingPathComponent("UITestSongPool")
        if testing { try? FileManager.default.removeItem(at: testPool) }
        if testing && ProcessInfo.processInfo.arguments.contains("-ui-testing-library-genres") {
            var fixture = PoolCatalog()
            let tracks = [Track(id: -9101, title: "House 筛选样本", artist: "测试", album: "测试", artwork: nil, duration: 24, demoIndex: 0),
                          Track(id: -9102, title: "非 House 样本", artist: "测试", album: "测试", artwork: nil, duration: 24, demoIndex: 1)]
            _ = fixture.enqueue(tracks, account: "demo", source: "UI test")
            for index in fixture.songs.indices {
                fixture.songs[index].state = .completed
                fixture.songs[index].genres = GenreAnalysis(matches: [GenreMatch(index: index == 0 ? 50 : 125,
                    family: "Electronic", style: index == 0 ? "Deep House" : "Synth-pop", score: 0.7)],
                    windows: 10, duration: 20, analyzedAt: Date())
                fixture.songs[index].wikiMetadata = SongWikiMetadata(songID: tracks[index].id, fetchedAt: Date(), bpm: nil,
                    fields: [.init(kind: "songTag", title: "曲风", values: [index == 0 ? "流行-合成器流行" : "电子-House"])])
            }
            try? FileManager.default.createDirectory(at: testPool, withIntermediateDirectories: true)
            try? JSONEncoder().encode(fixture).write(to: testPool.appendingPathComponent("song-pool.json"))
        }
        pool = SongPoolStore(fileURL: testing ? testPool.appendingPathComponent("song-pool.json") : nil, resolve: { track in
            if let index = track.demoIndex {
                guard let url = Bundle.main.url(forResource: "demo-\(index)", withExtension: "wav") else { throw AnalysisError.noAudio }
                return url
            }
            return try await poolAPI.playbackURL(id: track.id)
        }, fetchWiki: { track in
            try await poolAPI.songWiki(id: track.id)
        }, semanticAnalyze: { try await DCLAPAnalyzer.analyze(url: $0) }, concepts: try? ConceptCatalog.bundled(),
           fetchLyrics: { try await poolAPI.lyrics(id: $0.id) },
           genreAnalyze: { try await GenreAnalyzer.analyze(url: $0) })
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        historyURL = archiveURL ?? folder.appendingPathComponent(testing ? "ui-test-listening.json" : "listening.json")
        if testing && archiveURL == nil { try? FileManager.default.removeItem(at: historyURL) }
        if let data = try? Data(contentsOf: historyURL), let saved = try? JSONDecoder().decode(Archive.self, from: data) {
            sessions = saved.sessions; feedback = saved.feedback
        }
        player.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        #if os(iOS)
        player.originalBPMForTrack = { [weak self] track in
            guard let self else { return nil }
            let expected = self.listener.map { "netease:\($0.id)" } ?? (self.demoMode ? "demo" : "guest")
            guard self.pool.account == expected else { return nil }
            return self.pool.songs.first(where: { $0.track.id == track.id })?.resolvedBPM
        }
        pool.$catalog.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.player.refreshOriginalBPM()
        }.store(in: &cancellables)
        #endif
        player.onNext = { [weak self] in self?.next() }
        player.onPrevious = { [weak self] in self?.previous() }
        player.onLike = { [weak self] in
            guard let self, let song = self.currentTrack else { return }
            self.record(.fits, track: song)
        }
        if testing && ProcessInfo.processInfo.arguments.contains("-ui-testing-mini-player") {
            // Visual interaction fixture only: no audio playback, API calls or production history.
            demoMode = true; queue = Array(DemoCatalog.tracks.prefix(2)); activePrompt = "输入交互验收"
        }
        if testing && ProcessInfo.processInfo.arguments.contains("-ui-testing-library-genres") { demoMode = true }
        if testing && ProcessInfo.processInfo.arguments.contains("-ui-testing-playlist-preview") {
            demoMode = true
            try? stageRecommendation(prompt: "阴郁一点的 House", tracks: Array(DemoCatalog.tracks.prefix(3)),
                query: RecommendationQuery(summary: "阴郁的 House", bpmMinimum: 110, bpmMaximum: 130, bpmRequired: true,
                    preferences: [.init(concept: "house", direction: .prefer, weight: 1)], unsupported: []))
        }
    }
    func restoreSession() async {
        guard !restored else { return }; restored = true
        guard api.hasCredentials else { return }
        AppLog.shared.record(.auth, .started, operation: .restoreSession)
        restoring = true
        let ticket = accountEpoch
        defer { restoring = false }
        do {
            let user = try await api.profile()
            guard ticket == accountEpoch else { return }
            listener = user
            restorePlayback()
            AppLog.shared.record(.auth, .succeeded, operation: .restoreSession)
            await loadPlaylists()
        } catch CurrentError.expired {
            guard ticket == accountEpoch else { return }
            AppLog.shared.record(.auth, .failed, level: .warning, operation: .restoreSession, error: CurrentError.expired)
            api.clear(); self.error = CurrentError.expired.localizedDescription
        } catch {
            guard ticket == accountEpoch else { return }
            AppLog.shared.record(.auth, .failed, level: .error, operation: .restoreSession, error: error)
            self.error = "暂时无法恢复账号，登录状态已保留。可在我的页面重试。"
        }
    }
    func retryRestore() async { restored = false; await restoreSession() }
    func finishLogin() async throws {
        let ticket = accountEpoch
        let user = try await api.profile()
        guard ticket == accountEpoch else { throw CancellationError() }
        resetPlayback(); demoMode = false; listener = user
        restorePlayback()
        AppLog.shared.record(.auth, .succeeded, operation: .login)
        await loadPlaylists()
    }
    func enterDemo() {
        guard listener == nil else { return }
        AppLog.shared.record(.auth, .succeeded, operation: .demo)
        guard !demoMode else { return }
        demoMode = true; error = nil
        restorePlayback()
    }
    func signOut() async {
        AppLog.shared.record(.auth, .started, operation: .logout)
        #if os(iOS)
        companion.revokeAuthorization()
        #endif
        accountEpoch = UUID(); generationTask?.cancel(); playbackTask?.cancel()
        if let account = playbackAccount {
            var saved = readPlayback(); saved.removeValue(forKey: account); writePlayback(saved)
        }
        resetPlayback(); listener = nil; demoMode = false
        playlists = []; libraryTracks = []; selectedPlaylistID = nil
        libraryLoading = false; error = nil
        await api.logout()
        AppLog.shared.record(.auth, .succeeded, operation: .logout)
        if listener == nil && !demoMode { message = "已退出，登录凭据已从本机移除。" }
    }
    func loadPlaylists() async {
        guard let listener, !loadingPlaylists else { return }
        loadingPlaylists = true; libraryLoading = true
        let ticket = accountEpoch
        defer { loadingPlaylists = false; if ticket == accountEpoch { libraryLoading = false } }
        do {
            let values = try await api.playlists(uid: listener.id)
            guard ticket == accountEpoch else { return }
            playlists = values
            if !values.contains(where: { $0.id == selectedPlaylistID }) { selectedPlaylistID = values.first?.id }
        } catch {
            guard ticket == accountEpoch else { return }
            self.error = error.localizedDescription
        }
    }
    func generate(prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !generating else { return }
        generationError = nil
        guard listener != nil || demoMode else { generationError = "先连接网易云，或进入演示空间。"; return }
        guard deepSeekConfigured else { generationError = IntentResolutionFailure.missingKey.localizedDescription; return }
        generating = true; error = nil
        let ticket = accountEpoch
        let requestID = UUID(); generationID = requestID
        let poolAccount = pool.account
        generationTask = Task {
            defer { if ticket == accountEpoch && requestID == generationID { generating = false } }
            var ranking = false
            do {
                let intent = try await DeepSeekIntentResolver(diagnostics: IntentAPIDiagnostic.record).resolve(text: text, concepts: pool.intentConcepts)
                try Task.checkCancellation()
                guard ticket == accountEpoch, requestID == generationID, poolAccount == pool.account else { return }
                ranking = true
                AppLog.shared.record(.analysis, .started, operation: .recommendationQueue, span: requestID)
                let tracks = try await pool.recommendationQueue(query: intent)
                AppLog.shared.record(.analysis, .succeeded, operation: .recommendationQueue, span: requestID, count: tracks.count)
                try Task.checkCancellation()
                guard ticket == accountEpoch, requestID == generationID else { return }
                try stageRecommendation(prompt: text, tracks: tracks, query: intent)
            } catch is CancellationError {} catch {
                if ranking { AppLog.shared.record(.analysis, .failed, level: .error, operation: .recommendationQueue, span: requestID, error: error) }
                if ticket == accountEpoch && requestID == generationID { self.generationError = error.localizedDescription }
            }
        }
    }
    // Preparing a result never changes transport state. Playback starts only on an explicit action.
    func stageRecommendation(prompt: String, tracks: [Track], query: RecommendationQuery) throws {
        guard listener != nil || demoMode else { return }
        let result = RecommendationPlaylist(candidates: tracks.filter { pool.isAvailable($0) }).tracks
        guard !result.isEmpty else { throw CurrentError.message("暂时没有符合条件的歌曲，试着调整需求或补充歌曲。") }
        let session = ListeningSession(prompt: prompt, tracks: result, createdAt: Date(), listenerID: scope,
                                       recommendationQuery: query, allowsRepeat: true)
        generationError = nil
        generatedPlaylist = session
        sessions.insert(session, at: 0)
        sessions = Array(sessions.prefix(30)); persist()
    }
    var generatedPlaylistIsActive: Bool {
        guard let generatedPlaylist else { return false }
        return generatedPlaylist.id == activeRecommendation?.id
    }
    func playGeneratedPlaylist(at index: Int = 0) {
        guard let session = generatedPlaylist, session.tracks.indices.contains(index) else { return }
        replay(session, startingAt: index)
    }
    func dismissGenerationError() { generationError = nil }
    func saveDeepSeekKey(_ key: String) throws {
        try DeepSeekKeyStore.save(key)
        cancelGeneration(); deepSeekConfigured = true
    }
    func clearDeepSeekKey() throws {
        try DeepSeekKeyStore.clear()
        cancelGeneration(); deepSeekConfigured = false
    }
    func cancelGeneration() {
        generationID = UUID(); generationTask?.cancel(); generating = false
    }
    func playLibrary(_ songIDs: [UUID], account: String) {
        let expectedAccount = listener.map { "netease:\($0.id)" } ?? (demoMode ? "demo" : nil)
        guard account == expectedAccount, account == pool.account, !songIDs.isEmpty else { return }
        let available = Dictionary(uniqueKeysWithValues: pool.songs.filter { $0.state == .completed }.map { ($0.id, $0.track) })
        let tracks = songIDs.compactMap { available[$0] }
        guard tracks.count == songIDs.count else { return }
        cancelGeneration()
        clearRecommendation()
        activePrompt = "曲库筛选"
        queue = tracks
        rebuildPlaybackOrder(keeping: 0)
        message = "已替换播放列表，共 \(tracks.count) 首。"; error = nil
        play(at: 0)
    }
    func playLyrics(_ matches: [LyricsSearchMatch], selected: UUID, query: String, account: String) {
        guard let listener, account == pool.account, account == "netease:\(listener.id)",
              matches.contains(where: { $0.id == selected }) else { return }
        let owned = Set(pool.songs.filter { $0.state != .unavailable }.map(\.id))
        let playable = matches.filter { owned.contains($0.id) }
        guard let playableIndex = playable.firstIndex(where: { $0.id == selected }) else { return }
        cancelGeneration()
        clearRecommendation()
        activePrompt = "歌词：" + query
        message = "按歌词匹配的候选"; error = nil
        queue = playable.map(\.track)
        rebuildPlaybackOrder(keeping: playableIndex)
        play(at: playableIndex)
    }
    func replay(_ session: ListeningSession, startingAt index: Int = 0) {
        guard session.listenerID == scope else { return }
        guard demoMode || listener != nil else { return }
        let original = RecommendationPlaylist(candidates: session.rankedCandidates ?? session.tracks).tracks
        guard original.indices.contains(index) else { return }
        let tracks = original.filter { pool.isAvailable($0) }
        guard !tracks.isEmpty else { return }
        let playableIndex = tracks.firstIndex(where: { $0.id == original[index].id }) ?? 0
        cancelGeneration()
        clearRecommendation()
        activeRecommendation = session
        canRepeatRecommendation = session.allowsRepeat == true || session.recommendationQuery != nil || session.rankedCandidates != nil
        activePrompt = session.prompt; queue = tracks
        rebuildPlaybackOrder(keeping: playableIndex)
        if let index = sessions.firstIndex(where: { $0.id == session.id && $0.listenerID == scope }),
           sessions[index].rankedCandidates != nil {
            var full = ListeningSession(prompt: session.prompt, tracks: tracks, createdAt: session.createdAt,
                                        listenerID: session.listenerID, recommendationQuery: session.recommendationQuery, allowsRepeat: true)
            full.id = session.id; sessions[index] = full; persist()
        }
        play(at: playableIndex)
    }
    func play(at index: Int) {
        guard queue.indices.contains(index) else { return }
        guard pool.isAvailable(queue[index]) else {
            if let offset = playbackOrder.firstIndex(of: index),
               let next = playbackOrder.dropFirst(offset + 1).first(where: { pool.isAvailable(queue[$0]) }) { play(at: next) }
            else { player.pause(); queueEnded = true; message = "其余歌曲音源不可用，已跳过。" }
            return
        }
        currentIndex = index
        queueEnded = false
        let song = queue[index]
        persistPlayback()
        playbackTask?.cancel()
        let next = nextPlaybackIndex.map { queue[$0] }
        let ticket = accountEpoch, account = pool.account
        playbackTask = Task {
            await player.load(song, next: next) { [self] track in
                do { return try await api.playbackURL(id: track.id) }
                catch {
                    if ticket == accountEpoch, account == pool.account, !Task.isCancelled,
                       case CurrentError.unavailable(let reason) = error {
                        pool.markUnavailable(trackID: track.id, reason: reason)
                    }
                    throw error
                }
            }
        }
    }
    func next() {
        guard !queue.isEmpty else { return }
        if let next = nextPlaybackIndex { play(at: next) }
        else {
            player.pause(); queueEnded = true
            message = !canRepeatRecommendation ? "这一轮听完了，再写一句话，开启下一段。" : "本歌单已听完，可再听一遍，或写下新的需求。"
        }
    }
    func continueWithRepeats() {
        guard queueEnded, canRepeatRecommendation, !queue.isEmpty else { return }
        rebuildPlaybackOrder(keeping: nil)
        if let first = playbackOrder.first { play(at: first) }
    }
    private func clearRecommendation() {
        activeRecommendation = nil
        canRepeatRecommendation = false; queueEnded = false
    }
    func previous() {
        if queueEnded { play(at: currentIndex) }
        else if player.position > 3 { player.seek(0) }
        else if let offset = playbackOrder.firstIndex(of: currentIndex),
                let previous = playbackOrder.prefix(offset).last(where: { pool.isAvailable(queue[$0]) }) {
            play(at: previous)
        }
    }
    @discardableResult
    func record(_ kind: FeedbackKind, track: Track, prompt: String? = nil) -> UUID {
        let event = Feedback(trackID: track.id, trackTitle: track.title,
                             prompt: prompt ?? activePrompt, kind: kind, date: Date(), listenerID: scope)
        feedback.append(event)
        feedback = Array(feedback.suffix(300)); persist()
        if kind == .fits { message = "记住了，这首很合此刻。" }
        if kind != .fits, currentTrack?.id == track.id { next() }
        return event.id
    }
    func updateFeedback(_ id: UUID, kind: FeedbackKind) {
        guard let index = feedback.firstIndex(where: { $0.id == id && $0.listenerID == scope }) else { return }
        feedback[index].kind = kind; persist()
    }
    func undoFeedback(_ id: UUID) {
        feedback.removeAll { $0.id == id && $0.listenerID == scope }; persist()
    }
    func liked(_ track: Track) -> Bool {
        feedback.last(where: { $0.trackID == track.id && $0.listenerID == scope })?.kind == .fits
    }
    func clearHistory() {
        sessions.removeAll { $0.listenerID == scope }; feedback.removeAll { $0.listenerID == scope }; persist()
        message = "已清除此空间的听歌记录。"
    }
    private func resetPlayback() {
        clearRecommendation()
        generatedPlaylist = nil; generationError = nil
        cancelGeneration(); playbackTask?.cancel()
        player.stop(); queue = []; currentIndex = 0; activePrompt = ""
        shuffleEnabled = false
    }
    // Separate from listening history: no position, audio URL or credentials are stored.
    private struct PlaybackSnapshot: Codable {
        let queue: [Track]
        let currentIndex: Int
        let shuffle: Bool
        let order: [Int]
        let prompt: String
        let recommendation: ListeningSession?
        let canRepeat: Bool
    }
    private func readPlayback() -> [String: PlaybackSnapshot] {
        guard let data = try? Data(contentsOf: playbackURL),
              let saved = try? JSONDecoder().decode([String: PlaybackSnapshot].self, from: data) else { return [:] }
        return saved
    }
    private func writePlayback(_ saved: [String: PlaybackSnapshot]) {
        do {
            try JSONEncoder().encode(saved).write(to: playbackURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            AppLog.shared.record(.storage, .failed, level: .error, operation: .historySave, error: error)
        }
    }
    private func persistPlayback() {
        guard let account = playbackAccount, currentTrack != nil else { return }
        var saved = readPlayback()
        saved[account] = PlaybackSnapshot(queue: queue, currentIndex: currentIndex, shuffle: shuffleEnabled,
            order: playbackOrder, prompt: activePrompt, recommendation: activeRecommendation, canRepeat: canRepeatRecommendation)
        writePlayback(saved)
    }
    private func restorePlayback() {
        guard queue.isEmpty, let account = playbackAccount, let saved = readPlayback()[account],
              saved.queue.indices.contains(saved.currentIndex),
              saved.order.count == saved.queue.count, Set(saved.order) == Set(saved.queue.indices),
              saved.recommendation == nil || saved.recommendation?.listenerID == scope else { return }
        shuffleEnabled = saved.shuffle
        queue = saved.queue
        currentIndex = saved.currentIndex
        playbackOrder = saved.shuffle ? saved.order : Array(queue.indices)
        activePrompt = saved.prompt
        activeRecommendation = saved.recommendation
        canRepeatRecommendation = saved.canRepeat
        player.restore(queue[currentIndex], next: nextPlaybackIndex.map { queue[$0] }) { [api] track in
            try await api.playbackURL(id: track.id)
        }
    }
    private struct Archive: Codable { let sessions: [ListeningSession]; let feedback: [Feedback] }
    private func persist() {
        do {
            let data = try JSONEncoder().encode(Archive(sessions: sessions, feedback: feedback))
            try data.write(to: historyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            AppLog.shared.record(.storage, .failed, level: .error, operation: .historySave, error: error)
            self.error = "记录保存失败：\(error.localizedDescription)" }
    }
}

extension IntentAPIDiagnostic {
    static func record(_ diagnostic: Self) {
        let event: LogEvent
        switch diagnostic.event {
        case .started: event = .started
        case .response: event = .response
        case .succeeded: event = .succeeded
        case .failed: event = .failed
        case .cancelled: event = .cancelled
        }
        AppLog.shared.record(.api, event, level: event == .failed ? .error : .info, operation: diagnostic.providerHost == DeepSeekProvider.host ? .deepSeekRequest : .openRouterRequest,
                             span: diagnostic.span, status: diagnostic.status, elapsed: diagnostic.elapsed, error: diagnostic.failure)
    }
}

extension IntentResolutionFailure: SafeLogError {
    var logFailure: LogFailure {
        switch self {
        case .missingKey: return .intentMissingKey
        case .keychain: return .intentKeychain
        case .unavailable: return .intentUnavailable
        case .invalidQuery: return .intentInvalidQuery
        case .unsupported: return .intentUnsupported
        case .rejected: return .intentRejected
        case .rateLimited: return .intentRateLimited
        case .network: return .intentNetwork
        case .service: return .intentService
        case .missingBPM: return .intentMissingBPM
        case .missingGenre: return .intentMissingGenre
        case .missingConcept: return .intentMissingConcept
        case .incomplete: return .intentIncomplete
        }
    }
}
