import AVFoundation

/// File-only reader: does not activate AVAudioSession or share AVPlayer state.
enum NativeSongAnalyzer {
    static func analyze(url: URL) async throws -> AcousticFeatures {
        let span = UUID(), began = Date()
        AppLog.shared.record(.analysis, .started, operation: .decodeAudio, span: span)
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration >= 8 else { throw AnalysisError.tooShort }
            let start = max(0, (duration - 45) / 2)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AnalysisError.noAudio }
            let worker = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                return try read(asset: asset, track: track, start: start, seconds: min(45, duration))
            }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            AppLog.shared.record(.analysis, .succeeded, operation: .decodeAudio, span: span,
                                 elapsed: Date().timeIntervalSince(began), format: LogFormat(rawValue: url.pathExtension) ?? .unknown)
            return result
        } catch {
            AppLog.shared.record(.analysis, Task.isCancelled ? .cancelled : .failed,
                                 level: Task.isCancelled ? .info : .error, operation: .decodeAudio,
                                 span: span, elapsed: Date().timeIntervalSince(began), error: error)
            throw error
        }
    }

    private static func read(asset: AVAsset, track: AVAssetTrack, start: Double, seconds: Double) throws -> AcousticFeatures {
        let began = Date()
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AcousticDSP.sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalysisError.decode }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                      duration: CMTime(seconds: seconds, preferredTimescale: 600))
        guard reader.startReading() else { throw AnalysisError.decode }
        defer { reader.cancelReading() }
        var dsp = AcousticDSP()
        let cap = Int(45 * AcousticDSP.sampleRate)
        while reader.status == .reading && dsp.count < cap {
            try Task.checkCancellation()
            let more: Bool = try autoreleasepool {
                guard let buffer = output.copyNextSampleBuffer() else { return false }
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { throw AnalysisError.decode }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                                        totalLengthOut: &length, dataPointerOut: &pointer)
                guard status == kCMBlockBufferNoErr, let pointer else { throw AnalysisError.decode }
                let available = min(length / MemoryLayout<Float>.size, cap - dsp.count)
                pointer.withMemoryRebound(to: Float.self, capacity: available) {
                    dsp.append(UnsafeBufferPointer(start: $0, count: available))
                }
                return true
            }
            if !more { break }
        }
        try Task.checkCancellation()
        if reader.status == .failed { throw AnalysisError.decode }
        return try dsp.result(start: start, elapsed: Date().timeIntervalSince(began))
    }
}

private final class AudioDownloadLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let maxBytes: Int64 = 40 * 1_024 * 1_024
    private let lock = NSLock()
    private var hitLimit = false
    var exceeded: Bool { lock.lock(); defer { lock.unlock() }; return hitLimit }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > Self.maxBytes {
            lock.lock(); hitLimit = true; lock.unlock(); downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

enum AnalysisAudioDownloader {
    static func fetch(_ url: URL) async throws -> URL {
        let span = UUID(), began = Date()
        var status: Int?
        AppLog.shared.record(.analysis, .started, operation: .downloadAudio, span: span)
        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 90
            config.urlCache = nil
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let limit = AudioDownloadLimit()
            let temporary: URL, response: URLResponse
            do { (temporary, response) = try await session.download(from: url, delegate: limit) }
            catch {
                if Task.isCancelled { throw CancellationError() }
                if limit.exceeded { throw AnalysisError.tooLarge }
                throw error
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            status = (response as? HTTPURLResponse)?.statusCode
            guard let http = response as? HTTPURLResponse else { throw AnalysisError.download }
            guard (200..<300).contains(http.statusCode) else { throw AnalysisError.downloadHTTP(http.statusCode) }
            let size = (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size <= AudioDownloadLimit.maxBytes else { throw AnalysisError.tooLarge }
            try Task.checkCancellation()
            let fileExtension = try audioExtension(file: temporary, response: response)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("current-analysis-\(UUID().uuidString).\(fileExtension)")
            try FileManager.default.moveItem(at: temporary, to: destination)
            AppLog.shared.record(.analysis, .succeeded, operation: .downloadAudio, span: span,
                                 status: status, bytes: size, elapsed: Date().timeIntervalSince(began),
                                 format: LogFormat(rawValue: fileExtension) ?? .unknown)
            return destination
        } catch {
            AppLog.shared.record(.analysis, Task.isCancelled ? .cancelled : .failed,
                                 level: Task.isCancelled ? .info : .error, operation: .downloadAudio,
                                 span: span, status: status, elapsed: Date().timeIntervalSince(began), error: error)
            throw error
        }
    }
}


extension AnalysisAudioDownloader {
    /// Detect the actual container, not the signed URL's suffix or a generic temporary extension.
    static func audioExtension(file: URL, response: URLResponse) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let bytes = Array(try handle.read(upToCount: 64) ?? Data())
        func matches(_ text: String, at offset: Int = 0) -> Bool {
            let marker = Array(text.utf8)
            return bytes.count >= offset + marker.count && Array(bytes[offset..<(offset + marker.count)]) == marker
        }
        if matches("ftyp", at: 4) { return "m4a" }
        if matches("RIFF") && matches("WAVE", at: 8) { return "wav" }
        if matches("fLaC") { return "flac" }
        if matches("ID3") { return "mp3" }
        if bytes.count >= 2 && bytes[0] == 0xff {
            if bytes[1] & 0xf6 == 0xf0 { return "aac" }
            if bytes[1] & 0xe0 == 0xe0 { return "mp3" }
        }
        let prefix = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !prefix.hasPrefix("<"), !prefix.hasPrefix("{"), !prefix.hasPrefix("["), !bytes.isEmpty else {
            throw AnalysisError.invalidAudioResponse
        }
        let types = ["audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a",
                     "audio/aac": "aac", "audio/aacp": "aac", "audio/wav": "wav", "audio/x-wav": "wav",
                     "audio/flac": "flac", "audio/x-flac": "flac", "audio/aiff": "aiff"]
        if let mime = response.mimeType?.lowercased(), let ext = types[mime] { return ext }
        let allowed = Set(["mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "caf"])
        for name in [response.suggestedFilename, response.url?.lastPathComponent].compactMap({ $0 }) {
            let ext = (name as NSString).pathExtension.lowercased()
            if allowed.contains(ext) { return ext }
        }
        throw AnalysisError.invalidAudioResponse
    }
}
