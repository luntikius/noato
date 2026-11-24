import Foundation

/// Reconstructed from the committed Markdown; no separate history database.
struct CompletedTranscript: Sendable, Identifiable {
    let id: String
    let title: String
    let file: URL
    let savedAt: Date
    let startedAt: Date

    static func latest(in destination: URL, excluding pending: Set<String> = []) -> [CompletedTranscript] {
        latest(in: [destination], excluding: pending)
    }

    static func latest(in destinations: [URL], excluding pending: Set<String> = []) -> [CompletedTranscript] {
        let candidates = destinations.flatMap { destination in ArtifactFiles.children(destination).compactMap { file -> CompletedTranscript? in
            guard file.pathExtension.lowercased() == "md", ArtifactFiles.directChild(file, of: destination),
                  let mark = MarkdownMeeting.read(file), !pending.contains(mark.id) else { return nil }
            let dates = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let meeting = Meeting(id: mark.id, started: mark.started, application: mark.application, directory: destination)
            return CompletedTranscript(id: mark.id, title: meeting.title, file: file,
                                       savedAt: dates?.creationDate ?? dates?.contentModificationDate ?? mark.started,
                                       startedAt: mark.started)
        } }.sorted {
            if $0.savedAt != $1.savedAt { return $0.savedAt > $1.savedAt }
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.file.path < $1.file.path
        }
        var seen: Set<String> = []
        return Array(candidates.filter { seen.insert($0.id).inserted }.prefix(5))
    }
}

struct TranscriptionState: Sendable {
    let jobs: [MeetingJob]
    let completed: [CompletedTranscript]
}
