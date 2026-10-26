import XCTest
import UIKit
import AVFoundation
import MediaPlayer
@testable import Current

private final class ArtworkProtocol: URLProtocol {
    static let lock = NSLock()
    static var hits = 0
    static var data = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.hits += 1; let data = Self.data; Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class PlaybackArtworkTests: XCTestCase {
    private func fixture(_ id: Int = 42, artwork: URL? = nil) -> Track {
        Track(id: id, title: "Fixture \(id)", artist: "Artist", album: "Album", artwork: artwork, duration: 24, demoIndex: nil)
    }
    @MainActor private func localAudio() throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: "demo-0", withExtension: "wav"))
    }
    @MainActor private func cache(_ folder: URL) -> ArtworkCache {
        ArtworkProtocol.lock.lock()
        ArtworkProtocol.hits = 0
        ArtworkProtocol.data = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        ArtworkProtocol.lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkProtocol.self]
        return ArtworkCache(directory: folder, session: URLSession(configuration: config))
    }
    @MainActor func testPauseWhileResolvingIsImmediateAndSurvivesLoad() async throws {
        let engine = AVPlayer()
        let controller = PlaybackController(player: engine, systemIntegration: false)
        defer { controller.stop() }
        let started = expectation(description: "resolving")
        var reply: CheckedContinuation<URL, Error>?
        let task = Task {
            await controller.load(fixture()) { _ in
                try await withCheckedThrowingContinuation { reply = $0; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(controller.playing)
        XCTAssertTrue(controller.loading)
        XCTAssertFalse(controller.showLoading)
        controller.toggle()
        XCTAssertFalse(controller.playing)
        XCTAssertFalse(controller.loading)
        reply?.resume(returning: try localAudio())
        await task.value
        XCTAssertFalse(controller.playing)
        XCTAssertEqual(engine.rate, 0)
        controller.resume()
        XCTAssertTrue(controller.playing) // No wait for a transport callback.
    }
    @MainActor func testLoadingDelayAndStopInvalidateOutstandingLoad() async throws {
        let controller = PlaybackController(systemIntegration: false)
        let started = expectation(description: "resolving")
        var reply: CheckedContinuation<URL, Error>?
        let task = Task {
            await controller.load(fixture()) { _ in
                try await withCheckedThrowingContinuation { reply = $0; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(controller.showLoading)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(controller.showLoading)
        controller.stop()
        reply?.resume(returning: try localAudio())
        await task.value
        XCTAssertFalse(controller.playing)
        XCTAssertFalse(controller.showLoading)
        XCTAssertNil(controller.nowPlayingInfo)
    }
    @MainActor func testSupersededLoadCannotReplaceNewTrack() async throws {
        let controller = PlaybackController(systemIntegration: false)
        defer { controller.stop() }
        let started = expectation(description: "old request")
        var reply: CheckedContinuation<URL, Error>?
        let old = Task {
            await controller.load(fixture(1)) { _ in
                try await withCheckedThrowingContinuation { reply = $0; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let audio = try localAudio()
        await controller.load(fixture(2)) { _ in audio }
        controller.pause()
        reply?.resume(throwing: URLError(.timedOut))
        await old.value
        XCTAssertNil(controller.error)
        XCTAssertFalse(controller.playing)
        XCTAssertEqual(controller.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Fixture 2")
    }
    @MainActor func testArtworkCoalescesAndSurvivesNewCacheInstanceAndSizeChange() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = cache(folder)
        let url = URL(string: "https://p1.music.126.net/fixture.png?param=160y160")!
        async let a = first.image(for: url)
        async let b = first.image(for: url)
        let images = await (a, b)
        XCTAssertNotNil(images.0); XCTAssertNotNil(images.1)
        XCTAssertNotNil(first.cachedImage(for: url))
        let initialHits = ArtworkProtocol.lock.withLock { ArtworkProtocol.hits }
        XCTAssertEqual(initialHits, 1)
        let second = cache(folder) // Reset request count; disk should suffice.
        let disk = await second.image(for: url)
        XCTAssertNotNil(disk)
        let preview = await second.preview(for: ArtworkCache.url(url, pixels: 1024)!)
        XCTAssertNotNil(preview)
        let hits = ArtworkProtocol.lock.withLock { ArtworkProtocol.hits }
        XCTAssertEqual(hits, 0)
    }
    @MainActor func testLockScreenArtworkSurvivesPauseAndProgressAndClearsOnTrackChange() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = PlaybackController(systemIntegration: false, artworkCache: cache(folder))
        defer { controller.stop() }
        let audio = try localAudio()
        await controller.load(fixture(artwork: URL(string: "https://p1.music.126.net/fixture.png"))) { _ in audio }
        for _ in 0..<100 {
            if controller.nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(controller.nowPlayingInfo?[MPMediaItemPropertyArtwork])
        controller.pause()
        try await Task.sleep(for: .milliseconds(600)) // Includes a periodic progress update.
        XCTAssertNotNil(controller.nowPlayingInfo?[MPMediaItemPropertyArtwork])
        await controller.load(fixture(43)) { _ in audio }
        XCTAssertNil(controller.nowPlayingInfo?[MPMediaItemPropertyArtwork])
    }
}
