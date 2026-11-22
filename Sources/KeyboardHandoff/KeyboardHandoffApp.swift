import AppKit
import SwiftUI

@main
struct KeyboardHandoffApp: App {
    @NSApplicationDelegateAdaptor private var app: AppDelegate

    var body: some Scene {
        MenuBarExtra("Keyboard Handoff", systemImage: app.model.isBusy ? "arrow.left.arrow.right" : "keyboard") {
            HandoffMenu(model: app.model, shortcut: app.shortcut)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = HandoffModel()
    private var hotKey: GlobalHotKey?
    var shortcut: String? { hotKey == nil ? nil : "⌃⌥⌘K" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        hotKey = GlobalHotKey { [weak self] in
            guard let self else { return }
            await model.send()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.unregister()
    }
}

private struct HandoffMenu: View {
    let model: HandoffModel
    let shortcut: String?

    var body: some View {
        if let trustedMac = model.trustedMac {
            Button {
                Task { await model.send() }
            } label: {
                Text(shortcut.map { "Send to \(trustedMac.name)  \($0)" } ?? "Send to \(trustedMac.name)")
            }
            .disabled(model.destination == nil || model.keyboard == nil || model.isBusy)

            if model.destination == nil {
                Text("Waiting for \(trustedMac.name)…")
            }
            Button("Forget \(trustedMac.name)") { model.forgetMac() }
                .disabled(model.isBusy)
        } else if model.peers.isEmpty {
            Text("Looking for nearby Macs…")
        } else {
            ForEach(model.peers) { peer in
                Button("Trust \(peer.name)") { model.trust(peer) }
            }
        }

        Divider()

        if let keyboard = model.keyboard {
            Text(keyboard.name)
            Button("Clear Keyboard") { model.clearKeyboard() }
                .disabled(model.isBusy)
        } else {
            Menu("Choose Keyboard") {
                ForEach(model.knownKeyboards) { keyboard in
                    Button(keyboard.name) { model.select(keyboard) }
                }
                if model.knownKeyboards.isEmpty {
                    Text("No paired Bluetooth keyboards")
                }
                Button("Refresh") { model.refreshKeyboards() }
            }
            .disabled(model.isBusy)
        }

        Divider()

        Text(model.status)
        Button("Quit Keyboard Handoff") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .disabled(model.isBusy)
    }
}
