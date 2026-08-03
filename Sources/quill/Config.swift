import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": {
///         "enabled": true, "engine": "parakeet", "model": "v3",
///         "language": "pt", "silence_threshold_db": -34
///       },
///       "diarization": {
///         "enabled": false, "identify_speakers": true,
///         "max_speakers": 8, "match_threshold": 0.42,
///         "match_margin": 0.08
///       },
///       "auto_record": {
///         "zoom": true, "start_delay_seconds": 3,
///         "stop_delay_seconds": 20
///       },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name: "parakeet" (default, fast) or "whisper"
    /// (slower, more accurate). The coordinator warns and falls back to
    /// parakeet for anything else.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    /// Configured model for the engine, or nil when unset — each engine
    /// applies its own default, so the key can't mean two things at once.
    /// For parakeet: "v3" (multilingual, default) or "v2" (English-only,
    /// marginally higher recall on English). Whisper ships one model,
    /// "whisper-large-v3-turbo". Engines warn and fall back for anything they
    /// don't recognize.
    static func transcriptionModel() -> String? {
        guard let model = transcription()?["model"] as? String, !model.isEmpty else { return nil }
        return model
    }

    /// BCP-47-ish language code forced on engines that need one ("pt", "en",
    /// "es"). Only whisper reads it — parakeet v3 detects the language itself.
    /// Unset means whisper detects, which reads only the first window: a
    /// meeting that opens in another language can mislabel the whole
    /// transcript, so set this when you know the language.
    static func transcriptionLanguage() -> String? {
        guard let lang = transcription()?["language"] as? String, !lang.isEmpty else { return nil }
        return lang
    }

    /// RMS level which Whisper treats as possible voice, in dBFS. Whisper's
    /// own no-speech probability can be confidently wrong on silence, so the
    /// engine also checks the actual waveform. A lower value keeps quieter
    /// speech; a higher value suppresses more background noise. -34 dBFS is
    /// WhisperKit's EnergyVAD default. Clamp extreme config values so a typo
    /// cannot silently disable every transcript.
    static func whisperSilenceThresholdDB() -> Float {
        let configured = (transcription()?["silence_threshold_db"] as? NSNumber)?.floatValue
            ?? -34
        return min(max(configured, -80), -10)
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Split the system-audio track into stable participant clusters. Opt-in:
    /// first use downloads the FluidAudio offline diarization models and adds
    /// a second inference pass after ASR.
    static func diarizationEnabled() -> Bool {
        diarization()?["enabled"] as? Bool ?? false
    }

    /// Match diarized clusters against the local, user-labelled voiceprint
    /// library. Unknown or ambiguous voices keep their participant_N label.
    static func speakerIdentificationEnabled() -> Bool {
        diarization()?["identify_speakers"] as? Bool ?? true
    }

    /// Defensive cap for accidental over-clustering. The offline pipeline can
    /// infer the count itself; this only bounds the search space.
    static func diarizationMaxSpeakers() -> Int {
        let value = (diarization()?["max_speakers"] as? NSNumber)?.intValue ?? 8
        return min(max(value, 2), 20)
    }

    /// Maximum cosine distance accepted as a known voice. This is deliberately
    /// stricter than FluidAudio's within-recording clustering threshold: a
    /// false name is worse than an honest participant_N.
    static func voiceMatchThreshold() -> Float {
        let value = (diarization()?["match_threshold"] as? NSNumber)?.floatValue ?? 0.42
        return min(max(value, 0.05), 1.0)
    }

    /// Required separation between the best and second-best voice profiles.
    /// It prevents two similar voices from being assigned on a weak nearest
    /// neighbour win.
    static func voiceMatchMargin() -> Float {
        let value = (diarization()?["match_margin"] as? NSNumber)?.floatValue ?? 0.08
        return min(max(value, 0), 0.5)
    }

    private static func diarization() -> [String: Any]? {
        load()?["diarization"] as? [String: Any]
    }

    /// Start and stop recordings from Zoom's Core Audio activity. Opt-in:
    /// merely launching Zoom is not a call, so the monitor waits for Zoom to
    /// begin audio IO before it changes recording state.
    static func zoomAutoRecordEnabled() -> Bool {
        autoRecord()?["zoom"] as? Bool ?? false
    }

    /// Continuous Zoom audio required before starting. A small debounce keeps
    /// notification sounds and device reconfiguration from creating sessions.
    static func zoomAutoRecordStartDelay() -> TimeInterval {
        seconds(autoRecord()?["start_delay_seconds"], fallback: 3, range: 0...60)
    }

    /// How long Zoom may lose audio IO before an automatic recording stops.
    /// This absorbs device switches and short reconnects during a live call.
    static func zoomAutoRecordStopDelay() -> TimeInterval {
        seconds(autoRecord()?["stop_delay_seconds"], fallback: 20, range: 1...300)
    }

    private static func autoRecord() -> [String: Any]? {
        load()?["auto_record"] as? [String: Any]
    }

    private static func seconds(
        _ value: Any?,
        fallback: TimeInterval,
        range: ClosedRange<TimeInterval>
    ) -> TimeInterval {
        let parsed = (value as? NSNumber)?.doubleValue ?? fallback
        return min(max(parsed, range.lowerBound), range.upperBound)
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
