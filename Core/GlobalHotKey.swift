import Carbon

@MainActor
final class GlobalHotKey {
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private let action: @MainActor () async -> Void

    init?(action: @escaping @MainActor () async -> Void) {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let target = GetApplicationEventTarget()
        let context = Unmanaged.passUnretained(self).toOpaque()

        let installed = InstallEventHandler(target, { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let registration = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in await registration.action() }
            return noErr
        }, 1, &event, context, &eventHandler)
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: 0x4B484F46, id: 1)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_K), modifiers, id, target, 0, &hotKey)
        guard registered == noErr else {
            unregister()
            return nil
        }
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}
