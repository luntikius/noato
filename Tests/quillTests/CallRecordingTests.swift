import CoreAudio
import Foundation
import Testing
@testable import quill

@Suite("Call recording policy")
struct CallRecordingTests {
    private func policy(_ enabled: Set<CallApplication> = [.telemost, .zoom]) -> CallRecordingPolicy {
        CallRecordingPolicy(enabled: enabled, startDelay: 3, stopDelay: 20)
    }

    @Test func shortSoundsDoNotStartAndActivityMustBeContinuous() {
        var p = policy()
        p.observe(active: [.telemost], at: 0)
        p.observe(active: [.telemost], at: 2)
        #expect(p.candidate == nil)
        p.observe(active: [], at: 2.5)
        p.observe(active: [.telemost], at: 3)
        p.observe(active: [.telemost], at: 5)
        #expect(p.candidate == nil)
        p.observe(active: [.telemost], at: 6)
        #expect(p.candidate == .telemost)
    }

    @Test func reconnectResetsStopDelay() {
        var p = policy()
        p.observe(active: [.telemost], at: 0)
        p.observe(active: [.telemost], at: 3)
        p.observe(active: [], at: 4)
        p.observe(active: [], at: 23)
        #expect(p.isActive(.telemost))
        p.observe(active: [.telemost], at: 23.5)
        p.observe(active: [], at: 24)
        p.observe(active: [], at: 43)
        #expect(p.isActive(.telemost))
        p.observe(active: [], at: 44)
        #expect(!p.isActive(.telemost))
        #expect(p.candidate == nil)
    }

    @Test func simultaneousCallsPreferTelemostThenSwitchToZoom() {
        var p = policy()
        p.observe(active: [.zoom, .telemost], at: 0)
        #expect(p.candidate == nil)
        p.observe(active: [.zoom, .telemost], at: 3)
        #expect(p.candidate == .telemost)
        p.observe(active: [.zoom], at: 4)
        p.observe(active: [.zoom], at: 24)
        #expect(p.candidate == .zoom)
    }

    @Test func firstCallWinsEvenWhenTelemostJoinsLater() {
        var p = policy()
        p.observe(active: [.zoom], at: 0)
        p.observe(active: [.zoom], at: 3)
        p.observe(active: [.zoom, .telemost], at: 4)
        p.observe(active: [.zoom, .telemost], at: 7)
        #expect(p.candidate == .zoom)
        #expect(p.isActive(.telemost))
    }

    @Test func manualStopStaysSuppressedThroughReconnectUntilCallEnds() {
        var p = policy()
        p.observe(active: [.telemost], at: 0)
        p.observe(active: [.telemost], at: 3)
        #expect(p.candidate == .telemost)
        p.suppressActive()
        #expect(p.candidate == nil)
        p.observe(active: [], at: 4)
        p.observe(active: [.telemost], at: 10)
        #expect(p.candidate == nil)
        p.observe(active: [], at: 11)
        p.observe(active: [], at: 31)
        p.observe(active: [.telemost], at: 32)
        p.observe(active: [.telemost], at: 35)
        #expect(p.candidate == .telemost)
    }

    @Test func failedSourceDoesNotBlockOtherApplication() {
        var p = policy()
        p.observe(active: [.telemost, .zoom], at: 0)
        p.observe(active: [.telemost, .zoom], at: 3)
        p.suppress(.telemost)
        #expect(p.candidate == .zoom)
    }

    @Test func disabledApplicationsNeverBecomeCandidates() {
        var p = policy([.zoom])
        p.observe(active: [.telemost], at: 0)
        p.observe(active: [.telemost], at: 100)
        #expect(p.candidate == nil)
        #expect(!p.isActive(.telemost))
    }
}

@Suite("Application audio selection")
struct CallAudioSelectionTests {
    private let apps: [CallApplication: URL] = [
        .telemost: URL(fileURLWithPath: "/Applications/Yandex.Telemost.app"),
        .zoom: URL(fileURLWithPath: "/Applications/zoom.us.app"),
    ]

    private func process(_ id: UInt32, _ path: String, input: Bool = false, output: Bool = false) -> CallAudioProcess {
        CallAudioProcess(id: id, executablePath: path, inputActive: input, outputActive: output)
    }

    @Test func helpersMustBelongToExactApplicationBundle() {
        let snapshot = CallAudioSnapshot.matching([
            process(1, "/Applications/Yandex.Telemost.app/Contents/MacOS/Yandex.Telemost"),
            process(2, "/Applications/Yandex.Telemost.app/Contents/Frameworks/QtWebEngineProcess", output: true),
            process(3, "/Applications/Other.app/Contents/MacOS/QtWebEngineProcess", output: true),
            process(4, "/Applications/Yandex.Telemost.app.copy/Contents/MacOS/QtWebEngineProcess", output: true),
            process(5, "/Applications/zoom.us.app/Contents/Frameworks/CptHost.app/Contents/MacOS/CptHost"),
        ], applications: apps)
        #expect(snapshot.processIDs(for: .telemost) == [1, 2])
        #expect(snapshot.processIDs(for: .zoom) == [5])
        #expect(snapshot.activeApplications == [.telemost])
        #expect(snapshot.availableApplications == [.telemost, .zoom])
    }

    @Test func inputOrOutputActivityTriggersButIdleAppDoesNot() {
        let idle = CallAudioSnapshot.matching([
            process(1, "/Applications/zoom.us.app/Contents/MacOS/zoom.us")
        ], applications: apps)
        #expect(idle.activeApplications.isEmpty)
        let input = CallAudioSnapshot.matching([
            process(1, "/Applications/zoom.us.app/Contents/MacOS/zoom.us", input: true)
        ], applications: apps)
        #expect(input.activeApplications == [.zoom])
        let output = CallAudioSnapshot.matching([
            process(1, "/Applications/zoom.us.app/Contents/MacOS/zoom.us", output: true)
        ], applications: apps)
        #expect(output.activeApplications == [.zoom])
    }

    @Test func helperReplacementDropsOldIdentityWithoutIncludingOtherApps() {
        let first = CallAudioSnapshot.matching([
            process(8, "/Applications/Yandex.Telemost.app/Contents/Frameworks/QtWebEngineProcess", output: true)
        ], applications: apps)
        let second = CallAudioSnapshot.matching([
            process(8, "/Applications/Other.app/Contents/MacOS/QtWebEngineProcess", output: true),
            process(9, "/Applications/Yandex.Telemost.app/Contents/Frameworks/QtWebEngineProcess", output: true),
        ], applications: apps)
        #expect(first.processIDs(for: .telemost) == [8])
        #expect(second.processIDs(for: .telemost) == [9])
    }

    @Test func absentModePreservesSystemButInvalidModeThrows() throws {
        #expect(try AudioCaptureMode.parse(nil) == .system)
        #expect(try AudioCaptureMode.parse("call_app") == .callApp)
        #expect(throws: (any Error).self) { try AudioCaptureMode.parse("call_ap") }
        #expect(throws: (any Error).self) { try AudioCaptureMode.parse(1) }
    }

    @Test func inclusiveTapNeverFallsBackToGlobalForEmptyProcesses() {
        let scoped = SystemAudioRecorder.tapDescription(processIDs: [1, 2])
        #expect(!scoped.isExclusive)
        #expect(scoped.processes == [1, 2])
        if #available(macOS 26.0, *) {
            #expect(scoped.bundleIDs.isEmpty)
            #expect(!scoped.isProcessRestoreEnabled)
        }
        let disconnected = SystemAudioRecorder.tapDescription(processIDs: [])
        #expect(!disconnected.isExclusive)
        #expect(disconnected.processes.isEmpty)
        #expect(SystemAudioRecorder.tapDescription(processIDs: nil).isExclusive)
    }
}
