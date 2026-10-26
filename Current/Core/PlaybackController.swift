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
    private let player: AVPlayer
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
    private var shouldResume = false
    private var track: Track?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onLike: (() -> Void)?
    init(player: AVPlayer = AVPlayer(), systemIntegration: Bool = true, artworkCache: ArtworkCache = .shared) {
        self.player = player; self.systemIntegration = systemIntegration; self.artworkCache = artworkCache
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
                guard let self else { return }
                self.position = time.seconds.isFinite ? max(0, time.seconds) : 0
                self.publishNowPlaying()
            }
        }
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
    func load(_ song: Track, api: NetEaseAPI, next: Track? = nil) async {
        await load(song, next: next) { track in try await api.playbackURL(id: track.id) }
    }

    // The resolver is injectable so a paused in-flight request can be tested without a server.
    func load(_ song: Track, next: Track? = nil, resolve: @escaping (Track) async throws -> URL) async {
        guard !Task.isCancelled else { return }
        let ticket = UUID(); generation = ticket
        AppLog.shared.record(.playback, .started, operation: .playback, span: ticket)
        statusObservation = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        loadingTask?.cancel(); loading = false; showLoading = false
        error = nil; playing = true; preparing = true
        track = song; upcoming = next; resolveURL = resolve
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
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, ticket == self.generation else { return }
                    if item.status == .readyToPlay {
                        AppLog.shared.record(.playback, .ready, operation: .playback, span: ticket)
                        self.preparing = false
                        if item.duration.seconds.isFinite { self.duration = item.duration.seconds }
                        self.updateLoading()
                    } else if item.status == .failed {
                        AppLog.shared.record(.playback, .failed, level: .error, operation: .playback, span: ticket, error: item.error)
                        self.fail("音频加载失败，请重试或换一首。")
                    }
                }
            }
            player.replaceCurrentItem(with: item)
            if playing { player.play() }
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
        playing = false; player.pause(); updateLoading(); publishNowPlaying()
    }
    func resume() {
        guard track != nil, error == nil else { return }
        AppLog.shared.record(.playback, .resumed, operation: .playback, span: generation)
        playing = true
        do {
            try activateSession()
            if player.currentItem != nil { player.play() }
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
        preparing = false; playing = false; error = message
        player.pause(); updateLoading(); publishNowPlaying()
    }
    private func updateLoading() {
        let busy = playing && error == nil && (preparing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
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
        player.seek(to: CMTime(seconds: max(0, min(time, duration)), preferredTimescale: 600))
    }
    func stop() {
        generation = UUID(); player.pause(); player.replaceCurrentItem(with: nil)
        loadingTask?.cancel(); artworkTask?.cancel(); cancelPrefetch()
        upcoming = nil; resolveURL = nil; artwork = nil; preparing = false; showLoading = false
        statusObservation = nil; track = nil; playing = false; loading = false
        position = 0; duration = 0; error = nil
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
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .playing ? 1.0 : 0.0
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        return info
    }
    private func publishNowPlaying() {
        guard systemIntegration else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
}
