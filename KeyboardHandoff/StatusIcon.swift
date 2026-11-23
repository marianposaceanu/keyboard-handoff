import AppKit

@MainActor
enum StatusIcon {
    static func image(sending: Bool) -> NSImage {
        let title = sending ? "Sending keyboard" : "Keyboard Handoff"
        let size = NSSize(width: 22, height: 18)
        let glyph = NSImage(systemSymbolName: "keyboard", accessibilityDescription: title)
        let arrow = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))
        let image = NSImage(size: size, flipped: false) { _ in
            glyph?.draw(in: NSRect(x: 0, y: 2, width: 20, height: 14))
            if sending {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 11, y: 0, width: 11, height: 11)).fill()
                NSGraphicsContext.restoreGraphicsState()
                NSColor.labelColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12, y: 1, width: 9, height: 9)).fill()
                arrow?.draw(in: NSRect(x: 13.5, y: 3, width: 6, height: 5), from: .zero, operation: .destinationOut, fraction: 1)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = title
        return image
    }
}
