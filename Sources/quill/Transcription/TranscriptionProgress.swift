import Foundation

enum MeetingPhase: String, Sendable {
    case recording, queued, preparing, transcribing, diarizing, finishingSpeakers, saving, failed

    var title: String {
        switch self {
        case .recording: return L10n.text("Recording")
        case .queued: return L10n.text("Queued")
        case .preparing: return L10n.text("Preparing model")
        case .transcribing: return L10n.text("Transcribing")
        case .diarizing: return L10n.text("Separating speakers")
        case .finishingSpeakers: return L10n.text("Finishing speaker separation")
        case .saving: return L10n.text("Saving")
        case .failed: return L10n.text("Error")
        }
    }
}

struct MeetingJob: Sendable, Identifiable {
    var id: String { meeting.id }
    let meeting: Meeting
    var phase: MeetingPhase
    var fraction: Double?
    var estimatedSeconds: TimeInterval?
    var detail: String = ""
    var error: String?

    var subtitle: String {
        if let error { return error }
        let label = detail.isEmpty ? phase.title : "\(phase.title) · \(detail)"
        if let seconds = estimatedSeconds, seconds.isFinite {
            let minutes = max(1, Int(ceil(seconds / 60)))
            return L10n.format("%@ · this stage: about %d min remaining", label, minutes)
        }
        switch phase {
        case .transcribing, .diarizing: return L10n.format("%@ · Estimating time…", label)
        default: return label
        }
    }
}

/// Audio or chunk units per wall second, from the last three completed windows.
/// The caller supplies a monotonic clock; stale or duplicate events do nothing.
struct RemainingTimeEstimator {
    private var last: (units: Double, time: TimeInterval)?
    private var windows: [(units: Double, seconds: TimeInterval)] = []
    private(set) var completed = 0.0

    mutating func start(at time: TimeInterval) {
        last = (0, time)
        windows = []
        completed = 0
    }

    mutating func observe(_ units: Double, total: Double, at time: TimeInterval) -> TimeInterval? {
        guard total > 0, units.isFinite, time.isFinite else { return nil }
        let value = min(total, max(0, units))
        guard value > completed else { return estimate(total: total) }
        if let last, time > last.time {
            windows.append((value - last.units, time - last.time))
            windows = Array(windows.suffix(3))
        }
        completed = value
        last = (value, time)
        return estimate(total: total)
    }

    private func estimate(total: Double) -> TimeInterval? {
        guard !windows.isEmpty else { return nil }
        let units = windows.reduce(0) { $0 + $1.units }
        let elapsed = windows.reduce(0) { $0 + $1.seconds }
        guard units > 0, elapsed > 0 else { return nil }
        return max(0, total - completed) * elapsed / units
    }
}
