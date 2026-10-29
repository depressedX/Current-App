import AVFoundation
import MediaPlayer
import Combine

@MainActor
final class PlaybackController: ObservableObject {
    /// User intent; buffering never turns a requested play into a pause.
    @Published private(set) var playing = false
    @Published private(set) var loading = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var error: String?
    @Published private(set) var showLoading = false
    @Published private(set) var tempo = PlaybackTempo()
    /// Supplied by AppStore, scoped to the active song-pool account.
    var originalBPMForTrack: ((Track) -> Double?)?
    private let tempoDefaults: UserDefaults
    private var tempoChange: Task<Void, Never>?
    var makeTempoStandby: (AVPlayerItem) -> AVPlayer = { AVPlayer(playerItem: $0) }
    private var tempoStandby: AVPlayer?
    private var tempoRevision = UUID()
    private var editingTempo = false
    private var renderedTempo = PlaybackTempo()
    @Published private(set) var tempoAdjustmentIssue: String?
    private static let targetKey = "current.playback.target-bpm"
    private var player: AVPlayer
    private let systemIntegration: Bool
    private let artworkCache: ArtworkCache
    private var preparing = false
    private var audioSessionActive = false
    private var loadingTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?
    private struct PreparedSource {
        let trackID: Int
        let asset: AVURLAsset
        let expires: Date
    }
    private var prepared: PreparedSource?
    private var prefetchTask: Task<PreparedSource?, Never>?
    private var prefetchTrackID: Int?
    private var upcoming: Track?
    private var resolveURL: ((Track) async throws -> URL)?
    private var observation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var timer: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptions: NSObjectProtocol?
    private var routeChanges: NSObjectProtocol?
    private var generation = UUID()
    private var pendingSeek: UUID?
    private var shouldResume = false
    private var track: Track?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onLike: (() -> Void)?
    init(player: AVPlayer = AVPlayer(), systemIntegration: Bool = true, artworkCache: ArtworkCache = .shared,
         tempoDefaults: UserDefaults = .standard) {
        self.player = player; self.systemIntegration = systemIntegration; self.artworkCache = artworkCache
        self.tempoDefaults = tempoDefaults
        if let last = tempoDefaults.object(forKey: Self.targetKey) as? Double {
            tempo.targetBPM = PlaybackTempo.snappedTarget(last)
        }
        observeTransport()
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.onNext?()
            }
        }
        interruptions = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                AppLog.shared.record(.playback, .interrupted, operation: .audioSession, status: type.map { Int($0) })
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.audioSessionActive = false
                    self.shouldResume = self.playing; self.pause()
                } else if self.shouldResume && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                    self.resume()
                }
            }
        }
        routeChanges = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in
                    AppLog.shared.record(.playback, .routeChanged, operation: .audioSession)
                    self?.pause()
                }
            }
        }
        guard systemIntegration else { return }
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.onNext?() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.onPrevious?() }; return .success }
        commands.likeCommand.isEnabled = true
        commands.likeCommand.addTarget { [weak self] _ in Task { @MainActor in self?.onLike?() }; return .success }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }; return .success
        }
    }
    private func observeTransport() {
        observation = nil
        if let timer { player.removeTimeObserver(timer) }
        timer = nil
        observation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateLoading()
                if player.timeControlStatus == .playing { self.prefetchNextIfNeeded() }
                self.publishNowPlaying()
            }
        }
        timer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.pendingSeek == nil else { return }
                let seconds = self.player.currentTime().seconds
                self.position = seconds.isFinite ? max(0, seconds) : 0
                self.publishNowPlaying()
            }
        }
    }
    func load(_ song: Track, api: NetEaseAPI, next: Track? = nil) async {
        await load(song, next: next) { track in try await api.playbackURL(id: track.id) }
    }

    // The resolver is injectable so a paused in-flight request can be tested without a server.
    func load(_ song: Track, next: Track? = nil, resolve: @escaping (Track) async throws -> URL) async {
        guard !Task.isCancelled else { return }
        let ticket = UUID(); generation = ticket
        pendingSeek = nil
        AppLog.shared.record(.playback, .started, operation: .playback, span: ticket)
        statusObservation = nil
        cancelTempoChange(); player.pause(); player.replaceCurrentItem(with: nil)
        loadingTask?.cancel(); loading = false; showLoading = false
        error = nil; playing = true; preparing = true
        track = song; upcoming = next; resolveURL = resolve
        tempo.originalBPM = originalBPM(for: song)
        position = 0; duration = song.duration
        updateLoading(); loadArtwork(song, ticket: ticket); publishNowPlaying()
        do {
            let asset: AVURLAsset
            if let index = song.demoIndex {
                cancelPrefetch()
                guard let local = Bundle.main.url(forResource: "demo-\(index)", withExtension: "wav") else {
                    throw CurrentError.message("演示音频缺失，请重新构建。")
                }
                asset = AVURLAsset(url: local)
            } else if let source = prepared, source.trackID == song.id, source.expires > Date() {
                asset = source.asset
                cancelPrefetch()
            } else {
                // Never wait for speculative work: foreground playback gets a fresh request.
                cancelPrefetch()
                asset = AVURLAsset(url: try await resolve(song))
            }
            try Task.checkCancellation()
            guard ticket == generation else { return }
            if playing { try activateSession() }
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .spectral
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, ticket == self.generation, self.player.currentItem === item else { return }
                    if item.status == .readyToPlay {
                        AppLog.shared.record(.playback, .ready, operation: .playback, span: ticket)
                        self.preparing = false
                        if item.duration.seconds.isFinite { self.duration = item.duration.seconds }
                        self.applyTempo()
                        self.updateLoading()
                    } else if item.status == .failed {
                        AppLog.shared.record(.playback, .failed, level: .error, operation: .playback, span: ticket, error: item.error)
                        self.fail("音频加载失败，请重试或换一首。")
                    }
                }
            }
            player.replaceCurrentItem(with: item)
            applyTempo()
            updateLoading()
        } catch is CancellationError {
            AppLog.shared.record(.playback, .cancelled, operation: .playback, span: ticket)
            if ticket == generation { preparing = false; playing = false; updateLoading(); publishNowPlaying() }
        } catch {
            guard ticket == generation else { return }
            AppLog.shared.record(.playback, .failed, level: .error, operation: .playback, span: ticket, error: error)
            fail(error.localizedDescription)
        }
    }
    func toggle() { playing ? pause() : resume() }
    func pause() {
        AppLog.shared.record(.playback, .paused, operation: .playback, span: generation)
        cancelTempoChange()
        playing = false; player.pause(); updateLoading(); publishNowPlaying()
    }
    func resume() {
        guard track != nil, error == nil else { return }
        AppLog.shared.record(.playback, .resumed, operation: .playback, span: generation)
        playing = true
        do {
            try activateSession()
            applyTempo()
            updateLoading(); publishNowPlaying()
        } catch {
            AppLog.shared.record(.playback, .failed, level: .error, operation: .audioSession, error: error)
            fail(error.localizedDescription)
        }
    }
    private func activateSession() throws {
        guard systemIntegration, !audioSessionActive else { return }
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        audioSessionActive = true
    }
    private func fail(_ message: String) {
        cancelTempoChange()
        preparing = false; playing = false; error = message
        player.pause(); updateLoading(); publishNowPlaying()
    }
    private func updateLoading() {
        let busy = playing && error == nil && tempo.issue == nil && (preparing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        guard loading != busy else { return }
        loading = busy
        loadingTask?.cancel(); loadingTask = nil
        if !busy { showLoading = false; return }
        let ticket = generation
        loadingTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, self.generation == ticket, self.loading else { return }
            self.showLoading = true
        }
    }
    func updateUpcomingTrack(_ next: Track?) {
        cancelPrefetch()
        upcoming = next
        if playing { prefetchNextIfNeeded() }
    }
    private func prefetchNextIfNeeded() {
        guard let next = upcoming, !next.isDemo, !ProcessInfo.processInfo.isLowPowerModeEnabled,
              prefetchTrackID != next.id, let resolveURL else { return }
        prefetchTrackID = next.id
        let ticket = generation
        prefetchTask = Task { [weak self] in
            do {
                let url = try await resolveURL(next)
                try Task.checkCancellation()
                let asset = AVURLAsset(url: url)
                // Prime URL and metadata only; no full-song background download on cellular.
                _ = try await asset.load(.isPlayable, .duration)
                guard !Task.isCancelled, let self, self.generation == ticket else { return nil }
                let source = PreparedSource(trackID: next.id, asset: asset, expires: Date().addingTimeInterval(120))
                self.prepared = source
                return source
            } catch { return nil }
        }
    }
    private func cancelPrefetch() {
        prefetchTask?.cancel(); prefetchTask = nil
        prepared = nil; prefetchTrackID = nil
    }
    private func loadArtwork(_ song: Track, ticket: UUID) {
        artworkTask?.cancel(); artwork = nil
        guard let url = ArtworkCache.url(song.artwork, pixels: 1024) else { return }
        artworkTask = Task { [weak self] in
            guard let self else { return }
            let preview = await self.artworkCache.preview(for: url)
            guard !Task.isCancelled, self.generation == ticket else { return }
            if let preview { self.applyArtwork(preview) }
            let image = await self.artworkCache.image(for: url)
            guard !Task.isCancelled, self.generation == ticket, let image else { return }
            self.applyArtwork(image)
        }
    }
    private func applyArtwork(_ image: UIImage) {
        artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        publishNowPlaying()
    }
    func seek(_ time: Double) {
        guard time.isFinite, duration.isFinite, duration > 0, player.currentItem != nil else { return }
        cancelTempoChange()
        let target = max(0, min(time, duration))
        let ticket = UUID()
        pendingSeek = ticket
        position = target
        publishNowPlaying()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pendingSeek == ticket else { return }
                self.pendingSeek = nil
                let seconds = self.player.currentTime().seconds
                if seconds.isFinite { self.position = max(0, seconds) }
                self.publishNowPlaying()
            }
        }
    }
    func stop() {
        cancelTempoChange()
        generation = UUID(); player.pause(); player.replaceCurrentItem(with: nil)
        pendingSeek = nil
        loadingTask?.cancel(); artworkTask?.cancel(); cancelPrefetch()
        upcoming = nil; resolveURL = nil; artwork = nil; preparing = false; showLoading = false
        statusObservation = nil; track = nil; playing = false; loading = false
        position = 0; duration = 0; error = nil
        tempo.enabled = false; tempo.originalBPM = nil; player.defaultRate = 1
        renderedTempo = tempo; editingTempo = false; tempoAdjustmentIssue = nil
        guard systemIntegration else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioSessionActive = false
    }
    var nowPlayingInfo: [String: Any]? {
        guard let track else { return nil }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album, MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .playing ? Double(player.rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(player.defaultRate)
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        return info
    }
    private func publishNowPlaying() {
        guard systemIntegration else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    // Drag updates never alter tempo intent or the rendering players.
    func beginTempoEditing() {
        guard !editingTempo else { return }
        editingTempo = true
        cancelTempoChange()
        let original = tempo.originalBPM
        tempo = renderedTempo
        tempo.originalBPM = original
        tempoAdjustmentIssue = nil
    }
    func cancelTempoEditing() {
        guard editingTempo else { return }
        editingTempo = false
        if playing, player.rate == 0 { applyTempo() }
    }
    func endTempoEditing(at bpm: Double) {
        editingTempo = false
        setTargetBPM(bpm)
    }
    private func cancelTempoChange() {
        tempoRevision = UUID()
        tempoChange?.cancel(); tempoChange = nil
        tempoStandby?.cancelPendingPrerolls()
        tempoStandby?.currentItem?.cancelPendingSeeks()
        player.volume = 1
        tempoStandby?.pause(); tempoStandby = nil
    }
    func setTempoEnabled(_ enabled: Bool) {
        guard tempo.enabled != enabled else { return }
        var candidate = tempo
        if enabled, tempoDefaults.object(forKey: Self.targetKey) == nil, let bpm = candidate.originalBPM {
            candidate.targetBPM = PlaybackTempo.snappedTarget(bpm)
        }
        candidate.enabled = enabled
        commitTempo(candidate)
    }
    func setTargetBPM(_ bpm: Double) {
        var candidate = tempo
        candidate.targetBPM = PlaybackTempo.snappedTarget(bpm)
        candidate.enabled = true
        commitTempo(candidate)
    }
    private func commitTempo(_ candidate: PlaybackTempo) {
        // Reject unsupported selections without stopping the current audio or claiming they were applied.
        if candidate.originalBPM != nil, candidate.playbackRate == nil {
            cancelTempoChange()
            tempo = renderedTempo
            tempoAdjustmentIssue = candidate.issue
            return
        }
        tempoAdjustmentIssue = nil
        tempo = candidate
        tempoDefaults.set(tempo.targetBPM, forKey: Self.targetKey)
        applyTempo(deferred: true)
    }
    func refreshOriginalBPM() {
        guard let track else { return }
        let bpm = originalBPM(for: track)
        guard bpm != tempo.originalBPM else { return }
        tempo.originalBPM = bpm
        applyTempo(deferred: true)
    }
    private func originalBPM(for track: Track) -> Double? {
        PlaybackTempo.validOriginal(originalBPMForTrack?(track))
    }
    private func applyTempo(deferred: Bool = false) {
        guard !editingTempo else { return }
        cancelTempoChange()
        guard let rate = tempo.playbackRate else {
            // An unresolved new track waits; a playing track must never be interrupted by a tempo edit.
            if player.rate == 0 { player.pause() }
            updateLoading(); publishNowPlaying(); return
        }
        guard playing, error == nil, let item = player.currentItem else {
            player.defaultRate = rate
            renderedTempo = tempo
            publishNowPlaying(); return
        }
        if deferred, player.rate > 0 {
            guard abs(player.rate - rate) > 0.001 else { renderedTempo = tempo; return }
            let source = player
            let revision = tempoRevision
            let requested = tempo
            let standby = makeTempoStandby(AVPlayerItem(asset: item.asset))
            standby.currentItem?.audioTimePitchAlgorithm = .spectral
            standby.volume = 0
            standby.defaultRate = rate
            standby.automaticallyWaitsToMinimizeStalling = false
            tempoStandby = standby
            tempoChange = Task { [weak self] in
                do {
                    try await TempoHandoff.prepare(standby, alongside: source, rate: rate)
                    for step in 1...10 {
                        try Task.checkCancellation()
                        guard standby.timeControlStatus == .playing else { throw TempoHandoff.Failure.notReady }
                        source.volume = 1 - Float(step) / 10
                        standby.volume = Float(step) / 10
                        try await Task.sleep(for: .milliseconds(12))
                    }
                    guard let self, !Task.isCancelled, self.tempoRevision == revision, !self.editingTempo else { return }
                    // Remove time observers from their owning player before transferring transport ownership.
                    self.observation = nil
                    self.statusObservation = nil
                    if let timer = self.timer { source.removeTimeObserver(timer) }
                    self.timer = nil
                    self.player = standby
                    self.tempoStandby = nil
                    self.tempoChange = nil
                    self.renderedTempo = requested
                    self.observeTransport()
                    self.statusObservation = standby.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
                        Task { @MainActor in
                            guard let self, self.player.currentItem === item, item.status == .failed else { return }
                            self.fail("音频加载失败，请重试或换一首。")
                        }
                    }
                    source.pause(); source.replaceCurrentItem(with: nil)
                    standby.automaticallyWaitsToMinimizeStalling = true
                    self.updateLoading(); self.publishNowPlaying()
                } catch {
                    guard let self, self.tempoRevision == revision else { return }
                    self.cancelTempoChange()
                    self.tempo = self.renderedTempo
                    self.tempoAdjustmentIssue = "暂未完成调速，继续按原速度播放，请重试"
                    self.updateLoading(); self.publishNowPlaying()
                }
            }
        } else {
            player.defaultRate = rate
            renderedTempo = tempo
            player.play()
        }
        updateLoading(); publishNowPlaying()
    }
}

/// Prepare a separate, inaudible pipeline; the source keeps playing through every wait and seek.
@MainActor
private enum TempoHandoff {
    enum Failure: Error { case notReady }
    static func prepare(_ next: AVPlayer, alongside source: AVPlayer, rate: Float) async throws {
        try await wait { next.status == .readyToPlay }
        let seekTime = source.currentTime()
        guard seekTime.isNumeric else { throw Failure.notReady }
        guard await next.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) else {
            throw Failure.notReady
        }
        try Task.checkCancellation()
        // Bound preroll as well as readiness: slow networks leave the old audio untouched.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { next.cancelPendingPrerolls() }
        }
        defer { timeout.cancel() }
        guard await next.preroll(atRate: rate) else { throw Failure.notReady }
        try Task.checkCancellation()
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        let lead = CMTime(seconds: 0.15, preferredTimescale: 60_000)
        let position = CMTimeAdd(source.currentTime(), CMTimeMultiplyByFloat64(lead, multiplier: Double(source.rate)))
        next.setRate(rate, time: position, atHostTime: CMTimeAdd(host, lead))
        try await Task.sleep(for: .milliseconds(180))
        try await wait { next.timeControlStatus == .playing && next.currentItem?.isPlaybackLikelyToKeepUp == true }
        // Do not fade into a stalled or misaligned replacement.
        guard abs(next.currentTime().seconds - source.currentTime().seconds) < 0.15 else { throw Failure.notReady }
    }
    static func wait(until ready: () -> Bool) async throws {
        for _ in 0..<400 {
            try Task.checkCancellation()
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.notReady
    }
}
