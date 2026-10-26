import AVFoundation
import SoundAnalysis
import Accelerate

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
                var features = try read(asset: asset, track: track, start: start, seconds: min(45, duration))
                features.profile = try scanWholeFile(url: url)
                return features
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

    /// One bounded PCM buffer, serial utility worker. Never activates the playback session.
    private static func scanWholeFile(url: URL) throws -> ObjectiveProfile {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard Double(file.length) / format.sampleRate <= 7200 else { throw AnalysisError.tooLarge }
        guard format.sampleRate > 0, file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw AnalysisError.decode }
        let observer = SoundEvidence()
        let classifier = SNAudioStreamAnalyzer(format: format)
        var available = false
        if let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) {
            request.windowDuration = CMTime(seconds: 3, preferredTimescale: 48_000)
            request.overlapFactor = 0
            do { try classifier.add(request, withObserver: observer); available = true } catch { }
        }
        defer { classifier.removeAllRequests() }
        var seconds: [Double] = []
        var spectrum = SpectrumEvidence(rate: format.sampleRate)
        var energy = 0.0, samples = 0, processed: AVAudioFramePosition = 0
        let perSecond = Int(format.sampleRate.rounded())
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let position = file.framePosition
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            if available { classifier.analyze(buffer, atAudioFramePosition: position) }
            for frame in 0..<Int(buffer.frameLength) {
                // Sum channel power, avoiding phase cancellation in stereo mixes.
                var power = 0.0
                for channel in 0..<Int(format.channelCount) {
                    let x = Double(channels[channel][frame])
                    if x.isFinite { power += x * x }
                }
                spectrum.append(channels[0][frame])
                energy += power / Double(format.channelCount); samples += 1
                if samples >= perSecond {
                    seconds.append(AcousticDSP.db(sqrt(energy / Double(samples))))
                    energy = 0; samples = 0
                }
            }
            processed += AVAudioFramePosition(buffer.frameLength)
        }
        if samples > 0 { seconds.append(AcousticDSP.db(sqrt(energy / Double(samples)))) }
        if available {
            classifier.completeAnalysis()
            try observer.waitForCompletion()
        }
        try Task.checkCancellation()
        return makeProfile(levels: seconds, duration: Double(processed) / format.sampleRate,
                           coverage: min(1, Double(processed) / Double(file.length)),
                           evidence: observer.snapshot(), available: available, spectralChange: spectrum.change, spectralPeak: spectrum.peakChange)
    }

    static func makeProfile(levels: [Double], duration: Double, coverage: Double,
                            evidence: SoundEvidence.Snapshot, available: Bool, spectralChange: Double? = nil, spectralPeak: Double? = nil) -> ObjectiveProfile {
        // RMS dBFS, not LUFS/LRA. Ignore near-silence for the spread; transitions retain timestamps.
        let active = levels.filter { $0 > -60 }.sorted()
        let spread = active.isEmpty ? 0 : active[Int(Double(active.count - 1) * 0.9)] - active[Int(Double(active.count - 1) * 0.1)]
        var rises: [LoudnessRise] = []
        if levels.count >= 6 {
            for i in 3...(levels.count - 3) {
                let before = levels[(i-3)..<i].reduce(0,+) / 3
                let after = levels[i..<(i+3)].reduce(0,+) / 3
                let delta = after - before
                if before > -60 && delta >= 6 {
                    let event = LoudnessRise(second: i, decibels: delta)
                    if let last = rises.last, i - last.second < 6 {
                        if delta > last.decibels { rises[rises.count - 1] = event }
                    } else { rises.append(event) }
                }
            }
        }
        return ObjectiveProfile(duration: duration, decodedFraction: coverage, activeSeconds: active.count,
                                loudnessSpreadDB: spread, spectralChange: spectralChange, spectralPeak: spectralPeak, largestRiseDB: rises.map(\.decibels).max() ?? 0,
                                rises: Array(rises.prefix(32)), vocalWindows: evidence.vocal,
                                classifiedWindows: evidence.total, uncertainVocalWindows: evidence.uncertain,
                                soundLabels: evidence.sounds, classifierAvailable: available && !evidence.failed)
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

/// SoundAnalysis scores are model confidence, never vocal energy or calibrated probability.
final class SoundEvidence: NSObject, SNResultsObserving {
    struct Snapshot {
        var total = 0, vocal = 0, uncertain = 0
        var sounds: [DetectedSound] = []
        var failed = false
    }
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var state = Snapshot()
    private let completed = DispatchSemaphore(value: 0)
    private static let vocals: Set<String> = ["speech", "singing", "choir_singing", "rapping"]
    private static let instruments: [String: String] = [
        "guitar": "吉他", "acoustic_guitar": "木吉他", "electric_guitar": "电吉他",
        "piano": "钢琴", "electric_piano": "电钢琴", "synthesizer": "合成器",
        "drum_kit": "架子鼓", "drum": "鼓", "bass_guitar": "贝斯",
        "violin_fiddle": "小提琴", "cello": "大提琴", "saxophone": "萨克斯"]
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        lock.lock(); defer { lock.unlock() }
        state.total += 1
        let vocal = result.classifications.filter { Self.vocals.contains($0.identifier) }.map(\.confidence).max() ?? 0
        if vocal >= 0.65 { state.vocal += 1 }
        else if vocal >= 0.2 { state.uncertain += 1 }
        var found: Set<String> = []
        for item in result.classifications where item.confidence >= 0.65 {
            if let label = Self.instruments[item.identifier] { found.insert(label) }
        }
        for label in found { counts[label, default: 0] += 1 }
    }
    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.lock(); state.failed = true; lock.unlock(); completed.signal()
    }
    func requestDidComplete(_ request: SNRequest) { completed.signal() }
    func waitForCompletion() throws {
        for _ in 0..<600 {
            try Task.checkCancellation()
            if completed.wait(timeout: .now() + 0.1) == .success { return }
        }
        lock.lock(); state.failed = true; lock.unlock()
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var value = state
        value.sounds = counts.filter { $0.value >= 2 }.map { DetectedSound(label: $0.key, windows: $0.value) }
            .sorted { $0.windows == $1.windows ? $0.label < $1.label : $0.windows > $1.windows }
        return value
    }
}

/// Broad spectral distribution, normalized independently of amplitude. Not an emotion/genre score.
struct SpectrumEvidence {
    private let setup: vDSP_DFT_Setup?
    private let rate: Double
    private var input: [Float] = []
    private var previous: [Double]?
    private var changes: [Double] = []
    init(rate: Double) {
        self.rate = rate
        let dft = vDSP_DFT_zop_CreateSetup(nil, 1024, .FORWARD)
        setup = dft
        owner = dft.map(DFTLifetime.init)
    }
    // Setup lifetime is owned by the reference wrapper below, to keep this accumulator value-safe.
    private let owner: DFTLifetime?
    private static let window = (0..<1024).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 1023)) }
    mutating func append(_ sample: Float) {
        guard let setup else { return }
        input.append(sample.isFinite ? sample : 0)
        guard input.count == 1024 else { return }
        var real = [Float](repeating: 0, count: 1024), imaginary = real
        let zero = real
        for i in input.indices { input[i] *= Self.window[i] }
        withExtendedLifetime(owner) { vDSP_DFT_Execute(setup, input, zero, &real, &imaginary) }
        let edges: [Double] = [0, 125, 250, 500, 1000, 2000, 3000, 5000]
        var bands = [Double](repeating: 0, count: 7)
        for i in 1..<512 {
            let frequency = Double(i) * rate / 1024
            if let band = (0..<7).first(where: { frequency >= edges[$0] && frequency < edges[$0+1] }) {
                bands[band] += Double(real[i] * real[i] + imaginary[i] * imaginary[i])
            }
        }
        let total = bands.reduce(0,+)
        if total > 0.001 {
            bands = bands.map { $0 / total }
            // Compare ~3 second aggregates rather than individual drum transients.
            accumulated = zip(accumulated, bands).map(+); windows += 1
            if windows >= max(1, Int(3 * rate / 1024)) {
                let mean = accumulated.map { $0 / Double(windows) }
                if let previous { changes.append(zip(mean, previous).reduce(0) { $0 + abs($1.0 - $1.1) } / 2) }
                previous = mean; accumulated = Array(repeating: 0, count: 7); windows = 0
            }
        }
        input.removeAll(keepingCapacity: true)
    }
    private var accumulated = [Double](repeating: 0, count: 7)
    private var windows = 0
    var peakChange: Double? { changes.max() }
    var change: Double? {
        let sorted = changes.sorted()
        return sorted.count >= 2 ? sorted[Int(Double(sorted.count - 1) * 0.9)] : nil
    }
}
private final class DFTLifetime {
    let setup: vDSP_DFT_Setup
    init(_ setup: vDSP_DFT_Setup) { self.setup = setup }
    deinit { vDSP_DFT_DestroySetup(setup) }
}
