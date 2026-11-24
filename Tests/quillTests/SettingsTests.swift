import Foundation
import Testing
@testable import quill

@Suite("noato settings and meeting snapshots")
struct SettingsTests {
    @Test func defaultsAreLocalAndDestructiveFeaturesAreOff() throws {
        let value = AppSettings()
        #expect(value.destination.lastPathComponent == "noato")
        #expect(!value.zoom && !value.telemost && value.retention == nil)
        #expect(value.language == "ru" && value.engine == "whisper")
        #expect(value.diarization && value.maxSpeakers == 8)
        #expect(value.minimumDuration == 10 && value.startDelay == 3 && value.stopDelay == 20)
        #expect(try value.validated() == value)
    }
    @Test func atomicSaveKeepsPriorFoldersAndRejectsInvalidValues() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(file: root.appendingPathComponent("settings.json"))
        let original = try store.read()
        #expect(!FileManager.default.fileExists(atPath: store.file.path))
        let saved = try store.update { $0.transcriptsDirectory = root.appendingPathComponent("new").path; $0.telemost = true }
        #expect(saved.previousTranscriptDirectories == [original.transcriptsDirectory])
        #expect(try store.read() == saved)
        #expect(throws: SettingsError.self) { try store.update { $0.stopDelay = .nan } }
        #expect(try store.read() == saved)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
    @Test func importingQuillPreservesFolderAndSourcesWithoutHooks() throws {
        let imported = try AppSettings.importing([
            "transcripts_dir": "~/Documents/Team Meetings", "recordings_dir": "~/Recordings/Quill",
            "microphone_uid": "BuiltInMicrophoneDevice", "audio_capture": "call_app",
            "transcription": ["engine": "whisper", "language": "ru"],
            "auto_record": ["telemost": true, "zoom": true], "on_stop": "do-not-execute"
        ])
        #expect(imported.transcriptsDirectory == "~/Documents/Team Meetings")
        #expect(imported.microphoneUID == "BuiltInMicrophoneDevice")
        #expect(imported.zoom && imported.telemost && imported.retention == nil)
        #expect(!imported.setupCompleted)
    }
    @Test func frozenMeetingSurvivesRestartAndLaterSettingsChanges() async throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root)
        var before = AppSettings(); before.language = "ru"; before.transcriptsDirectory = root.appendingPathComponent("original").path
        var meta = try RecordingArchive.metadata(dir)
        try MeetingSettings.attach(before, to: &meta)
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        var after = before; after.language = "en"; after.transcriptsDirectory = root.appendingPathComponent("later").path
        #expect(try MeetingSettings.read(dir) == before)
        let observed = await MeetingSettings.$current.withValue(before) { Config.transcriptionLanguage() }
        #expect(observed == "ru")
        #expect(after.destination != before.destination)
        let restarted = try MeetingSettings.read(dir)
        #expect(restarted.destination.path == root.appendingPathComponent("original").path)
    }
    @Test func destinationRoundTripMaintainsOwnershipAndCompletesCleanup() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root)
        var settings = AppSettings(); settings.transcriptsDirectory = root.appendingPathComponent("round-trip").path
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(!FileManager.default.fileExists(atPath: decoded.destination.path))
        let output = try RecordingArchive.finish(dir, destination: decoded.destination, body: "test", hasMicrophoneSpeech: true)
        #expect(MarkdownMeeting.read(output)?.verified == true)
        #expect(ArtifactFiles.directChild(URL(fileURLWithPath: output.path), of: decoded.destination))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func historyAndCleanupSpanOldAndNewFoldersWithoutDuplicates() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        let old = MeetingTestFixtures.now.addingTimeInterval(-90000)
        for (id, destination) in [("old", first), ("new", second)] {
            let dir = try MeetingTestFixtures.session(root, id: id, started: old)
            try RecordingArchive.finish(dir, destination: destination, body: "text", hasMicrophoneSpeech: true)
        }
        #expect(Set(CompletedTranscript.latest(in: [first, second]).map(\.id)) == ["old", "new"])
        let recording = try MeetingTestFixtures.session(root, id: "active", started: old)
        let preview = MeetingCleanup.preview(roots: [root], destinations: [first, second], age: .day,
            now: MeetingTestFixtures.now, protected: [recording])
        #expect(Set(preview.candidates.map(\.id)) == ["old", "new"])
        #expect(preview.skippedActive == 1)
        #expect(preview.candidates.allSatisfy { $0.paths.count == 1 })
        #expect(ArtifactFiles.isRegular(recording.appendingPathComponent("mic.caf")))
    }
}
