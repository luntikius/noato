import AppKit
import Foundation
import Testing
@testable import quill

@Suite("Microphone signal diagnostics")
struct AudioSignalTests {
    @Test func digitalSilenceIsFiniteAndDistinctFromQuietSignal() {
        var silence = AudioSignalAccumulator()
        [Float](repeating: 0, count: 3200).withUnsafeBufferPointer {
            silence.observe($0, sampleRate: 16000)
        }
        #expect(silence.report.sample_count == 3200)
        #expect(silence.report.peak_db == -160)
        #expect(silence.report.rms_db.isFinite)
        var quiet = AudioSignalAccumulator()
        [Float](repeating: 0.005, count: 3200).withUnsafeBufferPointer {
            quiet.observe($0, sampleRate: 16000)
        }
        #expect(quiet.report.max_window_rms_db > -47)
        #expect(quiet.report.max_window_rms_db < -45)
        #expect(quiet.report.max_window_rms_db < -34)
        #expect(quiet.report.peak_db > silence.report.peak_db)
    }

    @Test func shortSpeechIsNotHiddenByWholeTrackAverage() {
        var signal = AudioSignalAccumulator()
        let samples = [Float](repeating: 0, count: 16000) + [Float](repeating: 0.1, count: 1600)
        samples.withUnsafeBufferPointer { signal.observe($0, sampleRate: 16000) }
        #expect(signal.report.max_window_rms_db > -21)
        #expect(signal.report.max_window_rms_db < -19)
        #expect(signal.report.rms_db < -29)
    }

    @Test @MainActor func recordingIconHasActualRedPixelsInsteadOfTemplateTint() throws {
        let image = try #require(MenuBarController.recordingImage())
        #expect(!image.isTemplate)
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
        let visible = (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).compactMap { x in bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) }
        }.filter { $0.alphaComponent > 0.9 }
        #expect(!visible.isEmpty)
        #expect(visible.allSatisfy { $0.redComponent > $0.greenComponent + 0.3 && $0.redComponent > $0.blueComponent + 0.3 })
        let idle = try #require(StatusBarLogo.image(recording: false))
        #expect(idle.isTemplate)
        #expect(idle.size == image.size)
    }
}
