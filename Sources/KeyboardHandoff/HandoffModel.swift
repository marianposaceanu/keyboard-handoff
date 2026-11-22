import CryptoKit
import Foundation
import Network
import Observation

enum HandoffRequest: Codable, Sendable {
    case offer(Keyboard)
    case status(Keyboard)
}

enum HandoffReply: Codable, Equatable, Sendable {
    case ready
    case connected
    case disconnected
    case busy
    case refused(String)
}

enum HandoffAction: String, Codable {
    case connect
}

@MainActor
@Observable
final class HandoffModel {
    private static let peerSetting = "trustedMac"
    private static let keyboardSetting = "keyboard"

    private let bluetooth = BluetoothKeyboards()
    private let defaults = UserDefaults.standard
    private var identity: MacIdentity?
    private var discovery: NearbyMacs?
    private var peerKey: SymmetricKey?

    private(set) var peers: [NearbyMac] = []
    private(set) var trustedMac: TrustedMac?
    private(set) var keyboard: Keyboard?
    private(set) var knownKeyboards: [Keyboard] = []
    private(set) var status = "Looking for nearby Macs…"
    private(set) var isBusy = false

    var destination: NearbyMac? {
        guard let trustedMac else { return nil }
        return peers.first { $0.publicKey == trustedMac.publicKey }
    }

    func start() {
        do {
            let identity = try MacIdentity.load()
            self.identity = identity
            keyboard = readSetting(Keyboard.self, key: Self.keyboardSetting).flatMap { $0.isValid ? $0 : nil }
            trustedMac = readSetting(TrustedMac.self, key: Self.peerSetting)
            peerKey = try trustedMac.map { try identity.key(for: $0.publicKey) }

            let discovery = NearbyMacs(identity: identity)
            self.discovery = discovery
            discovery.onPeers = { [weak self] peers in self?.peers = peers }
            discovery.onConnection = { [weak self] connection in
                guard let self, let trustedMac = self.trustedMac else {
                    connection.cancel()
                    return
                }
                Task { await receive(on: PeerConnection(connection), from: trustedMac.publicKey) }
            }
            discovery.onError = { [weak self] message in self?.status = message }
            try discovery.advertise(key: peerKey)
            discovery.startBrowsing()
            status = trustedMac == nil ? "Choose your other Mac on both Macs." : "Ready"
        } catch {
            status = error.localizedDescription
        }
        refreshKeyboards()
    }

    func trust(_ peer: NearbyMac) {
        guard !isBusy, let identity, let discovery else { return }
        do {
            let key = try identity.key(for: peer.publicKey)
            try discovery.advertise(key: key)
            peerKey = key
            let trusted = TrustedMac(name: peer.name, publicKey: peer.publicKey)
            save(trusted, key: Self.peerSetting)
            trustedMac = trusted
            status = "Trusted \(peer.name)."
        } catch {
            status = error.localizedDescription
        }
    }

    func forgetMac() {
        guard !isBusy else { return }
        do {
            try discovery?.advertise(key: nil)
            peerKey = nil
            trustedMac = nil
            defaults.removeObject(forKey: Self.peerSetting)
            status = "Choose your other Mac on both Macs."
        } catch {
            status = error.localizedDescription
        }
    }

    func refreshKeyboards() {
        knownKeyboards = bluetooth.knownKeyboards()
    }

    func select(_ keyboard: Keyboard) {
        guard !isBusy, keyboard.isValid else { return }
        self.keyboard = keyboard
        save(keyboard, key: Self.keyboardSetting)
        status = "Selected \(keyboard.name)."
    }

    func clearKeyboard() {
        guard !isBusy else { return }
        keyboard = nil
        defaults.removeObject(forKey: Self.keyboardSetting)
        status = "Choose a Bluetooth keyboard."
    }

    func send() async {
        guard !isBusy else { return }
        guard let destination, let peerKey else {
            status = "Open Keyboard Handoff on your other Mac and make sure it’s awake."
            return
        }
        guard let keyboard else {
            status = "Choose your Magic Keyboard first."
            return
        }

        isBusy = true
        defer { isBusy = false }
        var released = false
        var connectionRequested = false
        let channel = PeerConnection(to: destination.endpoint, key: peerKey)
        defer { channel.close() }

        do {
            try bluetooth.prepareToRelease(keyboard)
            status = "Checking \(destination.name)…"
            channel.setTimeout(.seconds(6))
            try await channel.send(HandoffRequest.offer(keyboard))
            let reply = try await channel.receive(HandoffReply.self)

            guard reply == .ready else {
                status = switch reply {
                case .busy: "\(destination.name) is busy. Try again in a moment."
                case .refused(let message): message
                case .connected: "The keyboard is already on \(destination.name)."
                default: "\(destination.name) couldn’t receive the keyboard."
                }
                return
            }

            status = "Sending \(keyboard.name) to \(destination.name)…"
            channel.setTimeout(.seconds(12))
            released = true
            try await bluetooth.release(keyboard)
            channel.setTimeout(.seconds(95))
            connectionRequested = true
            try await channel.send(HandoffAction.connect)
            let result = try await channel.receive(HandoffReply.self)

            switch result {
            case .connected:
                status = "\(keyboard.name) is on \(destination.name)."
            case .refused(let message):
                await restore(keyboard, after: message)
            default:
                throw HandoffError.message("Couldn’t confirm that the keyboard switched.")
            }
        } catch {
            channel.close()
            if connectionRequested {
                let result = await checkDestination(for: keyboard, at: destination, key: peerKey)
                switch result {
                case .connected:
                    status = "\(keyboard.name) is on \(destination.name)."
                case .disconnected:
                    await restore(keyboard, after: "The handoff was interrupted.")
                default:
                    status = "Check the keyboard on \(destination.name). Reconnect it by USB if needed."
                }
            } else if released {
                await restore(keyboard, after: error.localizedDescription)
            } else if error is NWError {
                status = "Couldn’t reach \(destination.name). Make sure both Macs have approved each other."
            } else {
                status = error.localizedDescription
            }
        }
    }

    private func receive(on channel: PeerConnection, from publicKey: Data) async {
        defer { channel.close() }
        channel.setTimeout(.seconds(6))
        do {
            let request = try await channel.receive(HandoffRequest.self)
            guard trustedMac?.publicKey == publicKey else { return }
            switch request {
            case .status(let keyboard):
                let reply: HandoffReply = if isBusy {
                    .busy
                } else if keyboard.isValid && self.keyboard?.address == keyboard.address && bluetooth.isConnected(keyboard) {
                    .connected
                } else {
                    .disconnected
                }
                try await channel.send(reply)
            case .offer(let keyboard):
                try await accept(keyboard, on: channel)
            }
        } catch {
            return
        }
    }

    private func accept(_ offered: Keyboard, on channel: PeerConnection) async throws {
        guard !isBusy else {
            try await channel.send(HandoffReply.busy)
            return
        }
        guard offered.isValid, keyboard == nil || keyboard?.address == offered.address else {
            try await channel.send(HandoffReply.refused("Select the same keyboard on both Macs."))
            return
        }
        do {
            try bluetooth.checkAvailability()
        } catch {
            try await channel.send(HandoffReply.refused("The other Mac needs Bluetooth access."))
            return
        }

        isBusy = true
        defer { isBusy = false }
        channel.setTimeout(.seconds(12))
        try await channel.send(HandoffReply.ready)
        _ = try await channel.receive(HandoffAction.self)
        channel.setTimeout(.seconds(92))

        status = "Connecting \(offered.name)…"
        do {
            try await bluetooth.connect(offered)
        } catch {
            status = error.localizedDescription
            try await channel.send(HandoffReply.refused(status))
            return
        }

        keyboard = offered
        save(offered, key: Self.keyboardSetting)
        status = "\(offered.name) is connected here."
        try await channel.send(HandoffReply.connected)
    }

    private func checkDestination(for keyboard: Keyboard, at peer: NearbyMac, key: SymmetricKey) async -> HandoffReply? {
        let channel = PeerConnection(to: peer.endpoint, key: key)
        defer { channel.close() }
        channel.setTimeout(.seconds(5))
        do {
            try await channel.send(HandoffRequest.status(keyboard))
            return try await channel.receive(HandoffReply.self)
        } catch {
            return nil
        }
    }

    private func restore(_ keyboard: Keyboard, after message: String) async {
        status = "\(message) Reconnecting here…"
        do {
            try await bluetooth.connect(keyboard)
            status = "\(message) The keyboard is back on this Mac."
        } catch {
            status = "\(message) Reconnect the keyboard by USB."
        }
    }

    private func readSetting<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<Value: Encodable>(_ value: Value, key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
