import Foundation
@testable import quill

enum MeetingTestFixtures {
    static let now = ISO8601DateFormatter().date(from: "2026-11-10T12:00:00Z")!
    static func root() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quill-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }
    static func session(_ root: URL, id: String = "recording-1", started: Date = now) throws -> URL {
        let dir = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta: [String: Any] = ["application": "zoom", "started": ISO8601DateFormatter().string(from: started),
                                   "ended": ISO8601DateFormatter().string(from: started.addingTimeInterval(60)),
                                   "recording_id": id, "files": ["mic": "mic.caf", "system": "system.caf"]]
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        try Data([1, 2]).write(to: dir.appendingPathComponent("mic.caf"))
        try Data([3, 4]).write(to: dir.appendingPathComponent("system.caf"))
        return dir
    }
    static func legacy(_ dir: URL, destination: URL, audioDeleted: Bool = true) throws -> RecordingArchive.LegacyReceipt {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let meeting = try Meeting.read(dir)
        let md = destination.appendingPathComponent(meeting.filename + ".md")
        let json = destination.appendingPathComponent(meeting.filename + ".json")
        let mdData = Data("# Old meeting\n\n**[0:01] me:** Проверка\n".utf8)
        let jsonData = Data("{\"recording_id\":\"\(meeting.id)\"}".utf8)
        try mdData.write(to: md)
        try jsonData.write(to: json)
        let receipt = RecordingArchive.LegacyReceipt(markdown: md.path, json: json.path,
            markdownHash: MarkdownMeeting.hash(mdData), jsonHash: MarkdownMeeting.hash(jsonData),
            audioFiles: ["mic.caf", "system.caf"], audioDeleted: audioDeleted)
        try JSONEncoder().encode(receipt).write(to: dir.appendingPathComponent("export.json"))
        return receipt
    }
}
