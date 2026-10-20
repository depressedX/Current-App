import Foundation
import Darwin

@main struct SemanticChecks {
    static func main() async throws {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let initialPeak = usage.ru_maxrss
        defer {
            getrusage(RUSAGE_SELF, &usage)
            print("HOST high-water RSS MiB", Double(initialPeak) / 1048576, "→", Double(usage.ru_maxrss) / 1048576, "(not iPhone)")
        }
        let args = CommandLine.arguments
        let catalog = try ConceptCatalog.load(url: URL(fileURLWithPath: args[1]))
        guard catalog.concepts.count >= 12 else { fatalError("Concept catalog incomplete") }
        let anchor = catalog.concepts[0]
        let matches = try catalog.matches(anchor.vector)
        precondition(matches.first?.id == anchor.id && abs(matches[0].similarity - 1) < 1e-5)
        for invalid in [[Float](), [Float](repeating: 0, count: 512), [Float](repeating: .nan, count: 512)] {
            do { _ = try EmbeddingMath.unit(invalid); fatalError("Invalid vector accepted") } catch SemanticError.invalidVector {}
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let disk = SemanticDisk(directory: temp), songID = UUID()
        let features = try await disk.save(SemanticAnalysis(vector: anchor.vector, windowStarts: [0,5,10], elapsedSeconds: 1), songID: songID, account: "account-a", catalog: catalog)
        let loaded = try await disk.load(features, songID: songID, account: "account-a")
        let storedCosine = try EmbeddingMath.cosine(loaded, anchor.vector)
        precondition(storedCosine > 0.99999)
        do { _ = try await disk.load(features, songID: songID, account: "account-b"); fatalError("Cross-account read") } catch SemanticError.incompatible {}
        do { _ = try await disk.load(features, songID: UUID(), account: "account-a"); fatalError("Wrong-song read") } catch SemanticError.incompatible {}
        let incompatible = SemanticFeatures(recordID: features.recordID, spaceID: "old-space", catalogVersion: features.catalogVersion,
                                            matches: [], windowStarts: [], windowSeconds: 10, elapsedSeconds: 0, analyzedAt: Date())
        do { _ = try await disk.load(incompatible, songID: songID, account: "account-a"); fatalError("Stale model accepted") } catch SemanticError.incompatible {}
        try Data("corrupt".utf8).write(to: temp.appendingPathComponent(features.recordID.uuidString).appendingPathExtension("json"))
        do { _ = try await disk.load(features, songID: songID, account: "account-a"); fatalError("Corruption accepted") } catch SemanticError.storage {}
        print("PASS semantic vectors, ranking, scoped storage, version and corruption guards")
        if args.count > 2 {
            let cache = URL(fileURLWithPath: args[2])
            func floats(_ name: String) throws -> [Float] {
                try Data(contentsOf: cache.appendingPathComponent(name)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
            let frontend = try DCLAPFrontend()
            let got = try frontend.mel(samples: floats("reference-audio.f32"))
            let reference = try floats("reference-mel.f32")
            precondition(got.count == reference.count)
            let differences = zip(got,reference).map { abs($0 - $1) }
            let maximum = differences.max()!, mean = differences.reduce(0,+)/Float(differences.count)
            print("FRONTEND max dB error",maximum,"mean",mean)
            precondition(maximum < 0.015 && mean < 0.001, "Frontend differs from librosa")
            if args.count > 3 {
                let began = Date()
                let engine = try DCLAPEngine(modelURL: URL(fileURLWithPath: args[3]))
                let native = try engine.embedding(mel: got)
                let expected = try JSONDecoder().decode([Float].self, from: Data(contentsOf: cache.appendingPathComponent("reference-embedding.json")))
                let similarity = try EmbeddingMath.cosine(native, expected)
                print("INFERENCE cosine",similarity,"seconds",Date().timeIntervalSince(began))
                precondition(similarity > 0.9999, "Native inference differs from Python ORT")
                if args.count > 4 {
                    let file = URL(fileURLWithPath: args[4])
                    let result = try await DCLAPAnalyzer.analyze(url: file, modelURL: URL(fileURLWithPath: args[3]))
                    precondition(result.vector.count == 512 && result.windowStarts.count <= 9)
                    let top = try catalog.matches(result.vector, limit: 3)
                    print("REAL AUDIO",result.windowStarts.count,"windows",result.elapsedSeconds,"seconds;",top.map { "\($0.label):\($0.similarity)" })
                    let cancelled = Task { try await DCLAPAnalyzer.analyze(url: file, modelURL: URL(fileURLWithPath: args[3])) }
                    try await Task.sleep(for: .milliseconds(50)); cancelled.cancel()
                    do { _ = try await cancelled.value; fatalError("Cancelled analysis committed") } catch is CancellationError {}
                    print("PASS native decode, serial-window inference and cancellation")
                }
            }
        }
    }
}
