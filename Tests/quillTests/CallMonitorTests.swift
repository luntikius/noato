import Dispatch
import Foundation
import Testing
@testable import quill

@Suite("AppKit call monitoring")
struct CallMonitorTests {
    @Test @MainActor
    func snapshotQueryRunsWhileMainActorIsBlocked() {
        let entered = DispatchSemaphore(value: 0)
        let monitor = CallMonitor(readSnapshot: { _ in
            entered.signal()
            return CallAudioSnapshot(processes: [:])
        })
        monitor.start()
        defer { monitor.stop() }
        // Reproduces NSApplication.run holding the Swift main actor. The
        // query must actually run, rather than merely arming a watchdog.
        #expect(entered.wait(timeout: .now() + 2) == .success)
    }

    @Test @MainActor
    func resultIsDeliveredThroughAppKitRunLoop() {
        let monitor = CallMonitor(readSnapshot: { _ in CallAudioSnapshot(processes: [:]) })
        var delivered = false
        monitor.onSnapshot = { _ in delivered = true }
        monitor.start()
        defer { monitor.stop() }
        let deadline = Date().addingTimeInterval(2)
        // AppKit pumps the run loop without yielding its owning Swift task.
        while !delivered, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(delivered)
    }

    @Test @MainActor
    func stoppedMonitorDoesNotDeliverLateSnapshot() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let monitor = CallMonitor(readSnapshot: { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            return CallAudioSnapshot(processes: [:])
        })
        var delivered = false
        monitor.onSnapshot = { _ in delivered = true }
        monitor.start()
        #expect(entered.wait(timeout: .now() + 2) == .success)
        monitor.stop()
        release.signal()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(!delivered)
    }
}
