import Foundation
import Testing
@testable import quill

private final class RecordingNotifications: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func receive(_ body: String) { lock.lock(); defer { lock.unlock() }; messages.append(body) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return messages }
}
private actor AdmissionCalls {
    private(set) var count = 0
    func process(_ dir: URL) -> URL { count += 1; return dir.appendingPathComponent("result.md") }
}

@Suite("Short recordings never enter ASR")
struct ShortRecordingTests {
    private func duration(_ seconds: Double, in dir: URL) throws {
        var meta = try RecordingArchive.metadata(dir)
        meta["duration_seconds"] = seconds
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
    }

    @Test(arguments: [0.0, 9.0, 9.999])
    func belowTenSecondsIsDiscardedWithOnlyNotification(_ seconds: Double) async throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root)
        try duration(seconds, in: dir)
        let notifications = RecordingNotifications()
        let calls = AdmissionCalls()
        let coordinator = TranscriptionCoordinator(destination: root.appendingPathComponent("meetings"),
            processor: { await calls.process($0) }, notifier: { _, body in notifications.receive(body) })
        #expect(ArtifactFiles.isDirectory(dir))
        await coordinator.enqueue(dir)
        #expect(!ArtifactFiles.isDirectory(dir))
        #expect(await calls.count == 0)
        #expect(await coordinator.state().jobs.isEmpty)
        #expect(await coordinator.state().completed.isEmpty)
        #expect(notifications.values == ["Recording too short — no transcript will be created"])
    }

    @Test func exactlyTenSecondsIsAdmitted() async throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root)
        try duration(10, in: dir)
        let calls = AdmissionCalls()
        let notifications = RecordingNotifications()
        let coordinator = TranscriptionCoordinator(destination: root.appendingPathComponent("meetings"),
            processor: { await calls.process($0) }, notifier: { _, body in notifications.receive(body) })
        await coordinator.enqueue(dir)
        for _ in 0..<1000 {
            if await calls.count == 1 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(await calls.count == 1)
        #expect(ArtifactFiles.isDirectory(dir))
        #expect(!notifications.values.contains("Recording too short — no transcript will be created"))
    }

    @Test func recoveredShortJobAndExplicitReprocessSkipModels() async throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root, id: "restored")
        var meta = try RecordingArchive.metadata(dir)
        meta["ended"] = ISO8601DateFormatter().string(from: MeetingTestFixtures.now.addingTimeInterval(9))
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        let notifications = RecordingNotifications()
        let coordinator = TranscriptionCoordinator(destination: root.appendingPathComponent("meetings"),
            notifier: { _, body in notifications.receive(body) })
        await coordinator.resumePending(root: root)
        #expect(!ArtifactFiles.isDirectory(dir))
        let explicit = try MeetingTestFixtures.session(root, id: "explicit")
        try duration(9.5, in: explicit)
        #expect(try await coordinator.processNow(explicit) == nil)
        #expect(!ArtifactFiles.isDirectory(explicit))
        #expect(notifications.values.count == 2)
        #expect(await coordinator.state().jobs.isEmpty)
    }

    @Test func unsafeFolderAndUnknownDurationArePreserved() async throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let short = try MeetingTestFixtures.session(root, id: "unsafe")
        try duration(5, in: short)
        try Data("keep".utf8).write(to: short.appendingPathComponent("personal.txt"))
        let unknown = try MeetingTestFixtures.session(root, id: "unknown")
        var meta = try RecordingArchive.metadata(unknown)
        meta.removeValue(forKey: "ended")
        try JSONSerialization.data(withJSONObject: meta).write(to: unknown.appendingPathComponent("meta.json"))
        let notifications = RecordingNotifications()
        let coordinator = TranscriptionCoordinator(destination: root.appendingPathComponent("meetings"),
            notifier: { _, body in notifications.receive(body) })
        await coordinator.enqueue(short)
        await coordinator.resumePending(root: root)
        #expect(ArtifactFiles.isRegular(short.appendingPathComponent("personal.txt")))
        #expect(ArtifactFiles.isRegular(unknown.appendingPathComponent("mic.caf")))
        #expect(await coordinator.state().jobs.first(where: { $0.id == "unknown" })?.phase == .failed)
        #expect(notifications.values.isEmpty)
    }
    @Test func previouslyCommittedShortTranscriptIsNotRetroactivelyRemoved() async throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("meetings")
        let dir = try MeetingTestFixtures.session(root)
        try duration(5, in: dir)
        let meeting = try Meeting.read(dir)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = destination.appendingPathComponent("completed.md")
        try MarkdownMeeting.render(meeting, body: "already saved").write(to: file)
        let notifications = RecordingNotifications()
        let coordinator = TranscriptionCoordinator(destination: destination, notifier: { _, body in notifications.receive(body) })
        await coordinator.resumePending(root: root)
        #expect(ArtifactFiles.isRegular(file))
        #expect(!ArtifactFiles.isDirectory(dir))
        #expect(notifications.values.isEmpty)
        #expect(await coordinator.state().completed.map(\.id) == ["recording-1"])
    }

}
