import AppKit
import Darwin
import Observation

@main
enum CoreMain {
    private static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            #if HANDOFF_FIXTURE
            guard let path = ProcessInfo.processInfo.environment["HANDOFF_TEST_SOCKET"] else { fail("Missing test socket.") }
            #else
            let path = try CoreIPC.socketPath()
            #endif
            switch args {
            case ["--help"]:
                print("keyboard-handoff-core status | send | stop | --serve")
            case ["--serve"]:
                try serve(path: path)
            case ["status"], ["send"], ["stop"]:
                do {
                    let command: Command = args == ["status"] ? .status : (args == ["send"] ? .send : .stop)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    print(String(decoding: try encoder.encode(CoreIPC.request(command, path: path)), as: UTF8.self))
                } catch IPCError.offline where args == ["status"] {
                    print("The core is stopped.")
                }
            default:
                fail("Usage: keyboard-handoff-core status | send | stop | --serve", code: 2)
            }
        } catch { fail(error.localizedDescription) }
    }

    @MainActor
    private static func serve(path: String) throws {
        let lock = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw IPCError.message("Core already running.") }
        defer { close(lock) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.message("Cannot open server socket.") }
        defer { close(fd) }
        var address = try CoreIPC.address(path)
        unlink(path)
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw IPCError.message("Cannot listen on core socket.") }
        defer { unlink(path) }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let model = HandoffModel()
        #if HANDOFF_FIXTURE
        let hotkey: GlobalHotKey? = nil
        #else
        model.start()
        let hotkey = GlobalHotKey { await model.send() }
        model.observeChanges()
        #endif
        let shortcut = hotkey != nil
        Task.detached {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue }; return }
                defer { close(client) }
                guard CoreIPC.sameUser(client) else { continue }
                CoreIPC.options(client, receiveTimeout: 2)
                var stopping = false
                do {
                    let request = try CoreIPC.read(Request.self, from: client)
                    guard request.version == 1 else { throw IPCError.message("Incompatible local core protocol.") }
                    let snapshot = try await model.handle(request.command, shortcut: shortcut)
                    if case .stop = request.command { stopping = true }
                    try CoreIPC.write(snapshot, to: client)
                } catch {
                    try? CoreIPC.write(Snapshot(error: error.localizedDescription), to: client)
                }
                if stopping { exit(0) }
            }
        }
        withExtendedLifetime(hotkey) { app.run() }
    }
}

extension HandoffModel {
    func observeChanges() {
        withObservationTracking {
            _ = (status, peers, isBusy, keyboard, knownKeyboards, trustedMac)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeChanges()
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("local.keyboard-handoff.changed"), object: nil, userInfo: nil,
                    deliverImmediately: true)
            }
        }
    }

    func handle(_ command: Command, shortcut: Bool) throws -> Snapshot {
        if isBusy {
            switch command {
            case .status: break
            default: throw IPCError.message("A handoff is in progress.")
            }
        }
        switch command {
        case .status, .stop: break
        case .send:
            guard destination != nil, keyboard != nil else { throw IPCError.message("Choose an available Mac and keyboard.") }
            Task { await self.send() }
        case .refresh: refreshKeyboards()
        case .forget: forgetMac()
        case .clear: clearKeyboard()
        case .trust(let id):
            guard let peer = peers.first(where: { $0.publicKey.base64EncodedString() == id }) else {
                throw IPCError.message("The selected Mac is unavailable.")
            }
            trust(peer)
        case .select(let id):
            guard let item = knownKeyboards.first(where: { $0.address == id }) else {
                throw IPCError.message("The selected keyboard is unavailable.")
            }
            select(item)
        }
        return Snapshot(status: status, peer: trustedMac?.name, keyboard: keyboard?.name,
                        peers: peers.map { Choice(id: $0.publicKey.base64EncodedString(), name: $0.name) },
                        keyboards: knownKeyboards.map { Choice(id: $0.address, name: $0.name) },
                        busy: isBusy, reachable: destination != nil, shortcut: shortcut)
    }
}
