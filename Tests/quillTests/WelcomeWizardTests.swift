import AppKit
import Testing
@testable import quill

@Suite("Sequential setup controls", .serialized)
@MainActor
struct WelcomeWizardTests {
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func action(_ step: SetupStep, in root: NSView) throws -> NSButton {
        let row = try #require(views(root).first { $0.identifier?.rawValue == "setup-step-\(step.rawValue)" })
        return try #require(views(row).compactMap { $0 as? NSButton }.first)
    }
    @Test func onlyMicrophoneIsEnabledAndFinishCannotCompleteEarly() throws {
        _ = NSApplication.shared
        let wizard = WelcomeWindowController(microphoneAllowed: { false })
        defer { wizard.close() }
        let root = try #require(wizard.window?.contentView)
        #expect(try action(.microphone, in: root).isEnabled)
        #expect(try !action(.systemAudio, in: root).isEnabled)
        #expect(try !action(.models, in: root).isEnabled)
        let finish = try #require(views(root).compactMap { $0 as? NSButton }.first { $0.title == "Finish Setup" })
        #expect(!finish.isEnabled)
        var completed = false
        wizard.onComplete = { completed = true }
        finish.performClick(nil)
        #expect(!completed)
    }
    @Test func existingPermissionShowsCheckAndUnlocksOnlySystemAudio() throws {
        _ = NSApplication.shared
        let wizard = WelcomeWindowController(microphoneAllowed: { true })
        defer { wizard.close() }
        let root = try #require(wizard.window?.contentView)
        let row = try #require(views(root).first { $0.identifier?.rawValue == "setup-step-0" })
        let icon = try #require(views(row).compactMap { $0 as? NSImageView }.first)
        #expect(icon.contentTintColor == .systemGreen)
        #expect(try action(.microphone, in: root).isHidden)
        #expect(try action(.systemAudio, in: root).isEnabled)
        #expect(try !action(.models, in: root).isEnabled)
    }
}
