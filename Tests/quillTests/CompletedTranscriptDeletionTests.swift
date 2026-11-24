import Foundation
import Testing
@testable import quill

@Suite("Confirmed single-transcript deletion")
struct CompletedTranscriptDeletionTests {
    @Test func previewAndCancelKeepFileConfirmationDeletesOnlySelected() async throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("meetings")
        for id in ["one", "two"] {
            let dir = try MeetingTestFixtures.session(root, id: id)
            try RecordingArchive.finish(dir, destination: destination, body: id, hasMicrophoneSpeech: true)
        }
        let coordinator = TranscriptionCoordinator(destination: destination)
        await coordinator.refreshCompleted()
        let history = await coordinator.state().completed
        let selected = try #require(history.first { $0.id == "one" })
        let other = try #require(history.first { $0.id == "two" })
        let preview = try await coordinator.previewCompletedDeletion(selected)
        #expect(preview.paths.count == 1)
        // The confirmation can be cancelled: preview itself performs no mutation.
        #expect(ArtifactFiles.isRegular(selected.file))
        #expect(ArtifactFiles.isRegular(other.file))
        #expect(await coordinator.state().completed.count == 2)
        #expect(await coordinator.deleteCompleted(preview) == nil)
        #expect(!ArtifactFiles.isRegular(selected.file))
        #expect(ArtifactFiles.isRegular(other.file))
        #expect(await coordinator.state().completed.map(\.id) == ["two"])
    }

    @Test func changedFileAndPendingJobInvalidateConfirmation() async throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("meetings")
        let dir = try MeetingTestFixtures.session(root)
        let meeting = try Meeting.read(dir)
        let file = try RecordingArchive.finish(dir, destination: destination, body: "text", hasMicrophoneSpeech: true)
        let coordinator = TranscriptionCoordinator(destination: destination)
        await coordinator.refreshCompleted()
        let transcript = try #require(await coordinator.state().completed.first)
        let preview = try await coordinator.previewCompletedDeletion(transcript)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("edited".utf8)); try handle.close()
        #expect(await coordinator.deleteCompleted(preview) != nil)
        #expect(ArtifactFiles.isRegular(file))
        let fresh = try await coordinator.previewCompletedDeletion(transcript)
        await coordinator.setRecording(meeting, revision: 1)
        #expect(await coordinator.deleteCompleted(fresh) != nil)
        #expect(ArtifactFiles.isRegular(file))
    }

    @Test func replacingFileWithSymlinkCannotDeleteTarget() async throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("meetings")
        let dir = try MeetingTestFixtures.session(root)
        let file = try RecordingArchive.finish(dir, destination: destination, body: "text", hasMicrophoneSpeech: true)
        let coordinator = TranscriptionCoordinator(destination: destination)
        await coordinator.refreshCompleted()
        let transcript = try #require(await coordinator.state().completed.first)
        let preview = try await coordinator.previewCompletedDeletion(transcript)
        let target = root.appendingPathComponent("personal.md")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(await coordinator.deleteCompleted(preview) != nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect((try file.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)
    }
    @Test func deletionRefillsFiveMostRecentFromRemainingFiles() async throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("meetings")
        for index in 0..<6 {
            let dir = try MeetingTestFixtures.session(root, id: "item-\(index)")
            let file = try RecordingArchive.finish(dir, destination: destination, body: "text", hasMicrophoneSpeech: true)
            try FileManager.default.setAttributes([.creationDate: MeetingTestFixtures.now.addingTimeInterval(Double(index) * 60)], ofItemAtPath: file.path)
        }
        let coordinator = TranscriptionCoordinator(destination: destination)
        await coordinator.refreshCompleted()
        #expect(await coordinator.state().completed.map(\.id) == ["item-5", "item-4", "item-3", "item-2", "item-1"])
        let transcript = try #require(await coordinator.state().completed.first)
        let preview = try await coordinator.previewCompletedDeletion(transcript)
        #expect(await coordinator.deleteCompleted(preview) == nil)
        #expect(await coordinator.state().completed.map(\.id) == ["item-4", "item-3", "item-2", "item-1", "item-0"])
    }

}
