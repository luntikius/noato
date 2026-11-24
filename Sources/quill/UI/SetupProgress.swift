import Foundation

enum SetupStep: Int, CaseIterable, Sendable {
    case microphone, systemAudio, models
    var title: String {
        switch self {
        case .microphone: L10n.text("Microphone")
        case .systemAudio: L10n.text("System audio")
        case .models: L10n.text("Local models")
        }
    }
}

/// The setup controller's single state machine. Side effects only run after
/// begin succeeds, and only the matching active step may accept a reply.
struct SetupProgress: Equatable {
    enum Phase { case waiting, ready, running, failed, completed }
    private(set) var completed: Set<SetupStep> = []
    private(set) var active: SetupStep?
    private(set) var failed: SetupStep?
    private(set) var message: String?
    private(set) var modelDiarization: Bool?

    var next: SetupStep? { SetupStep.allCases.first { !completed.contains($0) } }
    var canFinish: Bool { next == nil && active == nil }
    func canBegin(_ step: SetupStep) -> Bool { active == nil && next == step }
    func phase(_ step: SetupStep) -> Phase {
        if completed.contains(step) { return .completed }
        if active == step { return .running }
        if failed == step { return .failed }
        return next == step ? .ready : .waiting
    }
    mutating func refresh(microphoneAllowed: Bool, diarization: Bool) {
        if active != .microphone {
            if microphoneAllowed { completed.insert(.microphone); if failed == .microphone { failed = nil; message = nil } }
            else { completed.remove(.microphone) }
        }
        if completed.contains(.models), modelDiarization != diarization { completed.remove(.models) }
    }
    @discardableResult
    mutating func begin(_ step: SetupStep) -> Bool {
        guard canBegin(step) else { return false }
        active = step; failed = nil; message = nil
        return true
    }
    mutating func report(_ message: String, for step: SetupStep) {
        guard active == step else { return }
        self.message = message
    }
    @discardableResult
    mutating func complete(_ step: SetupStep, success: Bool, message: String? = nil, diarization: Bool? = nil) -> Bool {
        guard active == step else { return false }
        active = nil; self.message = message
        if success {
            completed.insert(step); failed = nil
            if step == .models { modelDiarization = diarization }
        } else { completed.remove(step); failed = step }
        return true
    }
}
