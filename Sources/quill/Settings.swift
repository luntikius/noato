import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    var transcriptsDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/noato").path
    var previousTranscriptDirectories: [String] = []
    var legacyRecordingDirectories: [String] = []
    var microphoneUID: String?
    var systemAudio: SystemAudioSource = .callApp
    var zoom = false
    var telemost = false
    var automaticPaused = false
    var language = "ru"
    var diarization = true
    var maxSpeakers = 8
    var startDelay = 3.0
    var stopDelay = 20.0
    var minimumDuration = 10.0
    var silenceThreshold = -34.0
    var retention: MeetingAge?
    var setupCompleted = false
    // Retained only for importing existing installations using Parakeet.
    var engine = "whisper"
    var transcriptionEnabled = true

    var sources: AudioSources { AudioSources(microphoneUID: microphoneUID, systemAudio: systemAudio) }
    var destination: URL { URL(fileURLWithPath: (transcriptsDirectory as NSString).expandingTildeInPath).standardizedFileURL }
    var destinations: [URL] {
        Array(Set(([transcriptsDirectory] + previousTranscriptDirectories).map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL
        })).sorted { $0.path < $1.path }
    }

    func validated() throws -> Self {
        guard !transcriptsDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (transcriptsDirectory.hasPrefix("/") || transcriptsDirectory.hasPrefix("~/")),
              (0...60).contains(startDelay), (1...300).contains(stopDelay),
              (0...3600).contains(minimumDuration), (-80 ... -10).contains(silenceThreshold),
              (2...20).contains(maxSpeakers), [startDelay, stopDelay, minimumDuration, silenceThreshold].allSatisfy(\.isFinite),
              language.isEmpty || language.range(of: #"^[a-z]{2,3}(-[A-Za-z]{2,4})?$"#, options: .regularExpression) != nil
        else { throw SettingsError.invalid }
        return self
    }

    static func importing(_ values: [String: Any]) throws -> Self {
        var result = Self()
        if let path = values["transcripts_dir"] as? String { result.transcriptsDirectory = path }
        if let path = values["recordings_dir"] as? String { result.legacyRecordingDirectories = [(path as NSString).expandingTildeInPath] }
        else { result.legacyRecordingDirectories = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Recordings/Quill").path] }
        let sources = try AudioSources.parse(values)
        result.microphoneUID = sources.microphoneUID
        result.systemAudio = sources.systemAudio
        let automatic = values["auto_record"] as? [String: Any] ?? [:]
        result.zoom = automatic["zoom"] as? Bool ?? false
        result.telemost = automatic["telemost"] as? Bool ?? false
        result.automaticPaused = automatic["paused"] as? Bool ?? false
        result.startDelay = automatic["start_delay_seconds"] as? Double ?? 3
        result.stopDelay = automatic["stop_delay_seconds"] as? Double ?? 20
        let transcription = values["transcription"] as? [String: Any] ?? [:]
        result.language = transcription["language"] as? String ?? "ru"
        result.engine = transcription["engine"] as? String ?? "whisper"
        result.transcriptionEnabled = transcription["enabled"] as? Bool ?? true
        result.silenceThreshold = transcription["silence_threshold_db"] as? Double ?? -34
        let diarization = values["diarization"] as? [String: Any] ?? [:]
        result.diarization = diarization["enabled"] as? Bool ?? true
        result.maxSpeakers = diarization["max_speakers"] as? Int ?? 8
        return try result.validated()
    }
}

enum SettingsError: Error, CustomStringConvertible {
    case invalid
    var description: String { L10n.text("Some settings are invalid. Check the folder, language code and numeric ranges.") }
}

/// One durable settings owner shared by the menu, windows and CLI. The lock
/// covers read/modify/write, so a menu toggle cannot overwrite a window save.
final class SettingsStore: @unchecked Sendable {
    static let shared = SettingsStore(file: Config.path)
    let file: URL
    private let lock = NSLock()
    init(file: URL) { self.file = file }

    func read() throws -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        return try readUnlocked()
    }
    private func readUnlocked() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: file.path) else { return AppSettings() }
        return try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: file)).validated()
    }
    @discardableResult
    func update(_ edit: (inout AppSettings) throws -> Void) throws -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        var settings = try readUnlocked()
        let previous = settings.transcriptsDirectory
        try edit(&settings)
        if previous != settings.transcriptsDirectory, !settings.previousTranscriptDirectories.contains(previous) {
            settings.previousTranscriptDirectories.append(previous)
        }
        settings = try settings.validated()
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return settings
    }
}

/// A persisted per-meeting snapshot is also installed as task-local context
/// during inference: engines never observe later global settings changes.
enum MeetingSettings {
    @TaskLocal static var current: AppSettings?
    static func read(_ dir: URL) throws -> AppSettings {
        let meta = try RecordingArchive.metadata(dir)
        if let object = meta["noato_settings"] {
            return try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object)).validated()
        }
        return Config.current
    }
    static func attach(_ settings: AppSettings, to meta: inout [String: Any]) throws {
        meta["noato_settings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
    }
}
