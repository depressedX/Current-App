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
        let ranked = (0..<29).map { index in
            Track(id: index, title: "Fixture", artist: "Fixture", album: "Fixture",
                  artwork: nil, duration: 24, demoIndex: 0)
        }
        let playlist = RecommendationPlaylist(candidates: ranked + ranked)
        precondition(playlist.tracks == ranked && playlist.tracks.count == 29)
        precondition(RecommendationPlaylist(candidates: []).tracks.isEmpty)
        precondition(RecommendationPlaylist(candidates: [ranked[0]]).tracks == [ranked[0]])
        let legacy = ListeningSession(prompt: "fixture", tracks: ranked, createdAt: Date(), listenerID: nil)
        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        legacyJSON.removeValue(forKey: "rankedCandidates")
        let oldSession = try JSONDecoder().decode(ListeningSession.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        precondition(oldSession.rankedCandidates == nil && oldSession.tracks == ranked)
        print("PASS full recommendation playlist, stable ordering, deduplication, empty/single results and legacy history")
        let track = NetEaseAPI.parseTracks([["id": 42, "name": "Test", "dt": 180000,
                                            "ar": [["name": "A"], ["name": "B"]], "al": ["name": "Album"]]]).first!
        precondition(track.duration == 180 && track.artist == "A / B" && !track.isDemo)
        precondition(NetEaseAPI.artworkURL("http://p1.music.126.net/cover.jpg?param=168y168")?.absoluteString == "https://p1.music.126.net/cover.jpg?param=168y168")
        precondition(NetEaseAPI.artworkURL(nil) == nil)
        precondition(NetEaseAPI.artworkURL("file:///tmp/cover.jpg") == nil)
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
        catch CurrentError.unavailable(.trialOnly) {}
        MockHTTP.response = ["code": 200, "data": [["url": "http://example.com/audio.mp3", "freeTrialInfo": NSNull()]]]
        let url = try await api.playbackURL(id: 42)
        precondition(url.scheme == "https")
        MockHTTP.response = ["code": 200, "data": [["url": NSNull()]]]
        do { _ = try await api.playbackURL(id: 42); fatalError("missing URL must fail") }
        catch CurrentError.unavailable(.noResource) {}
        print("PASS trial-only/missing audio is rejected; valid HTTP audio is upgraded to HTTPS")
        MockHTTP.response = ["code": 200, "data": [["code": 404, "url": NSNull()]]]
        do { _ = try await api.playbackURL(id: 42); fatalError("song-level 404 must be unavailable") }
        catch CurrentError.unavailable(.noResource) {}
        MockHTTP.response = ["code": 200, "data": [["code": 500, "url": NSNull()]]]
        do { _ = try await api.playbackURL(id: 42); fatalError("song-level service error must fail") }
        catch CurrentError.message {}
        MockHTTP.response = ["code": 200, "data": []]
        do { _ = try await api.playbackURL(id: 42); fatalError("malformed response must remain retryable") }
        catch CurrentError.message {}
        MockHTTP.response = ["code": 200, "data": [["url": "https://["]]]
        do { _ = try await api.playbackURL(id: 42); fatalError("invalid URL must remain retryable") }
        catch CurrentError.message {}
        MockHTTP.response = ["code": 404]
        do { _ = try await api.playbackURL(id: 42); fatalError("endpoint 404 must remain retryable") }
        catch CurrentError.message {}
        print("PASS unavailable songs and trial restrictions are distinct from malformed/service/endpoint errors")
        func wiki(_ text: String, kind: String = "bpm", title: String = "BPM") -> [String: Any] {
            ["code": 200, "data": ["blocks": [["creatives": [["creativeType": kind,
                "uiElement": ["mainTitle": ["title": title], "textLinks": [["text": text]]]]]]]]]
        }
        precondition(NetEaseAPI.parseWikiBPM(wiki("63")) == 63)
        precondition(NetEaseAPI.parseWikiBPM(wiki(" 127.5 BPM ")) == 127.5)
        precondition(NetEaseAPI.parseWikiBPM(wiki("63", kind: "other", title: "BPM")) == 63)
        for value in ["", "未知", "0", "2011", "NaN", "63 / 126", "https://example.com/63"] {
            precondition(NetEaseAPI.parseWikiBPM(wiki(value)) == nil)
        }
        precondition(NetEaseAPI.parseWikiBPM(wiki("63", kind: "year", title: "发行时间")) == nil)
        precondition(NetEaseAPI.parseWikiBPM(["code": 200, "data": ["blocks": []]]) == nil)
        MockHTTP.response = wiki("63")
        let wikiValue = try await api.songBPM(id: 42)
        precondition(wikiValue == 63)
        print("PASS wiki BPM parsing, bounds, missing/invalid fields and actual API wrapper mapping")
        if CommandLine.arguments.contains("--live-bpm") {
            let live = NetEaseAPI(ephemeral: true)
            let bpm = try await live.songBPM(id: 167727)
            precondition(bpm == 63)
            print("PASS live NetEase encyclopedia: 降温 (167727) BPM 63; anonymous session, no saved account accessed")
        }
        if CommandLine.arguments.contains("--live") {
            let live = NetEaseAPI(ephemeral: true)
            let key = try await live.qrKey()
            precondition(!key.isEmpty)
            let code = try await live.qrCheck(key)
            precondition(code == 801)
            print("PASS live QR creation and waiting-for-scan status (no saved account accessed)")
        }
        let fieldRows: [[String: Any]] = [
            ["creativeType": "songTag", "uiElement": ["mainTitle": ["title": "曲风"]],
             "resources": [["uiElement": ["mainTitle": ["title": "摇滚-后摇"]]],
                           ["valid": false, "uiElement": ["mainTitle": ["title": "无效标签"]]]]],
            ["creativeType": "instrument", "uiElement": ["mainTitle": ["title": "乐器"], "textLinks": [["text": "电吉他"], ["text": "电吉他"], ["text": "钢琴"]]]],
            ["creativeType": "bpm", "uiElement": ["mainTitle": ["title": "BPM"], "textLinks": [["text": "63"]]]],
            ["creativeType": "publishTime", "uiElement": ["mainTitle": ["title": "发行时间"], "textLinks": [["text": "2011-04-01"]]]],
            ["creativeType": "sheet", "uiElement": ["mainTitle": ["title": "乐谱"], "textLinks": [["text": "上传"]]]]
        ]
        let metadataBody: [String: Any] = ["data": ["blocks": [
            ["showType": "SONG_PLAY_ABOUT_TAB_SONG_BASIC", "creatives": fieldRows],
            ["showType": "PLAYLIST_MULTI_THREE_GRID", "creatives": [["creativeType": "songTag", "uiElement": ["mainTitle": ["title": "推荐歌单"], "textLinks": [["text": "不应录入"]]]]]]
        ]]]
        let snapshot = NetEaseAPI.parseSongWiki(metadataBody, songID: 42, fetchedAt: Date(timeIntervalSince1970: 100))
        precondition(snapshot.songID == 42 && snapshot.bpm == 63 && snapshot.fields.count == 4)
        precondition(snapshot.fields[0].values == ["摇滚-后摇"] && snapshot.fields[1].values == ["电吉他", "钢琴"])
        precondition(snapshot.fetchedAt == Date(timeIntervalSince1970: 100) && snapshot.source == "netease-song-wiki")
        let savedSnapshot = try JSONDecoder().decode(SongWikiMetadata.self, from: JSONEncoder().encode(snapshot))
        precondition(savedSnapshot == snapshot)
        MockHTTP.response = metadataBody
        let remoteSnapshot = try await api.songWiki(id: 42)
        precondition(remoteSnapshot.fields == snapshot.fields)
        print("PASS wiki resources/text links, deduplication, invalid/action/recommendation exclusion, snapshot persistence and API")
        MockHTTP.response = ["code": 200, "lrc": ["lyric": "[00:01]合成中文歌词"], "tlyric": ["lyric": "[00:01]合成译词"]]
        let lyrics = try await api.lyrics(id: 42)
        precondition(lyrics.songID == 42 && lyrics.original.contains("合成中文") && lyrics.translation.contains("合成译词"))
        MockHTTP.response = ["code": 200, "nolyric": true]
        let noLyrics = try await api.lyrics(id: 42)
        precondition(noLyrics.original.isEmpty && noLyrics.translation.isEmpty)
        print("PASS lyrics text/translation API mapping and explicit missing text")
        print("ALL CORE CHECKS PASSED")
    }
}
