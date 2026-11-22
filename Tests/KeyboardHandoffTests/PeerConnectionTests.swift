import CryptoKit
import Foundation
import Network
import Testing

@testable import KeyboardHandoff

@MainActor
struct PeerConnectionTests {
    private let keyboard = Keyboard(address: "02-00-00-00-00-01", name: "Magic Keyboard")

    @Test
    func trustedMacsExchangeAnOfferAndConfirmation() async throws {
        let source = MacIdentity(privateKey: .init())
        let destination = MacIdentity(privateKey: .init())
        let sourceKey = try source.key(for: destination.publicKey)
        let destinationKey = try destination.key(for: source.publicKey)

        try await withPeer(key: destinationKey) { channel in
            let request = try await channel.receive(HandoffRequest.self)
            guard case .offer(let offered) = request else {
                Issue.record("Expected a keyboard offer")
                return
            }
            #expect(offered == keyboard)
            try await channel.send(HandoffReply.ready)
            #expect(try await channel.receive(HandoffAction.self) == .connect)
            try await channel.send(HandoffReply.connected)
        } connect: { endpoint in
            let channel = PeerConnection(to: endpoint, key: sourceKey)
            defer { channel.close() }
            channel.setTimeout(.seconds(5))
            try await channel.send(HandoffRequest.offer(keyboard))
            #expect(try await channel.receive(HandoffReply.self) == .ready)
            try await channel.send(HandoffAction.connect)
            #expect(try await channel.receive(HandoffReply.self) == .connected)
        }
    }

    @Test
    func untrustedMacCannotDeliverAnOffer() async throws {
        let source = MacIdentity(privateKey: .init())
        let destination = MacIdentity(privateKey: .init())
        let outsider = MacIdentity(privateKey: .init())
        let destinationKey = try destination.key(for: source.publicKey)
        let outsiderKey = try outsider.key(for: destination.publicKey)

        try await withPeer(key: destinationKey) { channel in
            await #expect(throws: NWError.self) {
                _ = try await channel.receive(HandoffRequest.self)
            }
        } connect: { endpoint in
            let channel = PeerConnection(to: endpoint, key: outsiderKey)
            defer { channel.close() }
            channel.setTimeout(.seconds(5))
            await #expect(throws: NWError.self) {
                try await channel.send(HandoffRequest.offer(keyboard))
                _ = try await channel.receive(HandoffReply.self)
            }
        }
    }

    private func withPeer(
        key: SymmetricKey,
        receive: @escaping @MainActor (PeerConnection) async throws -> Void,
        connect: @MainActor (NWEndpoint) async throws -> Void
    ) async throws {
        let parameters = PeerConnection.parameters(key: key)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)

        let ports = AsyncThrowingStream<NWEndpoint.Port, Error>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port { ports.continuation.yield(port) }
                ports.continuation.finish()
            case .failed(let error), .waiting(let error):
                ports.continuation.finish(throwing: error)
            default:
                break
            }
        }
        let incoming = AsyncStream<NWConnection>.makeStream()
        listener.newConnectionHandler = { connection in
            if case .terminated = incoming.continuation.yield(connection) {
                connection.cancel()
            }
            incoming.continuation.finish()
        }
        listener.start(queue: .main)
        let timeout = Task {
            try await Task.sleep(for: .seconds(8))
            ports.continuation.finish()
            incoming.continuation.finish()
        }
        defer {
            timeout.cancel()
            listener.cancel()
            incoming.continuation.finish()
        }

        var portIterator = ports.stream.makeAsyncIterator()
        let port = try #require(try await portIterator.next())
        let server = Task {
            var iterator = incoming.stream.makeAsyncIterator()
            let connection = try #require(await iterator.next())
            let channel = PeerConnection(connection)
            defer { channel.close() }
            channel.setTimeout(.seconds(5))
            try await receive(channel)
        }
        defer { server.cancel() }

        try await connect(.hostPort(host: "127.0.0.1", port: port))
        try await server.value
    }
}
