import Foundation

final class RouterTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [OpenRouterDiagnostic] = []
    func append(_ value: OpenRouterDiagnostic) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var entries: [OpenRouterDiagnostic] { lock.lock(); defer { lock.unlock() }; return values }
}

final class RouterHTTP: URLProtocol {
    static var handler: (URLRequest) throws -> (Int, Data) = { _ in throw URLError(.badServerResponse) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                               httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct OpenRouterChecks {
    static func requestBody(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { fatalError("missing request body") }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            precondition(count >= 0)
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    static func response(_ query: [String: Any], finish: String = "stop") throws -> Data {
        let content = String(decoding: try JSONSerialization.data(withJSONObject: query), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["id": "fixture", "created": 1, "object": "chat.completion",
            "model": "fixture/free", "choices": [["index": 0, "finish_reason": finish,
                "message": ["role": "assistant", "content": content]]]])
    }
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouterHTTP.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let trace = RouterTrace()
        let resolver = OpenRouterIntentResolver(session: session, key: { "fixture-only-key" }, diagnostics: { trace.append($0) })
        let concepts = [IntentConcept(id: "romantic", label: "浪漫", definition: "亲密温暖"),
                        IntentConcept(id: "energetic", label: "激烈", definition: "强烈推进感"),
                        IntentConcept(id: "house", label: "House", definition: "House 节奏"),
                        IntentConcept(id: "melancholic", label: "阴郁", definition: "伤感低落")]
        var query: [String: Any] = ["summary": "100–120 BPM，浪漫，别太激烈", "bpmMinimum": 100, "bpmMaximum": 120,
            "bpmTarget": NSNull(), "bpmRequired": true, "preferences": [["concept": "romantic", "direction": "prefer", "weight": 1, "requirement": "required"],
                ["concept": "energetic", "direction": "avoid", "weight": 0.6, "requirement": "required"]], "unsupported": []]
        let good = try response(query)
        var requests = 0
        RouterHTTP.handler = { request in
            requests += 1
            precondition(request.url?.scheme == "https" && request.url?.host == "openrouter.ai")
            precondition(request.url?.path == "/api/v1/chat/completions")
            precondition(request.url?.port == nil || request.url?.port == 443)
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only-key")
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            precondition(body["model"] as? String == "openrouter/free")
            precondition((body["provider"] as? [String: Bool])?["require_parameters"] == true)
            let format = body["response_format"] as! [String: Any]
            precondition(format["type"] as? String == "json_schema")
            precondition((format["json_schema"] as? [String: Any])?["strict"] as? Bool == true)
            precondition(body["stream"] as? Bool != true)
            return (200, good)
        }
        let parsed = try await resolver.resolve(text: "BPM 100–120，浪漫，别太激烈", concepts: concepts)
        precondition(parsed.matchesBPM(100) && parsed.matchesBPM(120) && !parsed.matchesBPM(99) && !parsed.matchesBPM(nil))
        precondition(parsed.preferences[1].direction == .avoid && requests == 1)
        precondition(trace.entries.map(\.event) == [.started, .response, .succeeded])
        precondition(trace.entries[1].status == 200 && Set(trace.entries.map(\.span)).count == 1)
        print("PASS actual MacPaw SDK: URL, authorization, free model, provider routing, strict schema and query decoding")
        for status in [401, 402, 403, 429, 503] {
            RouterHTTP.handler = { _ in (status, Data("{\"error\":{\"code\":\(status),\"message\":\"private provider message\"}}".utf8)) }
            do { _ = try await resolver.resolve(text: "浪漫", concepts: concepts); fatalError("status accepted") }
            catch let error as OpenRouterFailure {
                precondition(error.localizedDescription == OpenRouterIntentResolver.failure(status: status).localizedDescription)
                precondition(!error.localizedDescription.contains("private"))
            }
        }
        print("PASS numeric OpenRouter errors: 401/402/403, 429, 503; provider response is never exposed")
        let badQueries: [[String: Any]] = [
            query.merging(["artist": "not represented"]) { _, new in new },
            query.filter { $0.key != "bpmMinimum" },
            query.merging(["bpmMinimum": 130]) { _, new in new },
            query.merging(["preferences": [["concept": "invented", "direction": "prefer", "weight": 1, "requirement": "required"]]]) { _, new in new },
            query.merging(["preferences": [["concept": "romantic", "direction": "prefer", "weight": 2, "requirement": "required"]]]) { _, new in new },
            query.merging(["unsupported": ["必须纯音乐"]]) { _, new in new }
        ]
        for invalid in badQueries {
            let data = try response(invalid)
            RouterHTTP.handler = { _ in (200, data) }
            do { _ = try await resolver.resolve(text: "fixture", concepts: concepts); fatalError("invalid query accepted") }
            catch is OpenRouterFailure {}
        }
        let truncated = try response(query, finish: "length")
        RouterHTTP.handler = { _ in (200, truncated) }
        do { _ = try await resolver.resolve(text: "fixture", concepts: concepts); fatalError("truncated response accepted") }
        catch OpenRouterFailure.incomplete {}
        query["bpmMinimum"] = NSNull(); query["bpmMaximum"] = NSNull()
        query["bpmRequired"] = false
        let nullable = try response(query)
        RouterHTTP.handler = { _ in (200, nullable) }
        let unbounded = try await resolver.resolve(text: "浪漫", concepts: concepts)
        precondition(unbounded.matchesBPM(nil))
        do { _ = try await resolver.resolve(text: "100bpm左右的house", concepts: concepts); fatalError("explicit BPM was silently dropped") }
        catch OpenRouterFailure.missingBPM {}
        precondition(trace.entries.last?.failure == .missingBPM)
        query["bpmTarget"] = 100
        query["bpmRequired"] = true
        query["preferences"] = [["concept": "house", "direction": "prefer", "weight": 1, "requirement": "required"]]
        let approximate = try response(query)
        RouterHTTP.handler = { _ in (200, approximate) }
        for prompt in ["100bpm左右的house", "约100 BPM的House", "House around 100 BPM"] {
            let result = try await resolver.resolve(text: prompt, concepts: concepts)
            precondition(result.bpmTarget == 100 && result.bpmMinimum == 90 && result.bpmMaximum == 110 && result.bpmRequired)
            precondition(result.bpmPreference(100) > result.bpmPreference(110) && result.bpmPreference(110) > result.bpmPreference(130))
            precondition(result.bpmPreference(nil) == 0 && result.displaySummary(concepts: concepts).contains("100"))
        }
        print("PASS screenshot regression: approximate 100 BPM retained, visible ±10 range, proximity ranking, omitted BPM rejected and safe request traces")
        // A generic mood/electronic response must not silently replace a requested genre.
        query["bpmTarget"] = NSNull()
        query["bpmRequired"] = false
        query["preferences"] = [["concept": "energetic", "direction": "prefer", "weight": 1, "requirement": "required"]]
        let omittedGenre = try response(query)
        RouterHTTP.handler = { _ in (200, omittedGenre) }
        for prompt in ["house音乐", "HOUSE 音乐", "浩室音乐", "摇滚音乐", "不要 House，轻快一点"] {
            do { _ = try await resolver.resolve(text: prompt, concepts: concepts); fatalError("explicit genre dropped") }
            catch OpenRouterFailure.missingGenre {}
        }
        precondition(trace.entries.last?.failure == .missingGenre)
        _ = try await resolver.resolve(text: "warehouse", concepts: concepts) // Not the word House.
        query["preferences"] = [["concept": "house", "direction": "prefer", "weight": 1, "requirement": "required"]]
        let houseResponse = try response(query)
        RouterHTTP.handler = { _ in (200, houseResponse) }
        let house = try await resolver.resolve(text: "house音乐", concepts: concepts)
        precondition(house.hasGenreConditions && house.displaySummary(concepts: concepts).contains("音频：House"))
        query["preferences"] = [["concept": "house", "direction": "avoid", "weight": 1, "requirement": "required"]]
        let noHouse = try response(query)
        RouterHTTP.handler = { _ in (200, noHouse) }
        let excluded = try await resolver.resolve(text: "不要 House", concepts: concepts)
        precondition(excluded.preferences[0].direction == .avoid && excluded.displaySummary(concepts: concepts).contains("排除曲风（任一命中）：音频：House"))
        print("PASS explicit genre omission rejected; House case/Chinese aliases, exclusions and word boundaries")
        query["bpmTarget"] = 120; query["bpmRequired"] = true
        query["preferences"] = [["concept": "house", "direction": "prefer", "weight": 1, "requirement": "required"],
                                ["concept": "melancholic", "direction": "prefer", "weight": 1, "requirement": "required"]]
        let combinedResponse = try response(query)
        RouterHTTP.handler = { _ in (200, combinedResponse) }
        let combined = try await resolver.resolve(text: "伤感的120bpm左右的house歌曲", concepts: concepts)
        precondition(combined.bpmMinimum == 110 && combined.bpmMaximum == 130 && combined.bpmRequired)
        precondition(combined.preferences.allSatisfy { $0.requirement == .required })
        precondition(combined.displaySummary(concepts: concepts).contains("110–130 BPM"))
        precondition(!combined.matchesBPM(109) && !combined.matchesBPM(131) && !combined.matchesBPM(nil))
        query["bpmMinimum"] = 100; query["bpmMaximum"] = 150
        let arbitraryBounds = try response(query)
        RouterHTTP.handler = { _ in (200, arbitraryBounds) }
        let fixedTolerance = try await resolver.resolve(text: "伤感的120bpm左右的house", concepts: concepts)
        precondition(fixedTolerance.bpmMinimum == 110 && fixedTolerance.bpmMaximum == 130)
        let explicitBounds = try await resolver.resolve(text: "伤感的100–150bpm的house", concepts: concepts)
        precondition(explicitBounds.bpmMinimum == 100 && explicitBounds.bpmMaximum == 150)
        query["bpmMinimum"] = NSNull(); query["bpmMaximum"] = NSNull(); query["bpmTarget"] = 100
        let wrongTarget = try response(query)
        RouterHTTP.handler = { _ in (200, wrongTarget) }
        do { _ = try await resolver.resolve(text: "伤感的120bpm左右的house", concepts: concepts); fatalError("target changed") }
        catch OpenRouterFailure.invalidQuery {}
        query["bpmTarget"] = 120
        query["preferences"] = [["concept": "house", "direction": "prefer", "weight": 1, "requirement": "required"]]
        let noMoodResponse = try response(query)
        RouterHTTP.handler = { _ in (200, noMoodResponse) }
        do { _ = try await resolver.resolve(text: "伤感的120bpm左右的house", concepts: concepts); fatalError("mood omitted") }
        catch OpenRouterFailure.missingConcept {}
        query["preferences"] = [["concept": "house", "direction": "prefer", "weight": 1, "requirement": "required"],
                                ["concept": "melancholic", "direction": "prefer", "weight": 1, "requirement": "preferred"]]
        let weakened = try response(query)
        RouterHTTP.handler = { _ in (200, weakened) }
        do { _ = try await resolver.resolve(text: "伤感的120bpm左右的house", concepts: concepts); fatalError("mood weakened") }
        catch OpenRouterFailure.invalidQuery {}
        let optional = try await resolver.resolve(text: "120bpm左右的house，最好伤感一点", concepts: concepts)
        precondition(optional.preferences[1].requirement == .preferred)
        query["bpmRequired"] = false
        let weakenedBPM = try response(query)
        RouterHTTP.handler = { _ in (200, weakenedBPM) }
        do { _ = try await resolver.resolve(text: "120bpm左右house", concepts: concepts); fatalError("BPM weakened") }
        catch OpenRouterFailure.invalidQuery {}
        _ = try await resolver.resolve(text: "house，最好120bpm左右，最好伤感", concepts: concepts)
        for value in [NSNull(), "unknown"] as [Any] {
            query["preferences"] = [["concept": "house", "direction": "prefer", "weight": 1, "requirement": value]]
            let badRequirement = try response(query)
            RouterHTTP.handler = { _ in (200, badRequirement) }
            do { _ = try await resolver.resolve(text: "house", concepts: concepts); fatalError("invalid requirement accepted") }
            catch OpenRouterFailure.invalidQuery {}
        }
        let legacyData = Data(#"{"concept":"melancholic","direction":"prefer","weight":1}"#.utf8)
        let legacy = try JSONDecoder().decode(RecommendationQuery.Preference.self, from: legacyData)
        precondition(legacy.requirement == .preferred)
        query["preferences"] = [["concept": "house", "direction": "prefer", "weight": 1]]
        let missingRequirement = try response(query)
        RouterHTTP.handler = { _ in (200, missingRequirement) }
        do { _ = try await resolver.resolve(text: "house", concepts: concepts); fatalError("network accepted legacy preference") }
        catch OpenRouterFailure.invalidQuery {}
        print("PASS conjunctive query contract: 120±10 range, required/optional terms, omission/downgrade rejection and legacy-local-only decoding")
        let wikiGenre = GenreReference(source: .encyclopedia, value: "电子-House").concept
        let audioGenre = GenreReference(source: .audioStyle, value: "Electronic---Deep House").concept
        let sourceConcepts = concepts + [wikiGenre, audioGenre]
        query["bpmTarget"] = NSNull(); query["bpmRequired"] = false
        query["preferences"] = [["concept": "house", "direction": "prefer", "weight": 1, "requirement": "required"],
                                ["concept": wikiGenre.id, "direction": "prefer", "weight": 1, "requirement": "required"]]
        let sourcesResponse = try response(query)
        RouterHTTP.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let system = messages[0]["content"] as! String
            precondition(system.contains(wikiGenre.id) && system.contains(audioGenre.id))
            precondition(system.contains("independent source vocabularies") && system.contains("unverified metadata"))
            return (200, sourcesResponse)
        }
        let sources = try await resolver.resolve(text: "House歌曲", concepts: sourceConcepts)
        precondition(sources.preferences[1].genreReference?.source == .encyclopedia)
        precondition(sources.displaySummary(concepts: sourceConcepts).contains("百科：电子-House"))
        do { _ = try RecommendationQuery.decode(try JSONSerialization.data(withJSONObject: query), allowedConcepts: Set(concepts.map(\.id))); fatalError("unavailable source label accepted") }
        catch OpenRouterFailure.invalidQuery {}
        print("PASS actual SDK receives both independent source vocabularies, preserves original labels, validates selected source IDs and source-aware summary")
        RouterHTTP.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await resolver.resolve(text: "fixture", concepts: concepts); fatalError("offline accepted") }
        catch OpenRouterFailure.network {}
        let missing = OpenRouterIntentResolver(session: session, key: { "" })
        do { _ = try await missing.resolve(text: "fixture", concepts: concepts); fatalError("missing key accepted") }
        catch OpenRouterFailure.missingKey {}
        print("PASS invalid bounds/concepts/weights, unsupported criteria, truncation, nullable BPM, offline and missing key")
    }
}
