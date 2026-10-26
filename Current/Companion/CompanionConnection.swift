import Foundation
import Network
import Security
import CryptoKit
import SRP

@MainActor
final class CompanionConnection {
    private let connection: NWConnection
    private var buffer = Data()
    private var ended = false
    private let logSpan = UUID()
    private var handshakeTimeout: Task<Void, Never>?
    private let handshakeLimit: TimeInterval
    var onMessage: ((CompanionMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClose: (() -> Void)?
    var onFailure: ((NWError) -> Void)?
    static func pairingFailureMessage(for error: NWError) -> String? {
        guard case .tls(let code) = error,
              code == errSSLBadRecordMac || code == errSSLPeerBadRecordMac || code == errSSLPeerHandshakeFail else { return nil }
        return "已发现 Mac，但加密连接验证失败，配对可能已失效。请在“更多”中解除配对后重新配对。"
    }
    init(_ connection: NWConnection, handshakeLimit: TimeInterval = 12) {
        self.connection = connection; self.handshakeLimit = handshakeLimit
    }
    static func browsingParameters(peerToPeer: Bool = true) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = peerToPeer
        return parameters
    }
    static func pairingParameters(peerToPeer: Bool = true) -> NWParameters {
        let tcp = NWProtocolTCP.Options(); tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = peerToPeer
        return parameters
    }
    static func parameters(secret: String, peerToPeer: Bool = true) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        // Apple's NWConnection PSK support uses TLS 1.2. An independent random
        // secret authenticates both peers; four-digit codes are only used by SRP.
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        // PSK suites are absent from tls_ciphersuite_t; this API remains required for PSK.
        sec_protocol_options_add_tls_ciphersuite(tls.securityProtocolOptions, SSLCipherSuite(TLS_PSK_WITH_AES_128_GCM_SHA256))
        let key = Data(SHA256.hash(data: Data(secret.utf8)))
        let identity = Data("current-analysis-v1".utf8)
        key.withUnsafeBytes { bytes in
            identity.withUnsafeBytes { name in
                sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                    DispatchData(bytes: bytes) as dispatch_data_t, DispatchData(bytes: name) as dispatch_data_t)
            }
        }
        let tcp = NWProtocolTCP.Options(); tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = peerToPeer
        return parameters
    }
    func start() {
        AppLog.shared.record(.companion, .started, operation: .companionConnection, span: logSpan)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.ended else { return }
                switch state {
                case .ready:
                    AppLog.shared.record(.companion, .ready, operation: .companionConnection, span: self.logSpan)
                    self.handshakeTimeout?.cancel(); self.onReady?(); self.receive()
                case .failed(let error), .waiting(let error):
                    AppLog.shared.record(.companion, .failed, level: .error, operation: .companionConnection, span: self.logSpan, error: error)
                    self.onFailure?(error); self.close()
                case .cancelled: self.close()
                default: break
                }
            }
        }
        handshakeTimeout = Task { [weak self] in
            let limit = self?.handshakeLimit ?? 12
            do { try await Task.sleep(for: .seconds(limit)) } catch { return }
            guard let self, !self.ended else { return }
            AppLog.shared.record(.companion, .failed, level: .warning, operation: .companionConnection, span: self.logSpan,
                                 error: NWError.posix(.ETIMEDOUT))
            self.onFailure?(.posix(.ETIMEDOUT)); self.close()
        }
        connection.start(queue: .main)
    }
    func send(_ message: CompanionMessage, completion: (() -> Void)? = nil) {
        guard !ended, let data = try? JSONEncoder().encode(message), data.count <= CompanionProtocol.maxFrame else { return }
        var length = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(data)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                if error != nil { self?.close() } else { completion?() }
            }
        })
    }
    func close() {
        guard !ended else { return }; ended = true
        handshakeTimeout?.cancel(); connection.cancel(); onClose?()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.ended else { return }
                if let data { self.buffer.append(data) }
                while self.buffer.count >= 4 {
                    let length = self.buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                    guard length > 0, length <= CompanionProtocol.maxFrame else { self.close(); return }
                    guard self.buffer.count >= 4 + length else { break }
                    let payload = Data(self.buffer.dropFirst(4).prefix(length))
                    self.buffer.removeFirst(4 + length)
                    guard let message = try? JSONDecoder().decode(CompanionMessage.self, from: payload),
                          message.version == CompanionProtocol.version else { self.close(); return }
                    self.onMessage?(message)
                }
                if complete || error != nil { self.close() } else { self.receive() }
            }
        }
    }
}

/// SRP-6a authenticates the short code without exposing an offline password oracle.
/// Only the proven session may unwrap the independent, random reconnect secret.
enum CompanionPairing {
    static let configuration = SRPConfiguration<SHA256>(.N2048)
    static func username(service: String, device: String) -> String { "current-pair-v1|\(service)|\(device)" }
    static func key(_ shared: SRPKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared.bytes),
            salt: Data("current-pair-v1".utf8), info: Data("reconnect-secret".utf8), outputByteCount: 32)
    }
    struct Server {
        let username: String
        let salt: [UInt8]
        let verifier: SRPKey
        let keys: SRPKeyPair
        let clientKey: SRPKey
        init(username: String, code: String, publicKey: Data) throws {
            guard publicKey.count == 256 else { throw CurrentError.message("配对请求无效") }
            self.username = username; clientKey = SRPKey(publicKey)
            let values = SRPClient(configuration: configuration).generateSaltAndVerifier(username: username, password: code)
            salt = values.salt; verifier = values.verifier
            keys = SRPServer(configuration: configuration).generateKeys(verifier: verifier)
        }
        func challenge() -> CompanionMessage {
            CompanionMessage(kind: .pairChallenge, publicKey: Data(keys.public.bytes), salt: Data(salt))
        }
        func complete(proof: Data, secret: String) throws -> CompanionMessage {
            guard proof.count == 32 else { throw CurrentError.message("配对码不正确") }
            let server = SRPServer(configuration: configuration)
            let shared = try server.calculateSharedSecret(clientPublicKey: clientKey, serverKeys: keys, verifier: verifier)
            let response = try server.verifyClientProof(proof: Array(proof), username: username, salt: salt,
                clientPublicKey: clientKey, serverPublicKey: keys.public, sharedSecret: shared)
            let sealed = try AES.GCM.seal(Data(secret.utf8), using: key(shared)).combined!
            return CompanionMessage(kind: .pairComplete, proof: Data(response), sealedSecret: sealed)
        }
    }
    final class Client {
        let username: String
        let code: String
        private let client = SRPClient(configuration: configuration)
        private let keys: SRPKeyPair
        private var shared: SRPKey?
        private var proof: [UInt8]?
        init(username: String, code: String) {
            self.username = username; self.code = code; keys = client.generateKeys()
        }
        func start(device: String) -> CompanionMessage { CompanionMessage(kind: .pairStart, device: device, publicKey: Data(keys.public.bytes)) }
        func respond(_ message: CompanionMessage) throws -> CompanionMessage {
            guard shared == nil, let publicKey = message.publicKey, publicKey.count == 256,
                  let salt = message.salt, salt.count == 32 else { throw CurrentError.message("配对请求无效") }
            let serverKey = SRPKey(publicKey)
            let value = try client.calculateSharedSecret(username: username, password: code, salt: Array(salt), clientKeys: keys, serverPublicKey: serverKey)
            let evidence = client.calculateClientProof(username: username, salt: Array(salt), clientPublicKey: keys.public, serverPublicKey: serverKey, sharedSecret: value)
            shared = value; proof = evidence
            return CompanionMessage(kind: .pairProof, proof: Data(evidence))
        }
        func finish(_ message: CompanionMessage) throws -> String {
            guard let shared, let proof, let response = message.proof, response.count == 32,
                  let sealed = message.sealedSecret, sealed.count < 1024 else { throw CurrentError.message("配对请求无效") }
            try client.verifyServerProof(serverProof: Array(response), clientProof: proof, clientPublicKey: keys.public, sharedSecret: shared)
            let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key(shared))
            guard let secret = String(data: clear, encoding: .utf8), secret.count == 64 else { throw CurrentError.message("配对请求无效") }
            return secret
        }
    }
}
