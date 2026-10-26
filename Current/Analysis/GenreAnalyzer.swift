import AVFoundation
import CryptoKit
#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#endif

/// One CPU session per song, run on the pool's serial utility worker.
/// Model and all inference remain on device; no playback audio session activation.
enum GenreAnalyzer {
    static let modelSHA256 = "a280825b334797cf677939db8cd5762c0392aedd0ca6415dbc1cd083f045e43c"
    static let labelsSHA256 = "f4dd09fce0f1decbbf48f25c2c7c70ba9320e178fdc06bae278ea98d90427d6d"
    static func analyze(url: URL, resources: URL? = nil) async throws -> GenreAnalysis {
        let began = Date(), span = UUID()
        AppLog.shared.record(.analysis, .started, operation: .genreAnalysis, span: span)
        do {
            let worker = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                guard let folder = resources ?? Bundle.main.resourceURL?.appendingPathComponent("Semantics/Genres") else { throw GenreError.missingModel }
                let labelsData = try verified(folder.appendingPathComponent("labels.json"), digest: labelsSHA256)
                let labels = try JSONDecoder().decode([String].self, from: labelsData)
                guard labels.count == 400 else { throw GenreError.incompatible }
                let engine = try GenreEngine(model: folder.appendingPathComponent("discogs-effnet.onnx"))
                var sum = [Double](repeating: 0, count: 400)
                let stream = try GenrePatchStream { patch in
                    let result = try engine.predict(patch)
                    for index in sum.indices { sum[index] += Double(result[index]) }
                }
                try decode(url: url, into: stream)
                try stream.finish()
                try Task.checkCancellation()
                guard stream.windowCount > 0 else { throw GenreError.tooShort }
                return try GenreAnalysis.summarize(scores: sum.map { $0 / Double(stream.windowCount) }, labels: labels,
                                                   windows: stream.windowCount, duration: Double(stream.sampleCount) / 16000)
            }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            AppLog.shared.record(.analysis, .succeeded, operation: .genreAnalysis, span: span,
                                 count: result.windows, elapsed: Date().timeIntervalSince(began))
            return result
        } catch {
            AppLog.shared.record(.analysis, Task.isCancelled ? .cancelled : .failed,
                                 level: Task.isCancelled ? .info : .error, operation: .genreAnalysis,
                                 span: span, elapsed: Date().timeIntervalSince(began), error: error)
            throw error
        }
    }
    static func verified(_ url: URL, digest: String) throws -> Data {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else { throw GenreError.missingModel }
        return data
    }
    private static func decode(url: URL, into stream: GenrePatchStream) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0, file.length > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { throw AnalysisError.decode }
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?, sourceError: Error?
            let status = converter.convert(to: output, error: &conversionError) { requested, state in
                if Task.isCancelled { sourceError = CancellationError(); state.pointee = .endOfStream; return nil }
                let count = AVAudioFrameCount(min(Int64(min(requested, input.frameCapacity)), max(0, file.length - file.framePosition)))
                guard count > 0 else { state.pointee = .endOfStream; return nil }
                do { try file.read(into: input, frameCount: count) }
                catch { sourceError = error; state.pointee = .endOfStream; return nil }
                guard input.frameLength > 0 else { state.pointee = .endOfStream; return nil }
                state.pointee = .haveData
                return input
            }
            if let error = sourceError ?? conversionError { throw error }
            guard status != .error, let samples = output.floatChannelData?[0] else { throw AnalysisError.decode }
            try stream.append(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
            if status == .endOfStream { break }
            guard output.frameLength > 0 else { throw AnalysisError.decode }
        }
    }
}

final class GenreEngine {
    #if canImport(OnnxRuntimeBindings)
    private let environment: ORTEnv
    private let session: ORTSession
    #endif
    init(model: URL) throws {
        _ = try GenreAnalyzer.verified(model, digest: GenreAnalyzer.modelSHA256)
        #if canImport(OnnxRuntimeBindings)
        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        session = try ORTSession(env: environment, modelPath: model.path, sessionOptions: options)
        guard try session.inputNames() == ["melspectrogram"], try session.outputNames().contains("activations") else { throw GenreError.incompatible }
        #else
        throw GenreError.missingModel
        #endif
    }
    func predict(_ patch: [Float]) throws -> [Float] {
        try Task.checkCancellation()
        guard patch.count == 128 * 96, patch.allSatisfy(\.isFinite) else { throw GenreError.invalidOutput }
        #if canImport(OnnxRuntimeBindings)
        let data = patch.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
        let input = try ORTValue(tensorData: data, elementType: .float, shape: [1, 128, 96])
        let results: [String: ORTValue]
        do { results = try session.run(withInputs: ["melspectrogram": input], outputNames: ["activations"], runOptions: nil) }
        catch { throw GenreError.inference }
        try Task.checkCancellation()
        guard let result = results["activations"] else { throw GenreError.invalidOutput }
        let info = try result.tensorTypeAndShapeInfo()
        guard info.elementType == .float, info.shape.map(\.intValue) == [1, 400] else { throw GenreError.invalidOutput }
        let bytes = try result.tensorData() as Data
        guard bytes.count == 400 * 4 else { throw GenreError.invalidOutput }
        let scores = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard scores.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw GenreError.invalidOutput }
        return scores
        #else
        throw GenreError.missingModel
        #endif
    }
}
