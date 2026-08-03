import Foundation

/// Launches work that must keep progressing while AppKit owns the main run
/// loop. A plain `Task {}` created from `AppController` inherits MainActor;
/// `NSApplication.run()` is blocking, so such a task can remain starved until
/// the daemon exits. Detached work is safe here because callers only capture
/// Sendable values (actors and URLs).
@MainActor
enum BackgroundWork {
    @discardableResult
    static func start(
        priority: TaskPriority? = .utility,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: priority, operation: operation)
    }
}
