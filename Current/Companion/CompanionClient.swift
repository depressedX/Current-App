import Foundation
import Combine
import Network
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class CompanionClient: ObservableObject {
    typealias Computer = CompanionComputer
    enum PairingStage { case waiting, code, verifying }
    @Published private(set) var pairingStage: PairingStage?
    @Published private(set) var pairingComputerName = "Mac"
    private var requestedComputer: Computer?
    @Published private(set) var computers: [Computer] = []
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var name = "Mac"
    @Published private(set) var error: String?
    @Published private(set) var statuses: [CompanionJobStatus] = []
    @Published private(set) var analysisPaused = false
    @Published private(set) var syncPaused = false
    @Published private(set) var authorized = false
    @Published private(set) var discovering = false
    private var browser: NWBrowser?
    private var discoveryTimeout: Task<Void, Never>?
    private var retryAttempt = 0
    private var discoveryVisible = false
    private let discoveryService: String
    private let scanDuration: TimeInterval
    private let retryBaseDelay: TimeInterval
    private let vault: any CompanionVault
    private var connection: CompanionConnection?
    private var pair: CompanionPair?
    private var candidate: CompanionPair?
    private var pairingSession: CompanionPairing.Client?
    private var api: NetEaseAPI?
    private weak var pool: SongPoolStore?
    private var subscription: AnyCancellable?
    private var pollTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var importing: Set<String> = []
    private var pendingAuthorization = false
    private var pendingUnpair = false
    private var foreground = false
    private var sessionAccount: String?
    private var cancelled: Set<UUID>
    private let deviceID: String
    init(vault: any CompanionVault = KeychainCompanionVault(), deviceID: String? = nil,
         discoveryService: String = CompanionProtocol.service, scanDuration: TimeInterval = 30,
         retryBaseDelay: TimeInterval = 5) {
        self.vault = vault; self.deviceID = deviceID ?? CompanionSecrets.identifier("companion-phone")
        self.discoveryService = discoveryService; self.scanDuration = scanDuration; self.retryBaseDelay = retryBaseDelay
        pair = vault.load("phone-pair", as: CompanionPair.self)
        cancelled = Set((UserDefaults.standard.stringArray(forKey: "companion-cancelled") ?? []).compactMap(UUID.init(uuidString:)))
    }
    var paired: Bool { pair != nil }
    var discoveredPairedComputer: Computer? { computers.first { $0.id == pair?.service } }
    var activeStatuses: [CompanionJobStatus] { statuses.filter { $0.state != .synced } }
    func attach(pool: SongPoolStore, api: NetEaseAPI) {
        guard self.pool == nil else { return }
        self.pool = pool; self.api = api
        pool.onLocalAnalysis = { [weak self] ids in self?.cancelForLocal(ids) }
        subscription = pool.$catalog.debounce(for: .milliseconds(150), scheduler: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor in self?.sendSession() }
        }
    }
    func setForeground(_ active: Bool) {
        foreground = active
        if active {
            if pair != nil || discoveryVisible { discover() }
            sendSession()
        } else {
            stopDiscovery(clearResults: true)
            reconnectTask?.cancel(); reconnectTask = nil
            connection?.close(); connection = nil
        }
    }
    func setDiscoveryVisible(_ visible: Bool) {
        discoveryVisible = visible
        if visible { discover() }
        else if pair == nil { stopDiscovery(clearResults: true) }
    }
    func discover() {
        retryAttempt = 0; reconnectTask?.cancel(); reconnectTask = nil
        beginDiscovery()
    }
    private func stopDiscovery(clearResults: Bool = false) {
        let old = browser; browser = nil
        old?.cancel(); discoveryTimeout?.cancel(); discoveryTimeout = nil; discovering = false
        if clearResults { computers = [] }
    }
    private func scheduleReconnect() {
        guard foreground, pair != nil, !connected, !connecting else { return }
        reconnectTask?.cancel()
        let delay = CompanionDiscoveryPolicy.retryDelay(attempt: retryAttempt, base: retryBaseDelay)
        retryAttempt += 1
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.foreground else { return }
            self.beginDiscovery()
        }
    }
    private func beginDiscovery() {
        guard foreground, browser == nil, !connected, !connecting else { return }
        discovering = true; error = nil; computers = []
        AppLog.shared.record(.companion, .started, operation: .companionDiscovery)
        let value = NWBrowser(for: .bonjourWithTXTRecord(type: discoveryService, domain: nil), using: CompanionConnection.browsingParameters())
        value.browseResultsChangedHandler = { [weak self, weak value] results, _ in
            Task { @MainActor in
                guard let self, let value, self.browser === value else { return }
                self.computers = Computer.unique(results.compactMap { result in
                    guard case .service(let serviceName, _, _, _) = result.endpoint,
                          case .bonjour(let record) = result.metadata else { return nil }
                    var values: [String: String] = [:]
                    for key in ["role", "id", "name", "pair"] {
                        if case .string(let value) = record.getEntry(for: key) { values[key] = value }
                    }
                    return Computer.parse(serviceName: serviceName, endpoint: result.endpoint, values: values, interfaces: result.interfaces)
                })
                AppLog.shared.record(.companion, .response, operation: .companionDiscovery, count: results.count)
                AppLog.shared.record(.companion, .response, operation: .companionDiscoveryVisible, count: self.computers.count)
                self.reconnect()
            }
        }
        value.stateUpdateHandler = { [weak self, weak value] state in
            Task { @MainActor in
                guard let self, let value, self.browser === value else { return }
                switch state {
                case .ready:
                    AppLog.shared.record(.companion, .ready, operation: .companionDiscovery)
                case .failed(let issue), .waiting(let issue):
                    AppLog.shared.record(.companion, .failed, level: .warning, operation: .companionDiscovery, error: issue)
                    self.stopDiscovery(clearResults: true)
                    self.error = "暂时无法发现 Mac，请靠近设备并检查 Wi-Fi 与本地网络权限"
                    self.scheduleReconnect()
                default: break
                }
            }
        }
        browser = value; value.start(queue: .main)
        discoveryTimeout = Task { [weak self, weak value] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(self.scanDuration)) } catch { return }
            guard let value, self.browser === value else { return }
            let empty = self.computers.isEmpty
            AppLog.shared.record(.companion, .cancelled, operation: .companionDiscovery, count: self.computers.count)
            self.stopDiscovery()
            if empty { self.error = "未发现 Mac，请保持两台设备在附近并开启 Wi-Fi，可重新寻找" }
            self.scheduleReconnect()
        }
    }
    func requestPairing(with computer: Computer) {
        guard pair == nil, !connecting else { return }
        guard let endpoint = computer.pairingEndpoint else { return }
        stopDiscovery(); reconnectTask?.cancel(); reconnectTask = nil
        connection?.onClose = nil; connection?.close()
        AppLog.shared.record(.companion, .started, operation: .companionRequest)
        requestedComputer = computer; pairingComputerName = computer.name
        pairingStage = .waiting; connecting = true; error = nil; pendingAuthorization = true
        let value = CompanionConnection(NWConnection(to: endpoint, using: CompanionConnection.pairingParameters())); connection = value
        value.onReady = { [weak self, weak value] in
            guard let self else { return }
            #if canImport(UIKit)
            let deviceName = UIDevice.current.name
            #else
            let deviceName = "Current device"
            #endif
            value?.send(CompanionMessage(kind: .pairRequest, device: self.deviceID, name: deviceName))
        }
        value.onMessage = { [weak self, weak value] message in
            guard let self, self.requestedComputer?.id == computer.id else { return }
            do {
                switch message.kind {
                case .pairWaiting:
                    AppLog.shared.record(.companion, .response, operation: .companionRequest)
                    self.pairingStage = .waiting
                case .pairAccepted:
                    AppLog.shared.record(.companion, .succeeded, operation: .companionApproval)
                    self.pairingStage = .code; self.error = nil
                case .pairChallenge:
                    guard let session = self.pairingSession else { throw CurrentError.message("配对请求无效") }
                    value?.send(try session.respond(message))
                case .pairComplete:
                    guard let session = self.pairingSession else { throw CurrentError.message("配对请求无效") }
                    let secret = try session.finish(message)
                    self.candidate = CompanionPair(service: computer.id, secret: secret, device: self.deviceID)
                    self.pairingSession = nil; self.requestedComputer = nil; self.pairingStage = nil
                    self.connect(computer, secret: secret)
                case .error:
                    self.error = message.text ?? "配对失败"
                    if self.pairingStage == .verifying { self.pairingSession = nil; self.pairingStage = .code }
                default: throw CurrentError.message("配对请求无效")
                }
            } catch {
                self.error = "配对验证失败，请重新请求配对"
                value?.close()
            }
        }
        value.onClose = { [weak self] in
            guard let self else { return }
            self.connecting = false; self.pairingSession = nil
            self.requestedComputer = nil; self.pairingStage = nil
            if self.error == nil { self.error = "配对连接已结束，请重新请求配对" }
        }
        value.start()
    }
    func verifyPairing(code: String) {
        guard pairingStage == .code, let computer = requestedComputer,
              code.count == 4, code.utf8.allSatisfy({ (48...57).contains($0) }) else { return }
        let session = CompanionPairing.Client(username: CompanionPairing.username(service: computer.id, device: deviceID), code: code)
        pairingSession = session; pairingStage = .verifying; error = nil
        connection?.send(session.start(device: deviceID))
    }
    func cancelPairing() {
        guard pairingStage != nil else { return }
        connection?.onClose = nil
        let value = connection
        value?.send(CompanionMessage(kind: .pairCancel)) { value?.close() }
        connection = nil; pairingSession = nil; requestedComputer = nil; pairingStage = nil
        connecting = false; pendingAuthorization = false; error = nil
        // Also close if the transport cannot flush the cancellation.
        Task { try? await Task.sleep(for: .seconds(1)); value?.close() }
    }
    private func reconnect() {
        guard foreground, !connected, !connecting, let pair,
              let computer = computers.first(where: { $0.id == pair.service }) else { return }
        connect(computer, secret: pair.secret)
    }
    private func connect(_ computer: Computer, secret: String) {
        connection?.onClose = nil; connection?.close()
        stopDiscovery(); reconnectTask?.cancel(); reconnectTask = nil
        connecting = true; error = nil
        let value = CompanionConnection(NWConnection(to: computer.endpoint, using: CompanionConnection.parameters(secret: secret)))
        connection = value
        value.onReady = { [weak self, weak value] in
            guard let self else { return }
            value?.send(CompanionMessage(kind: .hello, device: self.deviceID))
        }
        value.onFailure = { [weak self] issue in
            self?.error = CompanionConnection.pairingFailureMessage(for: issue)
                ?? "已发现 Mac，但连接未完成。请确认 Current 分析伴侣已打开且未暂停；如果持续失败，可在“更多”中重新配对。"
        }
        value.onMessage = { [weak self] message in self?.receive(message) }
        value.onClose = { [weak self] in
            guard let self else { return }
            self.connected = false; self.connecting = false; self.authorized = false
            self.pollTask?.cancel()
            if self.candidate != nil {
                if self.error == nil { self.error = "连接失败，请核对配对码与网络" }
                self.candidate = nil
            }
            self.stopDiscovery(clearResults: true)
            self.scheduleReconnect()
        }
        value.start()
    }
    private func receive(_ message: CompanionMessage) {
        switch message.kind {
        case .welcome:
            guard message.version == CompanionProtocol.version, message.signature == CompanionProtocol.signature else { error = "两端分析版本不兼容，请更新 App"; connection?.close(); return }
            if let candidate {
                do { try vault.save(candidate, key: "phone-pair"); pair = candidate; self.candidate = nil }
                catch { self.error = "无法保存配对，请检查钥匙串权限"; connection?.close(); return }
            }
            connected = true; connecting = false; retryAttempt = 0; name = message.name ?? "Current Mac"
            stopDiscovery(clearResults: true)
            sendSession()
            if pendingAuthorization { updateAuthorization() }
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    self?.connection?.send(CompanionMessage(kind: .poll))
                }
            }
        case .goodbye: forgetPairing()
        case .status:
            guard message.version == CompanionProtocol.version, message.signature == CompanionProtocol.signature else { error = "两端版本不兼容"; return }
            statuses = (message.statuses ?? []).filter { $0.state != .synced }; analysisPaused = message.analysisPaused ?? false; syncPaused = message.syncPaused ?? false
            pool?.importCompanionStatuses(statuses, account: message.account)
            authorized = message.account == pool?.account && message.authorizationAvailable == true && api?.hasCredentials == true
        case .result:
            guard !syncPaused, let result = message.result else { return }
            let delivery = result.jobID.uuidString + ":" + (result.requestID?.uuidString ?? "legacy")
            guard !importing.contains(delivery) else { return }
            importing.insert(delivery)
            Task {
                defer { importing.remove(delivery) }
                do {
                    guard let pool else { return }
                    try await pool.importCompanion(result)
                    connection?.send(CompanionMessage(kind: .acknowledge, ids: [result.jobID], requestID: result.requestID))
                } catch {
                    self.error = "结果同步失败：\(error.localizedDescription)"
                    setSyncPaused(true)
                }
            }
        case .error: error = message.text ?? "电脑操作失败"; pendingAuthorization = false
        default: break
        }
    }
    func updateAuthorization() {
        guard connected, let api, api.hasCredentials, let account = pool?.account, account.hasPrefix("netease:") else {
            error = "请先登录网易云并连接 Mac"; return
        }
        pendingAuthorization = false
        connection?.send(CompanionMessage(kind: .authorize, account: account, cookies: api.companionCredentials()))
    }
    func submit(_ ids: Set<UUID>, force: Bool = false) {
        guard connected, authorized, let pool else { error = "请先连接 Mac 并更新授权"; return }
        let selected = pool.songs.filter { ids.contains($0.id) && !$0.track.isDemo && $0.state != .unavailable && (force || !pool.companionReady($0)) }
        guard !selected.isEmpty else { error = "所选歌曲已有兼容结果，或没有可提交的歌曲"; return }
        guard selected.count <= 1000 else { error = "每批最多选择 1000 首"; return }
        let jobs = selected.map { CompanionJob(id: $0.id, track: $0.track, account: pool.account, requestID: UUID()) }
        pool.reserveCompanion(Set(selected.map(\.id)), requests: Dictionary(uniqueKeysWithValues: jobs.compactMap { job in job.requestID.map { (job.id, $0) } }))
        cancelled.subtract(selected.map(\.id)); saveCancellations()
        sendSession()
        connection?.send(CompanionMessage(kind: .submit, account: pool.account, jobs: jobs, force: force))
        error = nil
    }
    func setAnalysisPaused(_ value: Bool) { connection?.send(CompanionMessage(kind: .control, analysisPaused: value)) }
    func setSyncPaused(_ value: Bool) {
        syncPaused = value
        connection?.send(CompanionMessage(kind: .control, syncPaused: value))
        if !value { error = nil; connection?.send(CompanionMessage(kind: .poll)) }
    }
    func retryFailed() { submit(Set(statuses.filter { $0.state == .failed }.map(\.id)), force: true) }
    private func cancelForLocal(_ ids: [UUID]) {
        cancelled.formUnion(ids); saveCancellations()
        if connected { connection?.send(CompanionMessage(kind: .cancel, ids: Array(cancelled))) }
    }
    private func saveCancellations() { UserDefaults.standard.set(cancelled.map(\.uuidString), forKey: "companion-cancelled") }
    func sendSession() {
        guard connected, let pool, !pool.loading else { return }
        let current = pool.account.hasPrefix("netease:") ? pool.account : nil
        if let old = sessionAccount, old != current { connection?.send(CompanionMessage(kind: .revoke)) }
        sessionAccount = current
        connection?.send(CompanionMessage(kind: .session, account: current, ids: pool.songs.map(\.id)))
        if !cancelled.isEmpty { connection?.send(CompanionMessage(kind: .cancel, ids: Array(cancelled))) }
    }
    func revokeAuthorization() {
        authorized = false; sessionAccount = nil
        connection?.send(CompanionMessage(kind: .revoke))
    }
    func unpair() {
        if connected {
            pendingUnpair = true
            connection?.send(CompanionMessage(kind: .unpair))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.pendingUnpair else { return }
                self.error = "解除配对未确认，请重试或在 Mac 端解除"
                self.pendingUnpair = false
            }
        } else {
            forgetPairing()
            error = "手机配对已清除，请在 Mac 端解除配对并清除授权"
        }
    }
    private func forgetPairing() {
        pendingUnpair = false
        connection?.onClose = nil; connection?.close(); connection = nil
        stopDiscovery(clearResults: true)
        pollTask?.cancel(); reconnectTask?.cancel()
        vault.delete("phone-pair"); pair = nil; candidate = nil; pairingSession = nil; pairingStage = nil; requestedComputer = nil
        connected = false; connecting = false; authorized = false; statuses = []
    }
}
