import CryptoKit
import Foundation
import Network
import Security

struct NearbyMac: Equatable, Identifiable, Sendable {
    let endpoint: NWEndpoint
    let name: String
    let publicKey: Data

    var id: Data { publicKey }
}

struct TrustedMac: Codable, Sendable {
    let name: String
    let publicKey: Data
}

struct MacIdentity {
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    var publicKey: Data { privateKey.publicKey.rawRepresentation }

    static func load() throws -> Self {
        let directory = URL.applicationSupportDirectory
            .appending(path: "Keyboard Handoff", directoryHint: .isDirectory)
        let file = directory.appending(path: "identity")

        if FileManager.default.fileExists(atPath: file.path) {
            return try Self(privateKey: .init(rawRepresentation: Data(contentsOf: file)))
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let identity = Self(privateKey: .init())
        try identity.privateKey.rawRepresentation.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return identity
    }

    func key(for publicKey: Data) throws -> SymmetricKey {
        let otherMac = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        return try privateKey.sharedSecretFromKeyAgreement(with: otherMac)
            .hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data("Keyboard Handoff v1".utf8),
                sharedInfo: Data(),
                outputByteCount: 32
            )
    }
}

enum HandoffError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

@MainActor
final class PeerConnection {
    private static let maxMessageSize = 1_024

    private let connection: NWConnection
    private var timeout: Task<Void, Never>?

    static func parameters(key: SymmetricKey) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions

        // Network.framework supports pre-shared keys with TLS 1.2.
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let cipher = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        sec_protocol_options_append_tls_ciphersuite(options, cipher)

        let secret = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("Keyboard Handoff v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, secret as __DispatchData, identity as __DispatchData)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    init(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: .main)
    }

    convenience init(to endpoint: NWEndpoint, key: SymmetricKey) {
        self.init(NWConnection(to: endpoint, using: Self.parameters(key: key)))
    }

    func setTimeout(_ duration: Duration) {
        timeout?.cancel()
        timeout = Task { [connection] in
            do {
                try await Task.sleep(for: duration)
                connection.cancel()
            } catch is CancellationError {
                return
            } catch {
                connection.cancel()
            }
        }
    }

    func close() {
        timeout?.cancel()
        connection.cancel()
    }

    func send<Value: Encodable>(_ value: Value) async throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= Self.maxMessageSize else {
            throw HandoffError.message("The handoff message is too large.")
        }

        var length = UInt16(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive<Value: Decodable>(_ type: Value.Type) async throws -> Value {
        let header = try await read(bytes: 2)
        let length = header.reduce(0) { $0 * 256 + Int($1) }
        guard (1...Self.maxMessageSize).contains(length) else {
            throw HandoffError.message("The other Mac sent an invalid message.")
        }

        let payload = try await read(bytes: length)
        return try JSONDecoder().decode(type, from: payload)
    }

    private func read(bytes: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: bytes, maximumLength: bytes) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == bytes {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: HandoffError.message("The other Mac closed the connection."))
                }
            }
        }
    }
}

@MainActor
final class NearbyMacs {
    private static let serviceType = "_keyhandoff._tcp"
    private let name = Host.current().localizedName ?? "Mac"
    private let identity: MacIdentity
    private var browser: NWBrowser?
    private var listener: NWListener?

    var onPeers: (([NearbyMac]) -> Void)?
    var onConnection: ((NWConnection) -> Void)?
    var onError: ((String) -> Void)?

    init(identity: MacIdentity) {
        self.identity = identity
    }

    func startBrowsing() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: "local."), using: .tcp)
        let localKey = identity.publicKey
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let peers = results.compactMap { result -> NearbyMac? in
                guard case .service(let name, _, _, _) = result.endpoint,
                      case .bonjour(let record) = result.metadata,
                      let encodedKey = record["key"],
                      let key = Data(base64Encoded: encodedKey),
                      key.count == 32, key != localKey else { return nil }
                return NearbyMac(endpoint: result.endpoint, name: name, publicKey: key)
            }

            Task { @MainActor in
                self?.onPeers?(peers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error), .waiting(let error):
                Task { @MainActor in self?.onError?("Mac discovery failed. \(error.localizedDescription)") }
            default:
                break
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func advertise(key: SymmetricKey?) throws {
        let listener = try NWListener(using: key.map(PeerConnection.parameters) ?? .tcp)
        var record = NWTXTRecord()
        record["key"] = identity.publicKey.base64EncodedString()
        listener.service = NWListener.Service(name: name, type: Self.serviceType, domain: "local.", txtRecord: record)

        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor in
                guard let self, self.listener === listener, key != nil,
                      let onConnection = self.onConnection else {
                    connection.cancel()
                    return
                }
                onConnection(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            if case .failed(let error) = state {
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    self.onError?("Couldn’t advertise this Mac. \(error.localizedDescription)")
                }
            }
        }

        self.listener?.cancel()
        self.listener = listener
        listener.start(queue: .main)
    }
}
