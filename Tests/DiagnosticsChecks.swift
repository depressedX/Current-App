import Foundation

@main struct DiagnosticsChecks {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("current-diagnostic-check-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = AppLog(folder: folder, maxBytes: 2048, archiveCount: 2, systemLog: false)
        let secret = "MUSIC_U=private-cookie https://audio.invalid/song?token=private-token 用户私密需求"
        let underlying = NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [NSLocalizedDescriptionKey: secret])
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11828,
                            userInfo: [NSLocalizedDescriptionKey: secret, NSUnderlyingErrorKey: underlying])
        let trace = UUID(), span = UUID(), job = UUID()
        LogScope.$trace.withValue(trace) {
            log.record(.analysis, .failed, level: .error, operation: .decodeAudio, span: span, job: job,
                       stage: .analyzing, status: 200, elapsed: 0.125, error: error)
        }
        let first = try await log.entries()
        precondition(first.count == 1 && first[0].trace == trace && first[0].span == span && first[0].job == job)
        precondition(first[0].error?.code == -11828 && first[0].error?.underlyingCode == -1001 && first[0].elapsedMS == 125)
        let url = try await log.export()
        let exported = try String(contentsOf: url, encoding: .utf8)
        for privateText in ["private-cookie", "private-token", "audio.invalid", "用户私密需求", "localizedDescription"] {
            precondition(!exported.contains(privateText))
        }
        precondition(exported.contains("environment") && exported.contains("schemaVersion") && exported.contains("AVFoundation"))
        let arbitrary = LogError(NSError(domain: secret, code: 1))
        precondition(arbitrary.domain == "Application")
        print("PASS trace/span/job correlation, numeric cause chain, strict privacy, environment export")

        let oldWindow = Data(#"{"step":"shortWindow","windowStartMS":5000,"frames":478134,"expectedFrames":480000,"readerStatus":2,"sampleRate":48000,"channels":1}"#.utf8)
        let legacyWindow = try JSONDecoder().decode(LogAudioRead.self, from: oldWindow)
        precondition(legacyWindow.engine == nil && legacyWindow.frames == 478134)
        log.record(.analysis, .failed, operation: .semanticDecode, audioRead: legacyWindow)
        let windowEntries = try await log.entries()
        precondition(windowEntries.first?.audioRead?.windowStartMS == 5000)
        precondition(windowEntries.first?.audioRead?.expectedFrames == 480000)
        print("PASS numeric audio-window context roundtrip and old context without engine remain readable")

        for _ in 0..<80 { log.record(.api, .succeeded, operation: .playlists, status: 200) }
        let recent = try await log.entries()
        precondition(!recent.isEmpty && recent.count < 80)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "jsonl" }
        precondition(files.count <= 3)
        for file in files {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            precondition(size <= 2048)
        }
        print("PASS bounded rotation keeps at most active + 2 archives, each within configured cap")

        let active = folder.appendingPathComponent("current.jsonl")
        let file = try FileHandle(forWritingTo: active)
        try file.seekToEnd(); try file.write(contentsOf: Data("{partial-record".utf8)); try file.close()
        let restarted = AppLog(folder: folder, maxBytes: 2048, archiveCount: 2, systemLog: false)
        restarted.record(.app, .started, operation: .startup)
        let recovered = try await restarted.entries()
        precondition(recovered.first?.operation == .startup)
        print("PASS journal survives restart and repairs an interrupted trailing line")

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<25 { restarted.record(.playback, .paused, operation: .playback, reason: .user) }
                }
            }
        }
        let concurrent = try await restarted.entries()
        precondition(!concurrent.isEmpty && Set(concurrent.map(\.id)).count == concurrent.count)
        print("PASS concurrent producers serialize without corrupting JSON records")

        let exportBeforeClear = try await restarted.export()
        try await restarted.clear()
        precondition(!FileManager.default.fileExists(atPath: exportBeforeClear.path))
        let afterClear = try await restarted.entries()
        precondition(afterClear.count == 1 && afterClear[0].event == .cleared)
        print("PASS clear removes retained logs and export snapshots; later events can still be recorded")
        print("ALL DIAGNOSTICS CHECKS PASSED")
    }
}
