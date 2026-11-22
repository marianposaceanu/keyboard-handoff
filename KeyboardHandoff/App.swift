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
                        let core = Process()
                        core.executableURL = Bundle.main.executableURL?.deletingLastPathComponent()
                            .appendingPathComponent("keyboard-handoff-core")
                        core.arguments = ["--serve"]
                        core.standardInput = FileHandle.nullDevice
                        core.standardOutput = FileHandle.nullDevice
                        core.standardError = FileHandle.nullDevice
                        try core.run()
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

    private func display(_ snapshot: Snapshot) {
        guard state != snapshot else { return }
        state = snapshot
        menu.removeAllItems()
        let keyboard = NSImage(systemSymbolName: snapshot.busy ? "keyboard.badge.ellipsis" : "keyboard",
                               accessibilityDescription: snapshot.busy ? "Sending keyboard" : "Keyboard Handoff")
            ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard Handoff")
        keyboard?.isTemplate = true
        item.button?.image = keyboard?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
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
