import AppKit

@main
@MainActor
enum MenuApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = StatusMenu()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class StatusMenu: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var state: Snapshot?
    private var revision = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        display(Snapshot(status: "Connecting to the core…"))
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(coreChanged),
            name: Notification.Name("local.keyboard-handoff.changed"), object: nil)
        request(.status, start: true)
    }

    func menuWillOpen(_ menu: NSMenu) { request(.status) }
    @objc private func coreChanged() { request(.status) }

    private func request(_ command: Command, start: Bool = false, quit: Bool = false) {
        revision += 1
        let current = revision
        Task {
            do {
                let snapshot = try await Task.detached {
                    do { return try CoreIPC.request(command) }
                    catch IPCError.offline where start {
                        try Self.launchCore()
                        for _ in 0..<60 {
                            try await Task.sleep(for: .milliseconds(100))
                            do { return try CoreIPC.request(.status) } catch IPCError.offline { continue }
                        }
                        throw IPCError.message("Core startup timed out.")
                    }
                }.value
                if quit { NSApp.terminate(nil) }
                if revision == current { display(snapshot) }
            } catch {
                if revision == current { display(Snapshot(status: error.localizedDescription, error: error.localizedDescription)) }
            }
        }
    }

    private nonisolated static func launchCore() throws {
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("keyboard-handoff-core") else {
            throw IPCError.message("The bundled core is missing.")
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw IPCError.message("Cannot set up the core session.") }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            throw IPCError.message("Cannot detach the core session.")
        }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw IPCError.message("Cannot set up the core streams.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0...2 {
            guard posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0) == 0 else {
                throw IPCError.message("Cannot redirect core streams.")
            }
        }
        var argv = [strdup(executable.path), strdup("--serve"), nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable.path, &actions, &attributes, &argv, environ) == 0 else {
            throw IPCError.message("Couldn’t launch the bundled core.")
        }
        DispatchQueue.global(qos: .utility).async { [pid] in
            while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
        }
    }

    private func display(_ snapshot: Snapshot) {
        guard state != snapshot else { return }
        state = snapshot
        menu.removeAllItems()
        item.button?.image = StatusIcon.image(sending: snapshot.busy)
        item.button?.toolTip = snapshot.status

        if let peer = snapshot.peer {
            action("Send to " + peer + (snapshot.shortcut ? "    ⌃⌥⌘K" : ""), symbol: "arrow.right", .send,
                   enabled: snapshot.reachable && snapshot.keyboard != nil && !snapshot.busy)
            action("Forget " + peer, symbol: "minus.circle", .forget, enabled: !snapshot.busy)
        } else {
            for peer in snapshot.peers { action("Trust " + peer.name, symbol: "laptopcomputer", .trust(peer.id)) }
        }
        if let keyboard = snapshot.keyboard {
            menu.addItem(withTitle: keyboard, action: nil, keyEquivalent: "")
            action("Clear Keyboard", symbol: "xmark.circle", .clear, enabled: !snapshot.busy)
        } else {
            let chooser = NSMenu()
            chooser.autoenablesItems = false
            for keyboard in snapshot.keyboards {
                action(keyboard.name, symbol: "keyboard", .select(keyboard.id), in: chooser)
            }
            action("Refresh Keyboards", symbol: "arrow.clockwise", .refresh, in: chooser)
            menu.addItem(withTitle: "Choose Keyboard", action: nil, keyEquivalent: "").submenu = chooser
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: snapshot.status, action: nil, keyEquivalent: "")
        if snapshot.error != nil {
            menu.addItem(withTitle: "Reconnect to Core", action: #selector(reconnect), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Hide Menu Bar Icon", action: #selector(hide), keyEquivalent: "").target = self
        let stop = menu.addItem(withTitle: "Stop Handoff & Quit", action: #selector(stopCore), keyEquivalent: "q")
        stop.target = self
        stop.isEnabled = !snapshot.busy
    }

    private func action(_ title: String, symbol: String, _ command: Command, enabled: Bool = true, in target: NSMenu? = nil) {
        let entry = (target ?? menu).addItem(withTitle: title, action: #selector(performCommand(_:)), keyEquivalent: "")
        entry.target = self
        entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        entry.representedObject = command
        entry.isEnabled = enabled
    }

    @objc private func performCommand(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? Command { request(command) }
    }
    @objc private func hide() { NSApp.terminate(nil) }
    @objc private func stopCore() { request(.stop, quit: true) }
    @objc private func reconnect() { request(.status, start: true) }
}
