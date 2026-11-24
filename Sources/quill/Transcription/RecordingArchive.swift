import Foundation

/// The only durable meeting output is Markdown. Receipts exist only while
/// cleanup is unfinished, so export and deletion can recover after a crash.
enum RecordingArchive {
    struct Receipt: Codable, Sendable {
        let markdown: String
        let markdownHash: String
        let recordingID: String
    }

    struct LegacyReceipt: Codable {
        let markdown: String
        let json: String
        let markdownHash: String
        let jsonHash: String
        let audioFiles: [String]
        let audioDeleted: Bool
    }

    enum ArchiveError: Error, CustomStringConvertible {
        case invalidMetadata, changedExport, missingMicrophoneSpeech, unsafeSession
        var description: String {
            switch self {
            case .invalidMetadata: return L10n.text("Invalid recording metadata; audio has been kept")
            case .changedExport: return L10n.text("The saved transcript is unavailable or has changed; remaining files have been kept")
            case .missingMicrophoneSpeech: return L10n.text("No microphone speech was recognized, or recording errors occurred. Audio has been kept for retry.")
            case .unsafeSession: return L10n.text("Unknown files or links were found in the recording folder; cleanup was stopped")
            }
        }
    }

    static func metadata(_ dir: URL) throws -> [String: Any] {
        let url = dir.appendingPathComponent("meta.json")
        guard ArtifactFiles.isRegular(url),
              let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ArchiveError.invalidMetadata
        }
        return meta
    }

    static func needsProcessing(_ dir: URL) -> Bool {
        guard ArtifactFiles.safeSession(dir), let meta = try? metadata(dir), meta["ended"] != nil else { return false }
        return (try? Meeting.read(dir)) != nil
    }

    static func validateTracks(_ meta: [String: Any]) throws -> [String] {
        guard let files = meta["files"] as? [String: String], !files.isEmpty else { throw ArchiveError.invalidMetadata }
        let audio = ["mic", "system"].compactMap { files[$0] }
        guard !audio.isEmpty, audio.allSatisfy({ ["mic.caf", "system.caf"].contains($0) }) else {
            throw ArchiveError.invalidMetadata
        }
        return audio
    }

    @discardableResult
    static func finish(_ dir: URL, destination: URL, body: String, hasMicrophoneSpeech: Bool) throws -> URL {
        let meeting = try Meeting.read(dir)
        let meta = try metadata(dir)
        _ = try validateTracks(meta)
        guard ArtifactFiles.safeSession(dir) else { throw ArchiveError.unsafeSession }
        let hasMic = (meta["files"] as? [String: String])?["mic"] != nil
        let writeErrors = (meta["microphone_signal"] as? [String: Any])?["write_errors"] as? Int ?? 0
        guard !hasMic || (hasMicrophoneSpeech && writeErrors == 0) else { throw ArchiveError.missingMicrophoneSpeech }
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard ArtifactFiles.isDirectory(destination), destination.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL else {
            throw ArchiveError.unsafeSession
        }
        let data = MarkdownMeeting.render(meeting, body: body)
        var output = destination.appendingPathComponent(meeting.filename + ".md")
        var suffix = 2
        while ArtifactFiles.exists(output) {
            if let existing = MarkdownMeeting.read(output), existing.id == meeting.id {
                guard existing.verified, (try? Data(contentsOf: output)) == data else { throw ArchiveError.changedExport }
                break
            }
            output = destination.appendingPathComponent(meeting.filename + "-\(suffix).md")
            suffix += 1
        }
        try data.write(to: output, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        let receipt = Receipt(markdown: output.path, markdownHash: MarkdownMeeting.hash(data), recordingID: meeting.id)
        try PropertyListEncoder().encode(receipt).write(to: dir.appendingPathComponent("export.plist"), options: .atomic)
        try verifyAndRemove(dir, receipt: receipt, destination: destination)
        return output
    }

    /// Called before loading models; a committed Markdown needs only cleanup.
    static func resumeCommitted(_ dir: URL, destination: URL) throws -> URL? {
        let meeting = try Meeting.read(dir)
        let receiptURL = dir.appendingPathComponent("export.plist")
        if ArtifactFiles.isRegular(receiptURL) {
            let receipt = try PropertyListDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
            try verifyAndRemove(dir, receipt: receipt, destination: destination)
            return URL(fileURLWithPath: receipt.markdown)
        }
        // Also covers a crash between the atomic Markdown save and receipt save.
        for file in ArtifactFiles.children(destination) where file.pathExtension == "md" {
            if let mark = MarkdownMeeting.read(file), mark.id == meeting.id {
                guard mark.verified else { throw ArchiveError.changedExport }
                let receipt = Receipt(markdown: file.path, markdownHash: MarkdownMeeting.hash(try Data(contentsOf: file)), recordingID: meeting.id)
                try verifyAndRemove(dir, receipt: receipt, destination: destination)
                return file
            }
        }
        return try migrateLegacy(dir, destination: destination)
    }

    private static func verifyAndRemove(_ dir: URL, receipt: Receipt, destination: URL) throws {
        let meeting = try Meeting.read(dir)
        let file = URL(fileURLWithPath: receipt.markdown)
        guard receipt.recordingID == meeting.id, ArtifactFiles.directChild(file, of: destination),
              let mark = MarkdownMeeting.read(file), mark.id == meeting.id, mark.verified,
              MarkdownMeeting.hash(try Data(contentsOf: file)) == receipt.markdownHash else { throw ArchiveError.changedExport }
        guard ArtifactFiles.safeSession(dir) else { throw ArchiveError.unsafeSession }
        try removeLegacyOutputs(dir, keeping: file, destination: destination)
        try FileManager.default.removeItem(at: dir)
    }

    private static func removeLegacyOutputs(_ dir: URL, keeping markdown: URL, destination: URL) throws {
        guard let old = legacyReceipt(dir, destination: destination) else { return }
        let md = URL(fileURLWithPath: old.markdown)
        let json = URL(fileURLWithPath: old.json)
        let candidates = [(md, old.markdownHash), (json, old.jsonHash)].filter { $0.0.standardizedFileURL != markdown.standardizedFileURL }
        for (file, expected) in candidates where FileManager.default.fileExists(atPath: file.path) {
            guard ArtifactFiles.isRegular(file), MarkdownMeeting.hash(try Data(contentsOf: file)) == expected else {
                throw ArchiveError.changedExport
            }
        }
        for (file, _) in candidates where ArtifactFiles.isRegular(file) { try FileManager.default.removeItem(at: file) }
    }

    static func legacyReceipt(_ dir: URL, destination: URL) -> LegacyReceipt? {
        let file = dir.appendingPathComponent("export.json")
        guard ArtifactFiles.isRegular(file),
              let r = try? JSONDecoder().decode(LegacyReceipt.self, from: Data(contentsOf: file)),
              ArtifactFiles.directChild(URL(fileURLWithPath: r.markdown), of: destination),
              ArtifactFiles.directChild(URL(fileURLWithPath: r.json), of: destination),
              URL(fileURLWithPath: r.markdown).pathExtension == "md",
              URL(fileURLWithPath: r.json).pathExtension == "json" else { return nil }
        return r
    }

    private static func migrateLegacy(_ dir: URL, destination: URL) throws -> URL? {
        guard let receipt = legacyReceipt(dir, destination: destination), receipt.audioDeleted else { return nil }
        let md = URL(fileURLWithPath: receipt.markdown)
        let json = URL(fileURLWithPath: receipt.json)
        guard ArtifactFiles.safeSession(dir), ArtifactFiles.isRegular(md),
              let data = try? Data(contentsOf: md), MarkdownMeeting.hash(data) == receipt.markdownHash else { throw ArchiveError.changedExport }
        if FileManager.default.fileExists(atPath: json.path) {
            guard ArtifactFiles.isRegular(json), MarkdownMeeting.hash(try Data(contentsOf: json)) == receipt.jsonHash else { throw ArchiveError.changedExport }
        }
        let meeting = try Meeting.read(dir)
        let text = String(decoding: data, as: UTF8.self)
        let body = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
        let marked = MarkdownMeeting.render(meeting, body: body)
        // A marked Markdown is itself a commit marker if interrupted here.
        let updated = Receipt(markdown: md.path, markdownHash: MarkdownMeeting.hash(marked), recordingID: meeting.id)
        try marked.write(to: md, options: .atomic)
        try PropertyListEncoder().encode(updated).write(to: dir.appendingPathComponent("export.plist"), options: .atomic)
        try verifyAndRemove(dir, receipt: updated, destination: destination)
        return md
    }
}
