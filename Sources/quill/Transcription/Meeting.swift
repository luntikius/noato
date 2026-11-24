import CryptoKit
import Foundation

struct Meeting: Sendable, Equatable, Identifiable {
    let id: String
    let started: Date
    let application: CallApplication?
    let directory: URL

    var title: String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US")
        format.dateFormat = "dd.MM.yyyy · HH:mm"
        return "\(format.string(from: started)) · \(application?.title ?? "Mac")"
    }

    var filename: String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(application?.title ?? L10n.text("Meeting")) — \(format.string(from: started))"
    }

    static func read(_ directory: URL) throws -> Meeting {
        let meta = try RecordingArchive.metadata(directory)
        guard let rawDate = meta["started"] as? String,
              let started = ISO8601DateFormatter().date(from: rawDate),
              let id = meta["recording_id"] as? String, validID(id) else {
            throw RecordingArchive.ArchiveError.invalidMetadata
        }
        return Meeting(id: id, started: started,
                       application: (meta["application"] as? String).flatMap(CallApplication.init(rawValue:)),
                       directory: directory)
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 160 && id.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }
}

/// Ownership and commit marker stored in the Markdown itself, not a sidecar.
struct MarkdownMeeting: Sendable {
    let id: String
    let started: Date
    let application: CallApplication?
    let bodyHash: String
    let body: String

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func render(_ meeting: Meeting, body: String) -> Data {
        let marker = "<!-- quill:v1 id=\(meeting.id) started=\(ISO8601DateFormatter().string(from: meeting.started)) application=\(meeting.application?.rawValue ?? "system") body-sha256=\(hash(Data(body.utf8))) -->"
        return Data("# \(meeting.filename)\n\n\(marker)\n\n\(body)".utf8)
    }

    static func read(_ file: URL) -> MarkdownMeeting? {
        guard ArtifactFiles.isRegular(file),
              let text = try? String(contentsOf: file, encoding: .utf8),
              let range = text.range(of: "\n\n<!-- quill:v1 "), range.lowerBound < text.index(text.startIndex, offsetBy: min(300, text.count)),
              let end = text.range(of: " -->\n\n", range: range.upperBound..<text.endIndex) else { return nil }
        let fields = Dictionary(text[range.upperBound..<end.lowerBound].split(separator: " ").compactMap { part -> (String, String)? in
            let pair = part.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        }, uniquingKeysWith: { first, _ in first })
        guard let id = fields["id"], Meeting.validID(id),
              let date = fields["started"].flatMap({ ISO8601DateFormatter().date(from: $0) }),
              let hash = fields["body-sha256"], hash.count == 64,
              let app = fields["application"], app == "system" || CallApplication(rawValue: app) != nil else { return nil }
        return MarkdownMeeting(id: id, started: date, application: CallApplication(rawValue: app),
                               bodyHash: hash, body: String(text[end.upperBound...]))
    }

    var verified: Bool { Self.hash(Data(body.utf8)) == bodyHash }
}

/// Never follow links when inventorying or deleting meeting artifacts.
enum ArtifactFiles {
    // URL resource values may retain stale file types after delete/replace.
    // Read filesystem attributes afresh at every destructive boundary.
    private static func type(_ url: URL) -> FileAttributeType? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[.type] as? FileAttributeType
    }

    static func exists(_ url: URL) -> Bool { type(url) != nil }
    static func isRegular(_ url: URL) -> Bool { type(url) == .typeRegular }
    static func isDirectory(_ url: URL) -> Bool { type(url) == .typeDirectory }

    static func children(_ url: URL) -> [URL] {
        guard isDirectory(url) else { return [] }
        return (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }

    static func directChild(_ file: URL, of root: URL) -> Bool {
        let parent = URL(fileURLWithPath: file.standardizedFileURL.deletingLastPathComponent().path, isDirectory: true)
        let directory = URL(fileURLWithPath: root.standardizedFileURL.path, isDirectory: true)
        return parent == directory && directory.resolvingSymlinksInPath() == directory
    }

    static func safeSession(_ dir: URL) -> Bool {
        guard isDirectory(dir), dir.standardizedFileURL.resolvingSymlinksInPath() == dir.standardizedFileURL else { return false }
        // Only files produced by Quill may be removed with a whole session.
        let allowed: Set<String> = ["meta.json", "mic.caf", "system.caf", "transcript.md", "transcript.json",
                                    "export.json", "export.plist", "failure.plist", "transcribe.log",
                                    "mic.caf.signal.json", "system.caf.signal.json"]
        return children(dir).allSatisfy { isRegular($0) && allowed.contains($0.lastPathComponent) }
    }
}
