import Foundation
import Testing
@testable import quill

@Suite("Manual retention cleanup")
struct MeetingCleanupTests {
    @Test func preciseDayAndWeekBoundaries() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("meetings")
        let now = MeetingTestFixtures.now
        for (id, seconds) in [("day-old", -86401.0), ("day-exact", -86400), ("week-old", -604801), ("week-exact", -604800), ("recent", -3600)] {
            _ = try MeetingTestFixtures.session(root, id: id, started: now.addingTimeInterval(seconds))
        }
        let day = MeetingCleanup.preview(root: root, destination: destination, age: .day, now: now, protected: [])
        #expect(Set(day.candidates.map(\.id)) == ["day-old", "week-old", "week-exact"])
        let week = MeetingCleanup.preview(root: root, destination: destination, age: .week, now: now, protected: [])
        #expect(week.candidates.map(\.id) == ["week-old"])
    }

    @Test func monthUsesCalendarRatherThanThirtyDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = ISO8601DateFormatter()
        let now = date.date(from: "2026-03-31T12:00:00Z")!
        #expect(MeetingAge.month.cutoff(from: now, calendar: calendar) == date.date(from: "2026-02-28T12:00:00Z")!)
    }

    @Test func ownershipActiveWorkAndSymlinksAreRespected() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("recordings")
        let destination = root.appendingPathComponent("meetings")
        let old = MeetingTestFixtures.now.addingTimeInterval(-90000)
        let done = try MeetingTestFixtures.session(sessions, id: "done", started: old)
        let output = try RecordingArchive.finish(done, destination: destination, body: "text", hasMicrophoneSpeech: true)
        let active = try MeetingTestFixtures.session(sessions, id: "active", started: old)
        let waiting = try MeetingTestFixtures.session(sessions, id: "waiting", started: old)
        let stranger = destination.appendingPathComponent("personal.md")
        try Data("# personal".utf8).write(to: stranger)
        let link = destination.appendingPathComponent("linked.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: output)
        let preview = MeetingCleanup.preview(root: sessions, destination: destination, age: .day,
                                             now: MeetingTestFixtures.now, protected: [active])
        #expect(Set(preview.candidates.map(\.id)) == ["done", "waiting"])
        #expect(preview.skippedActive == 1)
        #expect(preview.bytes > 0)
        // A preview and cancellation cause no filesystem mutation.
        #expect(ArtifactFiles.isRegular(output))
        #expect(ArtifactFiles.isDirectory(waiting))
        for candidate in preview.candidates { try MeetingCleanup.remove(candidate) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: waiting.path))
        #expect(ArtifactFiles.isDirectory(active))
        #expect(ArtifactFiles.isRegular(stranger))
        #expect((try link.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)
    }

    @Test func editedFileAndNewSessionContentInvalidatePreview() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("meetings")
        let old = MeetingTestFixtures.now.addingTimeInterval(-90000)
        let dir = try MeetingTestFixtures.session(root, started: old)
        let preview = MeetingCleanup.preview(root: root, destination: destination, age: .day, now: MeetingTestFixtures.now, protected: [])
        let candidate = try #require(preview.candidates.first)
        #expect(MeetingCleanup.unchanged(candidate))
        try Data([9]).write(to: dir.appendingPathComponent("mic.caf"))
        #expect(!MeetingCleanup.unchanged(candidate))
        #expect(throws: (any Error).self) { try MeetingCleanup.remove(candidate) }
        #expect(ArtifactFiles.isDirectory(dir))
    }

    @Test func legacyPairIsGroupedWithItsSession() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root, started: MeetingTestFixtures.now.addingTimeInterval(-90000))
        let destination = root.appendingPathComponent("meetings")
        let r = try MeetingTestFixtures.legacy(dir, destination: destination)
        let preview = MeetingCleanup.preview(root: root, destination: destination, age: .day, now: MeetingTestFixtures.now, protected: [])
        let candidate = try #require(preview.candidates.first)
        #expect(candidate.paths.count == 3)
        try MeetingCleanup.remove(candidate)
        #expect(!FileManager.default.fileExists(atPath: r.markdown))
        #expect(!FileManager.default.fileExists(atPath: r.json))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}
