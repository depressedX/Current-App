import Foundation

@main struct LyricsChecks {
    struct Reference: Decodable { let text: String; let ids: [Int64]; let vector: [Float] }
    static func main() async throws {
        let args = CommandLine.arguments
        let resources = URL(fileURLWithPath: args[1]), reference = URL(fileURLWithPath: args[2])
        let tokenizer = try BGEWordPiece(data: Data(contentsOf: resources.appendingPathComponent("tokenizer.json")))
        let rows = try JSONDecoder().decode([Reference].self, from: Data(contentsOf: reference.appendingPathComponent("reference.json")))
        for row in rows {
            let ids = try tokenizer.encode(row.text)
            if ids != row.ids { print("TOKENIZER MISMATCH", row.text.prefix(30), ids.prefix(30), row.ids.prefix(30), ids.count, row.ids.count); fflush(stdout) }
            precondition(ids == row.ids, "Tokenizer differs for synthetic input: \(row.text.prefix(15))")
        }
        print("PASS native case-sensitive WordPiece parity: Chinese, Latin, accents, controls, emoji, special tokens, 256-token truncation")
        fflush(stdout)
        let now = Date()
        let document = LyricsDocument(songID: 42,
            original: "[00:00.00]作词：测试人员\n[00:01.50]我们走过山川\n[00:04.00]毕业之后各奔东西\n[00:07.00]多年以后再相聚\n[00:10.00]今晚道声晚安",
            translation: "", fetchedAt: now)
        let prepared = try LyricsParser.prepare(document)
        precondition(prepared.status == .indexed && prepared.chunks.count == 2)
        precondition(prepared.chunks[0].lines[0].second == 1.5 && !prepared.chunks[0].text.contains("测试人员"))
        let translated = try LyricsParser.prepare(LyricsDocument(songID: 1, original: "[00:01]今日はお別れです", translation: "[00:01]今天我们将要告别", fetchedAt: now))
        precondition(translated.chunks.count == 1 && translated.chunks[0].source == .translation)
        let empty = try LyricsParser.prepare(LyricsDocument(songID: 1, original: "[00:00]纯音乐，请欣赏", translation: "", fetchedAt: now))
        let english = try LyricsParser.prepare(LyricsDocument(songID: 1, original: "[00:01]This is an English sentence", translation: "", fetchedAt: now))
        precondition(empty.status == .noUsableText && english.status == .noChineseText)
        let repeated = try LyricsParser.prepare(document)
        precondition(prepared.contentHash == repeated.contentHash)
        print("PASS LRC times, credits removal, Chinese source/translation, missing vs unsupported, deterministic content hash")
        fflush(stdout)
        let engine = try BGEEngine(resources: resources)
        var lowest = 1.0
        for row in rows {
            let vector = try engine.encode(row.text)
            let similarity = zip(vector, row.vector).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            lowest = min(lowest, similarity)
            precondition(similarity > 0.999, "Native ONNX vectors differ from Python: \(similarity)")
        }
        print("PASS real ORT 1.24.2 INT8 / external weights / CLS parity, minimum cosine", lowest)
        fflush(stdout)
        let cancelled = Task { try await LyricsAnalyzer.analyze(document, resources: resources) }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("cancelled index published") } catch is CancellationError { }
        let result = try await LyricsAnalyzer.analyze(document, resources: resources)
        precondition(result.status == .indexed && result.chunks.count == 2)
        do { _ = try await LyricsAnalyzer.query(String(repeating: "告别", count: 180), resources: resources); fatalError("Long query silently truncated") } catch LyricsError.tooLong { }
        let query = try await LyricsAnalyzer.query("毕业告别", resources: resources)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = LyricsDisk(directory: folder), songID = UUID()
        let summary = try await disk.save(result, songID: songID, account: "a")
        let saved = try await disk.load(summary, songID: songID, account: "a")
        precondition(saved.chunks.count == 2 && saved.chunks[0].chunk.lines == result.chunks[0].chunk.lines)
        do { _ = try await disk.load(summary, songID: songID, account: "b"); fatalError("cross-account record accepted") } catch LyricsError.incompatible { }
        do { _ = try await disk.load(summary, songID: UUID(), account: "a"); fatalError("cross-song record accepted") } catch LyricsError.incompatible { }
        let track = Track(id: 42, title: "Synthetic", artist: "Test", album: "", artwork: nil, duration: 12, demoIndex: nil)
        let matched = try await disk.search(query, entries: [LyricsSearchEntry(songID: songID, track: track, summary: summary)], account: "a")
        precondition(matched.matches.count == 1 && matched.matches[0].source == .original)
        try Data("corrupt".utf8).write(to: folder.appendingPathComponent(summary.recordID!.uuidString).appendingPathExtension("json"))
        let corrupt = try await disk.search(query, entries: [LyricsSearchEntry(songID: songID, track: track, summary: summary)], account: "a")
        precondition(corrupt.matches.isEmpty && corrupt.unavailableCount == 1)
        let absent = try await disk.save(LyricsAnalysis(status: .noUsableText, contentHash: empty.contentHash, chunks: [], fetchedAt: now), songID: UUID(), account: "a")
        precondition(absent.recordID == nil && absent.chunkCount == 0 && absent.status == .noUsableText)
        print("PASS model pipeline cancellation, immutable persistence, scope isolation, retrieval, corruption handling, explicit missing lyrics")
        if args.count > 3 {
            struct Source: Decodable { let id: Int; let title: String; let artist: String; let original: String; let translation: String }
            let corpus = URL(fileURLWithPath: args[3])
            let corpusDisk = LyricsDisk(directory: folder.appendingPathComponent("corpus"))
            var entries: [LyricsSearchEntry] = [], chunkCount = 0
            for file in try FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where Int(file.deletingPathExtension().lastPathComponent) != nil {
                let source = try JSONDecoder().decode(Source.self, from: Data(contentsOf: file))
                let document = LyricsDocument(songID: source.id, original: source.original, translation: source.translation, fetchedAt: now)
                let result = try await LyricsAnalyzer.analyze(document, resources: resources)
                guard result.status == .indexed else { continue }
                let id = UUID(), summary = try await corpusDisk.save(result, songID: id, account: "corpus")
                chunkCount += result.chunks.count
                let track = Track(id: source.id, title: source.title, artist: source.artist, album: "", artwork: nil, duration: 0, demoIndex: nil)
                entries.append(LyricsSearchEntry(songID: id, track: track, summary: summary))
            }
            let query = try await LyricsAnalyzer.query("分别、离别", resources: resources)
            let result = try await corpusDisk.search(query, entries: entries, account: "corpus")
            print("CORPUS PARITY", entries.count, "songs", chunkCount, "chunks", result.matches.prefix(3).map { ($0.track.id, $0.source.rawValue, $0.similarity) })
            precondition(entries.count == 8 && chunkCount == 164)
            precondition(result.matches.prefix(2).map(\.track.id) == [209216, 22780059])
            print("PASS production Swift matches the reviewed corpus preprocessing and top two lyric results")
        }
        print("ALL LYRICS CHECKS PASSED")
    }
}
