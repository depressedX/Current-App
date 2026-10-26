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
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var activePrompt = ""
    @Published private(set) var sessions: [ListeningSession] = []
    @Published private(set) var feedback: [Feedback] = []
    @Published private(set) var generating = false
    @Published private(set) var openRouterConfigured = OpenRouterKeyStore.hasKey
    @Published private(set) var recommendationExhausted = false
    @Published private(set) var queueEnded = false
    @Published private(set) var libraryLoading = false
    @Published var message: String?
    @Published var error: String?
    private var restored = false
    private var accountEpoch = UUID()
    private var generationTask: Task<Void, Never>?
    private var generationID = UUID()
    private var playbackTask: Task<Void, Never>?
    private var recommendationRun: RecommendationRun?
    private var activeSessionID: UUID?
    private var loadingPlaylists = false
    private var cancellables = Set<AnyCancellable>()
    private let historyURL: URL
    var currentTrack: Track? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }
    var accountLabel: String { listener?.name ?? (demoMode ? "演示空间" : "尚未登录") }
    var scope: Int? { listener?.id }
    var visibleSessions: [ListeningSession] { sessions.filter { $0.listenerID == scope }.sorted { $0.createdAt > $1.createdAt } }
    var visibleFeedback: [Feedback] { feedback.filter { $0.listenerID == scope }.reversed() }
    init(archiveURL: URL? = nil) {
        let testing = archiveURL != nil || ProcessInfo.processInfo.arguments.contains("-ui-testing")
        api = NetEaseAPI(ephemeral: testing)
        let poolAPI = api
        let folder = archiveURL?.deletingLastPathComponent() ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Current")
        let testPool = folder.appendingPathComponent("UITestSongPool")
        if testing { try? FileManager.default.removeItem(at: testPool) }
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
        player.onNext = { [weak self] in self?.next() }
        player.onPrevious = { [weak self] in self?.previous() }
        player.onLike = { [weak self] in
            guard let self, let song = self.currentTrack else { return }
            self.record(.fits, track: song)
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
        AppLog.shared.record(.auth, .succeeded, operation: .login)
        await loadPlaylists()
    }
    func enterDemo() {
        guard listener == nil else { return }
        AppLog.shared.record(.auth, .succeeded, operation: .demo)
        demoMode = true; error = nil
    }
    func signOut() async {
        AppLog.shared.record(.auth, .started, operation: .logout)
        #if os(iOS)
        companion.revokeAuthorization()
        #endif
        accountEpoch = UUID(); generationTask?.cancel(); playbackTask?.cancel()
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
        guard listener != nil || demoMode else { error = "先连接网易云，或进入演示空间。"; return }
        guard openRouterConfigured else { error = OpenRouterFailure.missingKey.localizedDescription; return }
        generating = true; error = nil
        let ticket = accountEpoch
        let requestID = UUID(); generationID = requestID
        let poolAccount = pool.account
        generationTask = Task {
            defer { if ticket == accountEpoch && requestID == generationID { generating = false } }
            var ranking = false
            do {
                let intent = try await OpenRouterIntentResolver(diagnostics: OpenRouterDiagnostic.record).resolve(text: text, concepts: pool.intentConcepts)
                try Task.checkCancellation()
                guard ticket == accountEpoch, requestID == generationID, poolAccount == pool.account else { return }
                ranking = true
                AppLog.shared.record(.analysis, .started, operation: .recommendationQueue, span: requestID)
                let tracks = try await pool.recommendationQueue(query: intent)
                AppLog.shared.record(.analysis, .succeeded, operation: .recommendationQueue, span: requestID, count: tracks.count)
                try Task.checkCancellation()
                guard ticket == accountEpoch, requestID == generationID else { return }
                var run = RecommendationRun(rankedCandidates: tracks)
                let result = run.nextBatch()
                guard !result.isEmpty else { throw CurrentError.message("歌曲池中还没有可推荐的听感结果。") }
                activePrompt = text; queue = result; currentIndex = 0
                recommendationRun = run; recommendationExhausted = run.exhausted
                let session = ListeningSession(prompt: text, tracks: result, createdAt: Date(), listenerID: scope,
                                               rankedCandidates: run.rankedCandidates, issuedCandidateIDs: run.issued)
                activeSessionID = session.id
                sessions.insert(session, at: 0)
                sessions = Array(sessions.prefix(30)); persist()
                message = "\(intent.displaySummary(concepts: pool.intentConcepts)) · 首批 \(result.count) 首，后续自动补充。"
                play(at: 0)
            } catch is CancellationError {} catch {
                if ranking { AppLog.shared.record(.analysis, .failed, level: .error, operation: .recommendationQueue, span: requestID, error: error) }
                if ticket == accountEpoch && requestID == generationID { self.error = error.localizedDescription }
            }
        }
    }
    func saveOpenRouterKey(_ key: String) throws {
        try OpenRouterKeyStore.save(key)
        cancelGeneration(); openRouterConfigured = true
    }
    func clearOpenRouterKey() throws {
        try OpenRouterKeyStore.clear()
        cancelGeneration(); openRouterConfigured = false
    }
    private func cancelGeneration() {
        generationID = UUID(); generationTask?.cancel(); generating = false
    }
    func playLyrics(_ matches: [LyricsSearchMatch], selected: UUID, query: String, account: String) {
        guard let listener, account == pool.account, account == "netease:\(listener.id)",
              let selectedIndex = matches.firstIndex(where: { $0.id == selected }) else { return }
        let owned = Set(pool.songs.map(\.id))
        guard matches.allSatisfy({ owned.contains($0.id) }) else { return }
        cancelGeneration()
        clearRecommendation()
        activePrompt = "歌词：" + query
        message = "按歌词匹配的候选"; error = nil
        queue = matches.map(\.track)
        play(at: selectedIndex)
    }
    func replay(_ session: ListeningSession) {
        guard session.listenerID == scope else { return }
        guard demoMode || listener != nil else { return }
        cancelGeneration()
        clearRecommendation()
        if let ranked = session.rankedCandidates {
            let run = RecommendationRun(rankedCandidates: ranked, issued: session.issuedCandidateIDs ?? Set(session.tracks.map(\.id)))
            recommendationRun = run; recommendationExhausted = run.exhausted
            activeSessionID = session.id
        }
        activePrompt = session.prompt; queue = session.tracks; play(at: 0)
    }
    func play(at index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        queueEnded = false
        refillRecommendationIfNeeded()
        let song = queue[index]
        playbackTask?.cancel()
        let next = queue.indices.contains(index + 1) ? queue[index + 1] : nil
        playbackTask = Task { await player.load(song, api: api, next: next) }
    }
    func next() {
        guard !queue.isEmpty else { return }
        refillRecommendationIfNeeded()
        if currentIndex + 1 < queue.count { play(at: currentIndex + 1) }
        else {
            player.pause(); queueEnded = true
            message = recommendationRun == nil ? "这一轮听完了，再写一句话，开启下一段。" : "本轮候选已听完，可允许重复继续听，或写下新的需求。"
        }
    }
    func continueWithRepeats() {
        guard queueEnded, recommendationExhausted, let previous = recommendationRun else { return }
        var run = RecommendationRun(rankedCandidates: previous.rankedCandidates)
        let batch = run.nextBatch()
        guard !batch.isEmpty else { return }
        recommendationRun = run; recommendationExhausted = run.exhausted
        let resumeIndex = currentIndex + 1
        appendRecommendation(batch)
        play(at: resumeIndex)
    }
    private func refillRecommendationIfNeeded() {
        guard var run = recommendationRun,
              run.shouldRefill(remaining: queue.count - currentIndex - 1) else { return }
        let batch = run.nextBatch()
        recommendationRun = run; recommendationExhausted = run.exhausted
        appendRecommendation(batch)
    }
    private func appendRecommendation(_ batch: [Track]) {
        guard !batch.isEmpty else { return }
        queue.append(contentsOf: batch)
        if let index = sessions.firstIndex(where: { $0.id == activeSessionID && $0.listenerID == scope }) {
            // ListeningSession keeps an immutable snapshot, including batches already issued.
            let old = sessions[index]
            var updated = ListeningSession(prompt: old.prompt, tracks: old.tracks + batch,
                                           createdAt: old.createdAt, listenerID: old.listenerID,
                                           rankedCandidates: old.rankedCandidates, issuedCandidateIDs: recommendationRun?.issued)
            updated.id = old.id; sessions[index] = updated; persist()
        }
    }
    private func clearRecommendation() {
        recommendationRun = nil; activeSessionID = nil
        recommendationExhausted = false; queueEnded = false
    }
    func previous() {
        if queueEnded { play(at: currentIndex) }
        else if player.position > 3 { player.seek(0) }
        else if currentIndex > 0 { play(at: currentIndex - 1) }
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
        cancelGeneration(); playbackTask?.cancel()
        player.stop(); queue = []; currentIndex = 0; activePrompt = ""
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

extension OpenRouterDiagnostic {
    static func record(_ diagnostic: Self) {
        let event: LogEvent
        switch diagnostic.event {
        case .started: event = .started
        case .response: event = .response
        case .succeeded: event = .succeeded
        case .failed: event = .failed
        case .cancelled: event = .cancelled
        }
        AppLog.shared.record(.api, event, level: event == .failed ? .error : .info, operation: .openRouterRequest,
                             span: diagnostic.span, status: diagnostic.status, elapsed: diagnostic.elapsed, error: diagnostic.failure)
    }
}

extension OpenRouterFailure: SafeLogError {
    var logFailure: LogFailure {
        switch self {
        case .missingKey: return .openRouterMissingKey
        case .keychain: return .openRouterKeychain
        case .unavailable: return .openRouterUnavailable
        case .invalidQuery: return .openRouterInvalidQuery
        case .unsupported: return .openRouterUnsupported
        case .rejected: return .openRouterRejected
        case .rateLimited: return .openRouterRateLimited
        case .network: return .openRouterNetwork
        case .service: return .openRouterService
        case .missingBPM: return .openRouterMissingBPM
        case .incomplete: return .openRouterIncomplete
        }
    }
}
