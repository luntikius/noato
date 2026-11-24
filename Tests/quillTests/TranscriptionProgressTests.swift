import Foundation
import Testing
@testable import quill

@Suite("Transcription progress and remaining time")
struct TranscriptionProgressTests {
    @Test func lastThreeWindowsAndDuplicateCallbacks() {
        var estimate = RemainingTimeEstimator()
        estimate.start(at: 100)
        #expect(estimate.observe(0, total: 100, at: 101) == nil)
        #expect(estimate.observe(10, total: 100, at: 102) == 18)
        #expect(estimate.observe(20, total: 100, at: 104) == 16)
        #expect(estimate.observe(30, total: 100, at: 106) == 14)
        // The slow first window is evicted after the fourth completion.
        #expect(estimate.observe(40, total: 100, at: 107) == 10)
        #expect(estimate.observe(20, total: 100, at: 108) == 10)
        #expect(estimate.completed == 40)
        #expect(estimate.observe(100, total: 100, at: 110) == 0)
        estimate.start(at: 200)
        #expect(estimate.completed == 0)
        #expect(estimate.observe(0, total: 0, at: 200) == nil)
    }

    @Test func estimatesAreExplicitlyScopedToCurrentStage() {
        let meeting = Meeting(id: "one", started: MeetingTestFixtures.now, application: .telemost,
                              directory: URL(fileURLWithPath: "/tmp/one"))
        let queued = MeetingJob(meeting: meeting, phase: .queued)
        #expect(queued.subtitle == "Queued")
        let processing = MeetingJob(meeting: meeting, phase: .transcribing, fraction: 0.5, estimatedSeconds: 120, detail: "Microphone")
        #expect(processing.subtitle == "Transcribing · Microphone · this stage: about 2 min remaining")
        let loading = MeetingJob(meeting: meeting, phase: .preparing)
        #expect(loading.estimatedSeconds == nil)
        #expect(loading.subtitle == "Preparing model")
    }
}
