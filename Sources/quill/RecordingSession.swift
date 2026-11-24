import CoreAudio
import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — whisper does better on clean single-source audio,
/// and two tracks give free two-party diarization.
final class RecordingSession {
    let dir: URL
    let startedAt = Date()
    let application: CallApplication?
    let captureMode: AudioCaptureMode
    var meeting: Meeting { Meeting(id: recordingID, started: startedAt, application: application, directory: dir) }
    private let settings = Config.current
    private let recordingID = UUID().uuidString
    private let microphoneUID: String?
    private var inputSignalReported = false
    private let initialProcessIDs: [AudioObjectID]?

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
    init(
        root: URL, application: CallApplication? = nil,
        captureMode: AudioCaptureMode = .system, processIDs: [AudioObjectID] = [],
        microphoneUID: String? = nil
    ) throws {
        if captureMode == .callApp {
            guard let application else { throw CallAudioError.invalidCaptureMode }
            guard !processIDs.isEmpty else { throw CallAudioError.unavailable(application) }
        }
        self.application = application
        self.captureMode = captureMode
        self.microphoneUID = microphoneUID
        initialProcessIDs = captureMode == .callApp ? processIDs : nil
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
        var initial: [String: Any] = ["recording_id": recordingID, "started": ISO8601DateFormatter().string(from: startedAt),
                                    "application": application?.rawValue ?? "system", "files": ["mic": "mic.caf", "system": "system.caf"]]
        try MeetingSettings.attach(settings, to: &initial)
        try JSONSerialization.data(withJSONObject: initial).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    func start() throws {
        try system.start(
            writingTo: dir.appendingPathComponent("system.caf"), processIDs: initialProcessIDs
        )
        do {
            try mic.start(writingTo: dir.appendingPathComponent("mic.caf"), microphoneUID: microphoneUID)
        } catch {
            system.stop()
            throw error
        }
    }

    var microphoneName: String? { mic.deviceName }

    func reportInputSignalIfReady() {
        guard !inputSignalReported, Date().timeIntervalSince(startedAt) >= 5 else { return }
        inputSignalReported = true
        let report = mic.signalReport
        FileHandle.standardError.write(Data(
            "mic input check: device=\(mic.deviceName ?? "unknown") samples=\(report.sample_count) peak=\(report.peak_db)dB max100ms=\(report.max_window_rms_db)dB errors=\(report.write_errors)\n".utf8
        ))
    }

    func updateProcesses(_ processIDs: [AudioObjectID]) throws {
        guard captureMode == .callApp else { return }
        try system.updateProcesses(processIDs)
    }

    /// Stop both tracks and write meta.json.
    func stop() {
        mic.stop()
        system.stop()

        let ended = Date()
        let iso = ISO8601DateFormatter()

        // The tracks don't start on the same buffer; record how far each
        // lags the earliest so transcript timestamps share one clock.
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)

        var meta: [String: Any] = [
            "audio_capture": captureMode.rawValue,
            "recording_id": recordingID,
            "archive_after_transcription": true,
            "microphone_name": mic.deviceName ?? "",
            "microphone_uid": mic.deviceUID ?? "",
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": ended.timeIntervalSince(startedAt),
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": [
                "mic": Int(micStart.timeIntervalSince(earliest) * 1000),
                "system": Int(systemStart.timeIntervalSince(earliest) * 1000),
            ],
        ]
        try? MeetingSettings.attach(settings, to: &meta)
        if let encoded = try? JSONEncoder().encode(mic.signalReport),
           let report = try? JSONSerialization.jsonObject(with: encoded) {
            meta["microphone_signal"] = report
        }
        if let application { meta["application"] = application.rawValue }
        if let data = try? JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
    }
}
