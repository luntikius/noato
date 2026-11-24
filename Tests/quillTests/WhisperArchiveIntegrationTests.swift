import AVFoundation
import Foundation
import Testing
@testable import quill

private actor ProgressSamples {
    private var samples: [MeetingJob] = []
    func receive(_ jobs: [MeetingJob]) {
        if let job = jobs.first {
            if samples.last?.phase != job.phase { print("integration stage:", job.phase.rawValue) }
            samples.append(job)
        }
    }
    func values() -> [MeetingJob] { samples }
}

@Suite("Offline public-audio integration")
struct WhisperArchiveIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QUILL_AUDIO_FIXTURE"] != nil))
    func russianAudioProducesOneMarkdownAndReportsRealProgress() async throws {
        let fixture = try #require(ProcessInfo.processInfo.environment["QUILL_AUDIO_FIXTURE"])
        let root = try MeetingTestFixtures.root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try MeetingTestFixtures.session(root, id: "public-russian-fixture")
        let source = URL(fileURLWithPath: fixture)
        for track in ["mic", "system"] {
            let input = try AVAudioFile(forReading: source)
            let output = try AVAudioFile(forWriting: dir.appendingPathComponent(track + ".caf"), settings: input.processingFormat.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)))
            try input.read(into: buffer)
            try output.write(from: buffer)
        }
        var meta = try RecordingArchive.metadata(dir)
        meta["start_offset_ms"] = ["mic": 0, "system": 1000]
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        let destination = root.appendingPathComponent("meetings")
        let coordinator = TranscriptionCoordinator(destination: destination)
        let observations = ProgressSamples()
        await coordinator.setStatusHandler { state in Task { await observations.receive(state.jobs) } }
        let result = try await coordinator.processNow(dir)
        let output = try #require(result)
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.range(of: "[А-Яа-я]", options: .regularExpression) != nil)
        #expect(text.contains("] me:**"))
        #expect(text.contains("] participant_1:**"))
        #expect(MarkdownMeeting.read(output)?.verified == true)
        #expect(ArtifactFiles.children(destination).map(\.lastPathComponent) == [output.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        let samples = await observations.values()
        #expect(samples.contains { $0.phase == .preparing })
        #expect(samples.contains { $0.phase == .transcribing && ($0.fraction ?? 0) > 0 && ($0.fraction ?? 1) < 1 })
        #expect(samples.contains { $0.phase == .transcribing && $0.estimatedSeconds != nil })
        print("integration verified: Russian, me/participant_1, Markdown marker, intermediate progress + ETA, source directory removed")
    }
}
