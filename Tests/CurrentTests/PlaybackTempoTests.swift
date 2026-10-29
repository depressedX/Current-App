import XCTest
import AVFoundation
import MediaPlayer
@testable import Current

final class PlaybackTempoTests: XCTestCase {
    private func fixture(_ id: Int) -> Track {
        Track(id: id, title: "Tempo \(id)", artist: "Fixture", album: "Fixture", artwork: nil, duration: 24, demoIndex: nil)
    }
    @MainActor private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "TempoTests.\(UUID().uuidString)")!
    }
    @MainActor private func audio() throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: "demo-0", withExtension: "wav"))
    }
    @MainActor func testDragCancelsPendingHandoffAndReleaseFadesIntoPreparedAudio() async throws {
        let engine = TempoRecordingPlayer()
        let controller = PlaybackController(player: engine, systemIntegration: false, tempoDefaults: defaults())
        defer { controller.stop() }
        var replacements: [TempoRecordingPlayer] = []
        controller.makeTempoStandby = { item in
            let next = TempoRecordingPlayer()
            next.replaceCurrentItem(with: TempoRecordingItem(asset: item.asset))
            replacements.append(next)
            return next
        }
        controller.originalBPMForTrack = { _ in 120 }
        let url = try audio()
        await controller.load(fixture(1)) { _ in url }
        let item = engine.currentItem
        engine.resetRecording()

        controller.beginTempoEditing()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(replacements.isEmpty, "Holding the ruler must not prepare or change speed")
        XCTAssertTrue(engine.rateWrites.isEmpty)
        XCTAssertEqual(engine.pauseCount, 0)
        controller.endTempoEditing(at: 100)
        XCTAssertEqual(engine.rate, 1, "Keep the source running while preparing the new rate")
        XCTAssertTrue(engine.currentItem === item)
        XCTAssertEqual(replacements.count, 1)
        controller.beginTempoEditing()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(engine.rateWrites.isEmpty, "A second drag cancels the earlier release")
        XCTAssertEqual(engine.pauseCount, 0)
        XCTAssertEqual(engine.volume, 1)
        controller.endTempoEditing(at: 90)
        try await Task.sleep(for: .milliseconds(650))
        let next = try XCTUnwrap(replacements.last)
        XCTAssertEqual(next.rate, 0.75)
        XCTAssertEqual(next.volume, 1)
        XCTAssertEqual(engine.pauseCount, 1, "Retire the source only after the replacement is audible")
        XCTAssertEqual(next.currentItem?.audioTimePitchAlgorithm, .spectral)
        XCTAssertNil(controller.tempoAdjustmentIssue)
        controller.setTempoEnabled(false)
        XCTAssertEqual(next.rate, 0.75, "Reset also keeps the audible pipeline running during preparation")
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(replacements.last?.rate, 1)
        XCTAssertEqual(replacements.last?.volume, 1)
    }

    @MainActor func testFailedPreparationLeavesTheSourceUntouched() async throws {
        let engine = TempoRecordingPlayer()
        let controller = PlaybackController(player: engine, systemIntegration: false, tempoDefaults: defaults())
        defer { controller.stop() }
        controller.makeTempoStandby = { item in
            let next = TempoRecordingPlayer()
            next.canSeek = false
            next.replaceCurrentItem(with: TempoRecordingItem(asset: item.asset))
            return next
        }
        controller.originalBPMForTrack = { _ in 120 }
        let url = try audio()
        await controller.load(fixture(1)) { _ in url }
        engine.resetRecording()
        controller.setTargetBPM(90)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(engine.rateWrites.isEmpty)
        XCTAssertEqual(engine.pauseCount, 0)
        XCTAssertEqual(engine.volume, 1)
        XCTAssertNotNil(controller.tempoAdjustmentIssue)
        XCTAssertFalse(controller.tempo.enabled)
    }

    @MainActor func testUnsupportedReleaseAndCancelledDragKeepAudioPlaying() async throws {
        let engine = TempoRecordingPlayer()
        let controller = PlaybackController(player: engine, systemIntegration: false, tempoDefaults: defaults())
        defer { controller.stop() }
        controller.originalBPMForTrack = { _ in 120 }
        let url = try audio()
        await controller.load(fixture(1)) { _ in url }
        engine.resetRecording()
        controller.beginTempoEditing()
        controller.endTempoEditing(at: 40)
        XCTAssertEqual(engine.rate, 1)
        XCTAssertEqual(engine.pauseCount, 0)
        XCTAssertFalse(controller.tempo.enabled)
        XCTAssertNotNil(controller.tempoAdjustmentIssue)
        controller.beginTempoEditing()
        controller.cancelTempoEditing()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(engine.rateWrites.isEmpty)
        XCTAssertEqual(engine.pauseCount, 0)
    }

    @MainActor func testPendingHandoffCannotRestartPausedOrStoppedPlayback() async throws {
        let engine = TempoRecordingPlayer()
        let controller = PlaybackController(player: engine, systemIntegration: false, tempoDefaults: defaults())
        defer { controller.stop() }
        controller.makeTempoStandby = { item in
            let next = TempoRecordingPlayer()
            next.replaceCurrentItem(with: TempoRecordingItem(asset: item.asset))
            return next
        }
        controller.originalBPMForTrack = { _ in 120 }
        let url = try audio()
        await controller.load(fixture(1)) { _ in url }
        controller.setTargetBPM(90)
        controller.pause()
        engine.resetRecording()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(engine.rateWrites.isEmpty)
        XCTAssertEqual(engine.rate, 0)
        controller.resume()
        XCTAssertEqual(engine.rate, 0.75)
        controller.setTargetBPM(100)
        controller.stop()
        engine.resetRecording()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(engine.rateWrites.isEmpty)
        XCTAssertEqual(engine.rate, 0)
        XCTAssertNil(engine.currentItem)
    }

    @MainActor func testTargetSurvivesTrackChangesAndPauseResumeWithoutChangingPitch() async throws {
        let engine = AVPlayer()
        let controller = PlaybackController(player: engine, systemIntegration: false, tempoDefaults: defaults())
        defer { controller.stop() }
        controller.originalBPMForTrack = { $0.id == 1 ? 96 : 120 }
        controller.setTargetBPM(100)
        let url = try audio()
        await controller.load(fixture(1)) { _ in url }
        XCTAssertEqual(engine.currentItem?.audioTimePitchAlgorithm, .spectral)
        XCTAssertEqual(engine.defaultRate, Float(100.0 / 96), accuracy: 0.0001)
        controller.pause()
        controller.setTargetBPM(115)
        XCTAssertFalse(controller.playing)
        XCTAssertEqual(engine.rate, 0, "Adjusting while paused must not start audio")
        controller.resume()
        XCTAssertTrue(controller.playing)
        XCTAssertEqual(engine.defaultRate, Float(115.0 / 96), accuracy: 0.0001)
        await controller.load(fixture(2)) { _ in url }
        XCTAssertEqual(controller.tempo.targetBPM, 115)
        XCTAssertEqual(controller.tempo.originalBPM, 120)
        XCTAssertEqual(engine.defaultRate, Float(115.0 / 120), accuracy: 0.0001)
        controller.pause()
        XCTAssertEqual(controller.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertEqual(controller.nowPlayingInfo?[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double,
                       Double(Float(115.0 / 120)))
    }
    @MainActor func testUnknownTempoWaitsForCatalogAndResetRestoresExactOriginal() async throws {
        let engine = AVPlayer()
        let controller = PlaybackController(player: engine, systemIntegration: false, tempoDefaults: defaults())
        defer { controller.stop() }
        var catalogBPM: Double?
        controller.originalBPMForTrack = { _ in catalogBPM }
        controller.setTargetBPM(100)
        let url = try audio()
        await controller.load(fixture(1)) { _ in url }
        XCTAssertTrue(controller.playing)
        XCTAssertEqual(engine.rate, 0)
        XCTAssertFalse(controller.loading)
        XCTAssertNotNil(controller.tempo.issue)
        catalogBPM = 123
        controller.refreshOriginalBPM()
        XCTAssertNil(controller.tempo.issue)
        XCTAssertEqual(engine.defaultRate, Float(100.0 / 123), accuracy: 0.0001)
        controller.pause()
        controller.setTempoEnabled(false)
        XCTAssertEqual(controller.tempo.displayBPM, 123, "Reset shows the exact original, not the saved target or nearest tick")
        XCTAssertEqual(engine.defaultRate, 1)
        controller.pause()
        catalogBPM = nil
        controller.refreshOriginalBPM()
        XCTAssertNil(controller.tempo.displayBPM)
        XCTAssertFalse(controller.playing)
        XCTAssertEqual(engine.rate, 0)
    }
    @MainActor func testInFlightLoadUsesLatestTargetAndStopDoesNotRestart() async throws {
        let engine = AVPlayer()
        let controller = PlaybackController(player: engine, systemIntegration: false, tempoDefaults: defaults())
        controller.originalBPMForTrack = { _ in 120 }
        let started = expectation(description: "URL resolver")
        var reply: CheckedContinuation<URL, Error>?
        let task = Task {
            await controller.load(fixture(1)) { _ in
                try await withCheckedThrowingContinuation { reply = $0; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        controller.setTargetBPM(95)
        controller.pause()
        reply?.resume(returning: try audio())
        await task.value
        XCTAssertEqual(engine.defaultRate, Float(95.0 / 120), accuracy: 0.0001)
        XCTAssertEqual(engine.rate, 0)
        controller.stop()
        XCTAssertFalse(controller.tempo.enabled)
        XCTAssertNil(controller.tempo.originalBPM)
        XCTAssertNil(controller.nowPlayingInfo)
    }
    @MainActor func testOnlyLastTargetIsRestoredAndRateOutsideLimitsNeverPlays() async throws {
        let saved = defaults()
        let first = PlaybackController(systemIntegration: false, tempoDefaults: saved)
        first.setTargetBPM(113)
        first.stop()
        let engine = AVPlayer()
        let second = PlaybackController(player: engine, systemIntegration: false, tempoDefaults: saved)
        defer { second.stop() }
        XCTAssertEqual(second.tempo.targetBPM, 115)
        XCTAssertFalse(second.tempo.enabled)
        second.originalBPMForTrack = { _ in 240 }
        second.setTargetBPM(100)
        let url = try audio()
        await second.load(fixture(1)) { _ in url }
        XCTAssertNotNil(second.tempo.issue)
        XCTAssertEqual(engine.rate, 0)
        second.setTempoEnabled(false)
        XCTAssertEqual(engine.defaultRate, 1)
        XCTAssertNil(second.tempo.issue)
    }
}

/// Records transport commands without a decoder or output device; acoustic continuity needs device QA.
private final class TempoRecordingPlayer: AVPlayer {
    var canSeek = true
    private var recordedItem: AVPlayerItem?
    private var currentRate: Float = 0
    private(set) var rateWrites: [Float] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    override var currentItem: AVPlayerItem? { recordedItem }
    override var status: AVPlayer.Status { .readyToPlay }
    override func currentTime() -> CMTime { .zero }
    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
                       completionHandler: (@Sendable (Bool) -> Void)?) { completionHandler?(canSeek) }
    override func preroll(atRate rate: Float, completionHandler: (@Sendable (Bool) -> Void)?) { completionHandler?(true) }
    override func setRate(_ rate: Float, time: CMTime, atHostTime hostClockTime: CMTime) { self.rate = rate }
    override var rate: Float {
        get { currentRate }
        set { currentRate = newValue; rateWrites.append(newValue) }
    }
    override var timeControlStatus: AVPlayer.TimeControlStatus { currentRate > 0 ? .playing : .paused }
    override func replaceCurrentItem(with item: AVPlayerItem?) { recordedItem = item }
    override func play() { playCount += 1; rate = defaultRate }
    override func pause() { pauseCount += 1; rate = 0 }
    func resetRecording() { rateWrites = []; playCount = 0; pauseCount = 0 }
}

private final class TempoRecordingItem: AVPlayerItem {
    override var isPlaybackLikelyToKeepUp: Bool { true }
}
