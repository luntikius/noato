import Foundation
import Testing
@testable import quill

private actor ControlledTranscription {
    private var started: Set<String> = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var observers: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var failures: Set<String> = []

    func process(_ dir: URL) async throws -> URL {
        let id = dir.lastPathComponent
        started.insert(id)
        for observer in observers.removeValue(forKey: id) ?? [] { observer.resume() }
        await withCheckedContinuation { gates[id] = $0 }
        if failures.remove(id) != nil { throw TranscriptionCoordinator.TranscriptionError.noReadableTracks }
        return dir.appendingPathComponent("result.md")
    }
    func waitStarted(_ id: String) async {
        if started.contains(id) { return }
        await withCheckedContinuation { observers[id, default: []].append($0) }
    }
    func release(_ id: String, fail: Bool = false) {
        if fail { failures.insert(id) }
        gates.removeValue(forKey: id)?.resume()
        started.remove(id)
    }
}

@Suite("Queue ownership, retry and deletion")
struct TranscriptionQueueTests {
    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<1000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    @Test func showsAllJobsAndDeletingQueuedWorkNeverStartsIt() async throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = MeetingTestFixtures.now.addingTimeInterval(-90000)
        let one = try MeetingTestFixtures.session(root, id: "one", started: old)
        let two = try MeetingTestFixtures.session(root, id: "two", started: old)
        let gate = ControlledTranscription()
        let queue = TranscriptionCoordinator(destination: root.appendingPathComponent("meetings"), processor: { try await gate.process($0) })
        await queue.enqueue(one)
        await gate.waitStarted("one")
        await queue.enqueue(two)
        let before = await queue.snapshot()
        #expect(before.map(\.id) == ["one", "two"])
        #expect(before[0].phase == .preparing)
        #expect(before[1].phase == .queued)
        let preview = await queue.previewDeletion(root: root, age: .day, now: MeetingTestFixtures.now, protecting: nil)
        #expect(preview.skippedActive == 1)
        #expect(preview.candidates.map(\.id) == ["two"])
        let result = await queue.delete(preview, protecting: nil)
        #expect(result.deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: two.path))
        #expect(await queue.snapshot().map(\.id) == ["one"])
        await gate.release("one")
        #expect(await waitUntil { await queue.snapshot().isEmpty })
    }

    @Test func previewCannotDeleteJobThatStartedWhileConfirming() async throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = MeetingTestFixtures.now.addingTimeInterval(-90000)
        let one = try MeetingTestFixtures.session(root, id: "one", started: old)
        let two = try MeetingTestFixtures.session(root, id: "two", started: old)
        let gate = ControlledTranscription()
        let queue = TranscriptionCoordinator(destination: root.appendingPathComponent("meetings"), processor: { try await gate.process($0) })
        await queue.enqueue(one)
        await gate.waitStarted("one")
        await queue.enqueue(two)
        let preview = await queue.previewDeletion(root: root, age: .day, now: MeetingTestFixtures.now, protecting: nil)
        await gate.release("one")
        await gate.waitStarted("two")
        let result = await queue.delete(preview, protecting: nil)
        #expect(result.deleted == 0)
        #expect(result.skipped == 1)
        #expect(ArtifactFiles.isRegular(two.appendingPathComponent("mic.caf")))
        await gate.release("two")
        #expect(await waitUntil { await queue.snapshot().isEmpty })
    }

    @Test func failuresRemainVisibleAndRecoverAfterRestartThenRetry() async throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root, id: "failed")
        let gate = ControlledTranscription()
        let queue = TranscriptionCoordinator(destination: root.appendingPathComponent("meetings"), processor: { try await gate.process($0) })
        await queue.enqueue(dir)
        await gate.waitStarted("failed")
        await gate.release("failed", fail: true)
        #expect(await waitUntil { await queue.snapshot().first?.phase == .failed })
        #expect(ArtifactFiles.isRegular(dir.appendingPathComponent("failure.plist")))
        #expect(ArtifactFiles.isRegular(dir.appendingPathComponent("mic.caf")))
        let restored = TranscriptionCoordinator(destination: root.appendingPathComponent("meetings"), processor: { try await gate.process($0) })
        await restored.resumePending(root: root)
        #expect(await restored.snapshot().first?.phase == .failed)
        await restored.retry("failed")
        await gate.waitStarted("failed")
        #expect(await restored.snapshot().first?.phase == .preparing)
        await gate.release("failed")
        #expect(await waitUntil { await restored.snapshot().isEmpty })
    }

    @Test func delayedRecordingEventsCannotResurrectStoppedRecording() async throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root)
        let meeting = try Meeting.read(dir)
        let queue = TranscriptionCoordinator(destination: root)
        await queue.setRecording(meeting, revision: 1)
        #expect(await queue.snapshot().first?.phase == .recording)
        await queue.setRecording(nil, revision: 2)
        await queue.setRecording(meeting, revision: 1)
        #expect(await queue.snapshot().isEmpty)
    }
}
