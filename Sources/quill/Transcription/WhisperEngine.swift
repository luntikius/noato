import AVFoundation
import Foundation
import WhisperKit

/// Whisper large-v3-turbo via WhisperKit's Core ML port (~1 GB). Roughly 20x
/// slower than parakeet — about six minutes for a one-hour meeting on Apple
/// Silicon, against twenty seconds — and noticeably more accurate, especially
/// on non-English speech and technical vocabulary. The engine to pick when the
/// transcript matters more than the turnaround.
actor WhisperEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case unreadableAudio(URL, Error?)

        var description: String {
            switch self {
            case .notPrepared: return "whisper engine used before prepare()"
            case .unreadableAudio(let url, let e):
                return "unreadable or empty audio \(url.lastPathComponent)"
                    + (e.map { ": \($0)" } ?? "")
            }
        }
    }

    /// Where the weights live. WhisperKit defaults its download base to
    /// ~/Documents, which is wrong twice over for a menu-bar daemon: iCloud
    /// Drive replicates that folder and evicts files to dataless stubs, and
    /// Core ML's mmap of an evicted weight file then blocks forever; and it's
    /// TCC-protected, so a LaunchAgent with no UI can't prompt its way in.
    /// Application Support is neither, and is tidy to uninstall.
    static let modelStore: URL = {
        if let path = ProcessInfo.processInfo.environment["NOATO_MODEL_DIR"] { return URL(fileURLWithPath: path) }
        let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/quill/models")
        if ProcessInfo.processInfo.environment["NOATO_DATA_DIR"] == nil,
           FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return Config.dataRoot.appendingPathComponent("models")
    }()

    /// WhisperKit's own repo identifier for the model, distinct from the name
    /// recorded as transcript provenance.
    static let whisperKitModel = "openai_whisper-large-v3-v20240930_turbo"

    static let modelDirectory = modelStore
        .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        .appendingPathComponent(whisperKitModel, isDirectory: true)

    static var modelsCached: Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy {
            FileManager.default.fileExists(atPath: modelDirectory
                .appendingPathComponent($0 + ".mlmodelc/coremldata.bin").path)
        }
    }

    nonisolated let name = "whisper"
    nonisolated let model = "whisper-large-v3-turbo"

    /// `WhisperKit` is a plain non-Sendable class, so Swift 6 refuses to pass
    /// an actor-isolated instance to its own nonisolated methods. Boxing it
    /// takes it out of the actor's region; the actor remains the real
    /// serialization point, since nothing outside these methods ever touches
    /// the pipeline and they run one at a time.
    private struct Pipeline: @unchecked Sendable {
        let kit: WhisperKit
    }

    private var pipeline: Pipeline?

    func prepare() async throws {
        guard pipeline == nil else { return }
        // A complete local model must not require Hub metadata/network access
        // on each meeting. WhisperKit validates the model contents on load.
        let cached = Self.modelsCached
        let config = WhisperKitConfig(
            model: Self.whisperKitModel,
            downloadBase: Self.modelStore,
            modelFolder: cached ? Self.modelDirectory.path : nil,
            verbose: false,
            prewarm: true,
            load: true,
            download: !cached
        )
        pipeline = Pipeline(kit: try await WhisperKit(config))
    }

    func transcribe(_ audio: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [TranscriptSegment] {
        guard let pipeline else { throw EngineError.notPrepared }

        // A track with no frames (recorder died before its first buffer)
        // makes AVFoundation raise an ObjC exception deep inside the
        // resampler — uncatchable from Swift, so it takes the whole daemon
        // down. Check readability up front instead.
        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw EngineError.unreadableAudio(audio, nil) }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        // Whisper's `noSpeechProb` is not a reliable silence detector. The
        // large-v3-turbo model reports 0.0 (absolute confidence that speech is
        // present) for some completely silent inputs, then emits stock phrases
        // such as "Продолжение следует...". Load the normalized 16 kHz
        // samples ourselves and run WhisperKit's energy VAD independently.
        // Passing the same array to transcribe avoids decoding the file twice.
        let samples: [Float]
        do {
            samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        var signal = AudioSignalAccumulator()
        samples.withUnsafeBufferPointer { signal.observe($0, sampleRate: 16000) }
        let health = signal.report
        Self.log("whisper signal \(audio.lastPathComponent): peak=\(health.peak_db)dB max100ms=\(health.max_window_rms_db)dB threshold=\(Config.whisperSilenceThresholdDB())dB")
        let detector = EnergyVAD(energyThreshold: Self.silenceThreshold())
        let voiceActivity = detector.voiceActivity(in: samples)
        guard voiceActivity.contains(true) else {
            Self.log("whisper: skipped silent track \(audio.lastPathComponent)")
            progress?(1)
            return []
        }

        // Capture this object: WhisperKit replaces its root Progress at completion.
        let trackProgress = pipeline.kit.progress
        let observation = trackProgress.observe(\.fractionCompleted, options: [.new]) { value, _ in
            progress?(value.fractionCompleted)
        }
        defer { observation.invalidate() }
        let results = try await pipeline.kit.transcribe(
            audioArray: samples,
            decodeOptions: Self.decodingOptions()
        )

        progress?(1)
        let rawSegments = results.flatMap(\.segments)
        let keptSegments = rawSegments.filter {
            Self.hasVoice(
                from: TimeInterval($0.start),
                to: TimeInterval($0.end),
                in: voiceActivity,
                frameDuration: TimeInterval(detector.frameLengthSamples)
                    / TimeInterval(detector.sampleRate)
            )
        }
        let dropped = rawSegments.count - keptSegments.count
        if dropped > 0 {
            Self.log(
                "whisper: dropped \(dropped) silent segment(s) from "
                    + audio.lastPathComponent
            )
        }

        return keptSegments
            .map {
                TranscriptSegment(
                    start: TimeInterval($0.start),
                    end: TimeInterval($0.end),
                    text: Self.clean($0.text),
                    words: ($0.words ?? []).compactMap { word in
                        let text = Self.clean(word.word)
                        guard !text.isEmpty else { return nil }
                        return TranscriptWord(
                            start: TimeInterval(word.start),
                            end: TimeInterval(word.end),
                            text: text
                        )
                    }
                )
            }
            .filter { !$0.text.isEmpty }
    }

    func release() async {
        await pipeline?.kit.unloadModels()
        pipeline = nil
    }

    /// Note what is deliberately absent: `chunkingStrategy` stays nil, so
    /// Whisper's own sequential seek loop walks long audio and segment
    /// timestamps stay coherent past the 30s window. The obvious-looking
    /// `.vad` truncates a 30s clip to its first ~20s, and with a language
    /// forced returns zero segments — both silently, which is the dangerous
    /// kind of wrong for a meeting you can't re-record (digimata/quill#5).
    ///
    /// Language: forcing beats detecting, because detection reads only the
    /// first window — a meeting that opens with a minute of English small
    /// talk mislabels the whole transcript. Detection is the fallback when
    /// `transcription.language` isn't set, since Whisper needs *some*
    /// language and guessing "en" would be worse.
    private static func decodingOptions() -> DecodingOptions {
        guard let language = Config.transcriptionLanguage() else {
            return DecodingOptions(
                detectLanguage: true,
                skipSpecialTokens: true,
                wordTimestamps: true
            )
        }
        return DecodingOptions(
            language: language,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            wordTimestamps: true
        )
    }

    /// Convert the user-facing dBFS threshold to the linear RMS value expected
    /// by EnergyVAD: amplitude = 10^(dB / 20).
    private static func silenceThreshold() -> Float {
        Float(pow(10, Double(Config.whisperSilenceThresholdDB()) / 20))
    }

    /// Require credible voice energy inside each decoded segment. A single
    /// click must not validate thirty seconds of hallucinated text, while a
    /// short real utterance should survive: at least 5% active frames, capped
    /// at one second and floored at one 100 ms VAD frame.
    private static func hasVoice(
        from start: TimeInterval,
        to end: TimeInterval,
        in activity: [Bool],
        frameDuration: TimeInterval
    ) -> Bool {
        guard !activity.isEmpty, frameDuration > 0, end > start else { return false }

        let lower = max(0, Int(floor(start / frameDuration)))
        let upper = min(activity.count, Int(ceil(end / frameDuration)))
        guard lower < upper else { return false }

        let frameCount = upper - lower
        let required = min(10, max(1, Int(ceil(Double(frameCount) * 0.05))))
        var active = 0
        for index in lower..<upper where activity[index] {
            active += 1
            if active >= required { return true }
        }
        return false
    }

    /// `skipSpecialTokens` is the primary fix for leaked control tokens. Keep
    /// a defensive cleanup too, so a future WhisperKit regression cannot put
    /// `<|startoftranscript|>` and timestamp tokens into markdown again.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"<\|[^>]+\|>"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
