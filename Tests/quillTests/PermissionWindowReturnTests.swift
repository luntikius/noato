import AppKit
import Testing
@testable import quill

@Suite("Permission window focus", .serialized)
@MainActor
struct PermissionWindowReturnTests {
    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func permissionReplyRestoresHiddenOriginalWindow() {
        let window = makeWindow(); defer { window.close() }
        let focus = PermissionWindowReturn(); focus.attach(to: window)
        window.makeKeyAndOrderFront(nil)
        let request = focus.begin()
        window.orderOut(nil)
        #expect(!window.isVisible)
        #expect(focus.restore(request))
        #expect(window.isVisible)
        #expect(!window.hidesOnDeactivate)
        #expect(!focus.restore(request))
    }

    @Test func explicitClosePreventsPermissionReplyFromReopeningWindow() {
        let window = makeWindow()
        let focus = PermissionWindowReturn(); focus.attach(to: window)
        window.makeKeyAndOrderFront(nil)
        let request = focus.begin()
        #expect(window.isVisible)
        window.close()
        #expect(!window.isVisible)
        #expect(!focus.restore(request))
        #expect(!window.isVisible)
    }

    @Test func newerPermissionRequestInvalidatesStaleReply() {
        let window = makeWindow(); defer { window.close() }
        let focus = PermissionWindowReturn(); focus.attach(to: window)
        let old = focus.begin(), latest = focus.begin()
        #expect(!window.isVisible)
        #expect(!focus.restore(old))
        #expect(!window.isVisible)
        #expect(focus.restore(latest))
        #expect(window.isVisible)
    }
}
