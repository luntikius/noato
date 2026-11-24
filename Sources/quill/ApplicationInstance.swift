import Darwin
import Foundation

/// Held for the process lifetime; advisory locking also handles crash recovery.
final class ApplicationInstance {
    private let descriptor: Int32
    init() throws {
        try FileManager.default.createDirectory(at: Config.dataRoot, withIntermediateDirectories: true)
        descriptor = open(Config.dataRoot.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw InstanceError.unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw InstanceError.running }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
    enum InstanceError: Error, CustomStringConvertible {
        case running, unavailable
        var description: String { L10n.text(self == .running ? "noato is already running. Use noato menu to open it." : "Could not lock the noato data folder.") }
    }
}
