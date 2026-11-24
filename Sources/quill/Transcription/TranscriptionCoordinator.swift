import AVFoundation
import Foundation

/// Sole owner of the serial transcription queue and its UI projection.
actor TranscriptionCoordinator {
    enum TranscriptionError: Error, CustomStringConvertible {
        case noReadableTracks, incompleteTracks, busy
        var description: String {
            switch self {
            case .busy: return L10n.text("A meeting is already being processed")
            case .noReadableTracks: return L10n.text("The audio tracks could not be read. The recording has been kept.")
            case .incompleteTracks: return L10n.text("An audio track could not be processed. The recording has been kept.")
            }
        }
    }
    private struct Failure: Codable { let message: String }
    private var queue: [URL] = []
    private var jobs: [String: MeetingJob] = [:]
    private var activeID: String?
    private var draining = false
    private var recordingRevision = -1
    private var engine: TranscriptionEngine?
    private var diarizer: SpeakerDiarizer?
    private var completed: [CompletedTranscript] = []
    private var idleHandler: (@Sendable () -> Void)?
    func setIdleHandler(_ handler: @escaping @Sendable () -> Void) { idleHandler = handler }
    private var statusHandler: (@Sendable (TranscriptionState) -> Void)?
    private var progressToken = UUID()
    private var estimator = RemainingTimeEstimator()
    private var publishTask: Task<Void, Never>?
    private var lastPublication = -Double.infinity
    private let notifier: @Sendable (String, String) -> Void
    private var destination: URL
    private let destinationOverride: URL?
    private var settings: AppSettings
    private var preparedSettings: AppSettings?
    private let processor: (@Sendable (URL) async throws -> URL)?

    init(destination: URL? = nil, processor: (@Sendable (URL) async throws -> URL)? = nil,
         notifier: @escaping @Sendable (String, String) -> Void = { notifyUser(title: $0, body: $1) }) {
        self.notifier = notifier
        self.destination = destination ?? Config.transcriptsDir()
        self.destinationOverride = destination
        self.settings = Config.current
        self.processor = processor
    }

    private var knownDestinations: [URL] {
        Array(Set((destinationOverride == nil ? settings.destinations : []) + [destination] + jobs.values.compactMap { try? jobSettings($0.meeting.directory).destination }))
    }

    func updateSettings(_ value: AppSettings) {
        settings = value
        if destinationOverride == nil { destination = value.destination }
        refreshCompleted()
    }

    func isBusy() -> Bool { activeID != nil || !queue.isEmpty }

    private func jobSettings(_ dir: URL) throws -> AppSettings {
        var value = try MeetingSettings.read(dir)
        if let destinationOverride { value.transcriptsDirectory = destinationOverride.path }
        return value
    }

    private func freezeSettings(_ dir: URL) throws {
        var meta = try RecordingArchive.metadata(dir)
        guard meta["noato_settings"] == nil else { return }
        try MeetingSettings.attach(try jobSettings(dir), to: &meta)
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }

    func setStatusHandler(_ handler: @escaping @Sendable (TranscriptionState) -> Void) {
        statusHandler = handler
        publish()
    }

    func refreshCompleted() {
        completed = CompletedTranscript.latest(in: knownDestinations, excluding: Set(jobs.keys))
        publish()
    }

    func state() -> TranscriptionState { TranscriptionState(jobs: snapshot(), completed: completed) }

    func snapshot() -> [MeetingJob] {
        func rank(_ phase: MeetingPhase) -> Int {
            switch phase { case .recording: return 1; case .queued: return 2; case .failed: return 3; default: return 0 }
        }
        return jobs.values.sorted {
            let a = rank($0.phase), b = rank($1.phase)
            if a != b { return a < b }
            return $0.meeting.started == $1.meeting.started ? $0.id < $1.id : $0.meeting.started < $1.meeting.started
        }
    }

    func setRecording(_ meeting: Meeting?, revision: Int) {
        guard revision > recordingRevision else { return }
        recordingRevision = revision
        jobs = jobs.filter { $0.value.phase != .recording }
        if let meeting { jobs[meeting.id] = MeetingJob(meeting: meeting, phase: .recording) }
        publish()
    }

    func enqueue(_ dir: URL) {
        guard let meeting = try? Meeting.read(dir), jobs[meeting.id]?.phase != .queued, activeID != meeting.id else { return }
        do { try freezeSettings(dir); if try discardIfTooShort(dir) { return } }
        catch { fail(meeting, message: String(describing: error)); return }
        guard processor != nil || ((try? jobSettings(dir).transcriptionEnabled) ?? false) else {
            fail(meeting, message: L10n.text("Transcription is disabled in Settings"))
            return
        }
        jobs[meeting.id] = MeetingJob(meeting: meeting, phase: .queued)
        if !queue.contains(dir) { queue.append(dir) }
        publish()
        drainIfIdle()
    }

    func retry(_ id: String) {
        guard let job = jobs[id], job.phase == .failed else { return }
        try? FileManager.default.removeItem(at: job.meeting.directory.appendingPathComponent("failure.plist"))
        enqueue(job.meeting.directory)
    }

    func resumePending(root: URL) {
        for dir in ArtifactFiles.children(root).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard ArtifactFiles.safeSession(dir), let meeting = try? Meeting.read(dir), jobs[meeting.id] == nil else { continue }
            do {
                try freezeSettings(dir)
                for name in ["transcribe.log", "mic.caf.signal.json", "system.caf.signal.json"] {
                    let file = dir.appendingPathComponent(name)
                    if ArtifactFiles.isRegular(file) { try FileManager.default.removeItem(at: file) }
                }
                if try RecordingArchive.resumeCommitted(dir, destination: jobSettings(dir).destination) != nil { continue }
                if try discardIfTooShort(dir) { continue }
                let failure = dir.appendingPathComponent("failure.plist")
                if ArtifactFiles.isRegular(failure),
                   let data = try? Data(contentsOf: failure),
                   let text = try? PropertyListDecoder().decode(Failure.self, from: data).message {
                    jobs[meeting.id] = MeetingJob(meeting: meeting, phase: .failed, error: text)
                } else if (try RecordingArchive.metadata(dir))["ended"] == nil {
                    fail(meeting, message: L10n.text("Recording was interrupted. You can retry transcription of the saved audio."))
                } else { enqueue(dir) }
            } catch { fail(meeting, message: String(describing: error)) }
        }
        refreshCompleted()
    }

    @discardableResult
    func processNow(_ dir: URL) async throws -> URL? {
        guard !draining, activeID == nil else { throw TranscriptionError.busy }
        if let saved = try RecordingArchive.resumeCommitted(dir, destination: jobSettings(dir).destination) {
            refreshCompleted()
            return saved
        }
        try freezeSettings(dir)
        if try discardIfTooShort(dir) { return nil }
        let meeting = try Meeting.read(dir)
        activeID = meeting.id
        jobs[meeting.id] = MeetingJob(meeting: meeting, phase: .preparing)
        publish()
        defer { activeID = nil; publish(); drainIfIdle() }
        do {
            let output = try await transcribe(dir)
            await releaseModels()
            jobs.removeValue(forKey: meeting.id)
            refreshCompleted()
            return output
        } catch {
            progressToken = UUID()
            await releaseModels()
            fail(meeting, message: String(describing: error))
            throw error
        }
    }

    func previewDeletion(root: URL, age: MeetingAge, now: Date, protecting: URL?) -> MeetingDeletion {
        MeetingCleanup.preview(roots: [root] + (destinationOverride == nil ? settings.legacyRecordingDirectories : []).map { URL(fileURLWithPath: $0) }, destinations: knownDestinations, age: age, now: now,
                               protected: protectedDirectories().union(protecting.map { [$0.standardizedFileURL] } ?? []))
    }

    /// No await between checking active work, queue exclusion and deletion.
    func delete(_ preview: MeetingDeletion, protecting: URL?) -> MeetingDeletionResult {
        let protected = protectedDirectories().union(protecting.map { [$0.standardizedFileURL] } ?? [])
        var result = MeetingDeletionResult()
        for candidate in preview.candidates {
            guard candidate.started < preview.cutoff, activeID != candidate.id,
                  !candidate.paths.contains(where: { protected.contains($0.standardizedFileURL) }),
                  MeetingCleanup.unchanged(candidate) else { result.skipped += 1; continue }
            queue.removeAll { dir in candidate.paths.contains { $0.standardizedFileURL == dir.standardizedFileURL } }
            do {
                try MeetingCleanup.remove(candidate)
                jobs.removeValue(forKey: candidate.id)
                result.deleted += 1
            } catch {
                // Keep failed work visible and retryable if any source survived.
                if let job = jobs[candidate.id], ArtifactFiles.isDirectory(job.meeting.directory) {
                    fail(job.meeting, message: L10n.format("Could not delete: %@", String(describing: error)))
                } else { jobs.removeValue(forKey: candidate.id) }
                result.errors.append("\(candidate.id): \(error)")
            }
        }
        refreshCompleted()
        return result
    }

    func deleteFailed(_ id: String) -> String? {
        guard let job = jobs[id], job.phase == .failed, activeID != id else { return L10n.text("The meeting state has changed") }
        guard ArtifactFiles.safeSession(job.meeting.directory),
              (try? Meeting.read(job.meeting.directory).id) == id else { return RecordingArchive.ArchiveError.unsafeSession.description }
        do {
            try FileManager.default.removeItem(at: job.meeting.directory)
            jobs.removeValue(forKey: id)
            refreshCompleted()
            return nil
        } catch { return String(describing: error) }
    }

    func previewCompletedDeletion(_ transcript: CompletedTranscript) throws -> MeetingDeletion.Candidate {
        guard jobs[transcript.id] == nil else { throw MeetingCleanup.TranscriptDeletionError.pending }
        guard let root = knownDestinations.first(where: { ArtifactFiles.directChild(transcript.file, of: $0) }) else { throw MeetingCleanup.TranscriptDeletionError.unavailable }
        return try MeetingCleanup.previewTranscript(transcript, destination: root)
    }

    func deleteCompleted(_ preview: MeetingDeletion.Candidate) -> String? {
        do {
            guard jobs[preview.id] == nil else { throw MeetingCleanup.TranscriptDeletionError.pending }
            guard preview.paths.count == 1, let file = preview.paths.first,
                  knownDestinations.contains(where: { ArtifactFiles.directChild(file, of: $0) }), MarkdownMeeting.read(file)?.id == preview.id,
                  MeetingCleanup.unchanged(preview) else { throw MeetingCleanup.TranscriptDeletionError.unavailable }
            try MeetingCleanup.remove(preview)
            refreshCompleted()
            return nil
        } catch {
            refreshCompleted()
            return String(describing: error)
        }
    }

    /// Admission rule shared by live stop, recovered jobs and explicit retry.
    /// Unknown duration and already committed outputs are preserved.
    private func discardIfTooShort(_ dir: URL) throws -> Bool {
        let meta = try RecordingArchive.metadata(dir)
        let duration: Double?
        if let seconds = meta["duration_seconds"] as? NSNumber { duration = seconds.doubleValue }
        else if let start = (meta["started"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }),
                let end = (meta["ended"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }) {
            duration = end.timeIntervalSince(start)
        } else { duration = nil }
        guard let duration, duration.isFinite, duration >= 0, duration < (try jobSettings(dir).minimumDuration) else { return false }
        let meeting = try Meeting.read(dir)
        // Never discard a previous export or its interrupted-cleanup receipt.
        if ArtifactFiles.exists(dir.appendingPathComponent("export.plist")) || ArtifactFiles.exists(dir.appendingPathComponent("export.json")) { return false }
        if knownDestinations.flatMap({ ArtifactFiles.children($0) }).contains(where: { MarkdownMeeting.read($0)?.id == meeting.id }) { return false }
        guard ArtifactFiles.safeSession(dir) else { throw RecordingArchive.ArchiveError.unsafeSession }
        try FileManager.default.removeItem(at: dir)
        queue.removeAll { $0.standardizedFileURL == dir.standardizedFileURL }
        jobs.removeValue(forKey: meeting.id)
        notifier("noato", L10n.text("Recording too short — no transcript will be created"))
        refreshCompleted()
        return true
    }

    private func protectedDirectories() -> Set<URL> {
        Set(jobs.values.filter { $0.phase == .recording || $0.id == activeID }.map { $0.meeting.directory.standardizedFileURL })
    }

    private func drainIfIdle() {
        guard !draining, activeID == nil, !queue.isEmpty else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            guard let meeting = try? Meeting.read(dir) else {
                if let job = jobs.values.first(where: { $0.meeting.directory.standardizedFileURL == dir.standardizedFileURL }) {
                    if ArtifactFiles.isDirectory(dir) { fail(job.meeting, message: L10n.text("Could not read recording metadata")) }
                    else { jobs.removeValue(forKey: job.id) }
                }
                publish()
                continue
            }
            activeID = meeting.id
            setPhase(.preparing, id: meeting.id)
            do {
                let output: URL
                if let processor { output = try await processor(dir) }
                else { output = try await transcribe(dir) }
                progressToken = UUID()
                jobs.removeValue(forKey: meeting.id)
                refreshCompleted()
                notifier(L10n.text("noato — transcript ready"), output.lastPathComponent)
                runHook(for: output)
            } catch {
                progressToken = UUID()
                await releaseModels()
                fail(meeting, message: String(describing: error))
                notifier(L10n.text("noato — transcription failed"), String(describing: error))
            }
            activeID = nil
            publish()
        }
        await releaseModels()
        draining = false
        idleHandler?()
        drainIfIdle()
    }

    private func releaseModels() async {
        await engine?.release()
        engine = nil
        diarizer = nil
    }

    private func fail(_ meeting: Meeting, message: String) {
        progressToken = UUID()
        jobs[meeting.id] = MeetingJob(meeting: meeting, phase: .failed, error: message)
        // A tiny recovery record, never a diagnostic log or transcript JSON.
        if let data = try? PropertyListEncoder().encode(Failure(message: message)) {
            try? data.write(to: meeting.directory.appendingPathComponent("failure.plist"), options: .atomic)
        }
        publish()
    }

    private func setPhase(_ phase: MeetingPhase, id: String, detail: String = "") {
        progressToken = UUID()
        estimator.start(at: ProcessInfo.processInfo.systemUptime)
        jobs[id]?.phase = phase
        jobs[id]?.detail = detail
        jobs[id]?.fraction = nil
        jobs[id]?.estimatedSeconds = nil
        publish()
    }

    private func updateProgress(id: String, token: UUID, completed: Double, total: Double) {
        guard token == progressToken, activeID == id, total > 0, completed.isFinite else { return }
        let value = min(total, max(estimator.completed, completed))
        jobs[id]?.estimatedSeconds = estimator.observe(value, total: total, at: ProcessInfo.processInfo.systemUptime)
        jobs[id]?.fraction = value / total
        publish()
    }

    private func publish() {
        guard publishTask == nil else { return }
        let delay = max(0, 0.25 - (ProcessInfo.processInfo.systemUptime - lastPublication))
        publishTask = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            self.flushPublication()
        }
    }

    private func flushPublication() {
        publishTask = nil
        lastPublication = ProcessInfo.processInfo.systemUptime
        statusHandler?(state())
    }

    private func transcribe(_ dir: URL) async throws -> URL {
        let settings = try jobSettings(dir)
        if preparedSettings != settings { await releaseModels(); preparedSettings = settings }
        return try await MeetingSettings.$current.withValue(settings) { try await transcribeFrozen(dir) }
    }

    private func transcribeFrozen(_ dir: URL) async throws -> URL {
        let destination = try jobSettings(dir).destination
        if let saved = try RecordingArchive.resumeCommitted(dir, destination: jobSettings(dir).destination) { return saved }
        let meeting = try Meeting.read(dir)
        let meta = try SessionMeta.read(from: dir)
        // ASR for both tracks first, then diarization: the audio ring is one
        // contiguous phase weighted by actual track durations.
        let durations = try meta.tracks.map { track -> Double in
            guard let file = try? AVAudioFile(forReading: dir.appendingPathComponent(track.file)),
                  file.length > 0, file.processingFormat.sampleRate > 0 else { throw TranscriptionError.noReadableTracks }
            return Double(file.length) / file.processingFormat.sampleRate
        }
        let engine = try await preparedEngine()
        let total = durations.reduce(0, +)
        var completed = 0.0
        var decoded: [(SessionMeta.Track, [TranscriptSegment])] = []
        setPhase(.transcribing, id: meeting.id)
        let token = progressToken
        for (index, track) in meta.tracks.enumerated() {
            jobs[meeting.id]?.detail = track.speaker == "me" ? L10n.text("Microphone") : (meeting.application?.title ?? L10n.text("Mac audio"))
            publish()
            let base = completed, duration = durations[index]
            let segments = try await engine.transcribe(dir.appendingPathComponent(track.file), progress: { [weak self] fraction in
                Task { await self?.updateProgress(id: meeting.id, token: token, completed: base + min(1, max(0, fraction)) * duration, total: total) }
            })
            decoded.append((track, segments))
            completed += duration
            updateProgress(id: meeting.id, token: token, completed: completed, total: total)
        }
        guard !decoded.isEmpty else { throw TranscriptionError.noReadableTracks }
        var merged: [Transcript.Segment] = []
        var info: Transcript.Diarization?
        for (track, segments) in decoded {
            let attributed: [AttributedTranscriptSegment]
            if track.speaker == "them", Config.diarizationEnabled(), !segments.isEmpty {
                do {
                    let result = try await diarize(segments, audio: dir.appendingPathComponent(track.file), id: meeting.id)
                    attributed = result.segments
                    info = result.info
                } catch {
                    // Speaker separation is optional; preserve the complete ASR.
                    attributed = Self.unattributed(segments, speaker: "them")
                }
            } else { attributed = Self.unattributed(segments, speaker: track.speaker) }
            let offset = Double(track.offsetMs) / 1000
            merged += attributed.map {
                Transcript.Segment(speaker: $0.speaker, speaker_id: $0.speakerID, speaker_cluster: $0.clusterID,
                                   speaker_match: $0.match.map(Transcript.SpeakerMatch.init),
                                   start_ms: Int(($0.start + offset) * 1000), end_ms: Int(($0.end + offset) * 1000), text: $0.text)
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }
        let transcript = Transcript(engine: engine.name, model: engine.model,
                                    created_at: ISO8601DateFormatter().string(from: Date()), diarization: info, segments: merged)
        setPhase(.saving, id: meeting.id)
        return try RecordingArchive.finish(dir, destination: destination, body: transcript.rendered(),
                                           hasMicrophoneSpeech: merged.contains { $0.speaker == "me" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let engine: TranscriptionEngine = Config.transcriptionEngine() == "whisper" ? WhisperEngine() : ParakeetEngine()
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    private func diarize(_ segments: [TranscriptSegment], audio: URL, id: String) async throws
      -> (segments: [AttributedTranscriptSegment], info: Transcript.Diarization?) {
        setPhase(.preparing, id: id, detail: L10n.text("Speaker separation model"))
        let diarizer = self.diarizer ?? SpeakerDiarizer()
        self.diarizer = diarizer
        try await diarizer.prepare()
        setPhase(.diarizing, id: id)
        let token = progressToken
        let snapshot = try await diarizer.process(audio, progress: { [weak self] done, total in
            Task { await self?.diarizationProgress(id: id, token: token, done: done, total: total) }
        })
        setPhase(.finishingSpeakers, id: id)
        guard !snapshot.turns.isEmpty else { return (Self.unattributed(segments, speaker: "them"), nil) }
        var matches: [String: VoiceMatch] = [:]
        if Config.speakerIdentificationEnabled(), let library = try? VoiceProfileStore().load() {
            for (cluster, embedding) in snapshot.embeddings {
                matches[cluster] = VoiceMatcher.match(embedding: embedding, in: library,
                    threshold: Config.voiceMatchThreshold(), margin: Config.voiceMatchMargin())
            }
        }
        let result = SpeakerAttribution.attribute(segments, turns: snapshot.turns, matches: matches)
        return (result.segments, Transcript.Diarization(model: SpeakerDiarizer.modelName,
                                                        speakers: result.speakers.map(Transcript.Diarization.Speaker.init)))
    }

    private func diarizationProgress(id: String, token: UUID, done: Int, total: Int) {
        guard token == progressToken, jobs[id]?.phase == .diarizing else { return }
        if done >= total, total > 0 {
            jobs[id]?.phase = .finishingSpeakers
            jobs[id]?.fraction = nil
            jobs[id]?.estimatedSeconds = nil
            publish()
        } else { updateProgress(id: id, token: token, completed: Double(done), total: Double(total)) }
    }

    private static func unattributed(_ segments: [TranscriptSegment], speaker: String) -> [AttributedTranscriptSegment] {
        segments.map { AttributedTranscriptSegment(speaker: speaker, speakerID: nil, clusterID: nil, match: nil,
                                                   start: $0.start, end: $0.end, text: $0.text) }
    }

    /// The hook now receives the durable Markdown path; no deleted session path.
    private func runHook(for output: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "\(cmd) \"$0\"", output.path]
        try? task.run()
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

        _ = try RecordingArchive.validateTracks(json)
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

/// In-memory transcript; only rendered Markdown is written.
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

    func rendered() -> String {
        var lines = ["engine: \(engine) (\(model))", ""]
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
