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
        try await wait { pool.songs.contains { $0.state == .analyzing } }
        pool.setPlaybackBusy(true)
        try await Task.sleep(for: .milliseconds(100))
        precondition(pool.completedCount == 3 && pool.waitReason != nil)
        pool.setPlaybackBusy(false)
        try await wait { pool.completedCount == 4 }
        pool.enqueue([DemoCatalog.tracks[4]], source: "test")
        try await wait { pool.songs.contains { $0.state == .analyzing } }
        pool.setForeground(false)
        try await Task.sleep(for: .milliseconds(100))
        precondition(pool.completedCount == 4)
        pool.setForeground(true)
        try await wait { pool.completedCount == 5 }
        print("PASS playback and background preempt analysis and resume remaining work")

        pool.enqueue([DemoCatalog.tracks[5]], source: "test")
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
        pool.enqueue([DemoCatalog.tracks[6]], source: "remove")
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

        let corruptURL = folder.appendingPathComponent("corrupt.json")
        let corruptData = Data("not an archive".utf8)
        try corruptData.write(to: corruptURL)
        let corrupt = SongPoolStore(fileURL: corruptURL, resolve: { _ in wav })
        try await wait { !corrupt.loading }
        precondition(corrupt.failure != nil && corrupt.enqueue(DemoCatalog.tracks, source: "test") == 0)
        let original = try Data(contentsOf: corruptURL)
        precondition(original == corruptData)
        print("PASS corrupt archive is preserved and cannot be overwritten by an empty pool")
        print("ALL ANALYSIS CHECKS PASSED")
    }
}
