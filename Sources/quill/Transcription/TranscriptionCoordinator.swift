import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var diarizer: SpeakerDiarizer?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    /// Regenerate one completed session from the CLI. This intentionally does
    /// not invoke `on_stop`: reprocessing derived files must not duplicate an
    /// upload, filing action, or downstream automation.
    func processNow(_ sessionDir: URL) async throws {
        do {
            try await transcribe(sessionDir)
            await releaseModels()
        } catch {
            await releaseModels()
            throw error
        }
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribe(dir)
                notifyUser(title: "quill — transcript ready", body: dir.lastPathComponent)
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "quill — transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
        }
        await releaseModels()
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func releaseModels() async {
        await engine?.release()
        engine = nil
        // SpeakerDiarizer owns the Core ML model stack. Dropping it after the
        // queue drains keeps quill's idle memory footprint small.
        diarizer = nil
    }

    private func transcribe(_ dir: URL) async throws {
        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine()

        var merged: [Transcript.Segment] = []
        var diarization: Transcript.Diarization?
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            let attributed: [AttributedTranscriptSegment]
            if track.speaker == "them", Config.diarizationEnabled(), !segments.isEmpty {
                do {
                    let result = try await diarize(segments, audio: audio, sessionDir: dir)
                    attributed = result.segments
                    diarization = result.info
                } catch {
                    // Diarization enriches a transcript; it must never be able
                    // to destroy one. Preserve the old `them` output on any
                    // model, audio, or voice-library failure.
                    log(dir, "diarization failed — keeping them: \(error)")
                    attributed = Self.unattributed(segments, speaker: track.speaker)
                }
            } else {
                attributed = Self.unattributed(segments, speaker: track.speaker)
            }
            let offset = TimeInterval(track.offsetMs) / 1000
            merged += attributed.map {
                Transcript.Segment(
                    speaker: $0.speaker,
                    speaker_id: $0.speakerID,
                    speaker_cluster: $0.clusterID,
                    speaker_match: $0.match.map(Transcript.SpeakerMatch.init),
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            diarization: diarization,
            segments: merged
        )
        try transcript.write(to: dir)
        log(dir, "done — \(merged.count) segments")
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let engine: TranscriptionEngine
        switch Config.transcriptionEngine() {
        case "parakeet":
            engine = ParakeetEngine()
        case "whisper":
            engine = WhisperEngine()
        case let other:
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(other)\" — using parakeet\n".utf8
            ))
            engine = ParakeetEngine()
        }
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    private func diarize(
        _ segments: [TranscriptSegment],
        audio: URL,
        sessionDir: URL
    ) async throws -> (segments: [AttributedTranscriptSegment], info: Transcript.Diarization?) {
        let diarizer: SpeakerDiarizer
        if let current = self.diarizer {
            diarizer = current
        } else {
            let created = SpeakerDiarizer()
            self.diarizer = created
            diarizer = created
        }

        log(sessionDir, "diarizing \(audio.lastPathComponent) (\(SpeakerDiarizer.modelName))")
        let snapshot = try await diarizer.process(audio)
        guard !snapshot.turns.isEmpty else {
            log(sessionDir, "diarization found no speaker turns — keeping them")
            return (Self.unattributed(segments, speaker: "them"), nil)
        }

        var matches: [String: VoiceMatch] = [:]
        if Config.speakerIdentificationEnabled() {
            do {
                let library = try VoiceProfileStore().load()
                for (cluster, embedding) in snapshot.embeddings {
                    matches[cluster] = VoiceMatcher.match(
                        embedding: embedding,
                        in: library,
                        threshold: Config.voiceMatchThreshold(),
                        margin: Config.voiceMatchMargin()
                    )
                }
            } catch {
                // A corrupt optional library should not disable anonymous
                // participant diarization.
                log(sessionDir, "voice identification skipped: \(error)")
            }
        }

        let result = SpeakerAttribution.attribute(
            segments,
            turns: snapshot.turns,
            matches: matches
        )
        let speakers = result.speakers.map(Transcript.Diarization.Speaker.init)
        let identified = speakers.filter { $0.profile_id != nil }.count
        log(
            sessionDir,
            "diarization done — \(speakers.count) participant(s), \(identified) identified"
        )
        return (
            result.segments,
            Transcript.Diarization(model: SpeakerDiarizer.modelName, speakers: speakers)
        )
    }

    private static func unattributed(
        _ segments: [TranscriptSegment],
        speaker: String
    ) -> [AttributedTranscriptSegment] {
        segments.map {
            AttributedTranscriptSegment(
                speaker: speaker,
                speakerID: nil,
                clusterID: nil,
                match: nil,
                start: $0.start,
                end: $0.end,
                text: $0.text
            )
        }
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
private struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(tracks: tracks)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
private struct Transcript: Codable {
    struct SpeakerMatch: Codable {
        let profile_id: String
        let distance: Float
        let margin: Float

        init(_ match: VoiceMatch) {
            profile_id = match.profileID
            distance = match.distance
            margin = match.margin
        }
    }

    struct Diarization: Codable {
        struct Speaker: Codable {
            let id: String
            let cluster_id: String
            let label: String
            let profile_id: String?
            let match_distance: Float?
            let match_margin: Float?

            init(_ speaker: AttributedSpeaker) {
                id = speaker.speakerID
                cluster_id = speaker.clusterID
                label = speaker.label
                profile_id = speaker.match?.profileID
                match_distance = speaker.match?.distance
                match_margin = speaker.match?.margin
            }
        }

        let model: String
        let speakers: [Speaker]
    }

    struct Segment: Codable {
        let speaker: String
        let speaker_id: String?
        let speaker_cluster: String?
        let speaker_match: SpeakerMatch?
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let diarization: Diarization?
    let segments: [Segment]

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk — resumePending treats presence of transcript.json as "done".
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
