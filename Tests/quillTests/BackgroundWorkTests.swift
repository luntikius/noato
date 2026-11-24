import Darwin
import Foundation
import Dispatch
import Testing
@testable import quill

@Suite("Background work")
struct BackgroundWorkTests {
    @Test @MainActor
    func progressesWhileMainActorIsBlocked() {
        let completed = DispatchSemaphore(value: 0)

        BackgroundWork.start {
            completed.signal()
        }

        // This deliberately blocks MainActor, just as NSApplication.run()
        // does in the daemon. An inherited Task would time out here.
        #expect(completed.wait(timeout: .now() + 2) == .success)
    }
    @Test @MainActor
    func signalHandlerDoesNotInheritMainActorOnGlobalQueue() {
        var delivered = false
        let source = BackgroundWork.signalSource(SIGUSR2) { delivered = true }
        defer {
            source.cancel()
            signal(SIGUSR2, SIG_DFL)
        }
        kill(getpid(), SIGUSR2)
        let deadline = Date().addingTimeInterval(2)
        while !delivered, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(delivered)
    }

}
