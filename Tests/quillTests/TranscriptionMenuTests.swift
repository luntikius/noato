import AppKit
import Foundation
import Testing
@testable import quill

@Suite("Transcription submenu", .serialized)
@MainActor
struct TranscriptionMenuTests {
    private func labels(_ view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
    }

    @Test func liveRowsThenFiveCompletedAndClickOpensMarkdown() throws {
        _ = NSApplication.shared
        let controller = TranscriptionMenuController()
        func job(_ id: String, _ app: CallApplication, _ phase: MeetingPhase) -> MeetingJob {
            MeetingJob(meeting: Meeting(id: id, started: MeetingTestFixtures.now, application: app,
                                       directory: URL(fileURLWithPath: "/tmp/\(id)")), phase: phase)
        }
        var processing = job("processing", .zoom, .transcribing)
        processing.fraction = 0.58
        processing.estimatedSeconds = 240
        processing.detail = "Microphone"
        let pending = job("pending", .telemost, .queued)
        var failed = job("failed", .zoom, .failed)
        failed.error = "Аудио не удалось прочитать. Запись сохранена."
        let recent = (1...5).map { n in
            CompletedTranscript(id: "done-\(n)", title: "11.11.2026 · 1\(n):00 · Zoom",
                file: URL(fileURLWithPath: "/tmp/done-\(n).md"), savedAt: MeetingTestFixtures.now, startedAt: MeetingTestFixtures.now)
        }
        controller.update(TranscriptionState(jobs: [processing, pending, failed], completed: recent))
        let activeItems = controller.menu.items.filter { $0.view != nil && !($0.representedObject is URL) }
        #expect(activeItems.count == 3)
        let firstView = try #require(activeItems.first?.view)
        #expect(labels(firstView).contains("Transcribing · Microphone · this stage: about 4 min remaining"))
        #expect(labels(try #require(activeItems[1].view)).contains("Queued"))
        #expect(controller.menu.items.filter { $0.representedObject is URL }.count == 5)
        let titles = controller.menu.items.map(\.title)
        #expect(try #require(titles.firstIndex(of: "Recently completed")) > #require(titles.firstIndex(of: processing.meeting.title)))
        let firstCompleted = try #require(controller.menu.items.firstIndex { $0.representedObject is URL })
        var opened: URL?
        controller.onOpenTranscript = { opened = $0 }
        controller.menu.performActionForItem(at: firstCompleted)
        #expect(opened == recent[0].file)
        // A progress tick updates the existing custom view while the menu tracks.
        processing.fraction = 0.75
        controller.update(TranscriptionState(jobs: [processing, pending, failed], completed: recent))
        #expect(controller.menu.items.first(where: { $0.view != nil })?.view === firstView)

        controller.update(TranscriptionState(jobs: [], completed: recent))
        #expect(controller.menu.items.filter { $0.view != nil && !($0.representedObject is URL) }.isEmpty)
        #expect(controller.menu.items.map(\.title).contains("No current transcriptions"))
        controller.update(TranscriptionState(jobs: [], completed: []))
        #expect(controller.menu.items.map(\.title).contains("No completed transcripts yet"))
    }

    @Test func closingMenuKeepsJobsAndFailureActions() throws {
        _ = NSApplication.shared
        let controller = TranscriptionMenuController()
        let meeting = Meeting(id: "failed", started: MeetingTestFixtures.now, application: .telemost,
                              directory: URL(fileURLWithPath: "/tmp/failed"))
        let failure = MeetingJob(meeting: meeting, phase: .failed, error: "Запись сохранена")
        controller.update(TranscriptionState(jobs: [failure], completed: []))
        let view = try #require(controller.menu.items.first(where: { $0.view != nil })?.view)
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        var retried: String?
        controller.onRetry = { retried = $0 }
        try #require(buttons(view).first { $0.title == "Retry" }).performClick(nil)
        let deadline = Date().addingTimeInterval(1)
        while retried == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        #expect(retried == "failed")
        controller.menuDidClose(controller.menu)
        #expect(labels(view).contains("Запись сохранена"))
        #expect(buttons(view).map(\.title) == ["Retry", "Delete"])
    }
    @Test func completedTrashRequestsConfirmationWithoutOpeningDocument() throws {
        _ = NSApplication.shared
        let controller = TranscriptionMenuController()
        let completed = CompletedTranscript(id: "done", title: "11.11.2026 · 12:00 · Zoom",
            file: URL(fileURLWithPath: "/tmp/done.md"), savedAt: MeetingTestFixtures.now, startedAt: MeetingTestFixtures.now)
        controller.update(TranscriptionState(jobs: [], completed: [completed]))
        let view = try #require(controller.menu.items.first(where: { $0.representedObject is URL })?.view)
        let trash = try #require(view.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "Delete transcript" })
        if let path = ProcessInfo.processInfo.environment["QUILL_COMPLETED_ROW_PREVIEW"] {
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: view.bounds).fill()
            view.displayIgnoringOpacity(view.bounds, in: NSGraphicsContext.current!)
            image.unlockFocus()
            if let data = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: data),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: path))
            }
            window.close()
        }
        var requested: String?
        var opened = false
        controller.onDeleteCompleted = { requested = $0.id }
        controller.onOpenTranscript = { _ in opened = true }
        trash.performClick(nil)
        let deadline = Date().addingTimeInterval(1)
        while requested == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        #expect(requested == "done")
        #expect(!opened)
    }

}
