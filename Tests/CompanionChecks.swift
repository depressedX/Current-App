import Foundation
import Network
import Security

final class MemoryCompanionVault: CompanionVault {
    var values: [String: Data] = [:]
    func load<T: Decodable>(_ key: String, as: T.Type) -> T? { values[key].flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    func save<T: Encodable>(_ value: T, key: String) throws { values[key] = try JSONEncoder().encode(value) }
    func delete(_ key: String) { values[key] = nil }
}
final class CompanionProfileHTTP: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Data(#"{"code":200,"profile":{"userId":1,"nickname":"Fixture"}}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct CompanionChecks {
    @MainActor static func wait(_ predicate: () -> Bool, seconds: Double = 10) async throws {
        let began = Date()
        while !predicate() {
            guard Date().timeIntervalSince(began) < seconds else { throw CurrentError.message("test timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func result(_ id: UUID, trackID: Int = 42, signature: String = CompanionProtocol.signature) -> CompanionResult {
        let features = AcousticFeatures(bpm: 100, rhythmStrength: 0.5, rmsDBFS: -12, peakDBFS: -1, dynamicSpreadDB: 3,
            zeroCrossingsPerSecond: 1, sampleStart: 0, sampleDuration: 24, elapsedSeconds: 1,
            profile: ObjectiveProfile(duration: 24, decodedFraction: 1, activeSeconds: 24, loudnessSpreadDB: 3,
                spectralChange: nil, spectralPeak: nil, largestRiseDB: 1, rises: [], vocalWindows: 0, classifiedWindows: 0,
                uncertainVocalWindows: 0, soundLabels: [], classifierAvailable: false))
        let genres = GenreAnalysis(matches: (0..<5).map { GenreMatch(index: $0, family: "Rock", style: "Style \($0)", score: 0.1) },
            windows: 1, duration: 24, analyzedAt: Date())
        return CompanionResult(jobID: id, trackID: trackID, account: "netease:1", signature: signature, features: features, genres: genres,
            vector: [1] + Array(repeating: 0, count: 511), windowStarts: [0], semanticElapsed: 1,
            lyrics: LyricsAnalysis(status: .noUsableText, contentHash: "fixture", chunks: [], fetchedAt: Date()), wiki: nil)
    }
    @MainActor static func transport() async throws {
        let secret = UUID().uuidString
        let parameters = CompanionConnection.parameters(secret: secret, peerToPeer: false)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        var accepted: CompanionConnection?
        var received = false
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                let peer = CompanionConnection(connection)
                accepted = peer
                peer.onMessage = { message in
                    precondition(message.kind == .authorize && message.cookies?["MUSIC_U"] == "fixture-only")
                    peer.send(CompanionMessage(kind: .welcome, name: "fixture"))
                }
                peer.start()
            }
        }
        listener.start(queue: .main)
        defer { listener.cancel(); accepted?.close() }
        try await wait { (listener.port?.rawValue ?? 0) > 0 }
        let client = CompanionConnection(NWConnection(host: "127.0.0.1", port: listener.port!, using: CompanionConnection.parameters(secret: secret, peerToPeer: false)))
        defer { client.close() }
        client.onReady = { client.send(CompanionMessage(kind: .authorize, cookies: ["MUSIC_U": "fixture-only"])) }
        client.onMessage = { message in received = message.kind == .welcome }
        client.start()
        try await wait { received }
        print("PASS encrypted TLS-PSK credential-message round trip")
        accepted?.close()
        var wrongReady = false, wrongClosed = false
        let wrong = CompanionConnection(NWConnection(host: "127.0.0.1", port: listener.port!, using: CompanionConnection.parameters(secret: "incorrect")))
        wrong.onReady = { wrongReady = true }
        wrong.onClose = { wrongClosed = true }
        wrong.start(); defer { wrong.close() }
        try await wait { wrongClosed }
        precondition(!wrongReady)
        print("PASS incorrect pairing secret rejected before application data")
    }
    @MainActor static func imports(_ root: URL, resources: URL) async throws {
        let concepts = try ConceptCatalog.load(url: resources.appendingPathComponent("concept-vectors.json"))
        let pool = SongPoolStore(fileURL: root.appendingPathComponent("song-pool.json"), resolve: { _ in root }, concepts: concepts)
        pool.activate(account: "netease:1")
        try await wait { !pool.loading }
        let tracks = (42...44).map { Track(id: $0, title: "Fixture", artist: "Artist", album: "Album", artwork: nil, duration: 24, demoIndex: nil) }
        pool.enqueue(tracks, source: "fixture")
        let ids = pool.songs.map(\.id)
        pool.reserveCompanion(Set(ids))
        try await pool.importCompanion(result(ids[0]))
        precondition(pool.songs[0].state == .completed && pool.companionReady(pool.songs[0]))
        let query = RecommendationQuery(summary: "fixture", bpmMinimum: nil, bpmMaximum: nil, bpmRequired: false,
            preferences: [.init(concept: concepts.concepts[0].id, direction: .prefer, weight: 1, requirement: .preferred)], unsupported: [])
        let ranked = try await pool.recommendationQueue(query: query)
        precondition(ranked.map(\.id) == [42])
        print("PASS remote vector import feeds production recommendation ranking")
        do { try await pool.importCompanion(result(ids[1], trackID: 43, signature: "obsolete")); fatalError("accepted incompatible result") }
        catch { precondition(pool.songs[1].features == nil && pool.songs[1].remotePending == true) }
        pool.reserveCompanion([ids[1]], requests: [ids[1]: UUID()])
        try await pool.importCompanion(result(ids[1], trackID: 43))
        precondition(pool.songs[1].features == nil)
        pool.remove(ids[1])
        try await pool.importCompanion(result(ids[1], trackID: 43))
        precondition(pool.songs.count == 2)
        pool.resume() // Explicit local run supersedes outstanding remote assignment.
        try await pool.importCompanion(result(ids[2], trackID: 44))
        precondition(pool.songs.last?.features == nil && pool.songs.last?.remotePending != true)
        pool.pause()
        pool.activate(account: "netease:2")
        try await pool.importCompanion(result(ids[0]))
        precondition(pool.songs.isEmpty)
        print("PASS version mismatch, removed songs, local override and account isolation")
        let restored = SongPoolStore(fileURL: root.appendingPathComponent("song-pool.json"), resolve: { _ in root }, concepts: concepts)
        restored.activate(account: "netease:1")
        try await wait { !restored.loading }
        precondition(restored.songs.first?.semanticReady == true)
        let restoredRank = try await restored.recommendationQueue(query: query)
        precondition(restoredRank.map(\.id) == [42])
        print("PASS durable catalogue and vectors survive restart")
    }
    @MainActor static func unavailableSongs(_ root: URL) async throws {
        struct Archive: Codable { let jobs: [CompanionJob]; let analysisPaused: Bool; let syncPaused: Bool }
        let tracks = (70...71).map { Track(id: $0, title: "Unavailable fixture", artist: "Fixture", album: "", artwork: nil, duration: 24, demoIndex: nil) }
        let entries = tracks.map { CompanionJob(id: UUID(), track: $0, account: "netease:1", requestID: UUID()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Archive(jobs: entries, analysisPaused: false, syncPaused: false)).write(to: root.appendingPathComponent("tasks.json"))
        let vault = MemoryCompanionVault()
        try vault.save(CompanionAuthorization(account: "netease:1", cookies: ["MUSIC_U": "fixture"]), key: "mac-auth")
        var attempted: [Int] = []
        let worker = CompanionWorker(folder: root, startNetwork: false, vault: vault, processor: { job, _ in
            attempted.append(job.track.id)
            if job.track.id == 70 { throw CurrentError.unavailable(.noResource) }
            throw URLError(.timedOut)
        })
        try await wait { worker.runningCount == 0 && worker.jobs.allSatisfy { $0.state == .unavailable || $0.state == .failed } }
        precondition(worker.unavailableCount == 1 && worker.pendingCount == 0)
        worker.retryFailed()
        try await wait { worker.runningCount == 0 }
        precondition(attempted.filter { $0 == 70 }.count == 1 && attempted.filter { $0 == 71 }.count == 2)
        worker.shutdown()
        let restored = CompanionWorker(folder: root, startNetwork: false, restoreSecrets: false)
        precondition(restored.unavailableCount == 1 && restored.jobs[0].unavailability == .noResource)
        restored.shutdown()

        let phone = SongPoolStore(fileURL: root.appendingPathComponent("phone.json"), resolve: { _ in root })
        try await wait { !phone.loading }; phone.activate(account: "netease:1")
        phone.enqueue(tracks, source: "fixture")
        let song = phone.songs[0], request = UUID()
        phone.reserveCompanion([song.id], requests: [song.id: request])
        var status = CompanionJobStatus(id: song.id, track: song.track, state: .unavailable, failure: nil,
            requestID: UUID(), unavailability: .noResource)
        phone.importCompanionStatuses([status], account: "netease:1")
        precondition(phone.pendingCount == 2) // Superseded request cannot change the phone.
        status.requestID = request
        phone.importCompanionStatuses([status], account: "netease:2")
        precondition(phone.pendingCount == 2)
        phone.importCompanionStatuses([status], account: "netease:1")
        precondition(phone.unavailableCount == 1 && phone.pendingCount == 1 && phone.songs[0].remotePending != true)
        phone.retryFailed(); phone.resume()
        precondition(phone.songs[0].state == .unavailable)
        let retrySong = phone.songs[1], retryRequest = UUID()
        phone.reserveCompanion([retrySong.id], requests: [retrySong.id: retryRequest])
        var retryStatus = CompanionJobStatus(id: retrySong.id, track: retrySong.track, state: .failed,
            failure: "网络超时", requestID: retryRequest)
        phone.importCompanionStatuses([retryStatus], account: "netease:1")
        precondition(phone.pendingCount == 0 && phone.songs[1].remotePending != true)
        retryStatus = CompanionJobStatus(id: retrySong.id, track: retrySong.track, state: .fetching,
            failure: nil, requestID: retryRequest)
        phone.importCompanionStatuses([retryStatus], account: "netease:1")
        precondition(phone.pendingCount == 1 && phone.songs[1].remotePending == true)
        // A delayed successful result must not resurrect a terminal unavailable song.
        var stale = result(song.id, trackID: song.track.id); stale.requestID = request
        try await phone.importCompanion(stale)
        precondition(phone.songs[0].state == .unavailable)
        let wire = try JSONDecoder().decode(CompanionJobStatus.self, from: JSONEncoder().encode(status))
        precondition(wire.requestID == request && wire.unavailability == .noResource)
        print("PASS Mac unavailable/retryable separation, restart, terminal status wire sync and account/request fencing")
    }

    @MainActor static func recovery(_ root: URL) throws {
        let track = Track(id: 1, title: "Fixture", artist: "", album: "", artwork: nil, duration: 24, demoIndex: nil)
        struct Archive: Codable { let jobs: [CompanionJob]; let analysisPaused: Bool; let syncPaused: Bool }
        let id = UUID()
        let job = CompanionJob(id: id, track: track, account: "netease:1", state: .analyzing)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Archive(jobs: [job], analysisPaused: false, syncPaused: true)).write(to: root.appendingPathComponent("tasks.json"))
        let worker = CompanionWorker(folder: root, startNetwork: false, restoreSecrets: false)
        precondition(worker.jobs[0].state == .queued && worker.syncPaused && !worker.analysisPaused)
        worker.setAnalysisPaused(true)
        let reopened = CompanionWorker(folder: root, startNetwork: false, restoreSecrets: false)
        precondition(reopened.analysisPaused && reopened.syncPaused && reopened.jobs.count == 1)
        reopened.cancel([id]); precondition(reopened.jobs.isEmpty)
        print("PASS Mac task recovery, independent pause persistence and cancellation")
    }
    @MainActor static func discovery(_ worker: CompanionWorker) async throws {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: worker.discoveryService, domain: nil), using: CompanionConnection.browsingParameters(peerToPeer: false))
        var foundMain = false, foundPairing = false, preservedScope = false
        browser.browseResultsChangedHandler = { results, _ in
            Task { @MainActor in
                for result in results {
                    guard case .service(let name, let type, _, _) = result.endpoint else { continue }
                    precondition(type == worker.discoveryService)
                    if name == worker.serviceID {
                        foundMain = true
                        if let interface = result.interfaces.first,
                           case .service(let host, let service, let domain, _) = result.endpoint,
                           case .bonjour(let record) = result.metadata {
                            var values: [String: String] = [:]
                            for key in ["role", "id", "name", "pair"] {
                                if case .string(let value) = record.getEntry(for: key) { values[key] = value }
                            }
                            let scoped = NWEndpoint.service(name: host, type: service, domain: domain, interface: interface)
                            let computer = CompanionComputer.parse(serviceName: name, endpoint: scoped, values: values, interfaces: result.interfaces)!
                            precondition(computer.endpoint.interface?.index == interface.index)
                            precondition(computer.pairingEndpoint?.interface?.index == interface.index)
                            preservedScope = true
                        }
                    }
                    if name == CompanionProtocol.pairingName(worker.serviceID),
                       case .bonjour(let record) = result.metadata, record.getEntry(for: "role") == .string("pairing") { foundPairing = true }
                }
            }
        }
        browser.start(queue: .main); defer { browser.cancel() }
        try await wait { worker.ready && worker.pairingReady && foundMain && foundPairing && preservedScope }
        print("PASS real Bonjour desktop/pairing discovery with preserved link-local interface scope")
    }
    @MainActor static func handshakeDeadline() async throws {
        let parameters = CompanionConnection.pairingParameters(peerToPeer: false)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        var accepted: NWConnection?
        listener.newConnectionHandler = { value in Task { @MainActor in accepted = value; value.start(queue: .main) } }
        listener.start(queue: .main)
        defer { listener.cancel(); accepted?.cancel() }
        try await wait { (listener.port?.rawValue ?? 0) > 0 }
        // A TCP endpoint that never answers the TLS handshake must report a timeout.
        let peer = CompanionConnection(NWConnection(host: "127.0.0.1", port: listener.port!,
            using: CompanionConnection.parameters(secret: "fixture-only", peerToPeer: false)), handshakeLimit: 0.15)
        var failure: NWError?, closed = false
        peer.onFailure = { failure = $0 }; peer.onClose = { closed = true }
        peer.start(); defer { peer.close() }
        try await wait { closed }
        guard case .posix(.ETIMEDOUT)? = failure else { preconditionFailure("silent handshake timeout") }
        print("PASS stalled TLS handshake reports a bounded failure instead of a silent connecting state")
    }
    @MainActor static func serverLifecycle(_ root: URL, resources: URL) async throws {
        let concepts = try ConceptCatalog.load(url: resources.appendingPathComponent("concept-vectors.json"))
        let phone = SongPoolStore(fileURL: root.appendingPathComponent("phone/pool.json"), resolve: { _ in root }, concepts: concepts)
        try await wait { !phone.loading }
        phone.activate(account: "netease:1")
        phone.enqueue((42...43).map { Track(id: $0, title: "Fixture", artist: "", album: "", artwork: nil, duration: 24, demoIndex: nil) }, source: "fixture")
        let entries = phone.songs.map { CompanionJob(id: $0.id, track: $0.track, account: phone.account, requestID: UUID()) }
        phone.reserveCompanion(Set(entries.map(\.id)), requests: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.requestID!) }))
        let vault = MemoryCompanionVault()
        let factory: @MainActor () -> NetEaseAPI = {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CompanionProfileHTTP.self]
            return NetEaseAPI(ephemeral: true, configuration: config)
        }
        let worker = CompanionWorker(folder: root.appendingPathComponent("mac"), serviceID: "fixture-" + UUID().uuidString,
            vault: vault, makeAPI: factory, processor: { job, api in
                precondition(api.hasCredentials)
                try await Task.sleep(for: .milliseconds(100))
                return result(job.id, trackID: job.track.id)
            }, networkScope: .loopbackTests)
        defer { worker.stopNetworking() }
        worker.setSyncPaused(true)
        try await wait { (worker.listeningPort?.rawValue ?? 0) > 0 }
        try await discovery(worker)
        // No code exists before a request has been explicitly accepted on Mac.
        precondition(worker.pairingCode.isEmpty)
        try await wait { (worker.pairingPort?.rawValue ?? 0) > 0 }
        let bootstrap = CompanionConnection(NWConnection(host: "127.0.0.1", port: worker.pairingPort!, using: .tcp))
        var reconnectSecret: String?, pairing: CompanionPairing.Client?
        var waiting = false
        bootstrap.onReady = { bootstrap.send(CompanionMessage(kind: .pairRequest, device: "fixture-phone", name: "Fixture iPhone")) }
        bootstrap.onMessage = { message in
            do {
                if message.kind == .pairWaiting { waiting = true }
                if message.kind == .pairAccepted {
                    let value = CompanionPairing.Client(username: CompanionPairing.username(service: worker.serviceID, device: "fixture-phone"), code: worker.pairingCode)
                    pairing = value; bootstrap.send(value.start(device: "fixture-phone"))
                }
                if message.kind == .pairChallenge { bootstrap.send(try pairing!.respond(message)) }
                if message.kind == .pairComplete { reconnectSecret = try pairing!.finish(message) }
            } catch { fatalError("SRP bootstrap failed: \(error)") }
        }
        bootstrap.start()
        try await wait { waiting && worker.pairingRequest != nil }
        precondition(worker.pairingCode.isEmpty && worker.pairingRequest?.approved == false)
        worker.approvePairingRequest()
        precondition(worker.pairingCode.count == 4)
        try await wait { reconnectSecret != nil }; bootstrap.close()
        precondition(reconnectSecret!.count == 64)
        var submitted = false, received = 0
        func client() -> CompanionConnection {
            let peer = CompanionConnection(NWConnection(host: "127.0.0.1", port: worker.listeningPort!, using: CompanionConnection.parameters(secret: reconnectSecret!, peerToPeer: false)))
            peer.onReady = { peer.send(CompanionMessage(kind: .hello, device: "fixture-phone")) }
            peer.onMessage = { message in
                if message.kind == .welcome {
                    peer.send(CompanionMessage(kind: .session, account: "netease:1", ids: entries.map(\.id)))
                    if !submitted { peer.send(CompanionMessage(kind: .authorize, account: "netease:1", cookies: ["MUSIC_U": "fixture-only"])) }
                }
                if message.kind == .status, message.authorizationAvailable == true, !submitted {
                    submitted = true
                    peer.send(CompanionMessage(kind: .submit, account: "netease:1", jobs: entries))
                }
                if let result = message.result {
                    Task { @MainActor in
                        do {
                            try await phone.importCompanion(result)
                            received += 1
                            peer.send(CompanionMessage(kind: .acknowledge, ids: [result.jobID], requestID: result.requestID))
                        } catch { fatalError("fixture import failed") }
                    }
                }
            }
            peer.start(); return peer
        }
        let first = client()
        try await wait { worker.jobs.count == 2 && worker.jobs.allSatisfy { $0.state == .completed } }
        precondition(received == 0)
        first.close()
        try await wait { !worker.connected }
        let restored = CompanionWorker(folder: root.appendingPathComponent("mac"), startNetwork: false,
            serviceID: "fixture-restore", vault: vault, makeAPI: factory)
        precondition(restored.jobs.count == 2 && restored.jobs.allSatisfy { $0.result != nil })
        worker.setSyncPaused(false)
        let second = client(); defer { second.close() }
        try await wait { worker.jobs.isEmpty && received == 2 }
        let retainedFiles = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("mac/Results").path)
        precondition(retainedFiles.isEmpty)
        precondition(phone.completedCount == 2)
        let archive = try String(contentsOf: root.appendingPathComponent("mac/tasks.json"), encoding: .utf8)
        precondition(!archive.contains("fixture-only") && !archive.contains("MUSIC_U"))
        precondition(!archive.contains(entries[0].id.uuidString) && !archive.contains(entries[1].id.uuidString))
        second.send(CompanionMessage(kind: .control, analysisPaused: true))
        second.send(CompanionMessage(kind: .submit, account: "netease:1", jobs: [entries[0]], force: true))
        try await wait { worker.jobs.count == 1 && worker.analysisPaused }
        second.send(CompanionMessage(kind: .session, account: "netease:1", ids: []))
        try await wait { worker.jobs.isEmpty }
        second.send(CompanionMessage(kind: .revoke))
        try await wait { worker.account == nil && worker.jobs.isEmpty }
        precondition(vault.values["mac-auth"] == nil)
        print("PASS real server pairing, credential reuse, batch queue, paused sync, reconnect delivery, durable results, ACK retirement/result cleanup and revocation")
    }
    @MainActor static func pairingApproval(_ root: URL) async throws {
        let worker = CompanionWorker(folder: root, serviceID: "approval-" + UUID().uuidString, vault: MemoryCompanionVault(), networkScope: .loopbackTests)
        defer { worker.stopNetworking() }
        try await wait { (worker.pairingPort?.rawValue ?? 0) > 0 }
        func request(_ device: String, receive: @escaping (CompanionMessage) -> Void) -> CompanionConnection {
            let peer = CompanionConnection(NWConnection(host: "127.0.0.1", port: worker.pairingPort!, using: .tcp))
            peer.onReady = { peer.send(CompanionMessage(kind: .pairRequest, device: device, name: device)) }
            peer.onMessage = receive; peer.start(); return peer
        }
        var rejected = false
        let denied = request("denied") { if $0.kind == .error { rejected = true } }
        try await wait { worker.pairingRequest != nil }
        precondition(worker.pairingCode.isEmpty)
        worker.cancelPairingRequest(); try await wait { rejected }; denied.close()
        precondition(worker.pairingRequest == nil && worker.pairedDevice == nil)
        var accepted = false, errors = 0, challenger: CompanionPairing.Client?
        let retry = request("retry-phone") { message in
            if message.kind == .pairAccepted { accepted = true }
            if message.kind == .error { errors += 1 }
        }
        try await wait { worker.pairingRequest != nil }
        // An unrelated TCP peer cannot skip Mac approval or steal the active request.
        let bypass = CompanionConnection(NWConnection(host: "127.0.0.1", port: worker.pairingPort!, using: .tcp))
        var blocked = false
        bypass.onReady = { bypass.send(CompanionMessage(kind: .pairStart, device: "attacker", publicKey: Data(repeating: 1, count: 256))) }
        bypass.onMessage = { if $0.kind == .error { blocked = true }; precondition($0.kind != .pairChallenge) }
        bypass.start(); try await wait { blocked }; bypass.close()
        precondition(worker.pairingRequest?.device == "retry-phone" && worker.pairingCode.isEmpty)
        worker.approvePairingRequest(); try await wait { accepted }
        retry.onMessage = { message in
            if message.kind == .pairChallenge { retry.send(try! challenger!.respond(message)) }
            if message.kind == .error { errors += 1 }
        }
        for attempt in 1...5 {
            let bad = CompanionPairing.Client(username: CompanionPairing.username(service: worker.serviceID, device: "retry-phone"), code: worker.pairingCode == "0000" ? "0001" : "0000")
            challenger = bad; retry.send(bad.start(device: "retry-phone"))
            try await wait { errors == attempt }
        }
        try await wait { worker.pairingRequest == nil }; retry.close()
        precondition(worker.pairingCode.isEmpty && worker.pairedDevice == nil)
        let cancelled = request("cancelled") { _ in }
        try await wait { worker.pairingRequest != nil }
        cancelled.send(CompanionMessage(kind: .pairCancel))
        try await wait { worker.pairingRequest == nil }; cancelled.close()
        let timed = CompanionWorker(folder: root.appendingPathComponent("timeouts"), serviceID: "timeouts-" + UUID().uuidString,
            vault: MemoryCompanionVault(), requestLifetime: 0.15, codeLifetime: 0.15, networkScope: .loopbackTests)
        defer { timed.stopNetworking() }
        try await wait { (timed.pairingPort?.rawValue ?? 0) > 0 }
        for approve in [false, true] {
            let peer = CompanionConnection(NWConnection(host: "127.0.0.1", port: timed.pairingPort!, using: .tcp))
            var expired = false
            peer.onReady = { peer.send(CompanionMessage(kind: .pairRequest, device: "timeout-phone")) }
            peer.onMessage = { if $0.kind == .error { expired = true } }
            peer.start(); try await wait { timed.pairingRequest != nil }
            if approve { timed.approvePairingRequest() }
            try await wait { expired && timed.pairingRequest == nil }; peer.close()
            precondition(timed.pairingCode.isEmpty)
        }
        print("PASS explicit approval gate, rejection, peer binding, five-attempt limit, cancellation and request/code expiry")
    }
    @MainActor static func windowShutdown(_ root: URL) async throws {
        let vault = MemoryCompanionVault()
        try vault.save(CompanionAuthorization(account: "netease:1", cookies: ["MUSIC_U": "fixture-only"]), key: "mac-auth")
        let job = CompanionJob(id: UUID(), track: Track(id: 42, title: "Fixture", artist: "", album: "", artwork: nil, duration: 24, demoIndex: nil), account: "netease:1", requestID: UUID())
        struct Archive: Codable { let jobs: [CompanionJob]; let analysisPaused: Bool; let syncPaused: Bool }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Archive(jobs: [job], analysisPaused: false, syncPaused: false)).write(to: root.appendingPathComponent("tasks.json"))
        var started = false, cancelled = false
        let worker = CompanionWorker(folder: root, vault: vault, processor: { job, _ in
            started = true
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled = true; throw error }
            return result(job.id, trackID: job.track.id)
        }, networkScope: .loopbackTests)
        try await wait { started && worker.ready }
        worker.shutdown()
        try await wait { cancelled }
        precondition(!worker.ready && worker.listeningPort == nil && worker.pairingPort == nil)
        precondition(worker.analysisPaused && worker.jobs.first?.state == .queued)
        worker.start(); precondition(worker.listeningPort == nil)
        let restored = CompanionWorker(folder: root, startNetwork: false, vault: vault)
        precondition(restored.analysisPaused && restored.jobs.first?.state == .queued)
        print("PASS window shutdown cancels active analysis, withdraws discovery and saves unfinished tasks paused")
    }
    @MainActor static func parallelSongs(_ root: URL) async throws {
        @MainActor final class Gate {
            var active = 0, peak = 0, started = 0
            var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
            func run(_ job: CompanionJob) async throws -> CompanionResult {
                active += 1; started += 1; peak = max(peak, active)
                defer { active -= 1 }
                // Deliberately ignore cancellation until released, like a native inference call.
                await withCheckedContinuation { waiting[job.id] = $0 }
                if job.track.id == 43 { throw CurrentError.message("fixture failure") }
                return CompanionChecks.result(job.id, trackID: job.track.id)
            }
            func release(_ id: UUID) { waiting.removeValue(forKey: id)?.resume() }
            func releaseAll() { for id in Array(waiting.keys) { release(id) } }
        }
        struct Archive: Codable { let jobs: [CompanionJob]; let analysisPaused: Bool; let syncPaused: Bool }
        let entries = (42..<51).map { track in CompanionJob(id: UUID(), track: Track(id: track, title: "Fixture", artist: "", album: "", artwork: nil, duration: 24, demoIndex: nil), account: "netease:1", requestID: UUID()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Archive(jobs: entries, analysisPaused: false, syncPaused: false)).write(to: root.appendingPathComponent("tasks.json"))
        let vault = MemoryCompanionVault()
        try vault.save(CompanionAuthorization(account: "netease:1", cookies: ["MUSIC_U": "fixture-only"]), key: "mac-auth")
        let gate = Gate()
        let worker = CompanionWorker(folder: root, startNetwork: false, vault: vault, processor: { job, _ in try await gate.run(job) })
        try await wait { gate.active == 4 }
        precondition(gate.started == 4 && worker.runningCount == 4)
        worker.cancel([entries[0].id])
        precondition(gate.active == 4 && gate.started == 4 && worker.jobs.count == 8)
        gate.release(entries[0].id)
        try await wait { gate.started == 5 && gate.active == 4 }
        precondition(worker.jobs.filter { $0.state == .fetching }.count == 4)
        worker.setAnalysisPaused(true); worker.setAnalysisPaused(false)
        // Resuming must not allocate extra slots while cancelled inference calls drain.
        precondition(gate.started == 5 && worker.runningCount == 4)
        gate.releaseAll()
        try await wait { gate.started == 9 && gate.active == 4 }
        let deadline = Date().addingTimeInterval(10)
        while worker.jobs.contains(where: { $0.state == .queued || $0.state == .fetching || $0.state == .analyzing }) {
            guard Date() < deadline else { throw CurrentError.message("parallel queue timed out") }
            gate.releaseAll(); try await Task.sleep(for: .milliseconds(10))
        }
        try await wait { worker.runningCount == 0 }
        precondition(gate.peak == 4 && worker.jobs.filter { $0.state == .failed }.count == 1)
        precondition(worker.jobs.filter { $0.state == .completed }.count == 7)
        precondition(!worker.jobs.contains { $0.id == entries[0].id })
        worker.shutdown()
        let closeRoot = root.appendingPathComponent("close")
        try FileManager.default.createDirectory(at: closeRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(Archive(jobs: entries, analysisPaused: false, syncPaused: false)).write(to: closeRoot.appendingPathComponent("tasks.json"))
        let closingGate = Gate()
        let closing = CompanionWorker(folder: closeRoot, startNetwork: false, vault: vault, processor: { job, _ in try await closingGate.run(job) })
        try await wait { closingGate.active == 4 }
        closing.shutdown(); closingGate.releaseAll()
        try await wait { closing.runningCount == 0 }
        precondition(closing.analysisPaused && closingGate.started == 4 && closing.jobs.allSatisfy { $0.state == .queued && $0.result == nil })
        print("PASS four-song limit, slot refill, isolated cancellation, pause/resume draining, failure isolation and four-worker shutdown")
    }
    @MainActor static func configurableParallelism(_ root: URL) async throws {
        @MainActor final class Gate {
            var started = 0, active = 0
            var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
            func run(_ job: CompanionJob) async -> CompanionResult {
                started += 1; active += 1; defer { active -= 1 }
                await withCheckedContinuation { waiting[job.id] = $0 }
                return CompanionChecks.result(job.id, trackID: job.track.id)
            }
            func release(_ id: UUID) { waiting.removeValue(forKey: id)?.resume() }
            func releaseAll() { for id in Array(waiting.keys) { release(id) } }
        }
        struct Archive: Codable { let jobs: [CompanionJob]; let analysisPaused: Bool; let syncPaused: Bool }
        let entries = (100..<114).map { track in CompanionJob(id: UUID(), track: Track(id: track, title: "Fixture", artist: "", album: "", artwork: nil, duration: 24, demoIndex: nil), account: "netease:1", requestID: UUID()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Archive(jobs: entries, analysisPaused: false, syncPaused: false)).write(to: root.appendingPathComponent("tasks.json"))
        let vault = MemoryCompanionVault()
        try vault.save(CompanionAuthorization(account: "netease:1", cookies: ["MUSIC_U": "fixture-only"]), key: "mac-auth")
        let gate = Gate()
        let worker = CompanionWorker(folder: root, startNetwork: false, vault: vault, processor: { job, _ in await gate.run(job) })
        try await wait { gate.active == 4 }
        precondition(worker.concurrentAnalyses == 4)
        worker.setConcurrency(2)
        precondition(gate.active == 4 && gate.started == 4)
        gate.release(entries[0].id); gate.release(entries[1].id)
        try await wait { worker.runningCount == 2 }
        precondition(gate.started == 4 && worker.jobs.filter { $0.state == .completed }.count == 2)
        worker.setConcurrency(6)
        try await wait { gate.active == 6 }
        precondition(gate.started == 8)
        worker.shutdown(); gate.releaseAll(); try await wait { worker.runningCount == 0 }
        let restored = CompanionWorker(folder: root, startNetwork: false, vault: vault)
        precondition(restored.concurrentAnalyses == 6 && restored.analysisPaused)
        restored.setConcurrency(0); precondition(restored.concurrentAnalyses == 1)
        restored.setConcurrency(100); precondition(restored.concurrentAnalyses == 16)
        let reread = CompanionWorker(folder: root, startNetwork: false, restoreSecrets: false)
        precondition(reread.concurrentAnalyses == 16)
        print("PASS default/legacy concurrency, non-interrupting reduction, immediate increase, restart persistence and range validation")
    }
    @MainActor static func peerDiscoveryLifecycle() async throws {
        precondition(CompanionConnection.pairingFailureMessage(for: .tls(errSSLBadRecordMac)) != nil)
        precondition(CompanionConnection.pairingFailureMessage(for: .tls(errSSLPeerBadRecordMac)) != nil)
        precondition(CompanionConnection.pairingFailureMessage(for: .posix(.ECONNREFUSED)) == nil)
        precondition(CompanionConnection.browsingParameters().requiredInterface == nil)
        precondition(CompanionConnection.pairingParameters().requiredInterface == nil)
        precondition(CompanionConnection.parameters(secret: "fixture").requiredInterface == nil)
        precondition(CompanionConnection.browsingParameters().includePeerToPeer)
        precondition(CompanionConnection.pairingParameters().includePeerToPeer)
        precondition(CompanionConnection.parameters(secret: "fixture").includePeerToPeer)
        precondition(!CompanionConnection.browsingParameters(peerToPeer: false).includePeerToPeer)
        precondition(!CompanionConnection.pairingParameters(peerToPeer: false).includePeerToPeer)
        precondition(!CompanionConnection.parameters(secret: "fixture", peerToPeer: false).includePeerToPeer)
        precondition((0...8).map { CompanionDiscoveryPolicy.retryDelay(attempt: $0) } == [5, 10, 20, 40, 60, 60, 60, 60, 60])
        let idleService = "_cur-idle._tcp"
        let client = CompanionClient(vault: MemoryCompanionVault(), deviceID: "fixture-phone", discoveryService: idleService, scanDuration: 0.1)
        client.setDiscoveryVisible(true)
        precondition(!client.discovering)
        client.setForeground(true); precondition(client.discovering)
        try await wait { !client.discovering }
        precondition(client.error != nil)
        try await Task.sleep(for: .milliseconds(150)); precondition(!client.discovering)
        client.discover(); precondition(client.discovering)
        let endpoint = NWEndpoint.service(name: "missing-desktop", type: idleService, domain: "local.", interface: nil)
        let computer = CompanionComputer.parse(serviceName: "missing-desktop", endpoint: endpoint,
            values: ["role": "desktop", "id": "missing-desktop", "name": "Fixture", "pair": "missing-pair"])!
        precondition(computer.endpoint.interface == nil && computer.pairingEndpoint?.interface == nil)
        client.requestPairing(with: computer)
        precondition(!client.discovering && client.connecting && client.pairingStage == .waiting)
        client.cancelPairing(); client.setForeground(false)
        precondition(client.pairingStage == nil && !client.connecting && !client.discovering)
        let vault = MemoryCompanionVault()
        try vault.save(CompanionPair(service: "missing-desktop", secret: "fixture-only", device: "fixture-phone"), key: "phone-pair")
        let returning = CompanionClient(vault: vault, deviceID: "fixture-phone", discoveryService: idleService,
            scanDuration: 0.08, retryBaseDelay: 0.08)
        returning.setForeground(true); precondition(returning.discovering)
        try await wait { !returning.discovering }
        try await wait { returning.discovering }
        returning.setForeground(false)
        try await Task.sleep(for: .milliseconds(250)); precondition(!returning.discovering)
        print("PASS peer-to-peer discovery/pairing/TLS flags, fresh discovery routes, bounded scans, selection stop, reconnect backoff and background cleanup")
    }
    @MainActor static func syncedMigration(_ root: URL) throws {
        let track = Track(id: 42, title: "Fixture", artist: "", album: "", artwork: nil, duration: 24, demoIndex: nil)
        var old = (0..<300).map { _ in CompanionJob(id: UUID(), track: track, account: "netease:1", requestID: UUID()) }
        for i in old.indices { old[i].state = .synced }
        var pending = CompanionJob(id: UUID(), track: track, account: "netease:1", requestID: UUID())
        pending.state = .completed
        let queue = CompanionJob(id: UUID(), track: track, account: "netease:1", requestID: UUID())
        struct Archive: Codable { let jobs: [CompanionJob]; let analysisPaused: Bool; let syncPaused: Bool }
        let results = root.appendingPathComponent("Results")
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        for job in old { try Data("legacy-acknowledged".utf8).write(to: results.appendingPathComponent(job.id.uuidString + ".json")) }
        try JSONEncoder().encode(result(pending.id)).write(to: results.appendingPathComponent(pending.id.uuidString + ".json"))
        try JSONEncoder().encode(Archive(jobs: old + [pending, queue], analysisPaused: true, syncPaused: true)).write(to: root.appendingPathComponent("tasks.json"))
        let worker = CompanionWorker(folder: root, startNetwork: false, restoreSecrets: false)
        precondition(worker.jobs.count == 2 && worker.activeJobs.count == 2)
        precondition(worker.jobs.first { $0.id == pending.id }?.result != nil)
        precondition(worker.jobs.contains { $0.id == queue.id && $0.state == .queued })
        let files = try FileManager.default.contentsOfDirectory(atPath: results.path)
        precondition(files == [pending.id.uuidString + ".json"])
        let reopened = CompanionWorker(folder: root, startNetwork: false, restoreSecrets: false)
        precondition(reopened.jobs.count == 2 && reopened.syncPaused && reopened.analysisPaused)
        print("PASS legacy 300-synced-task cleanup, retained unacknowledged result and durable queue migration")
    }
    static func discoveryRecords() {
        func endpoint(_ name: String) -> NWEndpoint { .service(name: name, type: CompanionProtocol.service, domain: "local.", interface: nil) }
        let values = ["role": "desktop", "id": "device-a", "name": "MacBook Pro", "pair": "device-a-pair (2)"]
        let direct = CompanionComputer.parse(serviceName: "device-a", endpoint: endpoint("device-a"), values: values)!
        let duplicate = CompanionComputer.parse(serviceName: "device-a (2)", endpoint: endpoint("device-a (2)"), values: values)!
        var second = values; second["id"] = "device-b"; second["pair"] = "device-b-pair"
        let other = CompanionComputer.parse(serviceName: "device-b", endpoint: endpoint("device-b"), values: second)!
        let records = CompanionComputer.unique([duplicate, other, direct, duplicate])
        precondition(records.count == 2 && records[0].id == "device-a" && records[0].routeRank == direct.routeRank)
        precondition(records[0].pairingName == "device-a-pair (2)")
        precondition(CompanionComputer.parse(serviceName: "fixture", endpoint: endpoint("fixture"), values: [:]) == nil)
        precondition(CompanionComputer.parse(serviceName: "device-a-pair (2)", endpoint: endpoint("pair"), values: ["role": "pairing"]) == nil)
        print("PASS stable device deduplication, separate same-name Macs, actual pairing route and internal/legacy advertisement filtering")
    }
    static func pairingProofs() throws {
        let user = CompanionPairing.username(service: "fixture", device: "phone")
        for code in ["0000", "0123", "9999"] {
            let client = CompanionPairing.Client(username: user, code: code)
            let start = client.start(device: "phone")
            let server = try CompanionPairing.Server(username: user, code: code, publicKey: start.publicKey!)
            let proof = try client.respond(server.challenge())
            let secret = String(repeating: "a", count: 64)
            let complete = try server.complete(proof: proof.proof!, secret: secret)
            let recovered = try client.finish(complete)
            precondition(recovered == secret)
            var tampered = complete; tampered.sealedSecret![0] ^= 1
            do { _ = try client.finish(tampered); preconditionFailure("accepted tampered secret") } catch {}
            let wrong = CompanionPairing.Client(username: user, code: code == "0000" ? "0001" : "0000")
            let challenge = try CompanionPairing.Server(username: user, code: code, publicKey: wrong.start(device: "phone").publicKey!)
            let bad = try wrong.respond(challenge.challenge())
            do { _ = try challenge.complete(proof: bad.proof!, secret: secret); preconditionFailure("accepted wrong code") } catch {}
            // A proof from another exchange must not replay successfully.
            let fresh = try CompanionPairing.Server(username: user, code: code, publicKey: start.publicKey!)
            do { _ = try fresh.complete(proof: proof.proof!, secret: secret); preconditionFailure("accepted replay") } catch {}
        }
        print("PASS four-digit SRP, leading zeros, wrong code, replay and tampered secret rejection")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("current-companion-check-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setbuf(stdout, nil)
        try await imports(root.appendingPathComponent("phone"), resources: URL(fileURLWithPath: CommandLine.arguments[1]))
        try recovery(root.appendingPathComponent("mac"))
        try await unavailableSongs(root.appendingPathComponent("unavailable"))
        try syncedMigration(root.appendingPathComponent("synced-migration"))
        try await peerDiscoveryLifecycle()
        discoveryRecords()
        try pairingProofs()
        try await transport()
        try await handshakeDeadline()
        try await configurableParallelism(root.appendingPathComponent("concurrency"))
        try await parallelSongs(root.appendingPathComponent("parallel"))
        try await windowShutdown(root.appendingPathComponent("window"))
        try await pairingApproval(root.appendingPathComponent("approval"))
        try await serverLifecycle(root.appendingPathComponent("lifecycle"), resources: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
