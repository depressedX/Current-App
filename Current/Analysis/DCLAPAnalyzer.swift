import AVFoundation
import CryptoKit
#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#endif

/// Native inference worker. A session lives for one song and is released after completion/cancellation.
/// Serial queue ownership stays in SongPoolStore; never touches AVAudioSession.
enum DCLAPAnalyzer {
    static func analyze(url: URL, modelURL: URL? = nil) async throws -> SemanticAnalysis {
        let began = Date(), span = UUID()
        AppLog.shared.record(.analysis, .started, operation: .semanticAudio, span: span)
        do {
            let worker = Task.detached(priority: .utility) {
                let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                let duration = Double(file.length) / file.processingFormat.sampleRate
                guard duration.isFinite, duration >= 10 else { throw SemanticError.tooShort }
                let starts = windowStarts(duration: duration)
                let engine = try DCLAPEngine(modelURL: modelURL)
                let frontend = try DCLAPFrontend()
                var sum = [Float](repeating: 0, count: SemanticSpace.dimensions)
                for start in starts {
                    try Task.checkCancellation()
                    let embedding = try autoreleasepool {
                        let samples = try read(file: file, start: start, span: span)
                        return try engine.embedding(mel: frontend.mel(samples: samples))
                    }
                    for k in sum.indices { sum[k] += embedding[k] }
                }
                try Task.checkCancellation()
                return SemanticAnalysis(vector: try EmbeddingMath.unit(sum), windowStarts: starts, elapsedSeconds: Date().timeIntervalSince(began))
            }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            AppLog.shared.record(.analysis, .succeeded, operation: .semanticAudio, span: span,
                                 count: result.windowStarts.count, elapsed: result.elapsedSeconds)
            return result
        } catch {
            AppLog.shared.record(.analysis, Task.isCancelled ? .cancelled : .failed,
                                 level: Task.isCancelled ? .info : .error, operation: .semanticAudio,
                                 span: span, elapsed: Date().timeIntervalSince(began), error: error)
            throw error
        }
    }
    static func windowStarts(duration: Double) -> [Double] {
        guard duration >= 10 else { return [] }
        let region = min(20, duration)
        let bases = [0.0, (duration - region) / 2, duration - region]
        return Set(bases.flatMap { base in stride(from: 0.0, through: region - 10, by: 5).map { ((base + $0) * 1000).rounded() / 1000 } }).sorted()
    }
    /// Seek in source PCM frames and explicitly resample, rather than clipping compressed packets by AVAssetReader.timeRange.
    /// The iOS MP3 reader can silently lose ~40ms at a timeRange boundary even when status is completed.
    static func read(file: AVAudioFile, start: Double, span: UUID? = nil) throws -> [Float] {
        try Task.checkCancellation()
        let inputFormat = file.processingFormat
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0, start.isFinite, start >= 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { throw AnalysisError.decode }
        let offset = AVAudioFramePosition((start * inputFormat.sampleRate).rounded(.down))
        guard offset < file.length else { throw AnalysisError.decode }
        file.framePosition = offset
        var samples: [Float] = []; samples.reserveCapacity(DCLAPFrontend.sampleCount)
        var state = AVAudioConverterOutputStatus.haveData
        func log(_ step: LogAudioRead.Step, error: Error? = nil) {
            let cancelled = Task.isCancelled || error is CancellationError
            AppLog.shared.record(.analysis, cancelled ? .cancelled : error == nil ? .succeeded : .failed,
                                 level: cancelled || error == nil ? .info : .error, operation: .semanticDecode, span: span, error: error,
                                 audioRead: LogAudioRead(step: step, windowStartMS: Int(start * 1000), frames: samples.count,
                                                        expectedFrames: DCLAPFrontend.sampleCount, readerStatus: state.rawValue,
                                                        sampleRate: target.sampleRate, channels: Int(target.channelCount)))
        }
        while samples.count < DCLAPFrontend.sampleCount {
            try Task.checkCancellation()
            var conversionError: NSError?, sourceError: Error?
            output.frameLength = 0
            state = converter.convert(to: output, error: &conversionError) { requested, status in
                if Task.isCancelled { sourceError = CancellationError(); status.pointee = .endOfStream; return nil }
                let remaining = max(0, file.length - file.framePosition)
                let count = AVAudioFrameCount(min(Int64(min(requested, input.frameCapacity)), remaining))
                guard count > 0 else { status.pointee = .endOfStream; return nil }
                do { try file.read(into: input, frameCount: count) }
                catch { sourceError = error; status.pointee = .endOfStream; return nil }
                guard input.frameLength > 0 else { status.pointee = .endOfStream; return nil }
                status.pointee = .haveData
                return input
            }
            if let error = sourceError ?? conversionError {
                log(.readerFailed, error: error); throw error
            }
            guard state != .error, let pointer = output.floatChannelData?[0] else {
                log(.readerFailed, error: AnalysisError.decode); throw AnalysisError.decode
            }
            let count = min(Int(output.frameLength), DCLAPFrontend.sampleCount - samples.count)
            samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count))
            if state == .endOfStream { break }
            guard count > 0 else { log(.buffer, error: AnalysisError.decode); throw AnalysisError.decode }
        }
        try Task.checkCancellation()
        guard samples.count >= DCLAPFrontend.sampleCount - 960 else {
            log(.shortWindow, error: AnalysisError.decode); throw AnalysisError.decode
        }
        log(.completed)
        samples.append(contentsOf: repeatElement(0, count: DCLAPFrontend.sampleCount - samples.count))
        return samples
    }

}

final class DCLAPEngine {
    #if canImport(OnnxRuntimeBindings)
    private let environment: ORTEnv
    private let session: ORTSession
    private let output: String
    #endif
    init(modelURL: URL? = nil) throws {
        #if canImport(OnnxRuntimeBindings)
        guard let url = modelURL ?? Bundle.main.url(forResource: "model_epoch_36", withExtension: "onnx", subdirectory: "Semantics/Models") else { throw SemanticError.missingResource }
        // Check both graph and external weights before ORT opens them. No network or mutable downloaded code.
        for (file, digest) in [(url, "17860403f8fc90aff8ac0632a0741eb5e58d8c0b0ad2fce5ced967274b0ea971"),
                                (url.appendingPathExtension("data"), "2a735b23c2aad7b12d9ffc85334cebcc659c07696d2ff60e2e378da28b6df657")] {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else { throw SemanticError.missingResource }
        }
        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        try options.addConfigEntry(withKey: "session.use_env_allocators", value: "0")
        session = try ORTSession(env: environment, modelPath: url.path, sessionOptions: options)
        guard try session.inputNames() == ["mel_spectrogram"], let name = try session.outputNames().first else { throw SemanticError.incompatible }
        output = name
        #else
        throw SemanticError.missingResource
        #endif
    }
    func embedding(mel: [Float]) throws -> [Float] {
        #if canImport(OnnxRuntimeBindings)
        try Task.checkCancellation()
        guard mel.count == 128 * 1001, mel.allSatisfy(\.isFinite) else { throw SemanticError.invalidVector }
        let data = mel.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
        let input = try ORTValue(tensorData: data, elementType: .float, shape: [1, 1, 128, 1001])
        let result: [String: ORTValue]
        do { result = try session.run(withInputs: ["mel_spectrogram": input], outputNames: [output], runOptions: nil) }
        catch { throw SemanticError.inference }
        try Task.checkCancellation()
        guard let value = result[output], try value.tensorTypeAndShapeInfo().elementType == .float else { throw SemanticError.invalidVector }
        let bytes = try value.tensorData() as Data
        guard bytes.count == SemanticSpace.dimensions * 4 else { throw SemanticError.invalidVector }
        let vector = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        // Do not normalize each window: training/reference aggregates raw window outputs, then normalizes once.
        guard vector.allSatisfy(\.isFinite) else { throw SemanticError.invalidVector }
        return vector
        #else
        throw SemanticError.missingResource
        #endif
    }
}
