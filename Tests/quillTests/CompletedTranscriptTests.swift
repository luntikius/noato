import Foundation
import Testing
@testable import quill

@Suite("Five recent completed transcripts")
struct CompletedTranscriptTests {
    @Test func newestSavedFirstLimitFiveAndExcludeUnfinished() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("meetings")
        for index in 0..<7 {
            // Old meetings can finish later: sort by save time, not meeting date.
            let dir = try MeetingTestFixtures.session(root, id: "item-\(index)",
                started: MeetingTestFixtures.now.addingTimeInterval(Double(-index) * 86400))
            let file = try RecordingArchive.finish(dir, destination: destination, body: "text", hasMicrophoneSpeech: true)
            try FileManager.default.setAttributes([.creationDate: MeetingTestFixtures.now.addingTimeInterval(Double(index) * 60)], ofItemAtPath: file.path)
        }
        #expect(CompletedTranscript.latest(in: destination).map(\.id) == ["item-6", "item-5", "item-4", "item-3", "item-2"])
        #expect(CompletedTranscript.latest(in: destination, excluding: ["item-6"]).map(\.id) == ["item-5", "item-4", "item-3", "item-2", "item-1"])
    }

    @Test func editsCopiesUnrelatedMarkdownAndLinksDoNotPolluteHistory() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("meetings")
        let dir = try MeetingTestFixtures.session(root)
        let file = try RecordingArchive.finish(dir, destination: destination, body: "text", hasMicrophoneSpeech: true)
        // User edits do not make an already completed document disappear.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(" edited".utf8)); try handle.close()
        let copy = destination.appendingPathComponent("copy.md")
        try FileManager.default.copyItem(at: file, to: copy)
        try Data("# personal note".utf8).write(to: destination.appendingPathComponent("note.md"))
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("link.md"), withDestinationURL: file)
        let history = CompletedTranscript.latest(in: destination)
        #expect(history.map(\.id) == ["recording-1"])
        #expect(history[0].file.lastPathComponent != "link.md")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: copy)
        #expect(CompletedTranscript.latest(in: destination).isEmpty)
    }

    @Test func coordinatorRestoresHistoryAfterCommitAndRefreshesAfterDeletion() async throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("meetings")
        let dir = try MeetingTestFixtures.session(root)
        let meeting = try Meeting.read(dir)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let output = destination.appendingPathComponent(meeting.filename + ".md")
        try MarkdownMeeting.render(meeting, body: "committed").write(to: output)
        let coordinator = TranscriptionCoordinator(destination: destination)
        await coordinator.setRecording(meeting, revision: 1)
        await coordinator.refreshCompleted()
        #expect(await coordinator.state().completed.isEmpty)
        await coordinator.setRecording(nil, revision: 2)
        await coordinator.resumePending(root: root)
        #expect(await coordinator.state().jobs.isEmpty)
        #expect(await coordinator.state().completed.map(\.id) == ["recording-1"])
        #expect(!ArtifactFiles.isDirectory(dir))
        let preview = await coordinator.previewDeletion(root: root, age: .day,
            now: MeetingTestFixtures.now.addingTimeInterval(86401), protecting: nil)
        let result = await coordinator.delete(preview, protecting: nil)
        #expect(result.deleted == 1)
        #expect(await coordinator.state().completed.isEmpty)
        #expect(!ArtifactFiles.isRegular(output))
    }
}
