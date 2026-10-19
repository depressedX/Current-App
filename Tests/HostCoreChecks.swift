import Foundation

final class MockHTTP: URLProtocol {
    static var response: [String: Any] = [:]
    static var headers: [String: String] = [:]
    static var delay: Double = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = try! JSONSerialization.data(withJSONObject: Self.response)
        let headers = Self.headers
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@main
struct HostCoreChecks {
    @MainActor static func main() async throws {
        let composed = QueueComposer.compose(catalog: DemoCatalog.tracks + DemoCatalog.tracks, limit: 4, excluding: [-1, -2])
        precondition(composed.count == 4 && Set(composed.map(\.id)).count == 4)
        precondition(!composed.contains { [-1, -2].contains($0.id) })
        precondition(QueueComposer.compose(catalog: [], limit: 4).isEmpty)
        precondition(QueueComposer.compose(catalog: DemoCatalog.tracks, limit: -1).isEmpty)
        let feedback = Feedback(trackID: 42, trackTitle: "Example", prompt: "阴郁摇滚", kind: .wrongMood, date: Date(), listenerID: 123)
        let decoded = try JSONDecoder().decode(Feedback.self, from: JSONEncoder().encode(feedback))
        precondition(decoded.kind == .wrongMood && decoded.prompt == feedback.prompt && decoded.listenerID == 123)
        for kind in FeedbackKind.allCases {
            let event = Feedback(trackID: 42, trackTitle: "Example", prompt: "阴郁摇滚", kind: kind, date: Date(), listenerID: 123)
            let saved = try JSONDecoder().decode(Feedback.self, from: JSONEncoder().encode(event))
            precondition(saved.id == event.id && saved.kind == kind && saved.listenerID == 123)
        }
        print("PASS queue bounds, exclusions, deduplication, feedback reason/account roundtrip")
        let track = NetEaseAPI.parseTracks([["id": 42, "name": "Test", "dt": 180000,
                                            "ar": [["name": "A"], ["name": "B"]], "al": ["name": "Album"]]]).first!
        precondition(track.duration == 180 && track.artist == "A / B" && !track.isDemo)
        print("PASS response mapping preserves milliseconds, artist names and real/demo identity")
        let encoded = String(decoding: NetEaseCrypto.form(["params": "a+b/c="]), as: UTF8.self)
        precondition(encoded.contains("%2B"))
        let crypto = try NetEaseCrypto.weapi(Data("{}".utf8))
        let repeatedCrypto = try NetEaseCrypto.weapi(Data("{}".utf8))
        precondition(crypto["encSecKey"]?.count == 256 && crypto == repeatedCrypto)
        print("PASS request encoding and deterministic encryption")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        let api = NetEaseAPI(ephemeral: true, configuration: config)
        MockHTTP.response = ["code": 803]
        MockHTTP.headers = ["Set-Cookie": "MUSIC_U=fixture-only; Path=/; Secure"]
        let status = try await api.qrCheck("fixture")
        precondition(status == 803 && api.hasCredentials)
        api.clear()
        precondition(!api.hasCredentials)
        print("PASS QR 803 accepts cookie; local logout clears authentication")
        MockHTTP.delay = 0.2
        let pending = Task { try await api.qrCheck("fixture") }
        try await Task.sleep(for: .milliseconds(50))
        api.clear()
        do { _ = try await pending.value; fatalError("stale response should be rejected") }
        catch is CancellationError {}
        precondition(!api.hasCredentials)
        print("PASS a late login response cannot restore credentials after logout")
        MockHTTP.delay = 0; MockHTTP.headers = [:]
        MockHTTP.response = ["code": 301]
        do { _ = try await api.profile(); fatalError("expired login must fail") }
        catch CurrentError.expired {}
        print("PASS login expiration is distinguished from other errors")
        MockHTTP.response = ["code": 200, "data": [["url": "http://example.com/audio.mp3", "freeTrialInfo": ["start": 0, "end": 30]]]]
        do { _ = try await api.playbackURL(id: 42); fatalError("trial must be rejected") }
        catch CurrentError.message(let reason) { precondition(reason.contains("试听")) }
        MockHTTP.response = ["code": 200, "data": [["url": "http://example.com/audio.mp3", "freeTrialInfo": NSNull()]]]
        let url = try await api.playbackURL(id: 42)
        precondition(url.scheme == "https")
        MockHTTP.response = ["code": 200, "data": [["url": NSNull()]]]
        do { _ = try await api.playbackURL(id: 42); fatalError("missing URL must fail") }
        catch CurrentError.message {}
        print("PASS trial-only/missing audio is rejected; valid HTTP audio is upgraded to HTTPS")
        if CommandLine.arguments.contains("--live") {
            let live = NetEaseAPI(ephemeral: true)
            let key = try await live.qrKey()
            precondition(!key.isEmpty)
            let code = try await live.qrCheck(key)
            precondition(code == 801)
            print("PASS live QR creation and waiting-for-scan status (no saved account accessed)")
        }
        print("ALL CORE CHECKS PASSED")
    }
}
