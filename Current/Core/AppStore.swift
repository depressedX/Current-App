import SwiftUI
import Combine

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()
    let api: NetEaseAPI
    let player = PlaybackController()
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
    @Published private(set) var libraryLoading = false
    @Published var message: String?
    @Published var error: String?
    private var restored = false
    private var accountEpoch = UUID()
    private var generationTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var loadingPlaylists = false
    private var cancellables = Set<AnyCancellable>()
    private let historyURL: URL
    var currentTrack: Track? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }
    var accountLabel: String { listener?.name ?? (demoMode ? "演示空间" : "尚未登录") }
    var scope: Int? { listener?.id }
    var visibleSessions: [ListeningSession] { sessions.filter { $0.listenerID == scope }.sorted { $0.createdAt > $1.createdAt } }
    var visibleFeedback: [Feedback] { feedback.filter { $0.listenerID == scope }.reversed() }
    init() {
        let testing = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        api = NetEaseAPI(ephemeral: testing)
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Current")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        historyURL = folder.appendingPathComponent(testing ? "ui-test-listening.json" : "listening.json")
        if testing { try? FileManager.default.removeItem(at: historyURL) }
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
        restoring = true
        let ticket = accountEpoch
        defer { restoring = false }
        do {
            let user = try await api.profile()
            guard ticket == accountEpoch else { return }
            listener = user; await loadPlaylists()
        } catch CurrentError.expired {
            guard ticket == accountEpoch else { return }
            api.clear(); self.error = CurrentError.expired.localizedDescription
        } catch {
            guard ticket == accountEpoch else { return }
            self.error = "暂时无法恢复账号，登录状态已保留。可在我的页面重试。"
        }
    }
    func retryRestore() async { restored = false; await restoreSession() }
    func finishLogin() async throws {
        let ticket = accountEpoch
        let user = try await api.profile()
        guard ticket == accountEpoch else { throw CancellationError() }
        resetPlayback(); demoMode = false; listener = user
        await loadPlaylists()
    }
    func enterDemo() {
        guard listener == nil else { return }
        demoMode = true; error = nil
    }
    func signOut() async {
        accountEpoch = UUID(); generationTask?.cancel(); playbackTask?.cancel()
        resetPlayback(); listener = nil; demoMode = false
        playlists = []; libraryTracks = []; selectedPlaylistID = nil
        libraryLoading = false; error = nil
        await api.logout()
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
        generating = true; error = nil
        let ticket = accountEpoch
        let playlistID = selectedPlaylistID
        generationTask = Task {
            defer { if ticket == accountEpoch { generating = false } }
            do {
                let tracks: [Track]
                if listener != nil {
                    guard let playlistID else { throw CurrentError.message("还没有可用歌单，请先在音乐库刷新或选择一个歌单。") }
                    tracks = try await api.tracks(playlistID: playlistID)
                } else {
                    try await Task.sleep(for: .milliseconds(450))
                    tracks = DemoCatalog.tracks
                }
                try Task.checkCancellation()
                guard ticket == accountEpoch else { return }
                let result = QueueComposer.compose(catalog: tracks)
                guard !result.isEmpty else { throw CurrentError.message("这个歌单暂无歌曲，请换一个歌单。") }
                libraryTracks = tracks
                activePrompt = text; queue = result; currentIndex = 0
                sessions.insert(ListeningSession(prompt: text, tracks: result, createdAt: Date(), listenerID: scope), at: 0)
                sessions = Array(sessions.prefix(30)); persist()
                message = "已为此刻准备 \(result.count) 首歌。"
                play(at: 0)
            } catch is CancellationError {} catch {
                if ticket == accountEpoch { self.error = error.localizedDescription }
            }
        }
    }
    func replay(_ session: ListeningSession) {
        guard session.listenerID == scope else { return }
        guard demoMode || listener != nil else { return }
        generationTask?.cancel(); generating = false
        activePrompt = session.prompt; queue = session.tracks; play(at: 0)
    }
    func play(at index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        let song = queue[index]
        playbackTask?.cancel()
        playbackTask = Task { await player.load(song, api: api) }
    }
    func next() {
        guard !queue.isEmpty else { return }
        if currentIndex + 1 < queue.count { play(at: currentIndex + 1) }
        else { player.pause(); message = "这一轮听完了，再写一句话，开启下一段。" }
    }
    func previous() {
        if player.position > 3 { player.seek(0) }
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
        generationTask?.cancel(); playbackTask?.cancel(); generating = false
        player.stop(); queue = []; currentIndex = 0; activePrompt = ""
    }
    private struct Archive: Codable { let sessions: [ListeningSession]; let feedback: [Feedback] }
    private func persist() {
        do {
            let data = try JSONEncoder().encode(Archive(sessions: sessions, feedback: feedback))
            try data.write(to: historyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { self.error = "记录保存失败：\(error.localizedDescription)" }
    }
}
