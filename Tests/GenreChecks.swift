import Foundation
import Darwin

@main struct GenreChecks {
    static func main() async throws {
        let args = CommandLine.arguments
        let resources = URL(fileURLWithPath: args[1]), reference = URL(fileURLWithPath: args[2])
        func floats(_ name: String) throws -> [Float] {
            try Data(contentsOf: reference.appendingPathComponent(name)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let samples = try floats("pcm.f32"), mel = try floats("mel.f32")
        var patches: [[Float]] = []
        let stream = try GenrePatchStream { patches.append($0) }
        // Deliberately cross frame boundaries and audio-buffer boundaries.
        for start in stride(from: 0, to: samples.count, by: 733) {
            try Array(samples[start..<min(samples.count, start + 733)]).withUnsafeBufferPointer { try stream.append($0) }
        }
        try stream.finish()
        let referenceFrames = mel.count / 96
        let expectedCount = (referenceFrames - 128) / 62 + 1
        print("PATCH COUNT", patches.count, expectedCount); fflush(stdout)
        precondition(patches.count == expectedCount, "Patch count differs: \(patches.count) vs \(expectedCount)")
        var maxError: Float = 0, sumError: Float = 0, count = 0
        for (index, patch) in patches.enumerated() {
            let expected = mel[(index * 62 * 96)..<(index * 62 * 96 + 128 * 96)]
            for (a,b) in zip(patch, expected) { let d = abs(a-b); maxError = max(maxError,d); sumError += d; count += 1 }
        }
        print("Frontend parity max", maxError, "mean", sumError / Float(count), "patches", patches.count)
        fflush(stdout)
        precondition(maxError < 0.006 && sumError / Float(count) < 0.001, "Frontend differs from official Essentia")
        let labels = try JSONDecoder().decode([String].self, from: Data(contentsOf: resources.appendingPathComponent("labels.json")))
        var synthetic = [Double](repeating: 0, count: 400)
        let post = labels.firstIndex(of: "Rock---Post Rock")!, indie = labels.firstIndex(of: "Rock---Indie Rock")!
        synthetic[post] = 0.8; synthetic[indie] = 0.7
        let summary = try GenreAnalysis.summarize(scores: synthetic, labels: labels, windows: 2, duration: 5)
        precondition(summary.matches.count == 5 && summary.matches[0].style == "Post Rock" && summary.matches[1].style == "Indie Rock")
        let decoded = try JSONDecoder().decode(GenreAnalysis.self, from: JSONEncoder().encode(summary))
        precondition(decoded == summary && summary.matches[0].title == "后摇")
        synthetic[post] = .nan
        do { _ = try GenreAnalysis.summarize(scores: synthetic, labels: labels, windows: 1, duration: 5); fatalError("NaN accepted") }
        catch GenreError.invalidOutput {}
        print("PASS multi-label ranking, independent scores, translation, persistence, invalid output guard")
        #if canImport(OnnxRuntimeBindings)
        let engine = try GenreEngine(model: resources.appendingPathComponent("discogs-effnet.onnx"))
        var scores = [Double](repeating: 0, count: 400)
        for patch in patches {
            let result = try engine.predict(patch)
            for i in scores.indices { scores[i] += Double(result[i]) / Double(patches.count) }
        }
        let expected = try JSONDecoder().decode([Double].self, from: Data(contentsOf: reference.appendingPathComponent("scores.json")))
        let error = zip(scores,expected).map { abs($0-$1) }.max()!
        print("Native ONNX parity max", error)
        precondition(error < 0.001)
        let result = try await GenreAnalyzer.analyze(url: reference.appendingPathComponent("reference.wav"), resources: resources)
        precondition(result.windows == expectedCount && abs(result.duration - 5) < 0.001)
        for match in result.matches { precondition(abs(match.score - expected[match.index]) < 0.001) }
        let cancelled = Task { try await GenreAnalyzer.analyze(url: reference.appendingPathComponent("reference.wav"), resources: resources) }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled analysis completed") } catch is CancellationError {}
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("invalid".utf8).write(to: bad); defer { try? FileManager.default.removeItem(at: bad) }
        do { _ = try GenreEngine(model: bad); fatalError("Corrupt model accepted") } catch GenreError.missingModel {}
        print("PASS production file decode, full pipeline parity, cancellation and model integrity")
        #endif
    }
}
