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
    private let semanticAnalyze: (@Sendable (URL) async throws -> SemanticAnalysis)?
    private let concepts: ConceptCatalog?
    private let intentResolver: any ListeningIntentResolving
    private let resolve: @MainActor (Track) async throws -> URL
    private let fetchBPM: (@MainActor (Track) async throws -> Double?)?
    private let analyze: @Sendable (URL) async throws -> AcousticFeatures
    private var task: Task<Void, Never>?
    private var epoch = UUID()
    private var revision = 0
    private var observers: [NSObjectProtocol] = []
    var songs: [PoolSong] { catalog.songs.filter { $0.account == account } }
    var completedCount: Int { songs.filter { $0.state == .completed }.count }
    var pendingCount: Int { songs.filter { $0.state != .completed && $0.state != .failed }.count }
    var waitReason: String? {
        if loading { return "正在恢复歌曲池" }
        if paused { return "已暂停" }
        if !foreground { return "回到 App 后继续" }
        if playbackBusy { return "听歌优先，播放结束后继续" }
        if constrained { return "节能或设备温度较高，稍后继续" }
        return nil
    }
    init(fileURL: URL? = nil, resolve: @escaping @MainActor (Track) async throws -> URL,
         fetchBPM: (@MainActor (Track) async throws -> Double?)? = nil,
         semanticAnalyze: (@Sendable (URL) async throws -> SemanticAnalysis)? = nil,
         concepts: ConceptCatalog? = nil,
         intentResolver: any ListeningIntentResolving = MockListeningIntentResolver(),
         analyze: @escaping @Sendable (URL) async throws -> AcousticFeatures = { try await NativeSongAnalyzer.analyze(url: $0) }) {
        self.resolve = resolve; self.analyze = analyze; self.fetchBPM = fetchBPM
        self.semanticAnalyze = semanticAnalyze; self.concepts = concepts
        self.intentResolver = intentResolver
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Current")
        let archive = fileURL ?? folder.appendingPathComponent("song-pool.json")
        disk = PoolDisk(url: archive)
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
                failure = "歌曲池读取失败，原文件已保留。"
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
        stop(); epoch = UUID(); self.account = account; paused = true
    }
    @discardableResult func enqueue(_ tracks: [Track], source: String) -> Int {
        guard !loading, failure == nil else { return 0 }
        let count = catalog.enqueue(tracks, account: account, source: source)
        AppLog.shared.record(.analysis, .enqueued, operation: .pool, count: count)
        persist(); pump(); return count
    }
    func analyzeHearing() {
        guard !loading, failure == nil else { return }
        for i in catalog.songs.indices where catalog.songs[i].account == account && catalog.songs[i].state == .completed && !catalog.songs[i].semanticReady {
            catalog.songs[i].needsReanalysis = true
            catalog.songs[i].state = .queued
        }
        persist(); resume()
    }
    func mockSemanticQueue(text: String) async throws -> (tracks: [Track], anchor: String) {
        guard let concepts else { throw SemanticError.missingResource }
        let scope = account
        let anchor = try await intentResolver.resolve(text: text, catalog: concepts)
        try Task.checkCancellation()
        guard scope == account else { throw CancellationError() }
        guard anchor.spaceID == concepts.spaceID else { throw SemanticError.incompatible }
        _ = try EmbeddingMath.unit(anchor.vector)
        let candidates = songs.filter(\.semanticReady)
        guard !candidates.isEmpty else { throw CurrentError.message("先在我的 → 歌曲池完成听感分析。") }
        var ranked: [(Track, Double)] = []
        for song in candidates {
            try Task.checkCancellation()
            guard scope == account else { throw CancellationError() }
            guard let semantic = song.semantic else { continue }
            do {
                let vector = try await semanticDisk.load(semantic, songID: song.id, account: scope)
                ranked.append((song.track, try EmbeddingMath.cosine(anchor.vector, vector)))
            } catch {
                guard scope == account else { throw CancellationError() }
                AppLog.shared.record(.storage, .failed, level: .error, operation: .semanticLoad, job: song.id, error: error)
                if let i = index(song.id), catalog.songs[i].semantic?.recordID == semantic.recordID {
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
        return (Array(ranked.prefix(12).map { $0.0 }), anchor.label)
    }
    func contains(_ track: Track) -> Bool { songs.contains { $0.track.id == track.id } }
    func resume() {
        AppLog.shared.record(.analysis, .resumed, operation: .pool, reason: .user)
        paused = false; pump()
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
        for i in catalog.songs.indices where catalog.songs[i].account == account && catalog.songs[i].state == .failed {
            catalog.songs[i].state = .queued; catalog.songs[i].failure = nil
        }
        persist(); resume()
    }
    func reanalyze(_ id: UUID) {
        guard !loading, failure == nil, let i = index(id),
              catalog.songs[i].state == .completed || catalog.songs[i].state == .failed else { return }
        catalog.songs[i].needsReanalysis = true
        catalog.songs[i].state = .queued
        catalog.songs[i].failure = nil
        AppLog.shared.record(.analysis, .enqueued, operation: .pool, job: id, reason: .user)
        persist(); resume()
    }
    func backfillBPM(_ id: UUID) {
        guard !loading, failure == nil, let i = index(id), catalog.songs[i].canBackfillBPM else { return }
        catalog.songs[i].state = .queued
        persist(); resume()
    }
    func remove(_ id: UUID) {
        guard let i = index(id) else { return }
        if catalog.songs[i].state.active { stop() }
        catalog.songs.removeAll { $0.id == id && $0.account == account }
        persist(); pump()
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
        guard task == nil, waitReason == nil, failure == nil,
              let song = songs.first(where: { $0.state == .queued }) else { return }
        let ticket = epoch
        update(song.id, state: !song.track.isDemo && fetchBPM != nil ? .readingMetadata : .fetching)
        task = Task {
            await LogScope.$trace.withValue(song.id) {
                defer { task = nil; pump() }
                let fullRun = song.needsReanalysis == true
                var pendingWiki = song.wikiBPM
                var pendingLookup = song.bpmLookup
                var pendingCheckedAt = song.bpmCheckedAt
                var temporary: URL?
                defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
                do {
                    if !song.track.isDemo, (song.wikiBPM == nil || fullRun), let fetchBPM {
                        do {
                            let value = try await fetchBPM(song.track)
                            try Task.checkCancellation()
                            guard ticket == epoch, let i = index(song.id) else { return }
                            if let value, value.isFinite, (20...400).contains(value) {
                                pendingWiki = WikiBPM(value: value, fetchedAt: Date())
                                pendingLookup = .available
                            } else { pendingWiki = nil; pendingLookup = .missing }
                            pendingCheckedAt = Date()
                            if !fullRun {
                                catalog.songs[i].wikiBPM = pendingWiki
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
                    try Task.checkCancellation()
                    guard ticket == epoch, let current = index(song.id) else { return }
                    // Metadata backfill reuses existing acoustic results; no audio re-download.
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
                        catalog.songs[i].bpmLookup = pendingLookup
                        catalog.songs[i].bpmCheckedAt = pendingCheckedAt
                    }
                    catalog.songs[i].needsReanalysis = nil
                    catalog.songs[i].failure = nil
                    catalog.songs[i].features = result
                    catalog.songs[i].semantic = semantic
                    catalog.songs[i].finishedAt = Date()
                    update(song.id, state: .completed)
                } catch {
                    guard ticket == epoch, let i = index(song.id) else { return }
                    AppLog.shared.record(.analysis, Task.isCancelled ? .cancelled : .failed,
                                         level: Task.isCancelled ? .info : .error, operation: .pool, job: song.id,
                                         stage: LogStage(rawValue: catalog.songs[i].state.rawValue), error: error)
                    if Task.isCancelled {
                        update(song.id, state: .queued)
                    } else {
                        catalog.songs[i].failure = Self.safeMessage(error, stage: catalog.songs[i].state)
                        update(song.id, state: .failed)
                    }
                }
            }
        }
    }
    static func safeMessage(_ error: Error, stage: AnalysisState) -> String {
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
                failure = "歌曲池保存失败，请检查可用空间。"; pause()
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
