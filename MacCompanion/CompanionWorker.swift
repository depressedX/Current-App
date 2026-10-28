import Foundation
import Combine
import AppKit
import Network

@MainActor
final class CompanionWorker: ObservableObject {
    @Published private(set) var jobs: [CompanionJob] = []
    var activeJobs: [CompanionJob] { jobs.filter { $0.state != .synced } }
    var pendingCount: Int { jobs.filter { $0.state == .queued || $0.state == .authorizationRequired }.count }
    var unavailableCount: Int { jobs.filter { $0.state == .unavailable }.count }
    @Published private(set) var pairedDevice: String?
    @Published private(set) var account: String?
    @Published private(set) var connected = false
    @Published private(set) var ready = false
    @Published private(set) var pairingReady = false
    private var connectionReady = false
    private func updateReady() { ready = connectionReady && (pairedDevice != nil || pairingReady) }
    @Published private(set) var analysisPaused = false
    @Published private(set) var syncPaused = false
    @Published private(set) var error: String?
    struct PairingRequest: Identifiable {
        let id: UUID
        let device: String
        let name: String
        var approved = false
    }
    @Published private(set) var pairingCode = ""
    @Published private(set) var pairingRequest: PairingRequest?
    private let requestLifetime: TimeInterval
    private let codeLifetime: TimeInterval
    enum NetworkScope { case localNetwork, loopbackTests }
    private let networkScope: NetworkScope
    let discoveryService: String
    private var registeredPairingName: String?
    let serviceID: String
    var listeningPort: NWEndpoint.Port? { listener?.port }
    private let api: NetEaseAPI
    private let makeAPI: @MainActor () -> NetEaseAPI
    private let vault: any CompanionVault
    private let processor: ((CompanionJob, NetEaseAPI) async throws -> CompanionResult)?
    private var listener: NWListener?
    private var listenerRetry: Task<Void, Never>?
    private var listenerRetryAttempt = 0
    private var nearbyBrowser: NWBrowser?
    private var nearbyCycle: Task<Void, Never>?
    private var nearbyAttempt = 0
    private var pairingListener: NWListener?
    var pairingPort: NWEndpoint.Port? { pairingListener?.port }
    private var connectionSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var pairingPeers: [UUID: CompanionConnection] = [:]
    private var pairingSessions: [UUID: (String, CompanionPairing.Server)] = [:]
    private var pendingPairDevice: String?
    private var pairingAttempts = 0
    private var pairingExpires = Date()

    private var peers: [UUID: CompanionConnection] = [:]
    private var authenticated: Set<UUID> = []
    private var inventories: [UUID: Set<UUID>] = [:]
    private var sent: Set<UUID> = []
    static let concurrencyRange = 1...16
    @Published private(set) var concurrentAnalyses = 4
    @Published private(set) var runningCount = 0
    private var runs: [UUID: Task<Void, Never>] = [:]
    private var epoch = UUID()
    private var archiveFailed = false
    private var authorizing = false
    private var authorizationVersion = UUID()
    private let folder: URL
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private var stopped = false
    private struct Archive: Codable {
        var jobs: [CompanionJob]
        var analysisPaused: Bool
        var syncPaused: Bool
        var concurrency: Int? = nil
    }
    init(folder: URL? = nil, startNetwork: Bool = true, restoreSecrets: Bool = true,
         serviceID: String? = nil, vault: any CompanionVault = KeychainCompanionVault(),
         makeAPI: @escaping @MainActor () -> NetEaseAPI = { NetEaseAPI(ephemeral: true) },
         processor: ((CompanionJob, NetEaseAPI) async throws -> CompanionResult)? = nil,
         requestLifetime: TimeInterval = 60, codeLifetime: TimeInterval = 300,
         networkScope: NetworkScope = .localNetwork) {
        self.networkScope = networkScope
        self.discoveryService = networkScope == .localNetwork ? CompanionProtocol.service : "_current-test._tcp"
        self.requestLifetime = requestLifetime; self.codeLifetime = codeLifetime
        self.serviceID = serviceID ?? CompanionSecrets.identifier("companion-service")
        self.vault = vault; self.makeAPI = makeAPI; self.api = makeAPI(); self.processor = processor
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CurrentCompanion")
        if restoreSecrets, let saved: CompanionPair = vault.load("mac-pair", as: CompanionPair.self) {
            pairedDevice = saved.device; connectionSecret = saved.secret
        }
        if restoreSecrets, let auth: CompanionAuthorization = vault.load("mac-auth", as: CompanionAuthorization.self) {
            account = auth.account; api.useCompanionCredentials(auth.cookies)
        }
        let file = self.folder.appendingPathComponent("tasks.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let saved = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
                jobs = saved.jobs; analysisPaused = saved.analysisPaused; syncPaused = saved.syncPaused
                concurrentAnalyses = Self.clampConcurrency(saved.concurrency ?? 4)
                for i in jobs.indices where jobs[i].state == .completed {
                    do {
                        let result = try JSONDecoder().decode(CompanionResult.self, from: Data(contentsOf: self.folder.appendingPathComponent("Results").appendingPathComponent(jobs[i].id.uuidString + ".json")))
                        try result.validate(); jobs[i].result = result
                    } catch { jobs[i].state = .failed; jobs[i].failure = "结果记录缺失或版本已更新，请重试" }
                }
                for i in jobs.indices where jobs[i].state == .fetching || jobs[i].state == .analyzing { jobs[i].state = .queued }
            }
        } catch { archiveFailed = true; self.error = "任务记录读取失败，原文件已保留" }
        if account == nil { account = jobs.first?.account }
        let previouslySynced = Set(jobs.filter { $0.state == .synced }.map(\.id))
        if !previouslySynced.isEmpty { _ = retireJobs(previouslySynced) }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.interrupt() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.pump() }
        })
        if startNetwork { start() }
        pump()
    }
    private func desktopService() -> NWListener.Service {
        NWListener.Service(name: serviceID, type: discoveryService,
            txtRecord: NWTXTRecord(["role": "desktop", "id": serviceID,
                "name": Host.current().localizedName ?? "Current Mac",
                "pair": registeredPairingName ?? CompanionProtocol.pairingName(serviceID)]))
    }
    /// Window-owned lifetime: preserve unfinished tasks, cancel work, withdraw all discovery.
    func shutdown() {
        guard !stopped else { return }; stopped = true
        analysisPaused = true; sleeping = true; epoch = UUID()
        interrupt(); cancelPairingRequest(); stopNetworking()
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }; observers.removeAll()
        AppLog.shared.record(.companion, .cancelled, operation: .companionListener)
    }
    private func stopNearbyDiscovery() {
        let previous = nearbyBrowser; nearbyBrowser = nil; previous?.cancel()
        nearbyCycle?.cancel(); nearbyCycle = nil
    }
    private func beginNearbyDiscovery() {
        guard !stopped, !connected, networkScope == .localNetwork,
              nearbyBrowser == nil, nearbyCycle == nil else { return }
        let value = NWBrowser(for: .bonjour(type: discoveryService, domain: nil), using: CompanionConnection.browsingParameters())
        value.stateUpdateHandler = { state in
            if case .failed(let issue) = state {
                AppLog.shared.record(.companion, .failed, level: .warning, operation: .companionNearbySearch, error: issue)
            }
        }
        nearbyBrowser = value; value.start(queue: .main)
        AppLog.shared.record(.companion, .started, operation: .companionNearbySearch)
        nearbyCycle = Task { [weak self, weak value] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, let value, self.nearbyBrowser === value else { return }
            value.cancel(); self.nearbyBrowser = nil
            AppLog.shared.record(.companion, .cancelled, operation: .companionNearbySearch)
            let delay = CompanionDiscoveryPolicy.retryDelay(attempt: self.nearbyAttempt)
            self.nearbyAttempt += 1
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self.nearbyCycle = nil; self.beginNearbyDiscovery()
        }
    }
    func stopNetworking() {
        stopNearbyDiscovery()
        listenerRetry?.cancel(); listenerRetry = nil
        listener?.cancel(); pairingListener?.cancel(); listener = nil; pairingListener = nil
        for peer in Array(pairingPeers.values) + Array(peers.values) { peer.close() }
        connectionReady = false; pairingReady = false; updateReady()
    }
    private func scheduleListenerRestart() {
        guard !stopped, networkScope == .localNetwork, listenerRetry == nil else { return }
        let delay = CompanionDiscoveryPolicy.retryDelay(attempt: listenerRetryAttempt)
        listenerRetryAttempt += 1
        listenerRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !self.stopped else { return }
            self.listenerRetry = nil; self.start()
        }
    }
    func start() {
        guard !stopped else { return }
        listenerRetry?.cancel(); listenerRetry = nil
        connectionReady = false; pairingReady = false; updateReady()
        AppLog.shared.record(.companion, .started, operation: .companionListener)
        listener?.cancel()
        do {
            let parameters = CompanionConnection.parameters(secret: connectionSecret, peerToPeer: networkScope == .localNetwork)
            if networkScope == .loopbackTests { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
            let value = try NWListener(using: parameters)
            value.service = desktopService()
            value.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
            value.stateUpdateHandler = { [weak self, weak value] state in
                Task { @MainActor in
                    guard let self, let value, self.listener === value else { return }
                    switch state {
                    case .ready:
                        self.connectionReady = true; self.updateReady()
                        AppLog.shared.record(.companion, .ready, operation: .companionListener)
                    case .failed(let error), .waiting(let error):
                        self.connectionReady = false; self.updateReady()
                        self.error = "局域网服务启动失败，请重试并检查本地网络权限"
                        AppLog.shared.record(.companion, .failed, level: .error, operation: .companionListener, error: error)
                        self.scheduleListenerRestart()
                    default: break
                    }
                }
            }
            listener = value; value.start(queue: .main)
            startPairingListener(); beginNearbyDiscovery()
        } catch {
            self.error = "无法启动局域网服务"
            AppLog.shared.record(.companion, .failed, level: .error, operation: .companionListener, error: error)
            scheduleListenerRestart()
        }
    }
    func approvePairingRequest() {
        guard var request = pairingRequest, !request.approved, let peer = pairingPeers[request.id] else { return }
        AppLog.shared.record(.companion, .succeeded, operation: .companionApproval, span: request.id)
        request.approved = true; pairingRequest = request
        pairingAttempts = 0; pendingPairDevice = nil
        pairingCode = String(format: "%04d", Int.random(in: 0...9999))
        pairingExpires = Date().addingTimeInterval(codeLifetime)
        connectionSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        if listener != nil { start() }
        peer.send(CompanionMessage(kind: .pairAccepted, name: Host.current().localizedName ?? "Current Mac"))
        expirePairingRequest(request.id, after: codeLifetime, approved: true)
    }
    func cancelPairingRequest() {
        guard let request = pairingRequest else { return }
        AppLog.shared.record(.companion, .cancelled, operation: .companionRequest, span: request.id)
        pairingRequest = nil; pairingCode = ""; pendingPairDevice = nil
        pairingSessions[request.id] = nil
        pairingPeers[request.id]?.send(CompanionMessage(kind: .error, text: "Mac 已拒绝、取消配对或请求已超时")) { [weak self] in
            self?.pairingPeers[request.id]?.close()
        }
    }
    private func expirePairingRequest(_ id: UUID, after seconds: TimeInterval, approved: Bool) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.pairingRequest?.id == id, self.pairingRequest?.approved == approved else { return }
            self.cancelPairingRequest()
        }
    }
    private func startPairingListener() {
        pairingListener?.cancel(); pairingListener = nil
        pairingReady = false; updateReady()
        guard pairedDevice == nil else { return }
        AppLog.shared.record(.companion, .started, operation: .companionPairingListener)
        do {
            let parameters = CompanionConnection.pairingParameters(peerToPeer: networkScope == .localNetwork)
            if networkScope == .loopbackTests { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
            let value = try NWListener(using: parameters)
            value.service = NWListener.Service(name: CompanionProtocol.pairingName(serviceID), type: discoveryService,
                txtRecord: NWTXTRecord(["role": "pairing"]))
            value.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.acceptPairing(connection) }
            }
            value.stateUpdateHandler = { [weak self, weak value] state in
                Task { @MainActor in
                    guard let self, let value, self.pairingListener === value else { return }
                    switch state {
                    case .ready:
                        self.pairingReady = true; self.updateReady(); self.error = nil
                        AppLog.shared.record(.companion, .ready, operation: .companionPairingListener)
                    case .failed(let error), .waiting(let error):
                        self.pairingReady = false; self.updateReady()
                        self.error = "配对服务被系统阻止或启动失败，请重新启动 Mac App 并检查本地网络权限"
                        AppLog.shared.record(.companion, .failed, level: .error, operation: .companionPairingListener, error: error)
                        self.scheduleListenerRestart()
                    default: break
                    }
                }
            }
            value.serviceRegistrationUpdateHandler = { [weak self, weak value] change in
                Task { @MainActor in
                    guard let self, let value, self.pairingListener === value,
                          case .add(let endpoint) = change, case .service(let name, _, _, _) = endpoint else { return }
                    self.registeredPairingName = name
                    // Bonjour may rename a competing instance; publish the actual pairing route.
                    self.listener?.service = self.desktopService()
                }
            }
            pairingListener = value; value.start(queue: .main)
        } catch {
            self.error = "无法启动配对服务，请重试"
            AppLog.shared.record(.companion, .failed, level: .error, operation: .companionPairingListener, error: error)
            scheduleListenerRestart()
        }
    }
    private func acceptPairing(_ connection: NWConnection) {
        guard pairedDevice == nil, pairingPeers.count < 2 else { connection.cancel(); return }
        let id = UUID(), peer = CompanionConnection(connection)
        pairingPeers[id] = peer
        peer.onClose = { [weak self] in
            guard let self else { return }
            self.pairingPeers[id] = nil; self.pairingSessions[id] = nil
            if self.pairingRequest?.id == id {
                // A proven phone now reconnects through TLS; retain its short-lived permission.
                self.pairingRequest = nil; self.pairingCode = ""
            }
        }
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            if message.kind == .pairRequest {
                guard self.pairedDevice == nil, self.pairingRequest == nil,
                      message.signature == CompanionProtocol.signature,
                      let device = message.device, !device.isEmpty, device.count <= 128 else {
                    peer.send(CompanionMessage(kind: .error, text: "Mac 正在处理其他配对请求，请稍后重试")) { peer.close() }; return
                }
                let name = String((message.name ?? "iPhone").prefix(64))
                AppLog.shared.record(.companion, .response, operation: .companionRequest, span: id)
                self.pairingRequest = PairingRequest(id: id, device: device, name: name)
                peer.send(CompanionMessage(kind: .pairWaiting))
                self.expirePairingRequest(id, after: self.requestLifetime, approved: false)
                return
            }
            if message.kind == .pairCancel {
                if self.pairingRequest?.id == id { self.cancelPairingRequest() } else { peer.close() }
                return
            }
            guard let request = self.pairingRequest, request.id == id, request.approved,
                  self.pairedDevice == nil, Date() < self.pairingExpires else {
                peer.send(CompanionMessage(kind: .error, text: "请先请求配对并等待 Mac 接受")) { peer.close() }; return
            }
            do {
                switch message.kind {
                case .pairStart:
                    guard self.pairingAttempts < 5 else { self.cancelPairingRequest(); return }
                    self.pairingAttempts += 1
                    guard self.pairingSessions[id] == nil, message.signature == CompanionProtocol.signature,
                          message.device == request.device, let key = message.publicKey else {
                        throw CurrentError.message("配对请求无效")
                    }
                    let session = try CompanionPairing.Server(username: CompanionPairing.username(service: self.serviceID, device: request.device), code: self.pairingCode, publicKey: key)
                    self.pairingSessions[id] = (request.device, session)
                    peer.send(session.challenge())
                case .pairProof:
                    guard let (device, session) = self.pairingSessions.removeValue(forKey: id), let proof = message.proof else { throw CurrentError.message("配对请求无效") }
                    let response = try session.complete(proof: proof, secret: self.connectionSecret)
                    AppLog.shared.record(.companion, .succeeded, operation: .companionVerification, span: id)
                    self.pendingPairDevice = device
                    peer.send(response)
                default: peer.close()
                }
            } catch {
                if self.pairingAttempts >= 5 { self.cancelPairingRequest() }
                else { peer.send(CompanionMessage(kind: .error, text: "配对码不正确，请重新输入 Mac 上的 4 位数字")) }
            }
        }
        peer.start()
        Task { [weak self, weak peer] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(15))
            if self.pairingRequest?.id != id { peer?.close() }
        }
    }
    private func accept(_ connection: NWConnection) {
        guard peers.count < 4 else { connection.cancel(); return }
        let id = UUID(), peer = CompanionConnection(connection)
        peers[id] = peer
        peer.onMessage = { [weak self] message in self?.receive(message, peer: id) }
        peer.onClose = { [weak self] in
            guard let self else { return }
            self.peers[id] = nil; self.authenticated.remove(id); self.inventories[id] = nil
            self.connected = !self.authenticated.isEmpty; self.sent.removeAll()
            if !self.connected { self.beginNearbyDiscovery() }
        }
        peer.start()
        Task { [weak self, weak peer] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !self.authenticated.contains(id) else { return }
            peer?.close()
        }
    }
    private func receive(_ message: CompanionMessage, peer id: UUID) {
        guard let peer = peers[id] else { return }
        if message.kind == .hello {
            guard message.version == CompanionProtocol.version, message.signature == CompanionProtocol.signature, let device = message.device,
                  device.count <= 128, pairedDevice == device || (pendingPairDevice == device && Date() < pairingExpires) else {
                peer.send(CompanionMessage(kind: .error, text: "配对设备或分析版本不匹配")); return
            }
            do {
                try vault.save(CompanionPair(service: serviceID, secret: connectionSecret, device: device), key: "mac-pair")
                pairedDevice = device; pendingPairDevice = nil; pairingRequest = nil; listenerRetryAttempt = 0; updateReady()
                pairingListener?.cancel(); pairingListener = nil
                for other in Array(pairingPeers.values) { other.close() }
                pairingCode = ""
                for other in authenticated where other != id { peers[other]?.close() }
                authenticated.insert(id); connected = true; sent.removeAll()
                stopNearbyDiscovery(); nearbyAttempt = 0
                peer.send(CompanionMessage(kind: .welcome, name: Host.current().localizedName ?? "Current Mac", account: account))
            } catch { peer.send(CompanionMessage(kind: .error, text: "无法保存配对，请检查钥匙串权限")) }
            return
        }
        guard authenticated.contains(id) else { peer.close(); return }
        switch message.kind {
        case .authorize:
            guard !authorizing, let scope = message.account, let cookies = message.cookies,
                  cookies.count <= 50, cookies["MUSIC_U"] != nil, cookies.values.allSatisfy({ $0.utf8.count < 16_384 }) else { return }
            authorizing = true
            let ticket = authorizationVersion
            Task {
                defer { authorizing = false }
                let candidate = makeAPI(); candidate.useCompanionCredentials(cookies)
                do {
                    let profile = try await candidate.profile()
                    guard ticket == authorizationVersion, authenticated.contains(id) else { return }
                    guard scope == "netease:\(profile.id)" else { throw CurrentError.expired }
                    if account != nil && account != scope { revoke() }
                    try vault.save(CompanionAuthorization(account: scope, cookies: candidate.companionCredentials()), key: "mac-auth")
                    interrupt(); account = scope; api.useCompanionCredentials(candidate.companionCredentials())
                    for i in jobs.indices where jobs[i].state == .authorizationRequired { jobs[i].state = .queued }
                    error = nil; persist(); publish(); pump()
                } catch {
                    guard ticket == authorizationVersion else { return }
                    peer.send(CompanionMessage(kind: .error, text: "授权验证失败，请在手机更新授权"))
                }
            }
        case .session:
            if account != nil && message.account != account { revoke() }
            guard message.ids?.count ?? 0 <= 100_000 else { return }
            let inventory = Set(message.ids ?? []); inventories[id] = inventory
            if let scope = message.account {
                let removed = jobs.filter { $0.account == scope && !inventory.contains($0.id) }.map(\.id)
                cancel(removed)
            }
            publish(); deliver()
        case .submit:
            guard let scope = account, let entries = message.jobs, entries.count <= 1000,
                  message.account == scope, let inventory = inventories[id] else {
                peer.send(CompanionMessage(kind: .error, text: "请先更新授权，再提交任务")); return
            }
            for entry in entries where entry.account == scope && inventory.contains(entry.id) && !entry.track.isDemo && entry.requestID != nil {
                if let i = jobs.firstIndex(where: { $0.id == entry.id }) {
                    guard jobs[i].track.id == entry.track.id, jobs[i].account == scope else { continue }
                    if jobs[i].state == .unavailable {
                        // A repeated batch/force submission cannot revive a known unavailable song.
                        jobs[i].requestID = entry.requestID
                        continue
                    }
                    if jobs[i].requestID != entry.requestID { interrupt(ids: [entry.id]) }
                    jobs[i].requestID = entry.requestID; sent.remove(entry.id)
                    if message.force != true, var result = jobs[i].result, (try? result.validate()) != nil {
                        result.requestID = entry.requestID
                        jobs[i].result = result
                        do { try JSONEncoder().encode(result).write(to: resultFile(entry.id), options: .atomic) }
                        catch { self.error = "结果保存失败，请重试"; continue }
                        jobs[i].state = .completed
                    } else if jobs[i].state != .fetching && jobs[i].state != .analyzing {
                        jobs[i].state = .queued; jobs[i].failure = nil
                    }
                } else { jobs.append(CompanionJob(id: entry.id, track: entry.track, account: scope, requestID: entry.requestID)) }
            }
            persist(); publish(); deliver(); pump()
        case .acknowledge:
            let acknowledged = Set(jobs.filter {
                (message.ids ?? []).contains($0.id) && $0.account == account && $0.state == .completed && $0.requestID == message.requestID
            }.map(\.id))
            if !acknowledged.isEmpty, !retireJobs(acknowledged) { return }
            publish(); deliver()
        case .control:
            if let paused = message.analysisPaused { setAnalysisPaused(paused) }
            if let paused = message.syncPaused { setSyncPaused(paused) }
        case .cancel: cancel(message.ids ?? [])
        case .revoke: revoke(); publish()
        case .unpair: peer.send(CompanionMessage(kind: .goodbye)) { [weak self] in self?.unpair() }
        case .poll: publish(); deliver()
        default: break
        }
    }
    private static func clampConcurrency(_ value: Int) -> Int {
        min(concurrencyRange.upperBound, max(concurrencyRange.lowerBound, value))
    }
    func setConcurrency(_ value: Int) {
        guard !stopped else { return }
        let bounded = Self.clampConcurrency(value)
        guard bounded != concurrentAnalyses else { return }
        concurrentAnalyses = bounded
        persist(); pump()
    }
    func setAnalysisPaused(_ value: Bool) {
        analysisPaused = value
        if value { interrupt() } else { pump() }
        persist(); publish()
    }
    func setSyncPaused(_ value: Bool) { syncPaused = value; persist(); publish(); if !value { sent.removeAll(); deliver() } }
    func retryFailed() {
        for i in jobs.indices where jobs[i].state == .failed { jobs[i].state = .queued; jobs[i].failure = nil }
        error = nil; persist(); publish(); pump()
    }
    func cancel(_ ids: [UUID]) {
        let removed = Set(ids)
        interrupt(ids: removed)
        jobs.removeAll { removed.contains($0.id) }; sent.subtract(removed)
        for id in removed { try? FileManager.default.removeItem(at: resultFile(id)) }
        persist(); publish(); pump()
    }
    func unpair() {
        revoke(); pairedDevice = nil
        vault.delete("mac-pair")
        for peer in Array(peers.values) { peer.close() }
        connectionSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        cancelPairingRequest(); pairingCode = ""; start()
    }
    private func revoke() {
        authorizationVersion = UUID(); epoch = UUID(); interrupt()
        account = nil; api.clear(); vault.delete("mac-auth")
        jobs = []; sent.removeAll()
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("Results"))
        persist()
    }
    private func interrupt(ids: Set<UUID>? = nil) {
        for (id, task) in runs where ids?.contains(id) ?? true {
            task.cancel()
            if let i = jobs.firstIndex(where: { $0.id == id && ($0.state == .fetching || $0.state == .analyzing) }) { jobs[i].state = .queued }
        }
        // Cancelled workers retain their slot until they actually finish.
        persist()
    }
    private func pump() {
        guard !analysisPaused, !sleeping, !archiveFailed, api.hasCredentials, let account else { return }
        while !archiveFailed, runs.count < concurrentAnalyses,
              let job = jobs.first(where: { $0.account == account && $0.state == .queued && runs[$0.id] == nil }) {
            startAnalysis(job)
        }
    }
    private func startAnalysis(_ job: CompanionJob) {
        let ticket = epoch
        // Independent cookie state prevents concurrent responses from changing another job's authorization.
        let jobAPI = makeAPI(); jobAPI.useCompanionCredentials(api.companionCredentials())
        setState(job.id, .fetching)
        guard !archiveFailed else { return }
        runs[job.id] = Task {
            defer { runs[job.id] = nil; runningCount = runs.count; pump() }
            var local: URL?
            defer { if let local { try? FileManager.default.removeItem(at: local) } }
            do {
                var result: CompanionResult
                if let processor { result = try await processor(job, jobAPI) }
                else {
                    let url = try await jobAPI.playbackURL(id: job.track.id)
                    local = try await AnalysisAudioDownloader.fetch(url)
                    try Task.checkCancellation()
                    guard epoch == ticket, jobs.contains(where: { $0.id == job.id && $0.requestID == job.requestID && $0.account == job.account }) else { return }
                    let wiki = try? await jobAPI.songWiki(id: job.track.id)
                    let lyrics: LyricsAnalysis?
                    if let document = try? await jobAPI.lyrics(id: job.track.id) { lyrics = try? await LyricsAnalyzer.analyze(document) }
                    else { lyrics = nil }
                    try Task.checkCancellation()
                    guard let local else { return }
                    setState(job.id, .analyzing)
                    let features = try await NativeSongAnalyzer.analyze(url: local)
                    let genres = try await GenreAnalyzer.analyze(url: local)
                    let semantic = try await DCLAPAnalyzer.analyze(url: local)
                    try Task.checkCancellation()
                    result = CompanionResult(jobID: job.id, trackID: job.track.id, account: job.account,
                        signature: CompanionProtocol.signature, features: features, genres: genres,
                        vector: semantic.vector, windowStarts: semantic.windowStarts, semanticElapsed: semantic.elapsedSeconds, lyrics: lyrics, wiki: wiki)
                }
                try Task.checkCancellation()
                result.requestID = job.requestID
                try result.validate()
                guard epoch == ticket, let i = jobs.firstIndex(where: { $0.id == job.id && $0.requestID == job.requestID && $0.account == job.account }) else { return }
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("Results"), withIntermediateDirectories: true)
                try JSONEncoder().encode(result).write(to: resultFile(job.id), options: .atomic)
                jobs[i].result = result; jobs[i].state = .completed; jobs[i].failure = nil
                if persist() { publish(); deliver() }
            } catch {
                guard epoch == ticket, let i = jobs.firstIndex(where: { $0.id == job.id && $0.requestID == job.requestID && $0.account == job.account }) else { return }
                if Task.isCancelled { jobs[i].state = .queued }
                else if case CurrentError.expired = error {
                    jobs[i].state = .authorizationRequired
                    vault.delete("mac-auth"); api.clear(); interrupt()
                } else if case CurrentError.unavailable(let reason) = error {
                    jobs[i].state = .unavailable
                    jobs[i].unavailability = reason
                    jobs[i].failure = reason.message
                    jobs[i].result = nil
                } else {
                    jobs[i].state = .failed
                    jobs[i].failure = SongPoolErrorText.message(error)
                }
                persist(); publish()
            }
        }
        runningCount = runs.count
    }
    private func setState(_ id: UUID, _ state: CompanionJobState) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].state = state; persist(); publish()
    }
    /// Only called after a matching phone ACK, or for legacy records already marked synced.
    /// Commit the smaller queue before deleting result files, preserving retry data on disk failure.
    @discardableResult private func retireJobs(_ ids: Set<UUID>) -> Bool {
        let previous = jobs
        jobs.removeAll { ids.contains($0.id) }
        guard persist() else { jobs = previous; return false }
        sent.subtract(ids)
        for id in ids { try? FileManager.default.removeItem(at: resultFile(id)) }
        return true
    }
    private func publish() {
        let statuses = activeJobs.map { CompanionJobStatus(id: $0.id, track: $0.track, state: $0.state, failure: $0.failure, requestID: $0.requestID, unavailability: $0.unavailability) }
        for id in authenticated {
            peers[id]?.send(CompanionMessage(kind: .status, account: account, statuses: statuses, analysisPaused: analysisPaused, syncPaused: syncPaused, authorizationAvailable: api.hasCredentials))
        }
    }
    private func deliver() {
        guard !syncPaused, !archiveFailed else { return }
        // Only one unacknowledged result is sent at a time, bounding memory and retries.
        for id in authenticated {
            guard let inventory = inventories[id], let job = jobs.first(where: {
                $0.state == .completed && $0.account == account && inventory.contains($0.id) && !sent.contains($0.id)
            }), let result = job.result else { continue }
            guard sent.isEmpty else { return }
            sent.insert(job.id); peers[id]?.send(CompanionMessage(kind: .result, result: result))
        }
    }
    private func resultFile(_ id: UUID) -> URL { folder.appendingPathComponent("Results").appendingPathComponent(id.uuidString + ".json") }
    @discardableResult private func persist() -> Bool {
        guard !archiveFailed else { return false }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var metadata = jobs
            for i in metadata.indices { metadata[i].result = nil }
            try JSONEncoder().encode(Archive(jobs: metadata, analysisPaused: analysisPaused, syncPaused: syncPaused, concurrency: concurrentAnalyses))
                .write(to: folder.appendingPathComponent("tasks.json"), options: .atomic)
            return true
        } catch { archiveFailed = true; for task in runs.values { task.cancel() }; self.error = "任务保存失败，已停止分析，请检查磁盘空间"; return false }
    }
}

// Fixed user-facing messages: system errors may contain signed URLs.
enum SongPoolErrorText {
    static func message(_ error: Error) -> String {
        if let error = error as? GenreError { return error.localizedDescription }
        if let error = error as? SemanticError { return error.localizedDescription }
        if let error = error as? AnalysisError { return error.localizedDescription }
        if case CurrentError.unavailable(let reason) = error { return reason.message }
        if case CurrentError.expired = error { return "网易云授权已过期，请在手机更新授权" }
        if let issue = error as? URLError {
            return issue.code == .timedOut ? "获取音频超时，请重试" : "获取音频时网络出错，请重试"
        }
        return "获取或分析失败，请重试"
    }
}
