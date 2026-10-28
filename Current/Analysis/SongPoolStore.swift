import Foundation
import Combine

@MainActor
final class SongPoolStore: ObservableObject {
    @Published private(set) var catalog = PoolCatalog()
    @Published private(set) var paused = true
    @Published private(set) var account = "guest"
    @Published private(set) var failure: String?
    @Published private(set) var loading = true
    @Published private(set) var foreground = false
    @Published private(set) var playbackBusy = false
    @Published private(set) var constrained = false
    private let disk: PoolDisk
    private let semanticDisk: SemanticDisk
    private let lyricsDisk: LyricsDisk
    private let fetchLyrics: (@MainActor (Track) async throws -> LyricsDocument)?
    private let lyricsAnalyze: @Sendable (LyricsDocument) async throws -> LyricsAnalysis
    private let lyricsQuery: @Sendable (String) async throws -> [Float]
    @Published private(set) var lyricsSearching = false
    private let genreAnalyze: (@Sendable (URL) async throws -> GenreAnalysis)?
    private let semanticAnalyze: (@Sendable (URL) async throws -> SemanticAnalysis)?
    private let concepts: ConceptCatalog?
    private let intentResolver: any ListeningIntentResolving
    private let resolve: @MainActor (Track) async throws -> URL
    private let fetchWiki: (@MainActor (Track) async throws -> SongWikiMetadata)?
    private let fetchBPM: (@MainActor (Track) async throws -> Double?)?
    private let analyze: @Sendable (URL) async throws -> AcousticFeatures
    private var task: Task<Void, Never>?
    private var epoch = UUID()
    private var revision = 0
    private var localRunIDs: Set<UUID> = []
    var onLocalAnalysis: (([UUID]) -> Void)?
    private var observers: [NSObjectProtocol] = []
    var songs: [PoolSong] { catalog.songs.filter { $0.account == account } }
    var completedCount: Int { songs.filter { $0.state == .completed }.count }
    var localRunning: Bool {
        !paused && songs.contains { localRunIDs.contains($0.id) && ($0.state == .queued || $0.state.active) }
    }
    var pendingCount: Int { songs.filter { $0.state == .queued || $0.state.active }.count }
    var unavailableCount: Int { songs.filter { $0.state == .unavailable }.count }
    var localPendingCount: Int { songs.filter { $0.state == .queued && $0.remotePending != true }.count }
    func isAvailable(_ track: Track) -> Bool {
        !songs.contains { $0.track.id == track.id && $0.state == .unavailable }
    }
    func markUnavailable(trackID: Int, reason: TrackUnavailability) {
        guard let song = songs.first(where: { $0.track.id == trackID }) else { return }
        if song.state.active { stop() }
        guard let i = index(song.id) else { return }
        catalog.songs[i].state = .unavailable
        catalog.songs[i].unavailability = reason
        catalog.songs[i].failure = reason.message
        catalog.songs[i].remotePending = nil; catalog.songs[i].remoteRequestID = nil
        catalog.songs[i].needsLyricsReindex = nil; catalog.songs[i].lyricsReturnState = nil
        persist()
    }
    var waitReason: String? {
        if loading { return "正在恢复分析数据" }
        if lyricsSearching { return "正在检索歌词" }
        if paused || !localRunning {
            if songs.contains(where: { $0.remotePending == true }) { return "等待 Mac 分析与同步" }
            return localRunIDs.isEmpty ? "选择 Mac 或本机，手动开始分析" : "本机分析已暂停"
        }
        if !foreground { return "回到 App 后继续" }
        if playbackBusy { return "听歌优先，播放结束后继续" }
        if constrained { return "节能或设备温度较高，稍后继续" }
        return nil
    }
    init(fileURL: URL? = nil, resolve: @escaping @MainActor (Track) async throws -> URL,
         fetchBPM: (@MainActor (Track) async throws -> Double?)? = nil,
         fetchWiki: (@MainActor (Track) async throws -> SongWikiMetadata)? = nil,
         semanticAnalyze: (@Sendable (URL) async throws -> SemanticAnalysis)? = nil,
         concepts: ConceptCatalog? = nil,
         fetchLyrics: (@MainActor (Track) async throws -> LyricsDocument)? = nil,
         lyricsAnalyze: @escaping @Sendable (LyricsDocument) async throws -> LyricsAnalysis = { try await LyricsAnalyzer.analyze($0) },
         lyricsQuery: @escaping @Sendable (String) async throws -> [Float] = { try await LyricsAnalyzer.query($0) },
         genreAnalyze: (@Sendable (URL) async throws -> GenreAnalysis)? = nil,
         intentResolver: any ListeningIntentResolving = MockListeningIntentResolver(),
         analyze: @escaping @Sendable (URL) async throws -> AcousticFeatures = { try await NativeSongAnalyzer.analyze(url: $0) }) {
        self.resolve = resolve; self.analyze = analyze; self.fetchBPM = fetchBPM
        self.fetchWiki = fetchWiki
        self.semanticAnalyze = semanticAnalyze; self.concepts = concepts
        self.genreAnalyze = genreAnalyze
        self.fetchLyrics = fetchLyrics; self.lyricsAnalyze = lyricsAnalyze; self.lyricsQuery = lyricsQuery
        self.intentResolver = intentResolver
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Current")
        let archive = fileURL ?? folder.appendingPathComponent("song-pool.json")
        disk = PoolDisk(url: archive)
        lyricsDisk = LyricsDisk(directory: archive.deletingLastPathComponent().appendingPathComponent("LyricsAnalysis"))
        semanticDisk = SemanticDisk(directory: archive.deletingLastPathComponent().appendingPathComponent("SongAnalysis"))
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshConstraints() }
            })
        }
        refreshConstraints()
        Task {
            do {
                catalog = try await disk.load(); catalog.recoverInterrupted()
                AppLog.shared.record(.storage, .recovered, operation: .poolLoad, count: catalog.songs.count)
            } catch {
                AppLog.shared.record(.storage, .failed, level: .error, operation: .poolLoad, error: error)
                failure = "分析数据读取失败，原文件已保留。"
            }
            loading = false
            // An unreadable archive must not be overwritten by an empty pool.
            if failure == nil { persist() }
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    func activate(account: String) {
        guard self.account != account else { return }
        AppLog.shared.record(.analysis, .accountChanged, operation: .pool, reason: .scopeChanged)
        stop(); epoch = UUID(); localRunIDs = []; self.account = account; paused = true
    }
    @discardableResult func enqueue(_ tracks: [Track], source: String) -> Int {
        guard !loading, failure == nil else { return 0 }
        let count = catalog.enqueue(tracks, account: account, source: source)
        AppLog.shared.record(.analysis, .enqueued, operation: .pool, count: count)
        persist(); pump(); return count
    }
    func analyzeHearing() {
        guard !loading, failure == nil else { return }
        var ids = Set<UUID>()
        for i in catalog.songs.indices where catalog.songs[i].account == account && catalog.songs[i].state == .completed && (!catalog.songs[i].semanticReady || catalog.songs[i].features?.profile?.version != ObjectiveProfile.currentVersion || (genreAnalyze != nil && catalog.songs[i].genres?.compatible != true)) {
            catalog.songs[i].needsReanalysis = true
            catalog.songs[i].state = .queued
            ids.insert(catalog.songs[i].id)
        }
        persist(); startLocal(ids)
    }
    func mockSemanticQueue(text: String, limit: Int? = 12) async throws -> (tracks: [Track], anchor: String) {
        guard let concepts else { throw SemanticError.missingResource }
        let scope = account
        let anchor = try await intentResolver.resolve(text: text, catalog: concepts)
        try Task.checkCancellation()
        guard scope == account else { throw CancellationError() }
        guard anchor.spaceID == concepts.spaceID else { throw SemanticError.incompatible }
        _ = try EmbeddingMath.unit(anchor.vector)
        let candidates = songs.filter(\.semanticReady)
        guard !candidates.isEmpty else { throw CurrentError.message("先在我的 → 分析管理完成听感分析。") }
        let tracks = try await rank(candidates, scope: scope) { vector, _ in try EmbeddingMath.cosine(anchor.vector, vector) }
        return (limit.map { Array(tracks.prefix(max(0, $0))) } ?? tracks, anchor.label)
    }
    var intentConcepts: [IntentConcept] {
        let listening = concepts?.concepts.map { IntentConcept(id: $0.id, label: $0.label, definition: $0.definition) } ?? []
        var references: [String: IntentConcept] = [:]
        for song in songs where song.state == .completed {
            for match in song.genres?.supportedMatches ?? [] {
                for reference in [GenreReference(source: .audioFamily, value: match.family),
                                  GenreReference(source: .audioStyle, value: "\(match.family)---\(match.style)")] {
                    references[reference.id] = reference.concept
                }
            }
            for label in song.wikiGenreLabels {
                for reference in [GenreReference(source: .encyclopedia, value: label),
                                  GenreReference(source: .encyclopediaFamily, value: WikiGenre(label).family)] {
                    references[reference.id] = reference.concept
                }
            }
        }
        return listening + references.values.sorted { $0.id < $1.id }
    }
    func recommendationQueue(query: RecommendationQuery) async throws -> [Track] {
        guard let concepts else { throw SemanticError.missingResource }
        let query = try query.validated(allowedConcepts: Set(intentConcepts.map(\.id)))
        let terms = query.preferences.compactMap { preference -> (ListeningConcept, RecommendationQuery.Preference)? in
            guard let concept = concepts.concepts.first(where: { $0.id == preference.concept }) else { return nil }
            return (concept, preference)
        }
        let candidates = songs.filter {
            $0.semanticReady && query.matchesGenres($0.genres, wiki: $0.wikiGenreLabels) && (!query.bpmRequired || query.matchesBPM($0.resolvedBPM))
        }
        guard !candidates.isEmpty else {
            throw CurrentError.message(query.hasGenreConditions
                ? "音乐库中没有满足曲风及其他条件的歌曲。可补充歌曲或完成曲风分析；本次未生成歌单。"
                : "没有满足条件且已完成听感分析的歌曲。可调整条件或补充歌曲；未知 BPM 不计为满足范围。")
        }
        let tracks = try await rank(candidates, scope: account) { vector, song in
            var score = query.bpmPreference(song.resolvedBPM)
            for (concept, term) in terms {
                let similarity = try EmbeddingMath.cosine(concept.vector, vector)
                if !term.isGenre && !term.accepts(similarity: similarity) { return nil }
                score += term.weight * (term.direction == .prefer ? 1 : -1) * similarity
            }
            for term in query.preferences where term.genreReference != nil {
                if term.matchesGenre(song.genres, wiki: song.wikiGenreLabels) {
                    score += (term.direction == .prefer ? 1 : -1) * term.weight * 0.25
                }
            }
            return score
        }
        guard !tracks.isEmpty else { throw CurrentError.message("没有同时满足曲风、BPM 和听感条件的歌曲。可调整条件或补充歌曲；本次未生成歌单。") }
        return tracks
    }
    private func rank(_ candidates: [PoolSong], scope: String,
                      score: ([Float], PoolSong) throws -> Double?) async throws -> [Track] {
        var ranked: [(Track, Double)] = []
        for song in candidates {
            try Task.checkCancellation()
            guard scope == account else { throw CancellationError() }
            guard let semantic = song.semantic else { continue }
            do {
                let vector = try await semanticDisk.load(semantic, songID: song.id, account: scope)
                if isAvailable(song.track), let value = try score(vector, song) { ranked.append((song.track, value)) }
            } catch {
                guard scope == account else { throw CancellationError() }
                AppLog.shared.record(.storage, .failed, level: .error, operation: .semanticLoad, job: song.id, error: error)
                if let i = index(song.id), catalog.songs[i].state != .unavailable, catalog.songs[i].semantic?.recordID == semantic.recordID {
                    catalog.songs[i].failure = "听感结果无法读取，请重新分析"
                    catalog.songs[i].needsReanalysis = true
                    catalog.songs[i].state = .failed
                    persist()
                }
                throw error
            }
        }
        guard scope == account else { throw CancellationError() }
        ranked.sort { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
        return ranked.map { $0.0 }.filter { isAvailable($0) }
    }
    func contains(_ track: Track) -> Bool { songs.contains { $0.track.id == track.id } }
    func resume() {
        AppLog.shared.record(.analysis, .resumed, operation: .pool, reason: .user)
        // Songs handed to Mac keep their assignment; "本机分析" only takes the unassigned ones.
        startLocal(Set(songs.filter { $0.state == .queued && $0.remotePending != true }.map(\.id)))
    }
    /// Runs exactly these songs on this device and leaves every other queue entry untouched.
    private func startLocal(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        onLocalAnalysis?(Array(ids))
        localRunIDs.formUnion(ids)
        for i in catalog.songs.indices where catalog.songs[i].account == account && ids.contains(catalog.songs[i].id) {
            catalog.songs[i].remotePending = nil; catalog.songs[i].remoteRequestID = nil
        }
        paused = false; persist(); pump()
    }
    func pause() {
        AppLog.shared.record(.analysis, .paused, operation: .pool, reason: .user)
        paused = true; stop()
    }
    func setForeground(_ value: Bool) { foreground = value; value ? pump() : stop() }
    func setPlaybackBusy(_ value: Bool) {
        if playbackBusy != value && value { AppLog.shared.record(.analysis, .paused, operation: .pool, reason: .playbackBusy) }
        playbackBusy = value; value ? stop() : pump()
    }
    func retry(_ id: UUID) {
        guard let i = index(id), catalog.songs[i].state == .failed else { return }
        catalog.songs[i].state = .queued; catalog.songs[i].failure = nil
        persist(); pump()
    }
    func retryFailed() {
        let ids = Set(songs.filter { $0.state == .failed }.map(\.id))
        guard !ids.isEmpty else { return }
        for i in catalog.songs.indices where catalog.songs[i].account == account && ids.contains(catalog.songs[i].id) {
            catalog.songs[i].state = .queued; catalog.songs[i].failure = nil
        }
        persist(); startLocal(ids)
    }
    func reanalyze(_ id: UUID) {
        guard !loading, failure == nil, let i = index(id),
              catalog.songs[i].state == .completed || catalog.songs[i].state == .failed else { return }
        catalog.songs[i].needsReanalysis = true
        catalog.songs[i].state = .queued
        catalog.songs[i].failure = nil
        AppLog.shared.record(.analysis, .enqueued, operation: .pool, job: id, reason: .user)
        persist(); startLocal([id])
    }
    func backfillBPM(_ id: UUID) {
        guard !loading, failure == nil, let i = index(id), catalog.songs[i].canBackfillBPM else { return }
        catalog.songs[i].state = .queued
        persist(); startLocal([id])
    }
    func refreshWiki(_ id: UUID) {
        guard !loading, failure == nil, let i = index(id), !catalog.songs[i].track.isDemo,
              catalog.songs[i].state == .completed, fetchWiki != nil else { return }
        catalog.songs[i].state = .queued
        persist(); startLocal([id])
    }
    var lyricsCount: Int { songs.filter { $0.state != .unavailable && $0.lyrics?.compatible == true && $0.lyrics?.status == .indexed }.count }
    func indexLyrics(_ id: UUID) {
        guard !loading, failure == nil, fetchLyrics != nil, let i = index(id),
              !catalog.songs[i].track.isDemo, catalog.songs[i].state == .completed || catalog.songs[i].state == .failed else { return }
        catalog.songs[i].lyricsReturnState = catalog.songs[i].state
        catalog.songs[i].needsLyricsReindex = true
        catalog.songs[i].state = .queued
        persist(); startLocal([id])
    }
    func indexMissingLyrics() {
        guard !loading, failure == nil, fetchLyrics != nil else { return }
        var ids = Set<UUID>()
        for song in songs where (song.state == .completed || song.state == .failed) && !song.track.isDemo && (song.lyrics?.compatible != true || song.lyricsFailure == true) {
            guard let i = index(song.id) else { continue }
            catalog.songs[i].lyricsReturnState = catalog.songs[i].state
            catalog.songs[i].needsLyricsReindex = true
            catalog.songs[i].state = .queued
            ids.insert(song.id)
        }
        persist(); startLocal(ids)
    }
    func searchLyrics(_ text: String) async throws -> LyricsSearchResults {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 512 else { throw LyricsError.tooLong }
        guard !lyricsSearching else { throw CurrentError.message("请等待当前歌词检索完成") }
        let scope = account, ticket = epoch
        let entries = songs.compactMap { song -> LyricsSearchEntry? in
            guard song.state != .unavailable, let summary = song.lyrics, summary.compatible, summary.status == .indexed else { return nil }
            return LyricsSearchEntry(songID: song.id, track: song.track, summary: summary)
        }
        guard !entries.isEmpty else { throw CurrentError.message("先在分析管理完成歌词索引") }
        lyricsSearching = true
        stop() // Drain the serial analyser before loading another model session.
        defer { lyricsSearching = false; pump() }
        let span = UUID(), began = Date()
        AppLog.shared.record(.analysis, .started, operation: .lyricsSearch, span: span)
        do {
            while task != nil { try await Task.sleep(for: .milliseconds(10)) }
            try Task.checkCancellation()
            guard scope == account, ticket == epoch else { throw CancellationError() }
            let vector = try await lyricsQuery(query)
            let result = try await lyricsDisk.search(vector, entries: entries, account: scope)
            try Task.checkCancellation()
            guard scope == account, ticket == epoch else { throw CancellationError() }
            // Removed/reindexed songs must not return stale results after an await.
            let current = Dictionary(songs.filter { $0.state != .unavailable }.map { ($0.id, $0.lyrics?.recordID) }, uniquingKeysWith: { a, _ in a })
            let expected = Dictionary(entries.map { ($0.songID, $0.summary.recordID) }, uniquingKeysWith: { a, _ in a })
            let valid = result.matches.filter { current[$0.id] != nil && current[$0.id] == expected[$0.id] }
            AppLog.shared.record(.analysis, .succeeded, operation: .lyricsSearch, span: span, count: valid.count, elapsed: Date().timeIntervalSince(began))
            return LyricsSearchResults(matches: valid, unavailableCount: result.unavailableCount, indexedSongs: result.indexedSongs)
        } catch {
            AppLog.shared.record(.analysis, Task.isCancelled ? .cancelled : .failed, level: .warning, operation: .lyricsSearch, span: span, error: error)
            throw error
        }
    }
    func remove(_ id: UUID) {
        guard let i = index(id) else { return }
        if catalog.songs[i].state.active { stop() }
        catalog.songs.removeAll { $0.id == id && $0.account == account }
        persist(); pump()
    }
    func companionReady(_ song: PoolSong) -> Bool {
        song.semanticReady && song.features?.profile?.version == ObjectiveProfile.currentVersion &&
        song.genres?.compatible == true && song.lyrics?.compatible == true && song.lyricsFailure != true
    }
    func reserveCompanion(_ ids: Set<UUID>, requests: [UUID: UUID] = [:]) {
        pause()
        for i in catalog.songs.indices where catalog.songs[i].account == account && ids.contains(catalog.songs[i].id) && catalog.songs[i].state != .unavailable {
            catalog.songs[i].remotePending = true; catalog.songs[i].remoteRequestID = requests[catalog.songs[i].id]
            catalog.songs[i].state = .queued
        }
        persist()
    }
    /// Terminal Mac statuses must survive disconnects and use the same request fencing as results.
    func importCompanionStatuses(_ statuses: [CompanionJobStatus], account scope: String?) {
        guard !loading, failure == nil, scope == account else { return }
        var changed = false
        for status in statuses {
            guard let i = index(status.id), catalog.songs[i].track.id == status.track.id,
                  catalog.songs[i].remotePending == true || (catalog.songs[i].state == .failed && catalog.songs[i].remoteRequestID != nil),
                  catalog.songs[i].remoteRequestID == status.requestID else { continue }
            if status.state == .unavailable, let reason = status.unavailability {
                catalog.songs[i].state = .unavailable
                catalog.songs[i].unavailability = reason
                catalog.songs[i].failure = reason.message
                catalog.songs[i].remotePending = nil; catalog.songs[i].remoteRequestID = nil
                catalog.songs[i].needsLyricsReindex = nil; catalog.songs[i].lyricsReturnState = nil
            } else if status.state == .failed {
                guard catalog.songs[i].state != .failed || catalog.songs[i].failure != status.failure else { continue }
                catalog.songs[i].state = .failed
                catalog.songs[i].failure = status.failure
                // Retain the assignment so a retry started directly on Mac can sync later.
                catalog.songs[i].remotePending = nil
            } else if catalog.songs[i].state == .failed,
                      [.queued, .fetching, .analyzing, .completed, .authorizationRequired].contains(status.state) {
                catalog.songs[i].state = .queued
                catalog.songs[i].remotePending = true
                catalog.songs[i].failure = nil
            } else { continue }
            changed = true
        }
        if changed { persist() }
    }
    /// ACK only after vectors and the catalogue are durably stored. Never accept
    /// results for removed songs, a previous account, or a superseded local run.
    func importCompanion(_ result: CompanionResult) async throws {
        guard result.account == account, let initial = index(result.jobID),
              catalog.songs[initial].track.id == result.trackID,
              catalog.songs[initial].remotePending == true, catalog.songs[initial].remoteRequestID == result.requestID else { return }
        guard !loading, failure == nil, let concepts else { throw SemanticError.storage }
        try result.validate()
        guard result.wiki == nil || result.wiki?.songID == result.trackID else { throw SemanticError.incompatible }
        let ticket = epoch, scope = account
        let semantic = try await semanticDisk.save(SemanticAnalysis(vector: result.vector, windowStarts: result.windowStarts,
            elapsedSeconds: result.semanticElapsed), songID: result.jobID, account: scope, catalog: concepts)
        var lyrics: LyricsSummary?
        if let analysis = result.lyrics { lyrics = try await lyricsDisk.save(analysis, songID: result.jobID, account: scope) }
        guard ticket == epoch, let i = index(result.jobID), catalog.songs[i].remotePending == true, catalog.songs[i].remoteRequestID == result.requestID else { return }
        let old = catalog.songs[i]
        catalog.songs[i].features = result.features; catalog.songs[i].genres = result.genres
        catalog.songs[i].semantic = semantic
        if let lyrics { catalog.songs[i].lyrics = lyrics }
        catalog.songs[i].lyricsFailure = lyrics == nil ? true : nil
        if let wiki = result.wiki {
            catalog.songs[i].wikiMetadata = wiki
            if let bpm = wiki.bpm, bpm.isFinite, (20...400).contains(bpm) {
                catalog.songs[i].wikiBPM = WikiBPM(value: bpm, fetchedAt: Date()); catalog.songs[i].bpmLookup = .available
            } else { catalog.songs[i].wikiBPM = nil; catalog.songs[i].bpmLookup = .missing }
        }
        catalog.songs[i].remotePending = nil; catalog.songs[i].remoteRequestID = nil; catalog.songs[i].needsReanalysis = nil
        catalog.songs[i].needsLyricsReindex = nil; catalog.songs[i].lyricsReturnState = nil
        catalog.songs[i].state = .completed; catalog.songs[i].failure = nil; catalog.songs[i].finishedAt = Date()
        revision += 1
        do { try await disk.save(catalog, revision: revision) }
        catch {
            if ticket == epoch, let current = index(result.jobID), catalog.songs[current].semantic?.recordID == semantic.recordID { catalog.songs[current] = old }
            throw SemanticError.storage
        }
    }
    private func index(_ id: UUID) -> Int? { catalog.songs.firstIndex { $0.id == id && $0.account == account } }
    private func refreshConstraints() {
        let info = ProcessInfo.processInfo
        let limited = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
        if limited != constrained { AppLog.shared.record(.analysis, limited ? .paused : .resumed, operation: .pool, reason: info.isLowPowerModeEnabled ? .lowPower : .resourceLimited, status: Int(info.thermalState.rawValue)) }
        constrained = limited
        constrained ? stop() : pump()
    }
    private func stop() {
        task?.cancel()
        for i in catalog.songs.indices where catalog.songs[i].state.active { catalog.songs[i].state = .queued }
        if !loading && failure == nil { persist() }
    }
    private func pump() {
        guard task == nil, waitReason == nil, failure == nil else { return }
        guard let song = songs.first(where: { $0.state == .queued && localRunIDs.contains($0.id) && $0.remotePending != true }) else { return }
        let ticket = epoch
        update(song.id, state: !song.track.isDemo && (fetchWiki != nil || fetchBPM != nil) ? .readingMetadata : .fetching)
        task = Task {
            await LogScope.$trace.withValue(song.id) {
                defer { task = nil; pump() }
                let lyricsOnly = song.needsLyricsReindex == true || song.lyricsReturnState != nil
                let fullRun = song.needsReanalysis == true && !lyricsOnly
                var pendingWiki = song.wikiBPM
                var pendingMetadata = song.wikiMetadata
                var pendingLookup = song.bpmLookup
                var pendingCheckedAt = song.bpmCheckedAt
                var temporary: URL?
                defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
                do {
                    if !lyricsOnly, !song.track.isDemo, fetchWiki != nil || ((song.wikiBPM == nil || fullRun) && fetchBPM != nil) {
                        do {
                            let value: Double?
                            if let fetchWiki {
                                let metadata = try await fetchWiki(song.track)
                                guard metadata.songID == song.track.id else { throw CurrentError.message("百科歌曲信息不匹配") }
                                pendingMetadata = metadata
                                value = metadata.bpm
                            } else { value = try await fetchBPM?(song.track) }
                            try Task.checkCancellation()
                            guard ticket == epoch, let i = index(song.id) else { return }
                            if let value, value.isFinite, (20...400).contains(value) {
                                pendingWiki = WikiBPM(value: value, fetchedAt: Date())
                                pendingLookup = .available
                            } else { pendingWiki = nil; pendingLookup = .missing }
                            pendingCheckedAt = Date()
                            if !fullRun {
                                catalog.songs[i].wikiBPM = pendingWiki
                                catalog.songs[i].wikiMetadata = pendingMetadata
                                catalog.songs[i].bpmLookup = pendingLookup
                                catalog.songs[i].bpmCheckedAt = pendingCheckedAt
                                persist()
                            }
                            AppLog.shared.record(.analysis, .succeeded, operation: .songWiki, job: song.id,
                                                 count: pendingWiki == nil ? 0 : 1)
                        } catch {
                            try Task.checkCancellation()
                            guard ticket == epoch, let i = index(song.id) else { return }
                            pendingLookup = .failed; pendingCheckedAt = Date()
                            if !fullRun {
                                catalog.songs[i].bpmLookup = pendingLookup
                                catalog.songs[i].bpmCheckedAt = pendingCheckedAt
                                persist()
                            }
                            AppLog.shared.record(.analysis, .failed, level: .warning, operation: .songWiki, job: song.id, error: error)
                        }
                    }
                    if !song.track.isDemo, let fetchLyrics,
                       fullRun || song.needsLyricsReindex == true || (song.features == nil && song.lyrics == nil) {
                        update(song.id, state: .readingLyrics)
                        do {
                            let document = try await fetchLyrics(song.track)
                            guard document.songID == song.track.id else { throw LyricsError.incompatible }
                            let analysis = try await lyricsAnalyze(document)
                            try Task.checkCancellation()
                            guard ticket == epoch, index(song.id) != nil else { return }
                            let summary = try await lyricsDisk.save(analysis, songID: song.id, account: song.account)
                            try Task.checkCancellation()
                            guard ticket == epoch, let i = index(song.id) else { return }
                            catalog.songs[i].lyrics = summary
                            catalog.songs[i].lyricsFailure = nil
                            catalog.songs[i].needsLyricsReindex = nil
                            persist()
                        } catch {
                            try Task.checkCancellation()
                            guard ticket == epoch, let i = index(song.id) else { return }
                            catalog.songs[i].lyricsFailure = true
                            catalog.songs[i].needsLyricsReindex = nil
                            AppLog.shared.record(.analysis, .failed, level: .warning, operation: .lyricsIndex, job: song.id, error: error)
                            persist() // Independent failure: audio/encyclopedia results remain usable.
                        }
                    }
                    try Task.checkCancellation()
                    guard ticket == epoch, let current = index(song.id) else { return }
                    // Metadata backfill reuses existing acoustic results; no audio re-download.
                    if lyricsOnly {
                        let restored: AnalysisState = song.lyricsReturnState == .failed ? .failed : .completed
                        catalog.songs[current].lyricsReturnState = nil
                        update(song.id, state: restored); return
                    }
                    if catalog.songs[current].features != nil && !fullRun { update(song.id, state: .completed); return }
                    update(song.id, state: .fetching)
                    let source = try await resolve(song.track)
                    try Task.checkCancellation()
                    let local: URL
                    if source.isFileURL { local = source }
                    else {
                        local = try await AnalysisAudioDownloader.fetch(source)
                        temporary = local
                    }
                    try Task.checkCancellation()
                    guard ticket == epoch, index(song.id) != nil else { return }
                    update(song.id, state: .analyzing)
                    let result = try await analyze(local)
                    let genres = try await genreAnalyze?(local)
                    try Task.checkCancellation()
                    var semantic: SemanticFeatures?
                    if let semanticAnalyze {
                        guard let concepts else { throw SemanticError.missingResource }
                        let embedding = try await semanticAnalyze(local)
                        try Task.checkCancellation()
                        guard ticket == epoch, index(song.id) != nil else { return }
                        do {
                            semantic = try await semanticDisk.save(embedding, songID: song.id, account: song.account, catalog: concepts)
                            AppLog.shared.record(.storage, .succeeded, operation: .semanticSave, job: song.id)
                        } catch {
                            AppLog.shared.record(.storage, .failed, level: .error, operation: .semanticSave, job: song.id, error: error)
                            throw error
                        }
                    }
                    try Task.checkCancellation()
                    guard ticket == epoch, let i = index(song.id) else { return }
                    if fullRun {
                        catalog.songs[i].wikiBPM = pendingWiki
                        catalog.songs[i].wikiMetadata = pendingMetadata
                        catalog.songs[i].bpmLookup = pendingLookup
                        catalog.songs[i].bpmCheckedAt = pendingCheckedAt
                    }
                    catalog.songs[i].needsReanalysis = nil
                    catalog.songs[i].failure = nil
                    catalog.songs[i].features = result
                    catalog.songs[i].genres = genres
                    catalog.songs[i].semantic = semantic
                    catalog.songs[i].finishedAt = Date()
                    update(song.id, state: .completed)
                } catch {
                    guard ticket == epoch, let i = index(song.id), catalog.songs[i].state != .unavailable else { return }
                    AppLog.shared.record(.analysis, Task.isCancelled ? .cancelled : .failed,
                                         level: Task.isCancelled ? .info : .error, operation: .pool, job: song.id,
                                         stage: LogStage(rawValue: catalog.songs[i].state.rawValue), error: error)
                    if Task.isCancelled {
                        update(song.id, state: .queued)
                    } else if case CurrentError.unavailable(let reason) = error {
                        catalog.songs[i].unavailability = reason
                        catalog.songs[i].failure = reason.message
                        update(song.id, state: .unavailable)
                    } else {
                        catalog.songs[i].failure = Self.safeMessage(error, stage: catalog.songs[i].state)
                        update(song.id, state: .failed)
                    }
                }
            }
        }
    }
    static func safeMessage(_ error: Error, stage: AnalysisState) -> String {
        if let known = error as? LyricsError { return known.localizedDescription }
        if let known = error as? GenreError { return known.localizedDescription }
        if let known = error as? SemanticError { return known.localizedDescription }
        if let known = error as? AnalysisError { return known.localizedDescription }
        if let known = error as? CurrentError { return known.localizedDescription }
        let issue = error as NSError
        // Persist only a fixed stage/domain and numeric code; system messages can contain signed URLs.
        if issue.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: issue.code) {
            case .timedOut: return "音频下载超时，请重试"
            case .notConnectedToInternet, .networkConnectionLost: return "网络连接中断，请重试"
            case .appTransportSecurityRequiresSecureConnection: return "音频地址被系统安全策略拦截"
            default: return "音频下载失败（网络错误 \(issue.code)）"
            }
        }
        let phase = stage == .analyzing ? "音频解码失败" : "获取音频失败"
        let domains = ["AVFoundationErrorDomain": "AVFoundation", "NSOSStatusErrorDomain": "音频系统",
                       NSCocoaErrorDomain: "本地文件"]
        return "\(phase)（\(domains[issue.domain] ?? "系统错误") \(issue.code)）"
    }
    private func update(_ id: UUID, state: AnalysisState) {
        guard let i = index(id) else { return }
        AppLog.shared.record(.analysis, .stateChanged, operation: .pool, job: id, stage: LogStage(rawValue: state.rawValue))
        catalog.songs[i].state = state
        // Transient stage changes need UI updates, not a full archive rewrite.
        if !state.active { persist() }
    }
    private func persist() {
        revision += 1
        let snapshot = catalog, number = revision
        Task {
            do { try await disk.save(snapshot, revision: number) }
            catch {
                AppLog.shared.record(.storage, .failed, level: .error, operation: .poolSave, error: error)
                failure = "分析数据保存失败，请检查可用空间。"; pause()
            }
        }
    }
}

private actor PoolDisk {
    let url: URL
    private var written = 0
    init(url: URL) { self.url = url }
    func load() throws -> PoolCatalog {
        // Remove files abandoned by process termination, never unrelated temporary files.
        if let files = try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
                                                                    includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("current-analysis-") && Set(["audio", "mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "caf"]).contains(file.pathExtension) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return PoolCatalog() }
        return try JSONDecoder().decode(PoolCatalog.self, from: Data(contentsOf: url))
    }
    func save(_ catalog: PoolCatalog, revision: Int) throws {
        guard revision > written else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(catalog)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        written = revision
        let lyricsDirectory = url.deletingLastPathComponent().appendingPathComponent("LyricsAnalysis")
        let lyricsKeep = Set(catalog.songs.compactMap { $0.lyrics?.recordID?.uuidString })
        if let files = try? FileManager.default.contentsOfDirectory(at: lyricsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for file in files where file.pathExtension == "json" && !lyricsKeep.contains(file.deletingPathExtension().lastPathComponent) {
                if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   Date().timeIntervalSince(date) > 86_400 { try? FileManager.default.removeItem(at: file) }
            }
        }
        let directory = url.deletingLastPathComponent().appendingPathComponent("SongAnalysis")
        let keep = Set(catalog.songs.compactMap { $0.semantic?.recordID.uuidString })
        // Leave newly created files alone: a newer snapshot may already be waiting to save.
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for file in files where file.pathExtension == "json" && !keep.contains(file.deletingPathExtension().lastPathComponent) {
                if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   Date().timeIntervalSince(date) > 86_400 { try? FileManager.default.removeItem(at: file) }
            }
        }
    }
}
