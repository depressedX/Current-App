import Foundation
import OSLog
import Darwin

enum LogCategory: String, Codable, CaseIterable { case app, auth, api, playback, analysis, storage }
enum LogEvent: String, Codable {
    case started, succeeded, failed, cancelled, response, ready, paused, resumed
    case enqueued, stateChanged, accountChanged, interrupted, routeChanged, cleared, recovered
}
enum LogOperation: String, Codable {
    case semanticAudio, semanticDecode, semanticLoad, semanticSave
    case startup, scene, restoreSession, login, logout, demo, apiRequest, qrKey, qrCheck, profile
    case playlists, playlistTracks, songWiki, playbackURL, playback, audioSession, downloadAudio, decodeAudio
    case pool, poolLoad, poolSave, historySave, diagnostics
    static func api(_ path: String) -> Self {
        switch path {
        case "/login/qrcode/unikey": return .qrKey
        case "/login/qrcode/client/login": return .qrCheck
        case "/w/nuser/account/get": return .profile
        case "/logout": return .logout
        case "/user/playlist": return .playlists
        case "/v6/playlist/detail", "/v3/song/detail": return .playlistTracks
        case "/song/play/about/block/page": return .songWiki
        case "/song/enhance/player/url/v1": return .playbackURL
        default: return .apiRequest
        }
    }
}
enum LogReason: String, Codable { case user, active, inactive, background, playbackBusy, resourceLimited, lowPower, scopeChanged }
enum LogStage: String, Codable { case queued, readingMetadata, fetching, analyzing, completed, failed }
enum LogFormat: String, Codable { case mp3, m4a, aac, wav, flac, aiff, aif, caf, unknown }
enum LogLevel: String, Codable { case info, warning, error }

enum LogScope { @TaskLocal static var trace: UUID? }

enum LogFailure: String, Codable {
    case semanticModel, semanticVersion, semanticVector, semanticInference, semanticStorage
    case tooShort, silent, missingAudio, tooLarge, download, decode, invalidAudioResponse, httpStatus, authExpired, application
}
protocol SafeLogError { var logFailure: LogFailure { get } }

/// No descriptions, URLs, userInfo payloads, or arbitrary error domains enter the log.
struct LogError: Codable, Equatable {
    let domain: String
    let kind: LogFailure?
    let code: Int
    let underlyingDomain: String?
    let underlyingCode: Int?
    init(_ error: Error) {
        let issue = error as NSError
        domain = Self.domain(issue.domain); kind = (error as? SafeLogError)?.logFailure; code = issue.code
        let underlying = issue.userInfo[NSUnderlyingErrorKey] as? NSError
        underlyingDomain = underlying.map { Self.domain($0.domain) }; underlyingCode = underlying?.code
    }
    private static func domain(_ input: String) -> String {
        switch input {
        case NSURLErrorDomain: return "URLSession"
        case NSCocoaErrorDomain: return "Cocoa"
        case "AVFoundationErrorDomain": return "AVFoundation"
        case NSOSStatusErrorDomain: return "OSStatus"
        default: return "Application"
        }
    }
}

struct LogEnvironment: Codable {
    let appVersion: String
    let build: String
    let systemVersion: String
    let machine: String
    let platform: String
    static var current: Self {
        var system = utsname(); uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        let machine = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        #if os(iOS)
        let platform = ProcessInfo.processInfo.isiOSAppOnMac ? "iPhone-on-Mac" : "iOS"
        #else
        let platform = "macOS-host-check"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Self(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                    build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                    systemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", machine: machine, platform: platform)
    }
}

struct LogAudioRead: Codable {
    enum Step: String, Codable { case start, output, buffer, format, shortWindow, completed, readerFailed }
    let step: Step
    let windowStartMS: Int
    let frames: Int
    let expectedFrames: Int
    let readerStatus: Int
    let sampleRate: Double?
    let channels: Int?
    enum Engine: String, Codable { case assetReader, audioConverter }
    var engine: Engine? = .audioConverter
}
struct LogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let session: UUID
    let environment: LogEnvironment
    let trace: UUID?
    let span: UUID?
    let job: UUID?
    let category: LogCategory
    let event: LogEvent
    let level: LogLevel
    let operation: LogOperation
    let stage: LogStage?
    let reason: LogReason?
    let status: Int?
    let serviceCode: Int?
    let count: Int?
    let bytes: Int?
    let elapsedMS: Int?
    let format: LogFormat?
    let error: LogError?
    let audioRead: LogAudioRead?
    let droppedBefore: Int
}

/// OSLog + bounded JSONL journal. All disk work runs on one utility queue.
/// The typed API intentionally has no free-form message/metadata parameter.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog(folder: ProcessInfo.processInfo.environment["CURRENT_DIAGNOSTICS_ROOT"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) })
    static let subsystem = "com.liupenghao.current"
    private let queue = DispatchQueue(label: "current.diagnostics", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private var dropped = 0
    private let session = UUID()
    private let environment = LogEnvironment.current
    private let folder: URL
    private let exportFolder: URL
    private let maxBytes: Int
    private let archiveCount: Int
    private let systemLog: Bool
    private var fileIssue: Error?
    private var validatedTail = false
    private let loggers = Dictionary(uniqueKeysWithValues: LogCategory.allCases.map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) })
    init(folder: URL? = nil, maxBytes: Int = 512 * 1024, archiveCount: Int = 3, systemLog: Bool = true) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Current/Diagnostics", isDirectory: true)
        exportFolder = self.folder.appendingPathComponent("Exports", isDirectory: true)
        self.maxBytes = max(1024, maxBytes); self.archiveCount = max(1, archiveCount); self.systemLog = systemLog
    }
    func record(_ category: LogCategory, _ event: LogEvent, level: LogLevel = .info, operation: LogOperation,
                span: UUID? = nil, job: UUID? = nil, stage: LogStage? = nil, reason: LogReason? = nil,
                status: Int? = nil, serviceCode: Int? = nil, count: Int? = nil, bytes: Int? = nil,
                elapsed: TimeInterval? = nil, format: LogFormat? = nil, error: Error? = nil, audioRead: LogAudioRead? = nil) {
        lock.lock()
        guard pending < 256 else { dropped += 1; lock.unlock(); return }
        pending += 1; let skipped = dropped; dropped = 0; lock.unlock()
        let milliseconds = elapsed.flatMap { value -> Int? in
            guard value.isFinite else { return nil }
            return Int(min(Double(Int.max / 2), max(0, value * 1000)))
        }
        let entry = LogEntry(id: UUID(), timestamp: Date(), session: session, environment: environment, trace: LogScope.trace,
                             span: span, job: job, category: category, event: event, level: level,
                             operation: operation, stage: stage, reason: reason, status: status, serviceCode: serviceCode,
                             count: count, bytes: bytes, elapsedMS: milliseconds, format: format,
                             error: error.map(LogError.init), audioRead: audioRead, droppedBefore: skipped)
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            do {
                let encoder = Self.encoder()
                var data = try encoder.encode(entry); data.append(10)
                if systemLog, let text = String(data: data, encoding: .utf8), let logger = loggers[category] {
                    switch level {
                    case .info: logger.info("\(text, privacy: .public)")
                    case .warning: logger.warning("\(text, privacy: .public)")
                    case .error: logger.error("\(text, privacy: .public)")
                    }
                }
                try prepareFolder()
                let active = folder.appendingPathComponent("current.jsonl")
                let size = (try? active.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size + data.count > maxBytes { try rotate() }
                if !FileManager.default.fileExists(atPath: active.path) {
                    try data.write(to: active, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } else {
                    let file = try FileHandle(forWritingTo: active)
                    defer { try? file.close() }
                    try file.seekToEnd(); try file.write(contentsOf: data)
                }
                fileIssue = nil
            } catch {
                fileIssue = error
                loggers[.storage]?.error("Diagnostic journal write failed, code=\((error as NSError).code)")
            }
        }
    }
    func entries(limit: Int = 200) async throws -> [LogEntry] {
        try await perform { Array(try self.readEntries().suffix(max(0, limit)).reversed()) }
    }
    func export() async throws -> URL {
        try await perform {
            let entries = try self.readEntries()
            struct Bundle: Encodable { let schemaVersion = 1; let environment: LogEnvironment; let entries: [LogEntry] }
            let bundle = Bundle(environment: .current, entries: entries)
            try FileManager.default.createDirectory(at: self.exportFolder, withIntermediateDirectories: true)
            let url = self.exportFolder.appendingPathComponent("Current-diagnostics.json")
            try Self.encoder().encode(bundle).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return url
        }
    }
    func clear() async throws {
        try await perform {
            if FileManager.default.fileExists(atPath: self.folder.path) { try FileManager.default.removeItem(at: self.folder) }
            self.fileIssue = nil; self.validatedTail = false
        }
        record(.app, .cleared, operation: .diagnostics)
    }
    private func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
    private func prepareFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder, values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        if !validatedTail {
            let active = folder.appendingPathComponent("current.jsonl")
            if FileManager.default.fileExists(atPath: active.path) {
                let file = try FileHandle(forUpdating: active)
                defer { try? file.close() }
                let end = try file.seekToEnd()
                if end > 0 {
                    try file.seek(toOffset: end - 1)
                    if try file.read(upToCount: 1) != Data([10]) {
                        try file.seekToEnd(); try file.write(contentsOf: Data([10]))
                    }
                }
            }
            validatedTail = true
        }
    }
    private func rotate() throws {
        let manager = FileManager.default
        let oldest = folder.appendingPathComponent("archive-\(archiveCount).jsonl")
        if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
        if archiveCount > 1 {
            for i in stride(from: archiveCount - 1, through: 1, by: -1) {
                let source = folder.appendingPathComponent("archive-\(i).jsonl")
                if manager.fileExists(atPath: source.path) {
                    try manager.moveItem(at: source, to: folder.appendingPathComponent("archive-\(i + 1).jsonl"))
                }
            }
        }
        let active = folder.appendingPathComponent("current.jsonl")
        if manager.fileExists(atPath: active.path) { try manager.moveItem(at: active, to: folder.appendingPathComponent("archive-1.jsonl")) }
    }
    private func readEntries() throws -> [LogEntry] {
        if let fileIssue { throw fileIssue }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var result: [LogEntry] = []
        let names = stride(from: archiveCount, through: 1, by: -1).map { "archive-\($0).jsonl" } + ["current.jsonl"]
        for name in names {
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            for line in data.split(separator: 10) {
                if let entry = try? decoder.decode(LogEntry.self, from: Data(line)) { result.append(entry) }
            }
        }
        return result
    }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
