import Foundation
import Testing
@testable import quill

@Suite("Voice profile store")
struct VoiceProfileStoreTests {
    @Test func storeRoundTripAndRemove() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-voice-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voiceprints.json")
        let store = VoiceProfileStore(url: url)

        let created = try store.add(name: "Maria", embeddings: [embedding(axis: 0)])
        let updated = try store.add(name: "maria", embeddings: [embedding(axis: 1)])

        #expect(created.id == updated.id)
        #expect(try store.load().profiles.single?.embeddings.count == 2)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(try store.remove("MARIA"))
        #expect(try store.load().profiles.isEmpty)
    }

    @Test func matcherAcceptsClearWinner() {
        let library = VoiceLibrary(profiles: [
            profile(id: "maria", name: "Maria", embedding: embedding(axis: 0)),
            profile(id: "oleg", name: "Oleg", embedding: embedding(axis: 1)),
        ])
        let match = VoiceMatcher.match(
            embedding: embedding(axis: 0),
            in: library,
            threshold: 0.42,
            margin: 0.08
        )
        #expect(match?.profileID == "maria")
        #expect(abs((match?.distance ?? 1) - 0) < 0.0001)
    }

    @Test func matcherRejectsAmbiguousWinner() {
        var query = embedding(axis: 0)
        query[1] = 0.99
        let library = VoiceLibrary(profiles: [
            profile(id: "a", name: "A", embedding: embedding(axis: 0)),
            profile(id: "b", name: "B", embedding: embedding(axis: 1)),
        ])
        #expect(VoiceMatcher.match(
            embedding: query,
            in: library,
            threshold: 0.5,
            margin: 0.08
        ) == nil)
    }

    private func embedding(axis: Int) -> [Float] {
        var value = [Float](repeating: 0, count: 256)
        value[axis] = 1
        return value
    }

    private func profile(id: String, name: String, embedding: [Float]) -> VoiceProfile {
        VoiceProfile(
            id: id,
            name: name,
            embeddings: [embedding],
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
