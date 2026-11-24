import CoreAudio
import Foundation

/// Debounces a noisy boolean activity signal into call-boundary transitions.
/// Kept independent of Core Audio so its timing behavior is deterministic in
/// tests and manual recording policy stays in AppController.
struct AudioActivityGate {
    enum Transition: Equatable {
        case started
        case stopped
    }

    var startDelay: TimeInterval
    var stopDelay: TimeInterval

    private(set) var callIsActive = false
    private var activeSince: TimeInterval?
    private var inactiveSince: TimeInterval?

    init(startDelay: TimeInterval, stopDelay: TimeInterval) {
        self.startDelay = max(0, startDelay)
        self.stopDelay = max(0, stopDelay)
    }

    mutating func observe(audioIsActive: Bool, at now: TimeInterval) -> Transition? {
        if audioIsActive {
            inactiveSince = nil
            guard !callIsActive else { return nil }

            if activeSince == nil { activeSince = now }
            guard now - (activeSince ?? now) >= startDelay else { return nil }

            activeSince = nil
            callIsActive = true
            return .started
        }

        activeSince = nil
        guard callIsActive else {
            inactiveSince = nil
            return nil
        }

        if inactiveSince == nil { inactiveSince = now }
        guard now - (inactiveSince ?? now) >= stopDelay else { return nil }

        inactiveSince = nil
        callIsActive = false
        return .stopped
    }
}

/// One snapshot feeds detection, UI availability and process-tap updates.
@MainActor
final class CallMonitor {
    var onSnapshot: ((CallAudioSnapshot) -> Void)?
    var onError: ((Error) -> Void)?
    private var timer: Timer?
    private var lastError: String?
    private var pollTask: Task<Void, Never>?
    private var watchdog: Timer?
    private var generation: UInt = 0
    private let readSnapshot: @Sendable ([CallApplication: URL]) throws -> CallAudioSnapshot

    init(
        readSnapshot: @escaping @Sendable ([CallApplication: URL]) throws -> CallAudioSnapshot = {
            try CallAudioSnapshot.read(applications: $0)
        }
    ) {
        self.readSnapshot = readSnapshot
    }

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        watchdog?.invalidate()
        watchdog = nil
        pollTask?.cancel()
        pollTask = nil
        generation &+= 1
    }

    private func poll() {
        // Never accumulate parallel IPC requests when the audio server stalls.
        guard pollTask == nil else { return }
        let watchdog = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.report(CallAudioError.unresponsive) }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
        let applications = CallAudioSnapshot.installedApplications()
        let readSnapshot = self.readSnapshot
        generation &+= 1
        let current = generation
        // Neither the worker nor delivery may await MainActor: AppKit owns
        // that thread inside NSApplication.run(). Use its run loop directly.
        pollTask = BackgroundWork.start { [weak self] in
            let result = Result { try readSnapshot(applications) }
            guard !Task.isCancelled else { return }
            BackgroundWork.deliverToMainRunLoop {
                self?.complete(result, generation: current)
            }
        }
    }

    private func complete(_ result: Result<CallAudioSnapshot, any Error>, generation: UInt) {
        guard generation == self.generation else { return }
        watchdog?.invalidate()
        watchdog = nil
        pollTask = nil
        switch result {
        case .success(let snapshot):
            lastError = nil
            onSnapshot?(snapshot)
        case .failure(let error):
            report(error)
        }
    }

    private func report(_ error: Error) {
        let message = String(describing: error)
        if lastError != message { onError?(error) }
        lastError = message
    }
}

/// Debounced activity and ordering only; AppController owns the actual session.
struct CallRecordingPolicy {
    private(set) var isPaused: Bool
    private var gates: [CallApplication: AudioActivityGate]
    private var activeOrder: [CallApplication] = []
    private var suppressed: Set<CallApplication> = []

    init(enabled: Set<CallApplication>, startDelay: TimeInterval, stopDelay: TimeInterval, paused: Bool = false) {
        isPaused = paused
        gates = Dictionary(uniqueKeysWithValues: enabled.map {
            ($0, AudioActivityGate(startDelay: startDelay, stopDelay: stopDelay))
        })
    }

    mutating func reconfigure(enabled: Set<CallApplication>, startDelay: TimeInterval, stopDelay: TimeInterval, paused: Bool) {
        gates = Dictionary(uniqueKeysWithValues: enabled.map { app in
            var gate = gates[app] ?? AudioActivityGate(startDelay: startDelay, stopDelay: stopDelay)
            gate.startDelay = max(0, startDelay); gate.stopDelay = max(0, stopDelay)
            return (app, gate)
        })
        activeOrder.removeAll { !enabled.contains($0) }
        suppressed.formIntersection(enabled)
        isPaused = paused
    }

    mutating func observe(active: Set<CallApplication>, at now: TimeInterval) {
        // allCases establishes Telemost priority for simultaneous starts.
        for app in CallApplication.allCases {
            guard var gate = gates[app] else { continue }
            let transition = gate.observe(audioIsActive: active.contains(app), at: now)
            gates[app] = gate
            if transition == .started { activeOrder.append(app) }
            if transition == .stopped {
                activeOrder.removeAll { $0 == app }
                suppressed.remove(app)
            }
            if !active.contains(app), !gate.callIsActive { suppressed.remove(app) }
        }
    }

    func isActive(_ app: CallApplication) -> Bool { gates[app]?.callIsActive == true }

    var candidate: CallApplication? { candidate(allowing: Set(CallApplication.allCases)) }

    mutating func setPaused(_ paused: Bool) { isPaused = paused }

    func candidate(allowing applications: Set<CallApplication>) -> CallApplication? {
        guard !isPaused else { return nil }
        return activeOrder.first { applications.contains($0) && !suppressed.contains($0) }
    }

    mutating func suppress(_ app: CallApplication) { suppressed.insert(app) }

    mutating func suppressActive() { suppressed.formUnion(activeOrder) }
}
