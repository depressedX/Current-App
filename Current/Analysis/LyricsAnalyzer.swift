import Foundation
import CryptoKit
#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#endif

enum LyricsAnalyzer {
    static let queryInstruction = "为这个句子生成表示以用于检索相关文章："
    static func analyze(_ document: LyricsDocument, resources: URL? = nil) async throws -> LyricsAnalysis {
        let began = Date(), span = UUID()
        AppLog.shared.record(.analysis, .started, operation: .lyricsIndex, span: span)
        do {
            let worker = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let prepared = try LyricsParser.prepare(document)
                var chunks: [LyricsVectorChunk] = []
                if !prepared.chunks.isEmpty {
                    let engine = try BGEEngine(resources: resources)
                    for chunk in prepared.chunks {
                        try Task.checkCancellation()
                        chunks.append(LyricsVectorChunk(chunk: chunk, vector: try engine.encode(chunk.text)))
                    }
                }
                try Task.checkCancellation()
                return LyricsAnalysis(status: prepared.status, contentHash: prepared.contentHash, chunks: chunks, fetchedAt: document.fetchedAt)
            }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            AppLog.shared.record(.analysis, .succeeded, operation: .lyricsIndex, span: span, count: result.chunks.count, elapsed: Date().timeIntervalSince(began))
            return result
        } catch {
            AppLog.shared.record(.analysis, Task.isCancelled ? .cancelled : .failed, level: .warning, operation: .lyricsIndex, span: span, error: error)
            throw error
        }
    }
    static func query(_ text: String, resources: URL? = nil) async throws -> [Float] {
        guard text.count <= 512, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LyricsError.tooLong }
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try BGEEngine(resources: resources).encode(queryInstruction + text, allowTruncation: false)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

/// Graph and external weights stay together. One CPU thread and one chunk at a time.
final class BGEEngine {
    private let tokenizer: BGEWordPiece
    #if canImport(OnnxRuntimeBindings)
    private let environment: ORTEnv
    private let session: ORTSession
    #endif
    private static let hashes: [String: String] = ["model_quantized.onnx": "99a6e522710c00220c89f8c52e0cc5aa09d4cbb1c34c0e932eab3a9dfdc65df3", "model_quantized.onnx_data": "952623481ca8beea884e3d3c9ecaf8a3c7bf1d0c21de29e970cd31af9d37a90b", "tokenizer.json": "3d09c84ebd10306706a79a8276b3ab736a40d8ec03251c7639f4e52c3a1a4f8e"]
    init(resources: URL? = nil) throws {
        guard let folder = resources ?? Bundle.main.resourceURL?.appendingPathComponent("Semantics/Lyrics") else { throw LyricsError.model }
        for (file, hash) in Self.hashes {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(file), options: .mappedIfSafe),
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else { throw LyricsError.model }
        }
        tokenizer = try BGEWordPiece(data: Data(contentsOf: folder.appendingPathComponent("tokenizer.json")))
        #if canImport(OnnxRuntimeBindings)
        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        do { session = try ORTSession(env: environment, modelPath: folder.appendingPathComponent("model_quantized.onnx").path, sessionOptions: options) }
        catch { throw LyricsError.inference }
        guard Set(try session.inputNames()) == Set(["input_ids", "attention_mask", "token_type_ids"]),
              try session.outputNames().contains("last_hidden_state") else { throw LyricsError.incompatible }
        #else
        throw LyricsError.model
        #endif
    }
    func encode(_ text: String, allowTruncation: Bool = true) throws -> [Float] {
        try Task.checkCancellation()
        let ids = try tokenizer.encode(text, maxLength: allowTruncation ? 256 : 1024)
        guard ids.count <= 256 else { throw LyricsError.tooLong }
        #if canImport(OnnxRuntimeBindings)
        func tensor(_ values: [Int64]) throws -> ORTValue {
            let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
            return try ORTValue(tensorData: data, elementType: .int64, shape: [1, NSNumber(value: values.count)])
        }
        let input = try tensor(ids), mask = try tensor(Array(repeating: 1, count: ids.count)), types = try tensor(Array(repeating: 0, count: ids.count))
        let results: [String: ORTValue]
        do { results = try session.run(withInputs: ["input_ids": input, "attention_mask": mask, "token_type_ids": types], outputNames: ["last_hidden_state"], runOptions: nil) }
        catch { throw LyricsError.inference }
        try Task.checkCancellation()
        guard let result = results["last_hidden_state"] else { throw LyricsError.invalidVector }
        let info = try result.tensorTypeAndShapeInfo()
        guard info.elementType == .float, info.shape.map(\.intValue) == [1, ids.count, LyricsSpace.dimensions] else { throw LyricsError.invalidVector }
        let data = try result.tensorData() as Data
        guard data.count == ids.count * LyricsSpace.dimensions * 4 else { throw LyricsError.invalidVector }
        let vector = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(LyricsSpace.dimensions)) }
        return try LyricsMath.unit(vector)
        #else
        throw LyricsError.model
        #endif
    }
}
