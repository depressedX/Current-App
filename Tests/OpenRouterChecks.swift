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
                        IntentConcept(id: "house", label: "House", definition: "House 节奏")]
        var query: [String: Any] = ["summary": "100–120 BPM，浪漫，别太激烈", "bpmMinimum": 100, "bpmMaximum": 120,
            "bpmTarget": NSNull(), "bpmRequired": true, "preferences": [["concept": "romantic", "direction": "prefer", "weight": 1],
                ["concept": "energetic", "direction": "avoid", "weight": 0.6]], "unsupported": []]
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
            query.merging(["preferences": [["concept": "invented", "direction": "prefer", "weight": 1]]]) { _, new in new },
            query.merging(["preferences": [["concept": "romantic", "direction": "prefer", "weight": 2]]]) { _, new in new },
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
        query["bpmRequired"] = false
        query["preferences"] = [["concept": "house", "direction": "prefer", "weight": 1]]
        let approximate = try response(query)
        RouterHTTP.handler = { _ in (200, approximate) }
        for prompt in ["100bpm左右的house", "约100 BPM的House", "House around 100 BPM"] {
            let result = try await resolver.resolve(text: prompt, concepts: concepts)
            precondition(result.bpmTarget == 100 && result.bpmMinimum == nil && result.bpmMaximum == nil)
            precondition(result.bpmPreference(100) > result.bpmPreference(110) && result.bpmPreference(110) > result.bpmPreference(130))
            precondition(result.bpmPreference(nil) == 0 && result.displaySummary(concepts: concepts).contains("100"))
        }
        print("PASS screenshot regression: approximate 100 BPM retained, proximity ranking, omitted BPM rejected and safe request traces")
        RouterHTTP.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await resolver.resolve(text: "fixture", concepts: concepts); fatalError("offline accepted") }
        catch OpenRouterFailure.network {}
        let missing = OpenRouterIntentResolver(session: session, key: { "" })
        do { _ = try await missing.resolve(text: "fixture", concepts: concepts); fatalError("missing key accepted") }
        catch OpenRouterFailure.missingKey {}
        print("PASS invalid bounds/concepts/weights, unsupported criteria, truncation, nullable BPM, offline and missing key")
    }
}
