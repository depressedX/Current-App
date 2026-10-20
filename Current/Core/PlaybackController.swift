import AVFoundation
import MediaPlayer
import Combine

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var loading = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var error: String?
    private let player = AVPlayer()
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
    init() {
        observation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.playing = player.timeControlStatus == .playing
                self?.publishNowPlaying()
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
    func load(_ song: Track, api: NetEaseAPI) async {
        let ticket = UUID(); generation = ticket
        AppLog.shared.record(.playback, .started, operation: .playback, span: ticket)
        player.pause(); player.replaceCurrentItem(with: nil)
        statusObservation = nil; error = nil; loading = true; playing = false
        track = song; position = 0; duration = song.duration
        publishNowPlaying()
        do {
            let url: URL
            if let index = song.demoIndex {
                guard let local = Bundle.main.url(forResource: "demo-\(index)", withExtension: "wav") else {
                    throw CurrentError.message("演示音频缺失，请重新构建。")
                }
                url = local
            } else { url = try await api.playbackURL(id: song.id) }
            try Task.checkCancellation()
            guard ticket == generation else { return }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let item = AVPlayerItem(url: url)
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, ticket == self.generation else { return }
                    if item.status == .readyToPlay {
                        AppLog.shared.record(.playback, .ready, operation: .playback, span: ticket)
                        self.loading = false
                        if item.duration.seconds.isFinite { self.duration = item.duration.seconds }
                    } else if item.status == .failed {
                        AppLog.shared.record(.playback, .failed, level: .error, operation: .playback, span: ticket, error: item.error)
                        self.loading = false; self.error = "音频加载失败，请重试或换一首。"
                    }
                }
            }
            player.replaceCurrentItem(with: item); player.play()
        } catch is CancellationError {
            AppLog.shared.record(.playback, .cancelled, operation: .playback, span: ticket)
            if ticket == generation { loading = false }
        } catch {
            guard ticket == generation else { return }
            AppLog.shared.record(.playback, .failed, level: .error, operation: .playback, span: ticket, error: error)
            loading = false; self.error = error.localizedDescription
        }
    }
    func toggle() { playing ? pause() : resume() }
    func pause() {
        AppLog.shared.record(.playback, .paused, operation: .playback, span: generation)
        player.pause(); playing = false; publishNowPlaying() }
    func resume() {
        guard track != nil, player.currentItem != nil, error == nil else { return }
        AppLog.shared.record(.playback, .resumed, operation: .playback, span: generation)
        do { try AVAudioSession.sharedInstance().setActive(true); player.play() }
        catch {
            AppLog.shared.record(.playback, .failed, level: .error, operation: .audioSession, error: error)
            self.error = error.localizedDescription
        }
    }
    func seek(_ time: Double) {
        player.seek(to: CMTime(seconds: max(0, min(time, duration)), preferredTimescale: 600))
    }
    func stop() {
        generation = UUID(); player.pause(); player.replaceCurrentItem(with: nil)
        statusObservation = nil; track = nil; playing = false; loading = false
        position = 0; duration = 0; error = nil; MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func publishNowPlaying() {
        guard let track else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album, MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
    }
}
