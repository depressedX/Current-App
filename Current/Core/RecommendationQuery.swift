import Foundation

struct IntentConcept: Codable, Sendable {
    let id: String
    let label: String
    let definition: String
}

/// References keep the source's original vocabulary; they do not create a shared genre taxonomy.
struct GenreReference: Sendable {
    enum Source: String, Sendable { case audioStyle, audioFamily, encyclopedia, encyclopediaFamily }
    let source: Source
    let value: String
    var id: String { "\(source.rawValue):\(value)" }
    init(source: Source, value: String) { self.source = source; self.value = value }
    init?(id: String) {
        guard let colon = id.firstIndex(of: ":"), let source = Source(rawValue: String(id[..<colon])) else { return nil }
        let value = String(id[id.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        self.source = source; self.value = value
    }
    var concept: IntentConcept {
        let name = (source == .encyclopedia || source == .encyclopediaFamily) ? "网易云百科曲风" : "音频模型曲风"
        let label = source == .audioStyle ? value.replacingOccurrences(of: "---", with: " / ") : value
        let scope = source == .encyclopediaFamily || source == .audioFamily ? "一级分类，包含该分类及其全部子类。" : "具体标签，仅匹配该标签。"
        let hierarchy: String
        switch source {
        case .audioStyle:
            let family = value.components(separatedBy: "---")[0]
            hierarchy = "所属一级分类 ID：\(GenreReference(source: .audioFamily, value: family).id)。"
        case .encyclopedia:
            let genre = WikiGenre(value)
            let style = genre.style.map { "二级分类：\($0)。" } ?? "原始标签未提供二级分类。"
            hierarchy = "所属一级分类 ID：\(GenreReference(source: .encyclopediaFamily, value: genre.family).id)。" + style
        case .audioFamily, .encyclopediaFamily: hierarchy = ""
        }
        return IntentConcept(id: id, label: label, definition: "\(name)：\(scope)\(hierarchy)仅作为来源独立的匹配证据；不是已验证事实。")
    }
}

/// Parse only the first separator; keep any remaining hyphens in the style name.
struct WikiGenre: Equatable {
    let family: String
    let style: String?
    init(_ label: String) {
        let parts = label.split(separator: "-", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
            family = parts[0]; style = parts[1]
        } else {
            family = label.trimmingCharacters(in: .whitespacesAndNewlines); style = nil
        }
    }
    static func matches(_ selection: String, labels: Set<String>) -> Bool {
        let target = WikiGenre(selection)
        return labels.contains { label in
            let candidate = WikiGenre(label)
            return candidate.family == target.family && (target.style == nil || target.style == candidate.style)
        }
    }
}

struct GenreChoiceGroup: Identifiable {
    struct Option: Identifiable { let id: String; let title: String }
    let id: String
    let title: String
    let children: [Option]
    static func encyclopedia(_ labels: Set<String>) -> [Self] {
        let grouped = Dictionary(grouping: labels, by: { WikiGenre($0).family })
        return grouped.keys.sorted().map { family in
            Self(id: family,
                 title: family, children: (grouped[family] ?? []).sorted().compactMap { label in
                guard let style = WikiGenre(label).style else { return nil }
                return Option(id: label, title: style)
            })
        }
    }
}

/// Genre conditions use classifier evidence; mood/timbre conditions use audio/text similarity.
enum RecommendationGenre: String, CaseIterable, Sendable {
    case house, rock

    var mentionPattern: String {
        switch self {
        case .house: return #"(?i)((?<![a-z])house(?![a-z])|浩室|浩斯)"#
        case .rock: return #"(?i)((?<![a-z])rock(?![a-z])|摇滚)"#
        }
    }
}

struct RecommendationQuery: Codable, Sendable {
    enum Direction: String, Codable, Sendable { case prefer, avoid }
    enum Requirement: String, Codable, Sendable { case required, preferred }
    struct Preference: Codable, Sendable {
        let concept: String
        let direction: Direction
        let weight: Double
        var requirement: Requirement = .required
        var genre: RecommendationGenre? { RecommendationGenre(rawValue: concept) }
        var genreReference: GenreReference? { GenreReference(id: concept) }
        var isGenre: Bool { genre != nil || genreReference != nil }

        private enum CodingKeys: String, CodingKey { case concept, direction, weight, requirement }
        init(concept: String, direction: Direction, weight: Double, requirement: Requirement = .required) {
            self.concept = concept; self.direction = direction; self.weight = weight; self.requirement = requirement
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            concept = try values.decode(String.self, forKey: .concept)
            direction = try values.decode(Direction.self, forKey: .direction)
            weight = try values.decode(Double.self, forKey: .weight)
            // Older local history represented soft preferences. Network decoding requires the new field.
            requirement = try values.decodeIfPresent(Requirement.self, forKey: .requirement) ?? .preferred
        }

        /// Initial conservative retrieval threshold for this embedding model, not a probability.
        static let minimumSimilarity = 0.25
        func accepts(similarity: Double) -> Bool {
            guard similarity.isFinite, (-1...1).contains(similarity) else { return false }
            guard requirement == .required else { return true }
            return direction == .prefer ? similarity >= Self.minimumSimilarity : similarity < Self.minimumSimilarity
        }
    }
    let summary: String
    let bpmMinimum: Double?
    let bpmMaximum: Double?
    let bpmRequired: Bool
    let preferences: [Preference]
    let unsupported: [String]
    var bpmTarget: Double? = nil

    static func decode(_ data: Data, allowedConcepts: Set<String>) throws -> Self {
        guard data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["summary", "bpmMinimum", "bpmMaximum", "bpmTarget", "bpmRequired", "preferences", "unsupported"],
              let terms = object["preferences"] as? [[String: Any]],
              terms.allSatisfy({ Set($0.keys) == ["concept", "direction", "weight", "requirement"] && $0["requirement"] is String }) else { throw IntentResolutionFailure.invalidQuery }
        let query: Self
        do { query = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw IntentResolutionFailure.invalidQuery }
        return try query.validated(allowedConcepts: allowedConcepts)
    }

    func validated(allowedConcepts: Set<String>) throws -> Self {
        guard unsupported.isEmpty else { throw IntentResolutionFailure.unsupported }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, summary.count <= 160,
              preferences.count <= 64,
              Set(preferences.map(\.concept)).count == preferences.count,
              preferences.allSatisfy({ allowedConcepts.contains($0.concept) && $0.weight.isFinite && $0.weight > 0 && $0.weight <= 1 }),
              [bpmMinimum, bpmMaximum, bpmTarget].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1000 }),
              (bpmMinimum ?? 0) <= (bpmMaximum ?? 1000),
              !bpmRequired || bpmMinimum != nil || bpmMaximum != nil || bpmTarget != nil,
              !preferences.isEmpty || bpmMinimum != nil || bpmMaximum != nil || bpmTarget != nil else { throw IntentResolutionFailure.invalidQuery }
        return normalizedTempo
    }
    // Rendering stored conditions must not depend on a currently loaded concept catalog.
    private var normalizedTempo: Self {
        if let target = bpmTarget, target.isFinite, target > 0, target <= 1000, bpmMinimum == nil, bpmMaximum == nil {
            return Self(summary: summary, bpmMinimum: max(1, target - 10), bpmMaximum: min(1000, target + 10),
                        bpmRequired: bpmRequired, preferences: preferences, unsupported: unsupported, bpmTarget: target)
        }
        return self
    }
    func preservingExplicitBPM(in text: String) throws -> Self {
        let pattern = #"(?i)(\d+(?:\.\d+)?\s*bpm|bpm\s*\d+(?:\.\d+)?)"#
        if text.range(of: pattern, options: .regularExpression) != nil,
           bpmMinimum == nil, bpmMaximum == nil, bpmTarget == nil { throw IntentResolutionFailure.missingBPM }
        let rangePattern = #"\d+(?:\.\d+)?\s*(?:[-–—~～]|到|至)\s*\d+(?:\.\d+)?"#
        let approximatePattern = #"(?i)(?:大约|约|around\s*|about\s*|approximately\s*|roughly\s*)(?:bpm\s*)?\d+(?:\.\d+)?(?:\s*bpm)?|(?:\d+(?:\.\d+)?\s*bpm|bpm\s*\d+(?:\.\d+)?)\s*左右"#
        if text.range(of: rangePattern, options: .regularExpression) == nil,
           let expression = try? NSRegularExpression(pattern: pattern),
           expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) == 1,
           let approximate = text.range(of: approximatePattern, options: .regularExpression),
           let numeric = text[approximate].range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression),
           let target = Double(text[numeric]), target > 0, target <= 1000 {
            if let parsed = bpmTarget, parsed != target { throw IntentResolutionFailure.invalidQuery }
            return Self(summary: summary, bpmMinimum: max(1, target - 10), bpmMaximum: min(1000, target + 10),
                        bpmRequired: bpmRequired, preferences: preferences, unsupported: unsupported, bpmTarget: target)
        }
        return self
    }
    func preservingExplicitGenres(in text: String) throws -> Self {
        for genre in RecommendationGenre.allCases where text.range(of: genre.mentionPattern, options: .regularExpression) != nil {
            guard preferences.contains(where: {
                $0.genre == genre || $0.genreReference?.value.range(of: genre.mentionPattern, options: .regularExpression) != nil
            }) else { throw IntentResolutionFailure.missingGenre }
        }
        return self
    }
    func preservingExplicitConcepts(in text: String, concepts: [IntentConcept]) throws -> Self {
        let aliases: [String: [String]] = [
            "melancholic": ["伤感", "悲伤", "忧伤", "忧郁", "难过", "sad", "melancholy"],
            "cheerful": ["开心", "欢快", "轻快", "愉悦", "happy"],
            "mellow": ["放松", "轻柔", "温和", "relaxing"],
            "dreamy": ["梦幻"], "acoustic": ["原声"], "vocal": ["人声"]
        ]
        for concept in concepts where RecommendationGenre(rawValue: concept.id) == nil && GenreReference(id: concept.id) == nil {
            let words = [concept.id, concept.label] + (aliases[concept.id] ?? [])
            let mentioned = words.contains { word in
                let escaped = NSRegularExpression.escapedPattern(for: word)
                let pattern = word.allSatisfy(\.isASCII) ? "(?i)(?<![a-z])\(escaped)(?![a-z])" : escaped
                return text.range(of: pattern, options: .regularExpression) != nil
            }
            if mentioned && !preferences.contains(where: { $0.concept == concept.id }) { throw IntentResolutionFailure.missingConcept }
        }
        return self
    }
    func preservingRequiredConditions(in text: String) throws -> Self {
        let optionalPattern = #"(?i)(最好|优先|尽量|偏好|偏向|更喜欢|\bprefer(?:ably)?\b|\bideally\b|if possible)"#
        guard text.range(of: optionalPattern, options: .regularExpression) == nil else { return self }
        // Do not accept a model silently downgrading plain requirements to optional ranking hints.
        guard !preferences.contains(where: { $0.requirement == .preferred }) else { throw IntentResolutionFailure.invalidQuery }
        let numericBPM = text.range(of: #"(?i)(\d+(?:\.\d+)?\s*bpm|bpm\s*\d+(?:\.\d+)?)"#, options: .regularExpression) != nil
        guard !numericBPM || bpmRequired else { throw IntentResolutionFailure.invalidQuery }
        return self
    }
    var hasGenreConditions: Bool { preferences.contains { $0.isGenre } }
    func bpmPreference(_ bpm: Double?) -> Double {
        guard let bpm, bpm.isFinite, bpm > 0 else { return 0 }
        if let target = bpmTarget {
            // A smooth preference, not an invented hard range. 10% controls the falloff.
            let distance = (bpm - target) / max(1, target * 0.1)
            return 0.5 * exp(-0.5 * distance * distance)
        }
        return !bpmRequired && (bpmMinimum != nil || bpmMaximum != nil) && matchesBPM(bpm) ? 0.25 : 0
    }
    func displaySummary(concepts: [IntentConcept]) -> String {
        var parts: [String] = []
        let minimum = normalizedTempo.bpmMinimum, maximum = normalizedTempo.bpmMaximum
        if let target = bpmTarget { parts.append("目标 \(target.formatted(.number.precision(.fractionLength(0...1)))) BPM") }
        if minimum != nil || maximum != nil {
            let bounds = minimum.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "不限"
            let upper = maximum.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "不限"
            parts.append("\(bpmRequired ? "" : "优先 ")\(bounds)–\(upper) BPM")
        }
        parts += preferences.filter { !$0.isGenre }.compactMap { term in
            concepts.first(where: { $0.id == term.concept }).map {
                let prefix = term.direction == .avoid ? (term.requirement == .required ? "排除" : "减少") : (term.requirement == .preferred ? "优先" : "")
                return "\(prefix)\($0.label)\(term.genre == nil ? "" : "曲风")"
            }
        }
        let groups: [(Direction, Requirement, String)] = [
            (.prefer, .required, "曲风（任一命中）"), (.avoid, .required, "排除曲风（任一命中）"),
            (.prefer, .preferred, "优先曲风"), (.avoid, .preferred, "减少曲风")
        ]
        for (direction, requirement, title) in groups {
            let values = preferences.filter { $0.isGenre && $0.direction == direction && $0.requirement == requirement }.map { term in
                let label = concepts.first(where: { $0.id == term.concept })?.label ?? term.genreReference?.concept.label ?? term.concept
                let source = [.encyclopedia, .encyclopediaFamily].contains(term.genreReference?.source) ? "百科" : "音频"
                return "\(source)：\(label)"
            }
            if !values.isEmpty { parts.append(title + "：" + values.joined(separator: " / ")) }
        }
        return parts.joined(separator: " · ")
    }
    func matchesBPM(_ bpm: Double?) -> Bool {
        guard bpmMinimum != nil || bpmMaximum != nil else { return true }
        guard let bpm, bpm.isFinite else { return false }
        return bpm >= (bpmMinimum ?? 0) && bpm <= (bpmMaximum ?? .infinity)
    }
}

enum IntentResolutionFailure: String, LocalizedError, Sendable {
    case missingKey, keychain, unavailable, invalidQuery, unsupported, rejected, rateLimited, network, service, missingBPM, missingGenre, missingConcept, incomplete
    var errorDescription: String? {
        switch self {
        case .missingKey: return "请先在我的 → AI 设置填写个人 DeepSeek Key。"
        case .keychain: return "无法访问或保存 Keychain，请重试。"
        case .unavailable: return "当前构建未包含 AI 请求 SDK。"
        case .invalidQuery: return "模型未返回有效的推荐条件，请重试或换一种表达。"
        case .missingBPM: return "模型遗漏了你指定的 BPM 条件，请重试；本次没有生成歌单。"
        case .missingGenre: return "模型遗漏了你指定的曲风条件，请重试；本次没有生成歌单。"
        case .missingConcept: return "模型遗漏了你指定的听感条件，请重试；本次没有生成歌单。"
        case .incomplete: return "模型返回的推荐条件不完整，请重试。"
        case .unsupported: return "需求包含当前尚不支持的条件，请简化后重试。"
        case .rejected: return "DeepSeek Key 无效、余额不足或没有调用权限，请在 AI 设置中更新。"
        case .rateLimited: return "API 调用次数受限，请稍后重试。"
        case .network: return "无法连接 DeepSeek，请检查网络后重试。"
        case .service: return "DeepSeek 暂时无法完成请求，请稍后重试。"
        }
    }
}

// Compatibility for internal OpenRouter regression checks.
typealias OpenRouterFailure = IntentResolutionFailure
