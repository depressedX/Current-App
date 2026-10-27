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
