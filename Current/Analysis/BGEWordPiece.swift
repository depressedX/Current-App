import Foundation

/// Exact subset of the pinned Hugging Face tokenizer: case-sensitive BERT + greedy WordPiece.
/// No lowercasing, accent stripping, or Chinese word segmentation is substituted.
struct BGEWordPiece {
    private let vocabulary: [String: Int]
    private static let special = ["[PAD]": 0, "[UNK]": 100, "[CLS]": 101, "[SEP]": 102, "[MASK]": 103]
    init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any], model["type"] as? String == "WordPiece",
              let vocabulary = model["vocab"] as? [String: Int], vocabulary.count == 21128,
              let normalizer = root["normalizer"] as? [String: Any], normalizer["type"] as? String == "BertNormalizer",
              normalizer["lowercase"] as? Bool == false,
              Self.special.allSatisfy({ vocabulary[$0.key] == $0.value }) else { throw LyricsError.incompatible }
        self.vocabulary = vocabulary
    }
    func encode(_ text: String, maxLength: Int = 256) throws -> [Int64] {
        guard text.utf8.count <= 32_768, maxLength >= 2 else { throw LyricsError.tooLong }
        let special = try! NSRegularExpression(pattern: #"\[PAD\]|\[UNK\]|\[CLS\]|\[SEP\]|\[MASK\]"#)
        let ns = text as NSString
        var tokens: [Int] = [], offset = 0
        for match in special.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            tokens += pieces(ns.substring(with: NSRange(location: offset, length: match.range.location - offset)))
            tokens.append(Self.special[ns.substring(with: match.range)]!)
            offset = match.range.location + match.range.length
        }
        tokens += pieces(ns.substring(from: offset))
        return [101] + tokens.prefix(maxLength - 2).map(Int64.init) + [102]
    }
    private func pieces(_ text: String) -> [Int] {
        var words: [[String]] = [], current: [String] = []
        func flush() { if !current.isEmpty { words.append(current); current.removeAll(keepingCapacity: true) } }
        for scalar in text.unicodeScalars {
            let n = scalar.value, category = scalar.properties.generalCategory
            if n == 0 || n == 0xfffd { continue }
            if [9, 10, 13, 32].contains(n) || category == .spaceSeparator { flush(); continue }
            if category == .control || category == .format { continue }
            if Self.isHan(n) || Self.isPunctuation(scalar) { flush(); words.append([String(scalar)]); continue }
            current.append(String(scalar))
        }
        flush()
        return words.flatMap { word -> [Int] in
            guard word.count <= 100 else { return [100] }
            var result: [Int] = [], start = 0
            while start < word.count {
                var end = word.count, found: Int?
                while end > start {
                    let candidate = (start == 0 ? "" : "##") + word[start..<end].joined()
                    if let id = vocabulary[candidate] { found = id; break }
                    end -= 1
                }
                guard let found else { return [100] }
                result.append(found); start = end
            }
            return result
        }
    }
    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let n = scalar.value
        if (33...47).contains(n) || (58...64).contains(n) || (91...96).contains(n) || (123...126).contains(n) { return true }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }
    private static func isHan(_ n: UInt32) -> Bool {
        [(0x4e00, 0x9fff), (0x3400, 0x4dbf), (0x20000, 0x2a6df), (0x2a700, 0x2b73f),
         (0x2b740, 0x2b81f), (0x2b820, 0x2ceaf), (0xf900, 0xfaff), (0x2f800, 0x2fa1f)]
            .contains { UInt32($0.0) <= n && n <= UInt32($0.1) }
    }
}
