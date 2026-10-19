import XCTest
@testable import Current

final class CurrentTests: XCTestCase {
    func testComposerRespectsLimitDeduplicatesAndExcludes() {
        let source = DemoCatalog.tracks + DemoCatalog.tracks
        let queue = QueueComposer.compose(catalog: source, limit: 4, excluding: [-1, -2])
        XCTAssertEqual(queue.count, 4)
        XCTAssertEqual(Set(queue.map(\.id)).count, 4)
        XCTAssertFalse(queue.contains { [-1, -2].contains($0.id) })
    }
    func testEmptyAndZeroLimitStayEmpty() {
        XCTAssertTrue(QueueComposer.compose(catalog: []).isEmpty)
        XCTAssertTrue(QueueComposer.compose(catalog: DemoCatalog.tracks, limit: 0).isEmpty)
    }
    func testFeedbackRetainsReasonAndScopeAcrossPersistence() throws {
        let feedback = Feedback(trackID: 42, trackTitle: "Test", prompt: "阴郁摇滚", kind: .wrongMood, date: Date(), listenerID: 123)
        let decoded = try JSONDecoder().decode(Feedback.self, from: JSONEncoder().encode(feedback))
        XCTAssertEqual(decoded.kind, .wrongMood)
        XCTAssertEqual(decoded.listenerID, 123)
        XCTAssertEqual(decoded.prompt, "阴郁摇滚")
    }
    @MainActor func testTrackResponseMapsDurationAndArtists() {
        let tracks = NetEaseAPI.parseTracks([["id": 42, "name": "Song", "dt": 180000,
                                             "ar": [["name": "A"], ["name": "B"]], "al": ["name": "Album"]]])
        XCTAssertEqual(tracks.first?.duration, 180)
        XCTAssertEqual(tracks.first?.artist, "A / B")
        XCTAssertFalse(tracks.first!.isDemo)
    }
    func testFormPreservesBase64Plus() {
        let text = String(decoding: NetEaseCrypto.form(["params": "a+b/c="]), as: UTF8.self)
        XCTAssertTrue(text.contains("%2B"))
    }
    func testProtocolEncryptionIsStableAndNonempty() throws {
        let payload = Data("{}".utf8)
        let encrypted = try NetEaseCrypto.weapi(payload)
        XCTAssertEqual(encrypted["encSecKey"]?.count, 256)
        XCTAssertEqual(encrypted, try NetEaseCrypto.weapi(payload))
        XCTAssertFalse(try NetEaseCrypto.eapi(path: "/test", payload: payload)["params"]!.isEmpty)
    }
}
