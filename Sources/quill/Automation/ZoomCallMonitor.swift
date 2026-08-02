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

    let startDelay: TimeInterval
    let stopDelay: TimeInterval

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

/// Watches Zoom's Core Audio process objects. Zoom commonly remains open
/// between meetings, so application launch/window state is not a call signal;
/// active input/output IO is. Polling once per second is intentionally simple
/// and cheap (only a short AudioObject list) while also surviving Zoom helper
/// process replacement without listener bookkeeping.
@MainActor
final class ZoomCallMonitor {
    var onCallStarted: (() -> Void)?
    var onCallStopped: (() -> Void)?

    private static let zoomBundleIDs: Set<String> = [
        "us.zoom.xos",
        "us.zoom.CptHost",
        "us.zoom.zCCIMeetingHost",
        "us.zoom.ZoomHybridConf",
        "us.zoom.ZoomPhone",
    ]

    private var gate: AudioActivityGate
    private var timer: Timer?

    init(startDelay: TimeInterval, stopDelay: TimeInterval) {
        gate = AudioActivityGate(startDelay: startDelay, stopDelay: stopDelay)
    }

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.2
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let isActive = Self.zoomAudioIsActive()
        let now = ProcessInfo.processInfo.systemUptime
        switch gate.observe(audioIsActive: isActive, at: now) {
        case .started: onCallStarted?()
        case .stopped: onCallStopped?()
        case nil: break
        }
    }

    private static func zoomAudioIsActive() -> Bool {
        processObjectIDs().contains { processID in
            guard let bundleID = stringProperty(
                kAudioProcessPropertyBundleID,
                on: processID
            ), zoomBundleIDs.contains(bundleID) else {
                return false
            }
            return uint32Property(kAudioProcessPropertyIsRunningInput, on: processID) != 0
                || uint32Property(kAudioProcessPropertyIsRunningOutput, on: processID) != 0
        }
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            system,
            &address,
            0,
            nil,
            &byteCount
        ) == noErr else {
            return []
        }

        let count = Int(byteCount) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var objects = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let status = objects.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(
                system,
                &address,
                0,
                nil,
                &byteCount,
                buffer.baseAddress!
            )
        }
        guard status == noErr else { return [] }
        return objects
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        on object: AudioObjectID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &value
        )
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32Property(
        _ selector: AudioObjectPropertySelector,
        on object: AudioObjectID
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else {
            return 0
        }
        return value
    }
}
