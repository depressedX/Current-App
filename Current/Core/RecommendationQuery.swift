import Foundation

struct IntentConcept: Codable, Sendable {
    let id: String
    let label: String
    let definition: String
}

struct RecommendationQuery: Codable, Sendable {
    enum Direction: String, Codable, Sendable { case prefer, avoid }
    struct Preference: Codable, Sendable {
        let concept: String
        let direction: Direction
        let weight: Double
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
              terms.allSatisfy({ Set($0.keys) == ["concept", "direction", "weight"] }) else { throw OpenRouterFailure.invalidQuery }
        let query: Self
        do { query = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw OpenRouterFailure.invalidQuery }
        return try query.validated(allowedConcepts: allowedConcepts)
    }

    func validated(allowedConcepts: Set<String>) throws -> Self {
        guard unsupported.isEmpty else { throw OpenRouterFailure.unsupported }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, summary.count <= 160,
              preferences.count <= 16,
              Set(preferences.map(\.concept)).count == preferences.count,
              preferences.allSatisfy({ allowedConcepts.contains($0.concept) && $0.weight.isFinite && $0.weight > 0 && $0.weight <= 1 }),
              [bpmMinimum, bpmMaximum, bpmTarget].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1000 }),
              (bpmMinimum ?? 0) <= (bpmMaximum ?? 1000),
              !bpmRequired || bpmMinimum != nil || bpmMaximum != nil,
              !preferences.isEmpty || bpmMinimum != nil || bpmMaximum != nil || bpmTarget != nil else { throw OpenRouterFailure.invalidQuery }
        return self
    }
    func preservingExplicitBPM(in text: String) throws -> Self {
        let pattern = #"(?i)(\d+(?:\.\d+)?\s*bpm|bpm\s*\d+(?:\.\d+)?)"#
        if text.range(of: pattern, options: .regularExpression) != nil,
           bpmMinimum == nil, bpmMaximum == nil, bpmTarget == nil { throw OpenRouterFailure.missingBPM }
        return self
    }
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
        if let target = bpmTarget { parts.append("约 \(target.formatted(.number.precision(.fractionLength(0...1)))) BPM") }
        if bpmMinimum != nil || bpmMaximum != nil {
            let bounds = bpmMinimum.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "不限"
            let upper = bpmMaximum.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "不限"
            parts.append("\(bpmRequired ? "" : "优先 ")\(bounds)–\(upper) BPM")
        }
        parts += preferences.compactMap { term in
            concepts.first(where: { $0.id == term.concept }).map { "\(term.direction == .avoid ? "减少" : "")\($0.label)" }
        }
        return parts.joined(separator: " · ")
    }
    func matchesBPM(_ bpm: Double?) -> Bool {
        guard bpmMinimum != nil || bpmMaximum != nil else { return true }
        guard let bpm, bpm.isFinite else { return false }
        return bpm >= (bpmMinimum ?? 0) && bpm <= (bpmMaximum ?? .infinity)
    }
}

enum OpenRouterFailure: String, LocalizedError, Sendable {
    case missingKey, keychain, unavailable, invalidQuery, unsupported, rejected, rateLimited, network, service, missingBPM, incomplete
    var errorDescription: String? {
        switch self {
        case .missingKey: return "请先在我的 → AI 设置填写个人 OpenRouter Key。"
        case .keychain: return "无法访问或保存 Keychain，请重试。"
        case .unavailable: return "当前构建未包含 OpenRouter SDK。"
        case .invalidQuery: return "模型未返回有效的推荐条件，请重试或换一种表达。"
        case .missingBPM: return "模型遗漏了你指定的 BPM 条件，请重试；本次没有生成歌单。"
        case .incomplete: return "模型返回的推荐条件不完整，请重试。"
        case .unsupported: return "需求包含当前尚不支持的条件，请简化后重试。"
        case .rejected: return "OpenRouter Key 无效或没有调用权限，请在 AI 设置中更新。"
        case .rateLimited: return "免费模型调用次数受限，请稍后重试。"
        case .network: return "无法连接 OpenRouter，请检查网络后重试。"
        case .service: return "OpenRouter 暂时无法完成请求，请稍后重试。"
        }
    }
}
