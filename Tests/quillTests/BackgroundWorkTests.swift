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
}
