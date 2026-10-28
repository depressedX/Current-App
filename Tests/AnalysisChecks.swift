import Foundation
import AVFoundation
import Darwin

actor AnalysisProbe {
    var active = 0
    var maxActive = 0
    var calls = 0
    func run(_ url: URL) async throws -> AcousticFeatures {
        active += 1; calls += 1; maxActive = max(maxActive, active)
        defer { active -= 1 }
        // Simulates a decoder which needs time to drain even after cancellation.
        await Task.detached { try? await Task.sleep(for: .milliseconds(60)) }.value
        try Task.checkCancellation()
        return AcousticFeatures(bpm: 120, rhythmStrength: 0.8, rmsDBFS: -12, peakDBFS: -3,
                                dynamicSpreadDB: 4, zeroCrossingsPerSecond: 200,
                                sampleStart: 0, sampleDuration: 24, elapsedSeconds: 0.06)
    }
}

@main struct AnalysisChecks {
    @MainActor static func wait(_ check: () -> Bool) async throws {
        for _ in 0..<400 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Timed out waiting for analysis state")
    }
    static func fixture(_ url: URL, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        var offset = 0
        while offset < Int(seconds * format.sampleRate) {
            let frames = min(4096, Int(seconds * format.sampleRate) - offset)
            buffer.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames {
                let t = Double(offset + i) / format.sampleRate
                let phase = t.truncatingRemainder(dividingBy: 0.5)
                let value = Float(sin(2 * .pi * 440 * t) * (phase < 0.06 ? 0.8 * exp(-phase * 50) : 0.015))
                buffer.floatChannelData![0][i] = value; buffer.floatChannelData![1][i] = value
            }
            try file.write(from: buffer); offset += frames
        }
    }
    @MainActor static func conjunctiveChecks(in folder: URL, audio: URL) async throws {
        func axis(_ index: Int) -> [Float] {
            var vector = [Float](repeating: 0, count: SemanticSpace.dimensions); vector[index] = 1; return vector
        }
        let catalog = ConceptCatalog(schemaVersion: 1, spaceID: SemanticSpace.id, catalogVersion: SemanticSpace.catalogVersion,
            concepts: [ListeningConcept(id: "house", label: "House", definition: "House", vector: axis(0)),
                       ListeningConcept(id: "melancholic", label: "阴郁", definition: "伤感", vector: axis(1)),
                       ListeningConcept(id: "warm", label: "温暖", definition: "温暖", vector: axis(2)),
                       ListeningConcept(id: "energetic", label: "激烈", definition: "激烈", vector: axis(4))])
        let root = folder.appendingPathComponent("conjunctive")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let disk = SemanticDisk(directory: root.appendingPathComponent("SongAnalysis"))
        // BPM, sad similarity, warm similarity, House evidence, House semantic similarity.
        let fixtures: [(Double?, Float, Float, Bool, Float)] = [
            (120, 0.35, 0.1, true, 0.1), (110, 0.30, 0.35, true, 0.1), (130, 0.4, 0.2, true, 0.1),
            (120, 0.1, 0.1, true, 0.9), // Great House score cannot compensate for missing sadness.
            (120, 0.8, 0.1, false, 0.1), // Strong sadness cannot compensate for wrong genre.
            (140, 0.8, 0.1, true, 0.1), (nil, 0.8, 0.1, true, 0.1),
            (109, 0.8, 0.1, true, 0.1), (131, 0.8, 0.1, true, 0.1)
        ]
        var archive = PoolCatalog()
        for (i, fixture) in fixtures.enumerated() {
            let track = Track(id: 30000 + i, title: "Conjunctive fixture", artist: "Fixture", album: "Fixture",
                              artwork: nil, duration: 24, demoIndex: 0)
            _ = archive.enqueue([track], account: "a", source: "fixture")
            archive.songs[i].state = .completed
            if i == 4 {
                archive.songs[i].wikiMetadata = SongWikiMetadata(songID: track.id, fetchedAt: Date(), bpm: nil,
                    fields: [.init(kind: "songTag", title: "曲风", values: ["电子-House"]),
                             .init(kind: "songBizTag", title: "推荐标签", values: ["伤感"])])
            }
            if let bpm = fixture.0 { archive.songs[i].wikiBPM = WikiBPM(value: bpm, fetchedAt: Date()) }
            var vector = axis(3)
            vector[0] = fixture.4; vector[1] = fixture.1; vector[2] = fixture.2
            vector[3] = sqrt(1 - fixture.4 * fixture.4 - fixture.1 * fixture.1 - fixture.2 * fixture.2)
            archive.songs[i].semantic = try await disk.save(SemanticAnalysis(vector: vector, windowStarts: [0], elapsedSeconds: 0),
                songID: archive.songs[i].id, account: "a", catalog: catalog)
            archive.songs[i].genres = GenreAnalysis(matches: [GenreMatch(index: fixture.3 ? 91 : 125, family: "Electronic",
                style: fixture.3 ? "House" : "Synth-pop", score: 0.7)], windows: 10, duration: 20, analyzedAt: Date())
        }
        for (index, label) in [(0, "电子 - Synth-pop"), (1, "电子"), (5, "电子舞曲-House")] {
            archive.songs[index].wikiMetadata = SongWikiMetadata(songID: archive.songs[index].track.id, fetchedAt: Date(), bpm: nil,
                fields: [.init(kind: "songTag", title: "曲风", values: [label])])
        }
        let url = root.appendingPathComponent("pool.json")
        try JSONEncoder().encode(archive).write(to: url)
        let pool = SongPoolStore(fileURL: url, resolve: { _ in audio }, concepts: catalog)
        try await wait { !pool.loading }; pool.activate(account: "a")
        let required = RecommendationQuery(summary: "伤感的120 BPM左右的House", bpmMinimum: nil, bpmMaximum: nil,
            bpmRequired: true, preferences: [.init(concept: "house", direction: .prefer, weight: 1),
                                          .init(concept: "melancholic", direction: .prefer, weight: 0.1)], unsupported: [], bpmTarget: 120)
        let query = try required.validated(allowedConcepts: Set(catalog.concepts.map(\.id)))
        precondition(query.bpmMinimum == 110 && query.bpmMaximum == 130)
        let accepted = try await pool.recommendationQueue(query: required)
        precondition(Set(accepted.map(\.id)) == [30000, 30001, 30002])
        precondition(RecommendationPlaylist(candidates: accepted).tracks.count == 3)
        var warmer = required
        warmer = RecommendationQuery(summary: "also warm", bpmMinimum: nil, bpmMaximum: nil, bpmRequired: true,
            preferences: required.preferences + [.init(concept: "warm", direction: .prefer, weight: 0.1)], unsupported: [], bpmTarget: 120)
        let warmTracks = try await pool.recommendationQueue(query: warmer)
        precondition(warmTracks.map(\.id) == [30001])
        let optional = RecommendationQuery(summary: "House, preferably sad", bpmMinimum: nil, bpmMaximum: nil, bpmRequired: true,
            preferences: [.init(concept: "house", direction: .prefer, weight: 1),
                          .init(concept: "melancholic", direction: .prefer, weight: 1, requirement: .preferred)], unsupported: [], bpmTarget: 120)
        let optionalTracks = try await pool.recommendationQueue(query: optional)
        precondition(Set(optionalTracks.map(\.id)) == [30000, 30001, 30002, 30003])
        let empty = RecommendationQuery(summary: "energetic House", bpmMinimum: nil, bpmMaximum: nil, bpmRequired: true,
            preferences: required.preferences + [.init(concept: "energetic", direction: .prefer, weight: 1)], unsupported: [], bpmTarget: 120)
        do { _ = try await pool.recommendationQueue(query: empty); fatalError("semantic conditions relaxed") }
        catch is CurrentError {}
        precondition(pool.songs.allSatisfy { $0.semanticReady }) // Rejecting a condition is not a storage failure.
        let wikiID = GenreReference(source: .encyclopedia, value: "电子-House").id
        precondition(pool.intentConcepts.contains { $0.id == wikiID && $0.definition.contains("网易云百科") })
        precondition(pool.intentConcepts.contains { $0.id == "audioStyle:Electronic---House" })
        precondition(archive.songs[4].wikiGenreLabels == ["电子-House"])
        let union = RecommendationQuery(summary: "来源并集", bpmMinimum: nil, bpmMaximum: nil, bpmRequired: true,
            preferences: required.preferences + [.init(concept: wikiID, direction: .prefer, weight: 1)], unsupported: [], bpmTarget: 120)
        let unionTracks = try await pool.recommendationQueue(query: union)
        precondition(Set(unionTracks.map(\.id)) == [30000, 30001, 30002, 30004])
        let wikiOnly = RecommendationQuery(summary: "只选百科", bpmMinimum: nil, bpmMaximum: nil, bpmRequired: true,
            preferences: [.init(concept: wikiID, direction: .prefer, weight: 1), required.preferences[1]], unsupported: [], bpmTarget: 120)
        let wikiTracks = try await pool.recommendationQueue(query: wikiOnly)
        precondition(wikiTracks.map(\.id) == [30004])
        precondition(!archive.songs[4].matchesGenreFilters(audio: ["House"], encyclopedia: []))
        precondition(archive.songs[4].matchesGenreFilters(audio: ["House"], encyclopedia: ["电子-House"]))
        precondition(!archive.songs[0].matchesGenreFilters(audio: [], encyclopedia: ["电子-House"]))
        precondition(archive.songs[0].matchesGenreFilters(audio: ["House"], encyclopedia: ["电子-House"]))
        precondition(archive.songs[0].matchesGenreFilters(audio: [], encyclopedia: []))
        let excluding = RecommendationQuery(summary: "排除并集", bpmMinimum: nil, bpmMaximum: nil, bpmRequired: false,
            preferences: [.init(concept: "house", direction: .avoid, weight: 1),
                          .init(concept: wikiID, direction: .avoid, weight: 1)], unsupported: [])
        precondition(!excluding.matchesGenres(archive.songs[4].genres, wiki: archive.songs[4].wikiGenreLabels))
        precondition(!excluding.matchesGenres(archive.songs[0].genres, wiki: []))
        let familyID = GenreReference(source: .encyclopediaFamily, value: "电子").id
        precondition(pool.intentConcepts.contains { $0.id == familyID })
        precondition(WikiGenre(" 嘻哈说唱 - 情绪说唱 ").family == "嘻哈说唱")
        precondition(WikiGenre("电子 - Synth-pop").style == "Synth-pop")
        precondition(WikiGenre("慢摇DJ").style == nil)
        precondition(WikiGenre.matches("电子", labels: ["电子", "电子-House"]))
        precondition(!WikiGenre.matches("电子", labels: ["电子舞曲-House"]))
        precondition(!WikiGenre.matches("电子-House", labels: ["电子", "电子-Synth-pop"]))
        precondition(WikiGenre.matches("电子 - Synth-pop", labels: ["电子-Synth-pop"]))
        precondition(archive.songs[0].matchesGenreFilters(audio: [], encyclopedia: ["电子"]))
        precondition(archive.songs[1].matchesGenreFilters(audio: [], encyclopedia: ["电子"]))
        precondition(!archive.songs[5].matchesGenreFilters(audio: [], encyclopedia: ["电子"]))
        let groups = GenreChoiceGroup.encyclopedia(["电子 - Synth-pop", "电子-House", "电子", "摇滚"])
        precondition(groups.count == 2 && groups.first { $0.id == "电子" }?.children.count == 2)
        precondition(groups.first { $0.id == "摇滚" }?.children.isEmpty == true)
        let modelQuery = RecommendationQuery(summary: "电子但不要House，伤感，120 BPM左右", bpmMinimum: nil, bpmMaximum: nil,
            bpmRequired: true, preferences: [.init(concept: familyID, direction: .prefer, weight: 1),
                .init(concept: wikiID, direction: .avoid, weight: 1), required.preferences[1]], unsupported: [], bpmTarget: 120)
        precondition(modelQuery.preferences.contains { $0.concept == "melancholic" })
        precondition(!modelQuery.preferences.contains { $0.concept == "house" })
        precondition(modelQuery.bpmTarget == 120 && modelQuery.bpmRequired)
        let familyTracks = try await pool.recommendationQueue(query: modelQuery)
        precondition(Set(familyTracks.map(\.id)) == [30000, 30001])
        let decodedQuery = try JSONDecoder().decode(RecommendationQuery.self, from: JSONEncoder().encode(modelQuery))
        precondition(decodedQuery.displaySummary(concepts: pool.intentConcepts).contains("百科：电子"))
        let optionalGenre = RecommendationQuery(summary: "优先电子，减少House", bpmMinimum: nil, bpmMaximum: nil,
            bpmRequired: true, preferences: [.init(concept: familyID, direction: .prefer, weight: 1, requirement: .preferred),
                .init(concept: wikiID, direction: .avoid, weight: 1, requirement: .preferred), required.preferences[1]], unsupported: [], bpmTarget: 120)
        precondition(optionalGenre.preferences.filter(\.isGenre).allSatisfy { $0.requirement == .preferred })
        let optionalGenreTracks = try await pool.recommendationQueue(query: optionalGenre)
        precondition(Set(optionalGenreTracks.map(\.id)) == [30000, 30001, 30002, 30004])
        print("PASS hierarchical genres: first separator, parent/child boundaries, bare parent, shared filter semantics, include parent/exclude child, optional ranking and saved query")
        print("PASS independent audio/wiki genre sources: OR retrieval and manual filters, encyclopedia-only evidence, negative union, full-vector mood/BPM intersection, source vocabularies and non-genre metadata isolation")
        let boundary = RecommendationQuery.Preference(concept: "melancholic", direction: .prefer, weight: 1)
        precondition(boundary.accepts(similarity: 0.25) && !boundary.accepts(similarity: 0.249))
        precondition(!boundary.accepts(similarity: .nan))
        let avoid = RecommendationQuery.Preference(concept: "melancholic", direction: .avoid, weight: 1)
        precondition(avoid.accepts(similarity: 0.249) && !avoid.accepts(similarity: 0.25))
        print("PASS conjunctive retrieval: House AND 110–130 BPM AND sad threshold; no cross-condition compensation, optional ranking, multiple required moods, empty results and boundary handling")

        if let path = ProcessInfo.processInfo.environment["CURRENT_QUERY_POOL"],
           let conceptPath = ProcessInfo.processInfo.environment["CURRENT_QUERY_CONCEPTS"] {
            let device = try JSONDecoder().decode(PoolCatalog.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let concepts = try ConceptCatalog.load(url: URL(fileURLWithPath: conceptPath))
            let devicePool = SongPoolStore(fileURL: URL(fileURLWithPath: path), resolve: { _ in audio }, concepts: concepts)
            try await wait { !devicePool.loading }
            if let account = device.songs.first?.account { devicePool.activate(account: account) }
            do {
                let tracks = try await devicePool.recommendationQueue(query: required)
                print("DEVICE SNAPSHOT House AND 110–130 BPM AND sad:", tracks.count)
            } catch is CurrentError { print("DEVICE SNAPSHOT House AND 110–130 BPM AND sad: 0 (no relaxation)") }
        }
    }
    static func compressedDownloadCheck(in folder: URL) async throws {
        let input = folder.appendingPathComponent("compressed-input.wav")
        let aac = folder.appendingPathComponent("compressed.m4a")
        try fixture(input, seconds: 12)
        guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: input), presetName: AVAssetExportPresetAppleM4A) else {
            fatalError("AAC exporter unavailable")
        }
        try await exporter.export(to: aac, as: .m4a)
        let misleading = folder.appendingPathComponent("wrong.audio")
        try FileManager.default.copyItem(at: aac, to: misleading)
        let response = URLResponse(url: URL(string: "https://example.invalid/stream?token=secret")!,
                                   mimeType: "application/octet-stream", expectedContentLength: -1, textEncodingName: nil)
        let ext = try AnalysisAudioDownloader.audioExtension(file: misleading, response: response)
        precondition(ext == "m4a")
        let corrected = folder.appendingPathComponent("corrected.\(ext)")
        try FileManager.default.moveItem(at: misleading, to: corrected)
        let features = try await NativeSongAnalyzer.analyze(url: corrected)
        precondition(features.sampleDuration > 11)
        let html = folder.appendingPathComponent("error.mp3")
        try Data("<html>access denied</html>".utf8).write(to: html)
        do { _ = try AnalysisAudioDownloader.audioExtension(file: html, response: response); fatalError("HTML accepted") }
        catch AnalysisError.invalidAudioResponse {}
        print("PASS AAC container detection ignores misleading suffix/MIME; corrected file decodes; HTML rejected")

        guard CommandLine.arguments.contains("--download") else { return }
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        python.arguments = ["python3", "-u", "-c", """
        import http.server,sys,pathlib
        payload=pathlib.Path(sys.argv[1]).read_bytes()
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                if self.path.startswith('/denied'):
                    self.send_response(403); self.end_headers(); return
                body=b'<html>access denied</html>' if self.path.startswith('/html') else payload
                self.send_response(200)
                self.send_header('Content-Type','application/octet-stream')
                self.send_header('Content-Length',str(len(body)))
                self.end_headers(); self.wfile.write(body)
        server=http.server.HTTPServer(('127.0.0.1',0),Handler)
        print(server.server_port,flush=True)
        server.serve_forever()
        """, aac.path]
        let pipe = Pipe(); python.standardOutput = pipe
        try python.run()
        defer { python.terminate(); python.waitUntilExit() }
        var portData = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 10 { break }; portData.append(byte)
        }
        let port = String(decoding: portData, as: UTF8.self)
        guard Int(port) != nil else { fatalError("Local fixture server failed") }
        let local = try await AnalysisAudioDownloader.fetch(URL(string: "http://127.0.0.1:\(port)/stream?token=secret")!)
        defer { try? FileManager.default.removeItem(at: local) }
        precondition(local.pathExtension == "m4a")
        let downloaded = try await NativeSongAnalyzer.analyze(url: local)
        precondition(downloaded.sampleDuration > 11)
        do {
            _ = try await AnalysisAudioDownloader.fetch(URL(string: "http://127.0.0.1:\(port)/denied")!)
            fatalError("HTTP 403 accepted")
        } catch AnalysisError.downloadHTTP(let code) { precondition(code == 403) }
        do {
            _ = try await AnalysisAudioDownloader.fetch(URL(string: "http://127.0.0.1:\(port)/html")!)
            fatalError("HTTP HTML accepted")
        } catch AnalysisError.invalidAudioResponse {}
        print("PASS real HTTP download → format preservation → AAC decode; HTTP 403 and HTML classified")
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("current-analysis-check-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await compressedDownloadCheck(in: folder)
        let timeout = SongPoolStore.safeMessage(URLError(.timedOut), stage: .fetching)
        precondition(timeout.contains("超时"))
        let privateError = NSError(domain: "AVFoundationErrorDomain", code: -11828,
                                   userInfo: [NSLocalizedDescriptionKey: "https://example.invalid?secret=credential"])
        let safe = SongPoolStore.safeMessage(privateError, stage: .analyzing)
        precondition(safe.contains("解码") && safe.contains("-11828") && !safe.contains("secret"))
        print("PASS error messages distinguish stage/code without leaking signed URL")
        var catalog = PoolCatalog()
        precondition(catalog.enqueue(DemoCatalog.tracks, account: "a", source: "first") == 8)
        precondition(catalog.enqueue(DemoCatalog.tracks, account: "a", source: "second") == 0)
        precondition(catalog.songs[0].sources == ["first", "second"])
        precondition(catalog.enqueue([DemoCatalog.tracks[0]], account: "b", source: "other") == 1)
        catalog.songs[0].state = .analyzing
        let data = try JSONEncoder().encode(catalog)
        var recovered = try JSONDecoder().decode(PoolCatalog.self, from: data)
        recovered.recoverInterrupted()
        precondition(recovered.songs[0].state == .queued && recovered.songs.count == 9)
        precondition(recovered.songs.allSatisfy { !$0.semanticReady })
        print("PASS deduplication, multiple sources, account separation, interrupted recovery, semantic readiness")

        for bpm in [90.0, 120.0, 128.0] {
            let rate = 100.0
            let envelope = (0..<4500).map { i -> Double in
                let phase = (Double(i) / rate).truncatingRemainder(dividingBy: 60 / bpm)
                return phase < 0.04 ? exp(-phase * 50) : 0
            }
            let estimated = AcousticDSP.tempo(envelope: envelope, rate: rate).0!
            precondition(abs(estimated - bpm) < 2, "Synthetic BPM \(bpm): \(estimated)")
        }
        var silence = AcousticDSP()
        [Float](repeating: 0, count: 110_250).withUnsafeBufferPointer { silence.append($0) }
        do { _ = try silence.result(start: 0, elapsed: 0); fatalError("silence accepted") } catch AnalysisError.silent {}
        print("PASS synthetic tempo 90/120/128, silence rejection")

        let wav = folder.appendingPathComponent("long.wav")
        try fixture(wav, seconds: 180)
        var usageBefore = rusage()
        getrusage(RUSAGE_SELF, &usageBefore)
        let begin = Date()
        let features = try await NativeSongAnalyzer.analyze(url: wav)
        print("PROFILE", String(data: try JSONEncoder().encode(features.profile), encoding: .utf8)!)
        precondition(features.profile?.duration ?? 0 > 179)
        precondition(features.sampleDuration <= 45.01 && features.sampleDuration > 44)
        precondition(features.sampleStart > 60 && features.rmsDBFS.isFinite && features.dynamicSpreadDB.isFinite)
        precondition(features.bpm != nil && abs(features.bpm! - 120) < 2)
        print(String(format: "PASS real AVFoundation 180s stereo WAV → %.1fs bounded mono analysis; %.3fs wall; %.1f BPM",
                     features.sampleDuration, Date().timeIntervalSince(begin), features.bpm!))

        var usageAfter = rusage()
        getrusage(RUSAGE_SELF, &usageAfter)
        print(String(format: "HOST benchmark high-water RSS: %.1f MiB before / %.1f MiB after (not iPhone)",
                     Double(usageBefore.ru_maxrss) / 1_048_576, Double(usageAfter.ru_maxrss) / 1_048_576))
        let probe = AnalysisProbe()
        let archive = folder.appendingPathComponent("pool.json")
        let pool = SongPoolStore(fileURL: archive, resolve: { _ in wav }, analyze: { try await probe.run($0) })
        try await wait { !pool.loading }
        pool.activate(account: "a"); pool.setForeground(true)
        pool.enqueue(Array(DemoCatalog.tracks.prefix(3)), source: "test")
        precondition(pool.paused)
        pool.resume()
        try await wait { pool.songs.contains { $0.state == .analyzing } }
        pool.pause(); pool.resume()
        try await wait { pool.completedCount == 3 }
        let maximum = await probe.maxActive
        precondition(maximum == 1)
        print("PASS serial worker and rapid pause/resume never overlap")

        pool.enqueue([DemoCatalog.tracks[3]], source: "test")
        try await Task.sleep(for: .milliseconds(100))
        precondition(pool.completedCount == 3 && pool.songs.last?.state == .queued)
        pool.resume()
        print("PASS newly added songs wait for an explicit local submission")
        try await wait { pool.songs.contains { $0.state == .analyzing } }
        pool.setPlaybackBusy(true)
        try await Task.sleep(for: .milliseconds(100))
        precondition(pool.completedCount == 3 && pool.waitReason != nil)
        pool.setPlaybackBusy(false)
        try await wait { pool.completedCount == 4 }
        pool.enqueue([DemoCatalog.tracks[4]], source: "test"); pool.resume()
        try await wait { pool.songs.contains { $0.state == .analyzing } }
        pool.setForeground(false)
        try await Task.sleep(for: .milliseconds(100))
        precondition(pool.completedCount == 4)
        pool.setForeground(true)
        try await wait { pool.completedCount == 5 }
        print("PASS playback and background preempt analysis and resume remaining work")

        pool.enqueue([DemoCatalog.tracks[5]], source: "test"); pool.resume()
        try await wait { pool.songs.contains { $0.state == .analyzing } }
        pool.activate(account: "b")
        pool.enqueue([DemoCatalog.tracks[0]], source: "b"); pool.resume()
        try await wait { pool.completedCount == 1 }
        precondition(pool.songs.count == 1 && pool.songs[0].account == "b")
        pool.activate(account: "a")
        precondition(pool.songs.first { $0.track.id == DemoCatalog.tracks[5].id }?.state == .queued)
        print("PASS account switch discards stale completion and preserves separate queues")

        pool.resume()
        try await wait { pool.completedCount == 6 }
        pool.enqueue([DemoCatalog.tracks[6]], source: "remove"); pool.resume()
        try await wait { pool.songs.contains { $0.state == .analyzing } }
        let removed = pool.songs.first { $0.track.id == DemoCatalog.tracks[6].id }!.id
        pool.remove(removed)
        try await Task.sleep(for: .milliseconds(100))
        precondition(!pool.songs.contains { $0.id == removed })
        let finalMaximum = await probe.maxActive
        precondition(finalMaximum == 1)
        try await Task.sleep(for: .milliseconds(100))
        let disk = try JSONDecoder().decode(PoolCatalog.self, from: Data(contentsOf: archive))
        precondition(!disk.songs.contains { $0.id == removed })
        print("PASS removal during work never resurrects the song; archive retains results")
        let failures = SongPoolStore(fileURL: folder.appendingPathComponent("failure.json"),
                                     resolve: { track in
                                         if track.id == DemoCatalog.tracks[0].id { throw AnalysisError.noAudio }
                                         return wav
                                     }, analyze: { try await probe.run($0) })
        try await wait { !failures.loading }
        failures.activate(account: "a"); failures.setForeground(true)
        failures.enqueue(Array(DemoCatalog.tracks.prefix(2)), source: "failure test"); failures.resume()
        try await wait { failures.completedCount == 1 && failures.songs.contains { $0.state == .failed } }
        let failedID = failures.songs.first { $0.state == .failed }!.id
        failures.pause(); failures.retry(failedID)
        precondition(failures.songs.first { $0.id == failedID }?.state == .queued)
        print("PASS failure does not block next song; retry preserves explicit paused state")

        var unavailableAttempts = 0
        let unavailableURL = folder.appendingPathComponent("unavailable.json")
        let unavailablePool = SongPoolStore(fileURL: unavailableURL, resolve: { _ in
            unavailableAttempts += 1
            throw CurrentError.unavailable(.noResource)
        }, analyze: { try await probe.run($0) })
        try await wait { !unavailablePool.loading }
        unavailablePool.activate(account: "a"); unavailablePool.setForeground(true)
        unavailablePool.enqueue([DemoCatalog.tracks[0]], source: "fixture"); unavailablePool.resume()
        try await wait { unavailablePool.unavailableCount == 1 }
        precondition(unavailablePool.pendingCount == 0 && unavailableAttempts == 1)
        let unavailableID = unavailablePool.songs[0].id
        unavailablePool.retryFailed(); unavailablePool.retry(unavailableID); unavailablePool.reanalyze(unavailableID)
        unavailablePool.reserveCompanion([unavailableID])
        unavailablePool.enqueue([DemoCatalog.tracks[0]], source: "another import"); unavailablePool.resume()
        try await Task.sleep(for: .milliseconds(50))
        precondition(unavailablePool.songs[0].state == .unavailable && unavailableAttempts == 1)
        precondition(unavailablePool.songs[0].remotePending != true && !unavailablePool.songs[0].semanticReady)
        try await Task.sleep(for: .milliseconds(50))
        let unavailableReload = SongPoolStore(fileURL: unavailableURL, resolve: { _ in wav })
        try await wait { !unavailableReload.loading }
        unavailableReload.activate(account: "a")
        precondition(unavailableReload.unavailableCount == 1 && unavailableReload.pendingCount == 0)
        precondition(unavailableReload.songs[0].unavailability == .noResource)
        print("PASS unavailable songs persist, leave pending work, and cannot be revived by retry/reimport/remote submission")

        let realTrack = Track(id: 167727, title: "Fixture", artist: "Test", album: "", artwork: nil, duration: 24, demoIndex: nil)
        var order: [String] = []
        let wikiPool = SongPoolStore(fileURL: folder.appendingPathComponent("wiki-priority.json"),
                                    resolve: { _ in order.append("audio"); return wav },
                                    fetchBPM: { _ in order.append("wiki"); return 63 },
                                    analyze: { try await probe.run($0) })
        try await wait { !wikiPool.loading }
        wikiPool.activate(account: "a"); wikiPool.setForeground(true)
        wikiPool.enqueue([realTrack], source: "test"); wikiPool.resume()
        try await wait { wikiPool.completedCount == 1 }
        let wikiSong = wikiPool.songs[0]
        precondition(order == ["wiki", "audio"] && wikiSong.resolvedBPM == 63)
        precondition(wikiSong.features?.bpm == 120 && wikiSong.bpmSource == .neteaseWiki)
        print("PASS wiki lookup precedes audio; remote BPM wins while local estimate is preserved")

        for unavailable in [false, true] {
            let fallback = SongPoolStore(fileURL: folder.appendingPathComponent("fallback-\(unavailable).json"),
                                         resolve: { _ in wav }, fetchBPM: { _ in
                                             if unavailable { throw URLError(.notConnectedToInternet) }; return nil
                                         }, analyze: { try await probe.run($0) })
            try await wait { !fallback.loading }
            fallback.activate(account: "a"); fallback.setForeground(true)
            fallback.enqueue([realTrack], source: "test"); fallback.resume()
            try await wait { fallback.completedCount == 1 }
            precondition(fallback.songs[0].resolvedBPM == 120 && fallback.songs[0].bpmSource == .localAnalysis)
            precondition(fallback.songs[0].bpmLookup == (unavailable ? .failed : .missing))
        }
        print("PASS missing wiki BPM or network failure falls back to local analysis without failing the job")

        var legacy = PoolCatalog()
        legacy.enqueue([realTrack], account: "a", source: "legacy")
        legacy.songs[0].state = .completed
        legacy.songs[0].features = AcousticFeatures(bpm: nil, rhythmStrength: 0.65, rmsDBFS: -10,
            peakDBFS: -1, dynamicSpreadDB: 8, zeroCrossingsPerSecond: 1400,
            sampleStart: 0, sampleDuration: 24, elapsedSeconds: 0.1)
        let legacyURL = folder.appendingPathComponent("legacy.json")
        try JSONEncoder().encode(legacy).write(to: legacyURL)
        var downloads = 0
        let backfill = SongPoolStore(fileURL: legacyURL, resolve: { _ in downloads += 1; return wav },
                                    fetchBPM: { _ in 63 }, analyze: { try await probe.run($0) })
        try await wait { !backfill.loading }
        backfill.activate(account: "a"); backfill.setForeground(true)
        precondition(backfill.songs[0].resolvedBPM == nil)
        backfill.backfillBPM(backfill.songs[0].id)
        try await wait { backfill.completedCount == 1 && backfill.songs[0].wikiBPM != nil }
        precondition(downloads == 0 && backfill.songs[0].resolvedBPM == 63 && backfill.songs[0].features?.rhythmStrength == 0.65)
        print("PASS old archive remains readable; metadata-only backfill resolves unknown BPM without audio download")

        let reanalysisURL = folder.appendingPathComponent("reanalysis.json")
        var previous = legacy
        previous.songs[0].wikiBPM = WikiBPM(value: 63, fetchedAt: Date())
        previous.songs[0].bpmLookup = .available
        try JSONEncoder().encode(previous).write(to: reanalysisURL)
        var nextWiki = 88.0, failAudio = false, audioRuns = 0, metadataRuns = 0
        let rerun = SongPoolStore(fileURL: reanalysisURL, resolve: { _ in
            audioRuns += 1
            if failAudio { throw AnalysisError.download }
            return wav
        }, fetchBPM: { _ in metadataRuns += 1; return nextWiki }, analyze: { try await probe.run($0) })
        try await wait { !rerun.loading }
        rerun.activate(account: "a"); rerun.setForeground(true)
        let rerunID = rerun.songs[0].id
        rerun.reanalyze(rerunID); rerun.reanalyze(rerunID)
        precondition(rerun.songs[0].resolvedBPM == 63)
        try await wait { rerun.completedCount == 1 && rerun.songs[0].needsReanalysis != true }
        precondition(audioRuns == 1 && metadataRuns == 1 && rerun.songs[0].resolvedBPM == 88)
        precondition(rerun.songs[0].features?.bpm == 120)
        print("PASS reanalysis bypasses cached wiki and audio, ignores duplicate taps, replaces results only on success")

        let lastGood = rerun.songs[0].features
        let lastFinished = rerun.songs[0].finishedAt
        nextWiki = 99; failAudio = true
        rerun.reanalyze(rerunID)
        try await wait { rerun.songs[0].state == .failed }
        precondition(rerun.songs[0].resolvedBPM == 88 && rerun.songs[0].features == lastGood)
        precondition(rerun.songs[0].finishedAt == lastFinished && rerun.songs[0].needsReanalysis == true)
        failAudio = false; nextWiki = 100
        rerun.retry(rerunID)
        try await wait { rerun.completedCount == 1 && rerun.songs[0].needsReanalysis != true }
        precondition(rerun.songs[0].resolvedBPM == 100 && audioRuns == 3)
        print("PASS failed reanalysis retains previous BPM/features/date; retry still performs full analysis")

        rerun.reanalyze(rerunID); rerun.pause()
        try await Task.sleep(for: .milliseconds(150))
        let pausedSnapshot = try JSONDecoder().decode(PoolCatalog.self, from: Data(contentsOf: reanalysisURL))
        precondition(pausedSnapshot.songs[0].needsReanalysis == true && pausedSnapshot.songs[0].features != nil)
        rerun.resume()
        try await wait { rerun.completedCount == 1 && rerun.songs[0].needsReanalysis != true }
        print("PASS paused reanalysis persists its full-run mode and resumes without losing previous results")

        let unitVector: [Float] = [1] + Array(repeating: 0, count: 511)
        let concepts = ConceptCatalog(schemaVersion: 1, spaceID: SemanticSpace.id, catalogVersion: SemanticSpace.catalogVersion,
                                      concepts: [ListeningConcept(id: "test", label: "测试", definition: "fixture", vector: unitVector)])
        var failSemantic = false
        let semanticURL = folder.appendingPathComponent("semantic-pool.json")
        try JSONEncoder().encode(previous).write(to: semanticURL)
        let hearing = SongPoolStore(fileURL: semanticURL, resolve: { _ in wav },
                                    semanticAnalyze: { _ in
                                        if await MainActor.run(body: { failSemantic }) { throw SemanticError.inference }
                                        return SemanticAnalysis(vector: unitVector, windowStarts: [0, 5, 10], elapsedSeconds: 0.1)
                                    }, concepts: concepts, analyze: { try await probe.run($0) })
        try await wait { !hearing.loading }
        hearing.activate(account: "a"); hearing.setForeground(true)
        precondition(!hearing.songs[0].semanticReady)
        hearing.analyzeHearing()
        try await wait { hearing.songs[0].semanticReady }
        let matched = try await hearing.mockSemanticQueue(text: "text is intentionally ignored")
        precondition(matched.tracks.map(\.id) == [realTrack.id] && matched.anchor == "测试")
        let previousSemantic = hearing.songs[0].semantic!.recordID
        failSemantic = true
        hearing.reanalyze(hearing.songs[0].id)
        try await wait { hearing.songs[0].state == .failed }
        precondition(hearing.songs[0].semantic?.recordID == previousSemantic && !hearing.songs[0].semanticReady)
        do { _ = try await hearing.mockSemanticQueue(text: "ignored"); fatalError("Failed job entered recommendations") }
        catch is CurrentError {}
        failSemantic = false; hearing.retry(hearing.songs[0].id)
        try await wait { hearing.songs[0].semanticReady }
        precondition(hearing.songs[0].semantic?.recordID != previousSemantic)
        let damagedRecord = folder.appendingPathComponent("SongAnalysis").appendingPathComponent(hearing.songs[0].semantic!.recordID.uuidString).appendingPathExtension("json")
        try Data("broken".utf8).write(to: damagedRecord)
        do { _ = try await hearing.mockSemanticQueue(text: "ignored"); fatalError("Corrupt recommendation accepted") }
        catch SemanticError.storage {}
        precondition(hearing.songs[0].state == .failed && hearing.songs[0].needsReanalysis == true)
        hearing.activate(account: "b")
        do { _ = try await hearing.mockSemanticQueue(text: "ignored"); fatalError("Cross-account recommendations") }
        catch is CurrentError {}
        print("PASS semantic upgrade, real vector ranking, failed reanalysis preserves record, scope excludes other accounts")

        hearing.activate(account: "a")
        hearing.markUnavailable(trackID: realTrack.id, reason: .noResource)
        precondition(hearing.songs[0].semantic != nil && !hearing.songs[0].semanticReady)
        do { _ = try await hearing.mockSemanticQueue(text: "fixture"); fatalError("unavailable song with old vectors entered ranking") }
        catch is CurrentError {}
        let unavailableQuery = RecommendationQuery(summary: "fixture", bpmMinimum: nil, bpmMaximum: nil, bpmRequired: false,
            preferences: [.init(concept: "test", direction: .prefer, weight: 1)], unsupported: [])
        do { _ = try await hearing.recommendationQueue(query: unavailableQuery); fatalError("unavailable song entered production generation") }
        catch is CurrentError {}
        hearing.activate(account: "b")
        precondition(hearing.isAvailable(realTrack))
        print("PASS old acoustic/vector results cannot make unavailable songs eligible for recommendation; availability is account scoped")

        let batchFolder = folder.appendingPathComponent("recommendation-ranking")
        try FileManager.default.createDirectory(at: batchFolder, withIntermediateDirectories: true)
        let batchURL = batchFolder.appendingPathComponent("pool.json")
        let batchDisk = SemanticDisk(directory: batchFolder.appendingPathComponent("SongAnalysis"))
        let batchTracks = (0..<29).map { Track(id: 10000 + $0, title: "Ranking fixture", artist: "Fixture",
                                              album: "Fixture", artwork: nil, duration: 24, demoIndex: 0) }
        var batchCatalog = PoolCatalog()
        _ = batchCatalog.enqueue(batchTracks, account: "a", source: "fixture")
        for index in batchCatalog.songs.indices {
            batchCatalog.songs[index].state = .completed
            if index < 28 {
                batchCatalog.songs[index].wikiBPM = WikiBPM(value: index == 0 ? 99 : index == 1 ? 100 : index == 2 ? 120 : 121, fetchedAt: Date())
            }
            batchCatalog.songs[index].semantic = try await batchDisk.save(
                SemanticAnalysis(vector: unitVector, windowStarts: [0], elapsedSeconds: 0),
                songID: batchCatalog.songs[index].id, account: "a", catalog: concepts)
        }
        try JSONEncoder().encode(batchCatalog).write(to: batchURL)
        let rankingPool = SongPoolStore(fileURL: batchURL, resolve: { _ in wav }, concepts: concepts)
        try await wait { !rankingPool.loading }
        rankingPool.activate(account: "a")
        let firstBatch = try await rankingPool.mockSemanticQueue(text: "fixture")
        let fullRanking = try await rankingPool.mockSemanticQueue(text: "fixture", limit: nil)
        precondition(firstBatch.tracks == Array(batchTracks.prefix(12)))
        precondition(fullRanking.tracks == batchTracks && fullRanking.anchor == firstBatch.anchor)
        let bounded = RecommendationQuery(summary: "100–120 BPM", bpmMinimum: 100, bpmMaximum: 120, bpmRequired: true,
                                          preferences: [.init(concept: "test", direction: .prefer, weight: 1)], unsupported: [])
        let boundedTracks = try await rankingPool.recommendationQueue(query: bounded)
        precondition(boundedTracks == Array(batchTracks[1...2]))
        let preferred = RecommendationQuery(summary: "最好 100–120 BPM", bpmMinimum: 100, bpmMaximum: 120, bpmRequired: false,
                                            preferences: [.init(concept: "test", direction: .prefer, weight: 1)], unsupported: [])
        let preferredTracks = try await rankingPool.recommendationQueue(query: preferred)
        precondition(preferredTracks.count == 29 && Array(preferredTracks.prefix(2)) == Array(batchTracks[1...2]))
        let target = RecommendationQuery(summary: "约100 BPM", bpmMinimum: nil, bpmMaximum: nil, bpmRequired: false,
                                         preferences: [.init(concept: "test", direction: .prefer, weight: 1)], unsupported: [], bpmTarget: 100)
        let targetTracks = try await rankingPool.recommendationQueue(query: target)
        precondition(Array(targetTracks.prefix(3)) == [batchTracks[1], batchTracks[0], batchTracks[2]])
        precondition(targetTracks.last == batchTracks[28])
        print("PASS real query ranking: inclusive BPM bounds, unknown/outside exclusion and soft BPM preference")
        print("PASS recommendation ranking returns all 29 candidates for continuation; default batch remains 12")

        // Reproduce the reported false positives with real classifier scores. Make their semantic
        // scores higher than the genuine candidates so only the production genre gate can reject them.
        let genreFolder = folder.appendingPathComponent("genre-ranking")
        try FileManager.default.createDirectory(at: genreFolder, withIntermediateDirectories: true)
        let genreCatalog = ConceptCatalog(schemaVersion: 1, spaceID: SemanticSpace.id,
            catalogVersion: SemanticSpace.catalogVersion,
            concepts: [ListeningConcept(id: "house", label: "House", definition: "House", vector: unitVector),
                       ListeningConcept(id: "energetic", label: "激烈", definition: "推进感", vector: unitVector)])
        let genreFixtures: [(String, [(String, Double)])] = [
            ("我恨冬天", [("Downtempo", 0.115653), ("Deep House", 0.109366)]),
            ("Bizarre Love Triangle", [("Synth-pop", 0.304560), ("Italo-Disco", 0.224094)]),
            ("你少在那边", [("Synth-pop", 0.432822), ("Electro", 0.112513)]),
            ("霓虹甜心", [("Synth-pop", 0.247138), ("House", 0.084892)]),
            ("Lover (Gerd Janson Remix)", [("Nu-Disco", 0.275894), ("House", 0.224978), ("Deep House", 0.203647)]),
            ("Choreography (Extended Mix)", [("Deep House", 0.331612), ("House", 0.272264)]),
            ("A LITTLE BIT FUNKIER (Extended Mix)", [("House", 0.283693), ("Techno", 0.234468)]),
            ("Disco dominates", [("Disco", 0.513826), ("House", 0.317281)]),
            ("Low evidence", [("House", 0.12), ("Deep House", 0.11), ("Tech House", 0.10)]),
            ("Missing analysis", []), ("Stale analysis", [("House", 0.8)])
        ]
        var genrePoolCatalog = PoolCatalog()
        let genreDisk = SemanticDisk(directory: genreFolder.appendingPathComponent("SongAnalysis"))
        for (index, fixture) in genreFixtures.enumerated() {
            let track = Track(id: 20000 + index, title: fixture.0, artist: "Fixture", album: "Fixture",
                              artwork: nil, duration: 24, demoIndex: 0)
            _ = genrePoolCatalog.enqueue([track], account: "a", source: "fixture")
            genrePoolCatalog.songs[index].state = .completed
            var vector = unitVector
            if (4...6).contains(index) { vector = unitVector.map { -$0 } }
            genrePoolCatalog.songs[index].semantic = try await genreDisk.save(
                SemanticAnalysis(vector: vector, windowStarts: [0], elapsedSeconds: 0),
                songID: genrePoolCatalog.songs[index].id, account: "a", catalog: genreCatalog)
            if !fixture.1.isEmpty {
                var analysis = GenreAnalysis(matches: fixture.1.enumerated().map {
                    GenreMatch(index: $0.offset, family: "Electronic", style: $0.element.0, score: $0.element.1)
                }, windows: 10, duration: 20, analyzedAt: Date())
                if index == 10 { analysis.version = "obsolete" }
                genrePoolCatalog.songs[index].genres = analysis
            }
            genrePoolCatalog.songs[index].wikiBPM = WikiBPM(value: index == 4 ? 100 : 120, fetchedAt: Date())
        }
        let genrePoolURL = genreFolder.appendingPathComponent("pool.json")
        try JSONEncoder().encode(genrePoolCatalog).write(to: genrePoolURL)
        let genreRanking = SongPoolStore(fileURL: genrePoolURL, resolve: { _ in wav }, concepts: genreCatalog)
        try await wait { !genreRanking.loading }
        genreRanking.activate(account: "a")
        let houseQuery = RecommendationQuery(summary: "House", bpmMinimum: nil, bpmMaximum: nil, bpmRequired: false,
            preferences: [.init(concept: "house", direction: .prefer, weight: 1)], unsupported: [])
        let houseTracks = try await genreRanking.recommendationQueue(query: houseQuery)
        precondition(houseTracks.map(\.id) == [20004, 20005, 20006])
        precondition(RecommendationPlaylist(candidates: houseTracks).tracks.count == 3)
        let moodQuery = RecommendationQuery(summary: "激烈", bpmMinimum: nil, bpmMaximum: nil, bpmRequired: false,
            preferences: [.init(concept: "energetic", direction: .prefer, weight: 1, requirement: .preferred)], unsupported: [])
        let moodTracks = try await genreRanking.recommendationQueue(query: moodQuery)
        precondition(moodTracks.count == genreFixtures.count) // Mood requests do not require genre evidence.
        let avoidHouse = RecommendationQuery(summary: "不要House", bpmMinimum: nil, bpmMaximum: nil, bpmRequired: false,
            preferences: [.init(concept: "house", direction: .avoid, weight: 1)], unsupported: [])
        let withoutHouse = try await genreRanking.recommendationQueue(query: avoidHouse)
        precondition(Set(withoutHouse.map(\.id)).isDisjoint(with: Set(houseTracks.map(\.id))))
        let boundedHouse = RecommendationQuery(summary: "100 BPM House", bpmMinimum: 100, bpmMaximum: 100, bpmRequired: true,
            preferences: houseQuery.preferences, unsupported: [])
        let oneHouse = try await genreRanking.recommendationQueue(query: boundedHouse)
        precondition(oneHouse.map(\.id) == [20004])
        let noHouseQuery = RecommendationQuery(summary: "50 BPM House", bpmMinimum: 50, bpmMaximum: 50, bpmRequired: true,
            preferences: houseQuery.preferences, unsupported: [])
        do { _ = try await genreRanking.recommendationQueue(query: noHouseQuery); fatalError("Empty genre results padded") }
        catch is CurrentError {}
        let serializedQuery = try JSONDecoder().decode(RecommendationQuery.self, from: JSONEncoder().encode(houseQuery))
        precondition(serializedQuery.hasGenreConditions)
        let rockAnalysis = GenreAnalysis(matches: [GenreMatch(index: 1, family: "Rock", style: "Indie Rock", score: 0.7)],
                                         windows: 10, duration: 20, analyzedAt: Date())
        precondition(RecommendationGenre.rock.hasEvidence(in: rockAnalysis))
        precondition(rockAnalysis.filterLabels.contains("摇滚") && rockAnalysis.filterStyles.contains("独立摇滚"))
        precondition(!RecommendationGenre.house.hasEvidence(in: rockAnalysis))
        let invalidAnalysis = GenreAnalysis(matches: [GenreMatch(index: 91, family: "Electronic", style: "House", score: .nan)],
                                            windows: 10, duration: 20, analyzedAt: Date())
        precondition(!houseQuery.matchesGenres(invalidAnalysis))
        let wrongFamily = GenreAnalysis(matches: [GenreMatch(index: 91, family: "Pop", style: "House", score: 0.9)],
                                        windows: 10, duration: 20, analyzedAt: Date())
        precondition(!houseQuery.matchesGenres(wrongFamily))
        let deepHouse = GenreAnalysis(matches: [GenreMatch(index: 50, family: "Electronic", style: "Deep House", score: 0.7)],
                                      windows: 10, duration: 20, analyzedAt: Date())
        precondition(deepHouse.filterStyles.contains("House") && deepHouse.filterStyles.contains("Deep House"))
        precondition(deepHouse.filterFamilies == ["电子"])
        precondition(!genrePoolCatalog.songs[3].genres!.filterStyles.contains("House"))
        precondition(genrePoolCatalog.songs[10].genres!.filterLabels.isEmpty)
        print("PASS library genre labels: family and specific styles, House includes supported substyles, weak/obsolete evidence excluded")
        if let path = ProcessInfo.processInfo.environment["CURRENT_GENRE_POOL"] {
            let devicePool = try JSONDecoder().decode(PoolCatalog.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let accepted = devicePool.songs.filter { $0.semanticReady && houseQuery.matchesGenres($0.genres) }
            print("DEVICE SNAPSHOT House candidates:", accepted.count, "/", devicePool.songs.count)
            for song in accepted { print("DEVICE MATCH", song.track.title) }
            for title in genreFixtures.prefix(4).map(\.0) {
                precondition(!accepted.contains { $0.track.title.trimmingCharacters(in: .whitespacesAndNewlines) == title })
            }
        }
        print("PASS genre ranking: four reported false positives rejected, three supported tracks kept despite weaker semantics; no padding, BPM intersection, avoid and mood-only behavior")
        try await conjunctiveChecks(in: folder, audio: wav)

        let corruptURL = folder.appendingPathComponent("corrupt.json")
        let corruptData = Data("not an archive".utf8)
        try corruptData.write(to: corruptURL)
        let corrupt = SongPoolStore(fileURL: corruptURL, resolve: { _ in wav })
        try await wait { !corrupt.loading }
        precondition(corrupt.failure != nil && corrupt.enqueue(DemoCatalog.tracks, source: "test") == 0)
        let original = try Data(contentsOf: corruptURL)
        precondition(original == corruptData)
        print("PASS corrupt archive is preserved and cannot be overwritten by an empty pool")
        for path in CommandLine.arguments.dropFirst() {
            let result = try await NativeSongAnalyzer.analyze(url: URL(fileURLWithPath: path))
            print("REAL AUDIO PROFILE", String(data: try JSONEncoder().encode(result.profile), encoding: .utf8)!)
        }
        let flat = NativeSongAnalyzer.makeProfile(levels: Array(repeating: -20, count: 30), duration: 30, coverage: 1, evidence: .init(), available: false)
        precondition(flat.steadiness == "响度较平稳" && flat.vocalDescription == "无法判断")
        let jump = NativeSongAnalyzer.makeProfile(levels: Array(repeating: -30, count: 15) + Array(repeating: -12, count: 15), duration: 30, coverage: 1, evidence: .init(total: 10, vocal: 8), available: true)
        precondition(jump.largestRiseDB >= 12 && !jump.rises.isEmpty && jump.vocalDescription == "人声持续出现")
        let uncertain = NativeSongAnalyzer.makeProfile(levels: [-20], duration: 30, coverage: 1, evidence: .init(total: 10, vocal: 1, uncertain: 7), available: true)
        precondition(uncertain.vocalDescription == "人声分布不确定")
        let roundTrip = try JSONDecoder().decode(ObjectiveProfile.self, from: JSONEncoder().encode(jump))
        precondition(roundTrip == jump)
        print("PASS objective full-song profile, flat vs sustained jump, unknown vs positive vocals, persistence")
        var steadySpectrum = SpectrumEvidence(rate: 8192)
        var changedSpectrum = SpectrumEvidence(rate: 8192)
        for sample in 0..<(8192 * 24) {
            let time = Double(sample) / 8192
            steadySpectrum.append(Float(0.4 * sin(2 * .pi * 250 * time)))
            changedSpectrum.append(Float(0.4 * sin(2 * .pi * (time < 12 ? 250 : 2500) * time)))
        }
        precondition((steadySpectrum.peakChange ?? 1) < 0.02)
        precondition((changedSpectrum.peakChange ?? 0) > 0.8)
        print("PASS spectral change separates stable tone from sustained timbral transition")
        let cancelled = Task { try await NativeSongAnalyzer.analyze(url: wav) }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled full scan returned results") }
        catch is CancellationError { }
        print("PASS native pipeline cancellation does not publish partial results")
        var remoteMetadata = SongWikiMetadata(songID: realTrack.id, fetchedAt: Date(), bpm: 82,
                                             fields: [SongWikiField(kind: "instrument", title: "乐器", values: ["钢琴"])])
        var metadataCalls = 0, metadataAudioCalls = 0, failMetadata = false
        let metadataPool = SongPoolStore(fileURL: folder.appendingPathComponent("wiki-metadata.json"),
            resolve: { _ in metadataAudioCalls += 1; return wav },
            fetchWiki: { _ in
                metadataCalls += 1
                if failMetadata { throw CurrentError.message("unavailable") }
                return remoteMetadata
            }, genreAnalyze: { _ in
                GenreAnalysis(matches: [GenreMatch(index: 0, family: "Rock", style: "Indie Rock", score: 0.8)],
                              windows: 8, duration: 24, analyzedAt: Date())
            }, analyze: { try await probe.run($0) })
        try await wait { !metadataPool.loading }
        metadataPool.activate(account: "a"); metadataPool.setForeground(true)
        metadataPool.enqueue([realTrack], source: "metadata test"); metadataPool.resume()
        try await wait { metadataPool.completedCount == 1 }
        let originalFeatures = metadataPool.songs[0].features
        let originalGenres = metadataPool.songs[0].genres
        precondition(originalGenres?.matches.first?.style == "Indie Rock")
        precondition(metadataPool.songs[0].wikiMetadata == remoteMetadata && metadataPool.songs[0].resolvedBPM == 82)
        remoteMetadata = SongWikiMetadata(songID: realTrack.id, fetchedAt: Date(), bpm: nil,
                                         fields: [SongWikiField(kind: "songTag", title: "曲风", values: ["后摇"])])
        metadataPool.refreshWiki(metadataPool.songs[0].id)
        try await wait { metadataPool.completedCount == 1 && metadataCalls == 2 }
        precondition(metadataAudioCalls == 1 && metadataPool.songs[0].features == originalFeatures && metadataPool.songs[0].genres == originalGenres)
        precondition(metadataPool.songs[0].wikiMetadata == remoteMetadata && metadataPool.songs[0].resolvedBPM == 120)
        failMetadata = true; metadataPool.refreshWiki(metadataPool.songs[0].id)
        try await wait { metadataPool.completedCount == 1 && metadataCalls == 3 }
        precondition(metadataPool.songs[0].wikiMetadata == remoteMetadata && metadataPool.songs[0].bpmLookup == .failed)
        precondition(metadataAudioCalls == 1 && metadataPool.songs[0].features == originalFeatures && metadataPool.songs[0].genres == originalGenres)
        print("PASS wiki snapshot isolated from local features; metadata-only refresh/no-BPM fallback/failure preservation")
        let genreURL = folder.appendingPathComponent("genre-pool.json")
        try JSONEncoder().encode(legacy).write(to: genreURL)
        var failGenre = false
        let genreLabels = (0..<400).map { "Rock---Style \($0)" }
        var genreScores = [Double](repeating: 0.01, count: 400)
        genreScores[1] = 0.8; genreScores[2] = 0.7
        let expectedGenres = try GenreAnalysis.summarize(scores: genreScores, labels: genreLabels, windows: 3, duration: 5)
        let genrePool = SongPoolStore(fileURL: genreURL, resolve: { _ in wav }, genreAnalyze: { _ in
            if await MainActor.run(body: { failGenre }) { throw GenreError.inference }
            return expectedGenres
        }, analyze: { try await probe.run($0) })
        try await wait { !genrePool.loading }
        genrePool.activate(account: "a"); genrePool.setForeground(true)
        precondition(genrePool.songs[0].genres == nil)
        genrePool.analyzeHearing()
        try await wait { genrePool.songs[0].genres == expectedGenres }
        try await wait {
            (try? JSONDecoder().decode(PoolCatalog.self, from: Data(contentsOf: genreURL)))?.songs.first?.genres == expectedGenres
        }
        let oldGenres = genrePool.songs[0].genres
        failGenre = true; genrePool.reanalyze(genrePool.songs[0].id)
        try await wait { genrePool.songs[0].state == .failed }
        precondition(genrePool.songs[0].genres == oldGenres)
        precondition(genrePool.songs[0].failure == GenreError.inference.localizedDescription)
        failGenre = false; genrePool.retry(genrePool.songs[0].id)
        try await wait { genrePool.completedCount == 1 }
        precondition(genrePool.songs[0].genres?.matches.count == 5)
        print("PASS genre upgrade, multi-label persistence, failed rerun preservation and retry")
        var lyricsFetchCalls = 0, lyricAudioCalls = 0, failLyrics = false
        let lyricPool = SongPoolStore(fileURL: folder.appendingPathComponent("lyrics-pool.json"),
            resolve: { _ in lyricAudioCalls += 1; return wav },
            fetchLyrics: { track in
                lyricsFetchCalls += 1
                if failLyrics { throw CurrentError.message("network unavailable") }
                return LyricsDocument(songID: track.id, original: "[00:01]毕业之后，我们道别\n[00:03]来年再一起相见", translation: "", fetchedAt: Date())
            }, lyricsAnalyze: { document in
                let parsed = try LyricsParser.prepare(document)
                var vector = [Float](repeating: 0, count: 512); vector[0] = 1
                return LyricsAnalysis(status: parsed.status, contentHash: parsed.contentHash,
                    chunks: parsed.chunks.map { LyricsVectorChunk(chunk: $0, vector: vector) }, fetchedAt: document.fetchedAt)
            }, lyricsQuery: { _ in
                try await Task.sleep(for: .milliseconds(40))
                let active = await probe.active
                precondition(active == 0, "Query model overlapped pool analysis")
                var vector = [Float](repeating: 0, count: 512); vector[0] = 1
                return vector
            }, analyze: { try await probe.run($0) })
        try await wait { !lyricPool.loading }
        lyricPool.activate(account: "a"); lyricPool.setForeground(true)
        lyricPool.enqueue([realTrack], source: "lyrics"); lyricPool.resume()
        try await wait { lyricPool.completedCount == 1 }
        precondition(lyricPool.lyricsCount == 1 && lyricsFetchCalls == 1 && lyricAudioCalls == 1)
        let lyricFeatures = lyricPool.songs[0].features, originalLyricRecord = lyricPool.songs[0].lyrics!.recordID
        let lyricMatches = try await lyricPool.searchLyrics("毕业告别")
        precondition(lyricMatches.matches.count == 1 && lyricMatches.matches[0].track.id == realTrack.id)
        precondition(lyricMatches.matches[0].lines.first?.second == 1 && lyricMatches.matches[0].source == .original)
        failLyrics = true; lyricPool.indexLyrics(lyricPool.songs[0].id)
        try await wait { lyricPool.completedCount == 1 && lyricsFetchCalls == 2 }
        precondition(lyricPool.songs[0].lyrics?.recordID == originalLyricRecord && lyricPool.songs[0].lyricsFailure == true)
        precondition(lyricAudioCalls == 1 && lyricPool.songs[0].features == lyricFeatures)
        failLyrics = false; lyricPool.indexMissingLyrics()
        try await wait { lyricPool.completedCount == 1 && lyricsFetchCalls == 3 }
        precondition(lyricPool.songs[0].lyrics?.recordID != originalLyricRecord && lyricPool.songs[0].lyricsFailure != true)
        precondition(lyricAudioCalls == 1 && lyricPool.songs[0].features == lyricFeatures)
        let lateLyrics = Task { try await lyricPool.searchLyrics("毕业告别") }
        try await wait { lyricPool.lyricsSearching }
        lyricPool.activate(account: "b")
        do { _ = try await lateLyrics.value; fatalError("Stale cross-account query returned") } catch is CancellationError { }
        precondition(!lyricPool.lyricsSearching)
        do { _ = try await lyricPool.searchLyrics("毕业告别"); fatalError("Cross-account lyrics query") } catch is CurrentError { }
        precondition(lyricPool.lyricsCount == 0)
        print("PASS lyrics API/index/search queue, source/timestamps, text-only refresh, failure preservation, retry, account isolation")
        var unavailableAudioCalls = 0, independentFetchCalls = 0
        let independentLyrics = SongPoolStore(fileURL: folder.appendingPathComponent("lyrics-without-audio.json"),
            resolve: { _ in unavailableAudioCalls += 1; throw CurrentError.message("No audio permission") },
            fetchLyrics: { track in
                independentFetchCalls += 1
                return LyricsDocument(songID: track.id, original: "[00:02]多年以后再相见", translation: "", fetchedAt: Date())
            }, lyricsAnalyze: { doc in
                let prepared = try LyricsParser.prepare(doc)
                var vector = [Float](repeating: 0, count: 512); vector[0] = 1
                return LyricsAnalysis(status: prepared.status, contentHash: prepared.contentHash,
                    chunks: prepared.chunks.map { LyricsVectorChunk(chunk: $0, vector: vector) }, fetchedAt: doc.fetchedAt)
            }, lyricsQuery: { _ in var v = [Float](repeating: 0, count: 512); v[0] = 1; return v })
        try await wait { !independentLyrics.loading }
        independentLyrics.activate(account: "a"); independentLyrics.setForeground(true)
        independentLyrics.enqueue([realTrack], source: "independent lyrics"); independentLyrics.resume()
        try await wait { independentLyrics.songs.first?.state == .failed }
        precondition(independentLyrics.lyricsCount == 1 && independentLyrics.songs[0].features == nil)
        let noAudioRecord = independentLyrics.songs[0].lyrics!.recordID
        independentLyrics.indexLyrics(independentLyrics.songs[0].id)
        try await wait { independentLyrics.songs.first?.state == .failed && independentFetchCalls == 2 }
        precondition(independentLyrics.songs[0].lyrics?.recordID != noAudioRecord && unavailableAudioCalls == 1)
        precondition(independentLyrics.songs[0].features == nil && independentLyrics.songs[0].failure != nil)
        let independentMatches = try await independentLyrics.searchLyrics("再相见")
        precondition(independentMatches.matches.count == 1)
        print("PASS audio permission failure preserves usable lyrics; text-only retry retains audio failure and never downloads again")
        print("ALL ANALYSIS CHECKS PASSED")
    }
}
