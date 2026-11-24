import Foundation
import Testing
@testable import quill

@Suite("Audio source settings")
struct AudioSourcesTests {
    @Test func legacyModesKeepTheirMeaning() throws {
        #expect(try AudioSources.parse([:]).systemAudio == .system)
        #expect(try AudioSources.parse(["audio_capture": "call_app"]).systemAudio == .callApp)
        #expect(try AudioSources.parse(["system_audio_source": "zoom"]).systemAudio == .zoom)
        #expect(throws: (any Error).self) { try AudioSources.parse(["system_audio_source": "zoon"]) }
        #expect(throws: (any Error).self) { try AudioSources.parse(["microphone_uid": 1]) }
    }

    @Test func savingSourcesPreservesOtherSettingsAndCanRestoreDefaultMic() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        try Data(#"{"transcription":{"engine":"whisper","language":"ru"},"custom":"keep"}"#.utf8).write(to: file)
        try Config.saveAudioSources(AudioSources(microphoneUID: "usb-mic", systemAudio: .telemost), at: file)
        #expect(try Config.audioSources(at: file) == AudioSources(microphoneUID: "usb-mic", systemAudio: .telemost))
        let values = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(values["custom"] as? String == "keep")
        #expect((values["transcription"] as? [String: String])?["engine"] == "whisper")
        #expect(values["audio_capture"] as? String == "call_app")
        try Config.saveAudioSources(AudioSources(systemAudio: .system), at: file)
        #expect(try Config.audioSources(at: file).microphoneUID == nil)
        #expect(try Config.audioSources(at: file).systemAudio == .system)
    }

    @Test func selectingOneAppDoesNotGetBlockedByAnotherActiveCall() {
        var policy = CallRecordingPolicy(enabled: [.zoom, .telemost], startDelay: 3, stopDelay: 20)
        policy.observe(active: [.zoom, .telemost], at: 0)
        policy.observe(active: [.zoom, .telemost], at: 3)
        #expect(policy.candidate == .telemost)
        #expect(policy.candidate(allowing: SystemAudioSource.zoom.applications) == .zoom)
        #expect(SystemAudioSource.telemost.applications == [.telemost])
        #expect(SystemAudioSource.system.captureMode == .system)
    }
}
