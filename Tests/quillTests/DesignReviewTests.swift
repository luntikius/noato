import AppKit
import Foundation
import Testing
@testable import quill

/// Optional rendered evidence uses the actual controllers and native cells.
/// Every meeting is a fixture. It neither records audio nor reads live work.
@Suite("Native design review", .serialized)
@MainActor
struct DesignReviewTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func capture(_ window: NSWindow, name: String, directory: URL) throws {
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        if ProcessInfo.processInfo.environment["NOATO_SCREEN_CAPTURE"] == "1" {
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l", String(window.windowNumber), directory.appendingPathComponent(name + ".png").path]
            try task.run(); task.waitUntilExit()
            if task.terminationStatus == 0 { return }
        }
        let view = try #require(window.contentView?.superview)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: view.bounds).fill()
        view.displayIgnoringOpacity(view.bounds, in: NSGraphicsContext.current!)
        image.unlockFocus()
        let data = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOATO_DESIGN_DIR"] != nil))
    func renderNativeScreens() throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NOATO_DESIGN_DIR"]))
        _ = try #require(ProcessInfo.processInfo.environment["NOATO_DATA_DIR"])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let settings = SettingsWindowController()
        let welcome = WelcomeWindowController()
        let menu = MenuBarController()
        let date = MeetingTestFixtures.now
        let recording = MeetingJob(meeting: Meeting(id: "recording", started: date, application: .telemost, directory: output.appendingPathComponent("recording")), phase: .recording)
        var progress = MeetingJob(meeting: Meeting(id: "processing", started: date.addingTimeInterval(-7200), application: .zoom, directory: output.appendingPathComponent("processing")), phase: .transcribing)
        progress.fraction = 0.64; progress.estimatedSeconds = 120; progress.detail = "Microphone"
        let queued = MeetingJob(meeting: Meeting(id: "queued", started: date.addingTimeInterval(-3600), application: .telemost, directory: output.appendingPathComponent("queued")), phase: .queued)
        let failed = MeetingJob(meeting: Meeting(id: "failed", started: date.addingTimeInterval(-10800), application: .zoom, directory: output.appendingPathComponent("failed")), phase: .failed, error: "The audio track could not be read. Recording kept for retry.")
        let completed = (1...5).map { index in CompletedTranscript(id: "done-\(index)", title: "Nov 10 · 1\(index):00 · Zoom", file: output.appendingPathComponent("Zoom — 2026-11-10_1\(index)-00-00.md"), savedAt: date, startedAt: date) }
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            settings.present()
            let window = try #require(settings.window)
            let tab = try #require(window.contentView.flatMap { descendants($0).compactMap { $0 as? NSTabView }.first })
            for item in tab.tabViewItems {
                tab.selectTabViewItem(item)
                try capture(window, name: "\(theme)-settings-\(item.identifier as? String ?? "tab")", directory: output)
                if item.identifier as? String == "Recording", let page = item.view,
                   let disclosure = descendants(page).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Timing & minimum duration" }) {
                    disclosure.performClick(nil)
                    window.contentView?.layoutSubtreeIfNeeded()
                    let scroll = try #require(page as? NSScrollView)
                    let document = try #require(scroll.documentView)
                    #expect(document.frame.height > scroll.contentView.bounds.height)
                    document.scrollToVisible(NSRect(x: 0, y: document.bounds.maxY - 1, width: document.bounds.width, height: 1))
                    try capture(window, name: "\(theme)-settings-Recording-timing", directory: output)
                    disclosure.performClick(nil)
                    document.scrollToVisible(NSRect(x: 0, y: 0, width: document.bounds.width, height: 1))
                }
            }
            settings.close()
            welcome.present(); try capture(try #require(welcome.window), name: "\(theme)-welcome", directory: output); welcome.close()
            menu.configure(sources: AudioSources())
            menu.update(recording: false, elapsed: nil)
            try captureMenu(menu.menuForReview, name: "\(theme)-menu-idle", directory: output)
            menu.update(recording: true, elapsed: "12:34", application: .telemost, microphone: "MacBook Pro Microphone")
            try captureMenu(menu.menuForReview, name: "\(theme)-menu-recording", directory: output)
            menu.transcriptions.update(TranscriptionState(jobs: [progress, recording, queued, failed], completed: completed))
            try captureMenu(menu.transcriptions.menu, name: "\(theme)-transcripts", directory: output)
            let preview = MeetingDeletion(age: .week, cutoff: date, candidates: [.init(id: "old", started: date, paths: [], fingerprint: "preview", bytes: 40000000)], skippedActive: 2)
            let alert = DeletionAlerts.retention(preview, automatic: true)
            alert.layout(); try capture(alert.window, name: "\(theme)-deletion-confirmation", directory: output); alert.window.close()
        }
        NSApp.appearance = nil
    }

    private func captureMenu(_ menu: NSMenu, name: String, directory: URL) throws {
        let view = MenuEvidence(menu)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "noato · Design review · Sample data"; window.isReleasedWhenClosed = false
        window.contentView = view
        try capture(window, name: name, directory: directory)
        window.close()
    }
}

@MainActor
private final class MenuEvidence: NSView {
    private let entries: [(NSMenuItem, NSRect)]
    override var isFlipped: Bool { true }
    init(_ menu: NSMenu) {
        var top: CGFloat = 8
        var entries: [(NSMenuItem, NSRect)] = []
        for item in menu.items where !item.isHidden {
            let height = item.view?.frame.height ?? (item.isSeparatorItem ? 10 : 25)
            entries.append((item, NSRect(x: 0, y: top, width: 480, height: height)))
            top += height
        }
        self.entries = entries
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: top + 8))
        for (item, frame) in entries {
            let container = NSView(frame: frame)
            if let view = item.view { view.frame = container.bounds; container.addSubview(view) }
            else if !item.isSeparatorItem {
                let label = NSTextField(labelWithString: item.title)
                label.font = .menuFont(ofSize: 13); label.textColor = item.isEnabled ? .labelColor : .secondaryLabelColor
                label.frame = NSRect(x: 14, y: 2, width: 445, height: frame.height - 3)
                container.addSubview(label)
            }
            addSubview(container)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: bounds).fill()
        for (item, frame) in entries where item.isSeparatorItem {
            NSColor.separatorColor.setFill(); NSBezierPath(rect: NSRect(x: 12, y: frame.midY, width: 456, height: 1)).fill()
        }
    }
}
