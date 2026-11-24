import Foundation

enum MeetingAge: String, CaseIterable, Codable, Sendable {
    case day, week, month
    var title: String {
        switch self { case .day: return L10n.text("1 day"); case .week: return L10n.text("1 week"); case .month: return L10n.text("1 month") }
    }
    func cutoff(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .day: return now.addingTimeInterval(-24 * 3600)
        case .week: return now.addingTimeInterval(-7 * 24 * 3600)
        case .month: return calendar.date(byAdding: .month, value: -1, to: now)!
        }
    }
}

struct MeetingDeletion: Sendable {
    struct Candidate: Sendable {
        let id: String
        let started: Date
        var paths: [URL]
        var fingerprint: String
        var bytes: Int64
    }
    let age: MeetingAge
    let cutoff: Date
    let candidates: [Candidate]
    let skippedActive: Int
    var bytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
}

struct MeetingDeletionResult: Sendable {
    var deleted = 0
    var skipped = 0
    var errors: [String] = []
}

/// Inventory only verified Quill artifacts under the two configured roots.
/// The preview retains exact path fingerprints, not an open-ended delete query.
enum MeetingCleanup {
    enum TranscriptDeletionError: Error, CustomStringConvertible {
        case pending, unavailable
        var description: String {
            switch self {
            case .pending: return L10n.text("This meeting is still being processed. Its transcript cannot be deleted yet.")
            case .unavailable: return L10n.text("The transcript is unavailable or has changed. Reopen the list.")
            }
        }
    }

    static func previewTranscript(_ transcript: CompletedTranscript, destination: URL) throws -> MeetingDeletion.Candidate {
        let file = transcript.file
        guard ArtifactFiles.directChild(file, of: destination), file.pathExtension.lowercased() == "md",
              let mark = MarkdownMeeting.read(file), mark.id == transcript.id,
              let fingerprint = fingerprint([file]) else { throw TranscriptDeletionError.unavailable }
        return MeetingDeletion.Candidate(id: mark.id, started: mark.started, paths: [file],
                                         fingerprint: fingerprint, bytes: size(file))
    }

    static func preview(root: URL, destination: URL, age: MeetingAge, now: Date,
                        protected: Set<URL>, calendar: Calendar = .current) -> MeetingDeletion {
        let protectedPaths = Set(protected.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        let cutoff = age.cutoff(from: now, calendar: calendar)
        var groups: [String: MeetingDeletion.Candidate] = [:]
        var protectedIDs: Set<String> = []

        func add(_ file: URL, meeting: Meeting) {
            guard meeting.started < cutoff else { return }
            var candidate = groups[meeting.id] ?? .init(id: meeting.id, started: meeting.started, paths: [], fingerprint: "", bytes: 0)
            if !candidate.paths.contains(file) { candidate.paths.append(file) }
            groups[meeting.id] = candidate
        }

        for dir in ArtifactFiles.children(root) where ArtifactFiles.directChild(dir, of: root) {
            guard ArtifactFiles.safeSession(dir), let meeting = try? Meeting.read(dir) else { continue }
            if protectedPaths.contains(dir.standardizedFileURL.resolvingSymlinksInPath()) {
                if meeting.started < cutoff { protectedIDs.insert(meeting.id) }
                continue
            }
            add(dir, meeting: meeting)
            // Old outputs have no marker. Exact receipt plus both content hashes
            // establish ownership; no filename-pattern deletion is used.
            if let r = RecordingArchive.legacyReceipt(dir, destination: destination) {
                let md = URL(fileURLWithPath: r.markdown)
                let json = URL(fileURLWithPath: r.json)
                if ArtifactFiles.isRegular(md), ArtifactFiles.isRegular(json),
                   let mdData = try? Data(contentsOf: md), let jsonData = try? Data(contentsOf: json),
                   MarkdownMeeting.hash(mdData) == r.markdownHash,
                   MarkdownMeeting.hash(jsonData) == r.jsonHash {
                    add(md, meeting: meeting)
                    add(json, meeting: meeting)
                }
            }
        }
        for md in ArtifactFiles.children(destination) where md.pathExtension == "md" && ArtifactFiles.directChild(md, of: destination) {
            guard let mark = MarkdownMeeting.read(md) else { continue }
            let meeting = Meeting(id: mark.id, started: mark.started, application: mark.application, directory: root)
            add(md, meeting: meeting)
        }
        for id in protectedIDs { groups.removeValue(forKey: id) }
        let candidates = groups.values.compactMap { original -> MeetingDeletion.Candidate? in
            var candidate = original
            candidate.paths.sort { $0.path < $1.path }
            guard let fingerprint = fingerprint(candidate.paths) else { return nil }
            candidate.fingerprint = fingerprint
            candidate.bytes = candidate.paths.reduce(0) { $0 + size($1) }
            return candidate
        }.sorted { $0.started == $1.started ? $0.id < $1.id : $0.started < $1.started }
        return MeetingDeletion(age: age, cutoff: cutoff, candidates: candidates, skippedActive: protectedIDs.count)
    }

    static func preview(roots: [URL], destinations: [URL], age: MeetingAge, now: Date,
                        protected: Set<URL>, calendar: Calendar = .current) -> MeetingDeletion {
        var grouped: [String: MeetingDeletion.Candidate] = [:]
        let protectedMeetings = protected.compactMap { try? Meeting.read($0) }
        let protectedIDs = Set(protectedMeetings.map(\.id))
        let cutoff = age.cutoff(from: now, calendar: calendar)
        for root in roots {
            for destination in destinations {
                let inventory = preview(root: root, destination: destination, age: age, now: now, protected: protected, calendar: calendar)
                for candidate in inventory.candidates where !protectedIDs.contains(candidate.id) {
                    var merged = grouped[candidate.id] ?? candidate
                    merged.paths = Array(Set(merged.paths + candidate.paths)).sorted { $0.path < $1.path }
                    merged.bytes = merged.paths.reduce(0) { $0 + size($1) }
                    guard let hash = fingerprint(merged.paths) else { continue }
                    merged.fingerprint = hash
                    grouped[candidate.id] = merged
                }
            }
        }
        return MeetingDeletion(age: age, cutoff: age.cutoff(from: now, calendar: calendar),
                               candidates: grouped.values.sorted { $0.started < $1.started }, skippedActive: Set(protectedMeetings.filter { $0.started < cutoff }.map(\.id)).count)
    }

    static func unchanged(_ candidate: MeetingDeletion.Candidate) -> Bool {
        fingerprint(candidate.paths) == candidate.fingerprint
    }

    static func remove(_ candidate: MeetingDeletion.Candidate) throws {
        // Repeat at the last filesystem boundary, after queue exclusion.
        guard unchanged(candidate) else { throw RecordingArchive.ArchiveError.changedExport }
        for file in candidate.paths {
            if ArtifactFiles.isDirectory(file) {
                guard ArtifactFiles.safeSession(file) else { throw RecordingArchive.ArchiveError.unsafeSession }
            } else if !ArtifactFiles.isRegular(file) { throw RecordingArchive.ArchiveError.unsafeSession }
        }
        for file in candidate.paths { try FileManager.default.removeItem(at: file) }
    }

    private static func size(_ url: URL) -> Int64 {
        if ArtifactFiles.isDirectory(url) { return ArtifactFiles.children(url).reduce(0) { $0 + size($1) } }
        return ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    static func fingerprint(_ paths: [URL]) -> String? {
        var parts: [String] = []
        for path in paths {
            let files: [URL]
            if ArtifactFiles.isDirectory(path) {
                guard ArtifactFiles.safeSession(path) else { return nil }
                files = [path] + ArtifactFiles.children(path).sorted { $0.path < $1.path }
            } else {
                guard ArtifactFiles.isRegular(path) else { return nil }
                files = [path]
            }
            for file in files {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                      let date = attrs[.modificationDate] as? Date,
                      let inode = attrs[.systemFileNumber] as? NSNumber else { return nil }
                var entry = "\(file.path)|\(inode)|\(attrs[.size] ?? 0)|\(date.timeIntervalSince1970)"
                if ["md", "json", "plist"].contains(file.pathExtension.lowercased()), let data = try? Data(contentsOf: file) {
                    entry += "|" + MarkdownMeeting.hash(data)
                }
                parts.append(entry)
            }
        }
        return MarkdownMeeting.hash(Data(parts.joined(separator: "\n").utf8))
    }
}
