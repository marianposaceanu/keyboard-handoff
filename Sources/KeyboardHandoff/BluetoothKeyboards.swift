import CoreBluetooth
import Foundation
import IOBluetooth

struct Keyboard: Codable, Hashable, Identifiable, Sendable {
    let address: String
    let name: String

    var id: String { address }

    var isValid: Bool {
        let octets = address.split(separator: "-", omittingEmptySubsequences: false)
        return octets.count == 6
            && octets.allSatisfy { $0.utf8.count == 2 && $0.utf8.allSatisfy(Self.isHexDigit) }
            && (1...120).contains(name.utf8.count)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }
}

@MainActor
final class BluetoothKeyboards: NSObject, IOBluetoothDevicePairDelegate {
    private var pairing: IOBluetoothDevicePair?
    private var pairingResult: CheckedContinuation<Void, Error>?
    private var pairingTimeout: Task<Void, Never>?

    func checkAvailability() throws {
        if [.denied, .restricted].contains(CBManager.authorization) {
            throw HandoffError.message("Allow Keyboard Handoff in Privacy & Security → Bluetooth.")
        }
        guard IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON else {
            throw HandoffError.message("Turn on Bluetooth to use Keyboard Handoff.")
        }
    }

    func knownKeyboards() -> [Keyboard] {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return devices.compactMap { device in
            guard device.deviceClassMajor == kBluetoothDeviceClassMajorPeripheral,
                  device.deviceClassMinor & UInt32(kBluetoothDeviceClassMinorPeripheral1Keyboard) != 0,
                  let rawAddress = device.addressString else { return nil }
            let address = rawAddress.replacingOccurrences(of: ":", with: "-").lowercased()
            let keyboard = Keyboard(address: address, name: device.name ?? "Bluetooth keyboard")
            return keyboard.isValid ? keyboard : nil
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func isConnected(_ keyboard: Keyboard) -> Bool {
        IOBluetoothDevice(addressString: keyboard.address)?.isConnected() ?? false
    }

    func prepareToRelease(_ keyboard: Keyboard) throws {
        try checkAvailability()
        guard isConnected(keyboard) else {
            throw HandoffError.message("Connect \(keyboard.name) to this Mac over Bluetooth first.")
        }
        guard let device = IOBluetoothDevice(addressString: keyboard.address),
              device.responds(to: Self.removeSelector) else {
            throw HandoffError.message("This macOS version can’t release the keyboard automatically.")
        }
    }

    func release(_ keyboard: Keyboard) async throws {
        guard let device = IOBluetoothDevice(addressString: keyboard.address) else {
            throw HandoffError.message("The keyboard is unavailable.")
        }
        try await unpair(device, address: keyboard.address)
    }

    func connect(_ keyboard: Keyboard) async throws {
        try checkAvailability()
        guard keyboard.isValid, let device = IOBluetoothDevice(addressString: keyboard.address) else {
            throw HandoffError.message("The keyboard has an invalid Bluetooth address.")
        }
        if device.isConnected() { return }

        if device.isPaired() {
            if await openConnection(to: keyboard.address) || isConnected(keyboard) { return }
            try await unpair(device, address: keyboard.address)
        }
        guard let target = IOBluetoothDevice(addressString: keyboard.address) else {
            throw HandoffError.message("The keyboard is unavailable.")
        }

        try await pair(target)
        guard await openConnection(to: keyboard.address) else {
            throw HandoffError.message("The keyboard paired, but couldn’t connect.")
        }
    }

    private static let removeSelector = NSSelectorFromString("remove")

    private func unpair(_ device: IOBluetoothDevice, address: String) async throws {
        // IOBluetooth has no public API for forgetting a bonded device.
        guard device.responds(to: Self.removeSelector) else {
            throw HandoffError.message("This macOS version can’t release the keyboard automatically.")
        }

        _ = device.perform(Self.removeSelector)
        // The Bluetooth daemon removes the bond asynchronously and the old handle can be stale.
        try await Task.sleep(for: .milliseconds(500))
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(6)
        while IOBluetoothDevice(addressString: address)?.isConnected() == true {
            guard clock.now < deadline else {
                throw HandoffError.message("macOS didn’t release the keyboard.")
            }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    private func openConnection(to address: String) async -> Bool {
        await Task.detached {
            guard let device = IOBluetoothDevice(addressString: address) else { return false }
            if !device.isConnected() {
                _ = device.openConnection()
            }
            return device.isConnected()
        }.value
    }

    private func pair(_ device: IOBluetoothDevice) async throws {
        guard pairing == nil, let attempt = IOBluetoothDevicePair(device: device) else {
            throw HandoffError.message("Couldn’t start Bluetooth pairing.")
        }

        try await withCheckedThrowingContinuation { continuation in
            pairing = attempt
            pairingResult = continuation
            attempt.delegate = self

            let id = ObjectIdentifier(attempt)
            let result = attempt.start()
            guard result == kIOReturnSuccess else {
                finishPairing(id, error: .message("Couldn’t start Bluetooth pairing (\(result))."))
                return
            }

            pairingTimeout = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(60))
                    self?.finishPairing(id, error: .message("Bluetooth pairing timed out."), stop: true)
                } catch {
                    return
                }
            }
        }
    }

    private func finishPairing(_ id: ObjectIdentifier, error: HandoffError?, stop: Bool = false) {
        guard let pairing, ObjectIdentifier(pairing) == id, let pairingResult else { return }
        pairingTimeout?.cancel()
        pairingTimeout = nil
        pairing.delegate = nil
        if stop { pairing.stop() }
        self.pairing = nil
        self.pairingResult = nil

        if let error {
            pairingResult.resume(throwing: error)
        } else {
            pairingResult.resume()
        }
    }

    nonisolated func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        guard let attempt = sender as? IOBluetoothDevicePair else { return }
        let id = ObjectIdentifier(attempt)
        Task { @MainActor in
            let failure: HandoffError? = error == kIOReturnSuccess
                ? nil
                : .message("Bluetooth pairing failed (\(error)).")
            finishPairing(id, error: failure)
        }
    }

    nonisolated func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        guard let attempt = sender as? IOBluetoothDevicePair else { return }
        let id = ObjectIdentifier(attempt)
        Task { @MainActor in
            guard let pairing, ObjectIdentifier(pairing) == id else { return }
            pairing.replyUserConfirmation(true)
        }
    }

    nonisolated func devicePairingPINCodeRequest(_ sender: Any!) {
        guard let attempt = sender as? IOBluetoothDevicePair else { return }
        let id = ObjectIdentifier(attempt)
        Task { @MainActor in
            finishPairing(id, error: .message("Pair this keyboard in System Settings first."), stop: true)
        }
    }
}
