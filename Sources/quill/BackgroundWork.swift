import Foundation

/// Launches work that must keep progressing while AppKit owns the main run
/// loop. A plain `Task {}` created from `AppController` inherits MainActor;
/// `NSApplication.run()` is blocking, so such a task can remain starved until
/// the daemon exits. Detached work is safe here because callers only capture
/// Sendable values (actors and URLs).
@MainActor
enum BackgroundWork {
    /// AppKit's nested loop does not service the main dispatch queue while
    /// its owning Swift task is blocked. Schedule UI delivery on the run loop.
    nonisolated static func deliverToMainRunLoop(
        _ operation: @escaping @MainActor @Sendable () -> Void
    ) {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { operation() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Construct the dispatch callback outside MainActor so Swift cannot
    /// infer actor isolation for a handler invoked on a global queue.
    nonisolated static func signalSource(
        _ number: Int32, operation: @escaping @MainActor @Sendable () -> Void
    ) -> DispatchSourceSignal {
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
        source.setEventHandler {
            deliverToMainRunLoop(operation)
        }
        signal(number, SIG_IGN)
        source.resume()
        return source
    }

    @discardableResult
    static func start(
        priority: TaskPriority? = .utility,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: priority, operation: operation)
    }
}
