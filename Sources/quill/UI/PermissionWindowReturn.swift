import AppKit

/// Owns focus handoff for one permission window. A newer request or an
/// explicit close invalidates the old callback, so it cannot reopen the UI.
@MainActor
final class PermissionWindowReturn: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private var generation: UInt = 0

    func attach(to window: NSWindow) {
        self.window = window
        window.hidesOnDeactivate = false
        window.delegate = self
    }

    func begin() -> UInt {
        generation &+= 1
        return generation
    }

    @discardableResult
    func restore(_ request: UInt) -> Bool {
        guard request == generation, let window else { return false }
        generation &+= 1
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func windowWillClose(_ notification: Notification) { generation &+= 1 }
}
