import Foundation
import Testing
@testable import quill

@Suite("Markdown commit and complete session cleanup")
struct RecordingArchiveTests {
    @Test func successLeavesOnlyMarkdown() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root)
        let destination = root.appendingPathComponent("meetings")
        try Data("old log".utf8).write(to: dir.appendingPathComponent("transcribe.log"))
        #expect(RecordingArchive.needsProcessing(dir))
        let output = try RecordingArchive.finish(dir, destination: destination, body: "**[0:01] me:** Проверка\n", hasMicrophoneSpeech: true)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(ArtifactFiles.children(destination).map(\.standardizedFileURL) == [output.standardizedFileURL])
        let mark = try #require(MarkdownMeeting.read(output))
        #expect(mark.id == "recording-1")
        #expect(mark.started == MeetingTestFixtures.now)
        #expect(mark.verified)
        #expect(output.lastPathComponent.hasPrefix("Zoom — 2026-11-10_"))
    }

    @Test func failedSaveKeepsBothTracks() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root)
        let blocked = root.appendingPathComponent("blocked")
        try Data([1]).write(to: blocked)
        #expect(throws: (any Error).self) {
            try RecordingArchive.finish(dir, destination: blocked, body: "text", hasMicrophoneSpeech: true)
        }
        #expect(ArtifactFiles.isRegular(dir.appendingPathComponent("mic.caf")))
        #expect(ArtifactFiles.isRegular(dir.appendingPathComponent("system.caf")))
    }

    @Test func collisionsPreservePreviousMeeting() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try MeetingTestFixtures.session(root, id: "one")
        let second = try MeetingTestFixtures.session(root, id: "two")
        let destination = root.appendingPathComponent("meetings")
        let a = try RecordingArchive.finish(first, destination: destination, body: "first", hasMicrophoneSpeech: true)
        let original = try Data(contentsOf: a)
        let b = try RecordingArchive.finish(second, destination: destination, body: "second", hasMicrophoneSpeech: true)
        #expect(a != b)
        #expect(try Data(contentsOf: a) == original)
    }

    @Test func crashAfterMarkdownSaveResumesWithoutModelsOrDuplicates() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root)
        let destination = root.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let meeting = try Meeting.read(dir)
        let file = destination.appendingPathComponent(meeting.filename + ".md")
        try MarkdownMeeting.render(meeting, body: "complete").write(to: file)
        #expect(try RecordingArchive.resumeCommitted(dir, destination: destination)?.standardizedFileURL == file.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(ArtifactFiles.children(destination).map(\.standardizedFileURL) == [file.standardizedFileURL])
    }

    @Test func changedMarkdownPreventsAudioDeletion() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root)
        let destination = root.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let meeting = try Meeting.read(dir)
        let file = destination.appendingPathComponent("output.md")
        var data = MarkdownMeeting.render(meeting, body: "original")
        data.append(Data(" changed".utf8))
        try data.write(to: file)
        #expect(throws: (any Error).self) { try RecordingArchive.resumeCommitted(dir, destination: destination) }
        #expect(ArtifactFiles.isRegular(dir.appendingPathComponent("mic.caf")))
    }

    @Test func missingMicrophoneAndCaptureErrorsKeepAudio() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root)
        let destination = root.appendingPathComponent("meetings")
        #expect(throws: (any Error).self) {
            try RecordingArchive.finish(dir, destination: destination, body: "remote only", hasMicrophoneSpeech: false)
        }
        #expect(ArtifactFiles.isRegular(dir.appendingPathComponent("mic.caf")))
        #expect(ArtifactFiles.children(destination).isEmpty)
        var meta = try RecordingArchive.metadata(dir)
        meta["microphone_signal"] = ["write_errors": 1]
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        #expect(throws: (any Error).self) {
            try RecordingArchive.finish(dir, destination: destination, body: "some speech", hasMicrophoneSpeech: true)
        }
        #expect(ArtifactFiles.isRegular(dir.appendingPathComponent("system.caf")))
    }

    @Test func pathEscapesAndUnknownSessionFilesPreventCleanup() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root)
        var meta = try RecordingArchive.metadata(dir)
        meta["files"] = ["mic": "../outside.wav"]
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        #expect(throws: (any Error).self) {
            try RecordingArchive.finish(dir, destination: root.appendingPathComponent("meetings"), body: "text", hasMicrophoneSpeech: true)
        }
        meta["files"] = ["mic": "mic.caf"]
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        try Data([7]).write(to: dir.appendingPathComponent("personal.txt"))
        #expect(throws: (any Error).self) {
            try RecordingArchive.finish(dir, destination: root.appendingPathComponent("meetings"), body: "text", hasMicrophoneSpeech: true)
        }
        #expect(ArtifactFiles.isRegular(dir.appendingPathComponent("personal.txt")))
    }

    @Test func legacyMigrationVerifiesBothOutputsAndCleansEverythingElse() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root)
        let destination = root.appendingPathComponent("meetings")
        let receipt = try MeetingTestFixtures.legacy(dir, destination: destination)
        let output = try #require(try RecordingArchive.resumeCommitted(dir, destination: destination))
        #expect(output.path == receipt.markdown)
        #expect(MarkdownMeeting.read(output)?.verified == true)
        #expect(!FileManager.default.fileExists(atPath: receipt.json))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(ArtifactFiles.children(destination).map(\.standardizedFileURL) == [output.standardizedFileURL])
    }

    @Test func modifiedLegacyJsonPreventsMigration() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root)
        let destination = root.appendingPathComponent("meetings")
        let r = try MeetingTestFixtures.legacy(dir, destination: destination)
        try Data("changed".utf8).write(to: URL(fileURLWithPath: r.json))
        #expect(throws: (any Error).self) { try RecordingArchive.resumeCommitted(dir, destination: destination) }
        #expect(ArtifactFiles.isDirectory(dir))
        #expect(MarkdownMeeting.read(URL(fileURLWithPath: r.markdown)) == nil)
    }
    @Test func interruptedLegacyMigrationRemovesOnlyVerifiedJson() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root)
        let destination = root.appendingPathComponent("meetings")
        let old = try MeetingTestFixtures.legacy(dir, destination: destination)
        let file = URL(fileURLWithPath: old.markdown)
        // Crash after replacing the Markdown but before saving export.plist.
        try MarkdownMeeting.render(try Meeting.read(dir), body: "saved").write(to: file)
        #expect(try RecordingArchive.resumeCommitted(dir, destination: destination)?.standardizedFileURL == file.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(!FileManager.default.fileExists(atPath: old.json))
        #expect(MarkdownMeeting.read(file)?.verified == true)
    }

    @Test func danglingSymlinkIsNotOverwrittenByExport() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root)
        let destination = root.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let meeting = try Meeting.read(dir)
        let link = destination.appendingPathComponent(meeting.filename + ".md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("absent"))
        let output = try RecordingArchive.finish(dir, destination: destination, body: "text", hasMicrophoneSpeech: true)
        #expect(output.lastPathComponent == meeting.filename + "-2.md")
        #expect((try link.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)
    }

}
