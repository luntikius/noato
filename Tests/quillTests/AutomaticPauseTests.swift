import Foundation
import Testing
@testable import quill

@Suite("Automatic detection pause")
struct AutomaticPauseTests {
    @Test func pauseOnlyBlocksNewCandidatesAndResumeUsesCurrentCall() {
        var policy = CallRecordingPolicy(enabled: [.zoom, .telemost], startDelay: 3, stopDelay: 20, paused: true)
        policy.observe(active: [.zoom, .telemost], at: 0)
        policy.observe(active: [.zoom, .telemost], at: 3)
        #expect(policy.isPaused)
        #expect(policy.candidate == nil)
        #expect(policy.isActive(.zoom))
        policy.setPaused(false)
        #expect(policy.candidate == .telemost)
        policy.setPaused(true)
        // Existing automatic recordings can still detect the end of a call.
        policy.observe(active: [], at: 4)
        policy.observe(active: [], at: 24)
        #expect(!policy.isActive(.telemost))
        policy.setPaused(false)
        #expect(policy.candidate == nil)
    }

    @Test func manualStopSuppressionSurvivesPause() {
        var policy = CallRecordingPolicy(enabled: [.zoom], startDelay: 3, stopDelay: 20)
        policy.observe(active: [.zoom], at: 0)
        policy.observe(active: [.zoom], at: 3)
        #expect(policy.candidate == .zoom)
        policy.suppressActive()
        policy.setPaused(true)
        policy.setPaused(false)
        #expect(policy.candidate == nil)
        policy.observe(active: [], at: 4)
        policy.observe(active: [], at: 24)
        policy.observe(active: [.zoom], at: 25)
        policy.observe(active: [.zoom], at: 28)
        #expect(policy.candidate == .zoom)
    }

    @Test func persistingPausePreservesAppFlagsDelaysAndOtherSettings() throws {
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.json")
        try Data(#"{"auto_record":{"zoom":true,"telemost":true,"start_delay_seconds":3,"stop_delay_seconds":20,"custom":"keep"},"microphone_uid":"BuiltInMicrophoneDevice"}"#.utf8).write(to: file)
        for paused in [true, false] {
            try Config.saveAutoRecordPaused(paused, at: file)
            let settings = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let automatic = try #require(settings["auto_record"] as? [String: Any])
            #expect(automatic["paused"] as? Bool == paused)
            #expect(automatic["zoom"] as? Bool == true)
            #expect(automatic["telemost"] as? Bool == true)
            #expect(automatic["start_delay_seconds"] as? Int == 3)
            #expect(automatic["stop_delay_seconds"] as? Int == 20)
            #expect(automatic["custom"] as? String == "keep")
            #expect(settings["microphone_uid"] as? String == "BuiltInMicrophoneDevice")
        }
    }

    @Test func editingDelaysPreservesManualStopSuppression() {
        var policy = CallRecordingPolicy(enabled: [.zoom], startDelay: 3, stopDelay: 20)
        policy.observe(active: [.zoom], at: 0); policy.observe(active: [.zoom], at: 3)
        #expect(policy.candidate == .zoom)
        policy.suppress(.zoom)
        policy.reconfigure(enabled: [.zoom], startDelay: 1, stopDelay: 20, paused: false)
        #expect(policy.isActive(.zoom)); #expect(policy.candidate == nil)
        policy.observe(active: [], at: 4); policy.observe(active: [], at: 24)
        policy.observe(active: [.zoom], at: 25); policy.observe(active: [.zoom], at: 26)
        #expect(policy.candidate == .zoom)
    }

}
