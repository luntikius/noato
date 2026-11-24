import Foundation

enum Config {
    static let dataRoot: URL = {
        if let value = ProcessInfo.processInfo.environment["NOATO_DATA_DIR"] { return URL(fileURLWithPath: value) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/noato")
    }()
    static let path = dataRoot.appendingPathComponent("settings.json")
    static let legacyPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/quill/config.json")
    static let defaultRoot = dataRoot.appendingPathComponent("Meetings")
    static var current: AppSettings { MeetingSettings.current ?? ((try? SettingsStore.shared.read()) ?? AppSettings()) }
    static func recordingsDir() -> URL? { defaultRoot }
    static func transcriptsDir() -> URL { current.destination }
    static func resolveRoot(cliOverride: String?) -> URL {
        cliOverride.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultRoot
    }
    static func onStop() -> String? { nil }
    static func transcriptionEnabled() -> Bool { current.transcriptionEnabled }
    static func transcriptionEngine() -> String { current.engine }
    static func transcriptionModel() -> String? { nil }
    static func transcriptionLanguage() -> String? { current.language.isEmpty ? nil : current.language }
    static func whisperSilenceThresholdDB() -> Float { Float(current.silenceThreshold) }
    static func diarizationEnabled() -> Bool { current.diarization }
    static func diarizationMaxSpeakers() -> Int { current.maxSpeakers }
    static func speakerIdentificationEnabled() -> Bool { false }
    static func voiceMatchThreshold() -> Float { 0.42 }
    static func voiceMatchMargin() -> Float { 0.08 }
    static func zoomAutoRecordEnabled() -> Bool { current.zoom }
    static func telemostAutoRecordEnabled() -> Bool { current.telemost }
    static func zoomAutoRecordStartDelay() -> TimeInterval { current.startDelay }
    static func zoomAutoRecordStopDelay() -> TimeInterval { current.stopDelay }
    static func autoRecordPaused() -> Bool { current.automaticPaused }
    static func micVoiceProcessing() -> Bool { false }
    static func audioCapture() throws -> AudioCaptureMode { try SettingsStore.shared.read().systemAudio.captureMode }
    static func audioSources(at file: URL = path) throws -> AudioSources {
        if file == path { return try SettingsStore.shared.read().sources }
        guard FileManager.default.fileExists(atPath: file.path) else { return try AudioSources.parse([:]) }
        guard let values = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { throw SourceError.invalidSettings }
        return try AudioSources.parse(values)
    }
    static func saveAudioSources(_ sources: AudioSources, at file: URL = path) throws {
        if file == path {
            try SettingsStore.shared.update { $0.microphoneUID = sources.microphoneUID; $0.systemAudio = sources.systemAudio }
        } else {
            var values = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
            values["microphone_uid"] = sources.microphoneUID
            values["system_audio_source"] = sources.systemAudio.rawValue
            values["audio_capture"] = sources.systemAudio.captureMode.rawValue
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: values).write(to: file, options: .atomic)
        }
    }
    static func saveAutoRecordPaused(_ paused: Bool, at file: URL = path) throws {
        if file == path { try SettingsStore.shared.update { $0.automaticPaused = paused } }
        else {
            var values = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
            var automatic = values["auto_record"] as? [String: Any] ?? [:]
            automatic["paused"] = paused; values["auto_record"] = automatic
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: values).write(to: file, options: .atomic)
        }
    }
}
