import Foundation

struct VoiceProfile: Codable, Sendable, Equatable {
    let id: String
    var name: String
    var embeddings: [[Float]]
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, embeddings
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct VoiceLibrary: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var model: String = SpeakerDiarizer.embeddingModelName
    var profiles: [VoiceProfile] = []

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case model, profiles
    }
}

struct VoiceMatch: Sendable, Equatable {
    let profileID: String
    let name: String
    let distance: Float
    let margin: Float
}

enum VoiceLibraryError: Error, CustomStringConvertible {
    case invalidFile(URL)
    case incompatibleModel(String)
    case invalidEmbedding
    case emptyName

    var description: String {
        switch self {
        case .invalidFile(let url): return "can't parse voice library \(url.path)"
        case .incompatibleModel(let model):
            return "voice library uses incompatible model \(model)"
        case .invalidEmbedding: return "voice sample did not produce a valid 256D embedding"
        case .emptyName: return "voice profile name must not be empty"
        }
    }
}

/// Local storage for user-labelled voiceprints. The file contains biometric
/// embeddings, not audio, and is written owner-only (0600).
struct VoiceProfileStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/Application Support/quill/voiceprints.json",
            isDirectory: false
        )

    private static let embeddingSize = 256
    private static let maxEmbeddingsPerProfile = 20

    let url: URL

    init(url: URL = Self.defaultURL) {
        self.url = url
    }

    func load() throws -> VoiceLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return VoiceLibrary()
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let library = try decoder.decode(
                VoiceLibrary.self,
                from: Data(contentsOf: url)
            )
            guard library.model == SpeakerDiarizer.embeddingModelName else {
                throw VoiceLibraryError.incompatibleModel(library.model)
            }
            return library
        } catch let error as VoiceLibraryError {
            throw error
        } catch {
            throw VoiceLibraryError.invalidFile(url)
        }
    }

    @discardableResult
    func add(name rawName: String, embeddings rawEmbeddings: [[Float]]) throws -> VoiceProfile {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw VoiceLibraryError.emptyName }
        let embeddings = try rawEmbeddings.map(Self.validated)
        guard !embeddings.isEmpty else { throw VoiceLibraryError.invalidEmbedding }

        var library = try load()
        let now = Date()
        let index = library.profiles.firstIndex {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let profile: VoiceProfile
        if let index {
            library.profiles[index].name = name
            library.profiles[index].embeddings.append(contentsOf: embeddings)
            library.profiles[index].embeddings = Array(
                library.profiles[index].embeddings.suffix(Self.maxEmbeddingsPerProfile)
            )
            library.profiles[index].updatedAt = now
            profile = library.profiles[index]
        } else {
            let id = Self.uniqueID(for: name, existing: Set(library.profiles.map(\.id)))
            profile = VoiceProfile(
                id: id,
                name: name,
                embeddings: embeddings,
                createdAt: now,
                updatedAt: now
            )
            library.profiles.append(profile)
        }
        try save(library)
        return profile
    }

    @discardableResult
    func remove(_ nameOrID: String) throws -> Bool {
        var library = try load()
        let before = library.profiles.count
        library.profiles.removeAll {
            $0.id == nameOrID
                || $0.name.compare(
                    nameOrID,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
        }
        guard library.profiles.count != before else { return false }
        try save(library)
        return true
    }

    private func save(_ library: VoiceLibrary) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parent.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(library).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func validated(_ embedding: [Float]) throws -> [Float] {
        guard embedding.count == embeddingSize, embedding.allSatisfy(\.isFinite) else {
            throw VoiceLibraryError.invalidEmbedding
        }
        let normalized = VoiceMatcher.normalize(embedding)
        guard normalized.contains(where: { abs($0) > 0.000_001 }) else {
            throw VoiceLibraryError.invalidEmbedding
        }
        return normalized
    }

    private static func uniqueID(for name: String, existing: Set<String>) -> String {
        let folded = name.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let base = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        var slug = String(base)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
        if slug.isEmpty { slug = "speaker" }
        if !existing.contains(slug) { return slug }
        return "\(slug)-\(UUID().uuidString.prefix(8).lowercased())"
    }
}

enum VoiceMatcher {
    static func match(
        embedding: [Float],
        in library: VoiceLibrary,
        threshold: Float,
        margin requiredMargin: Float
    ) -> VoiceMatch? {
        guard embedding.count == 256 else { return nil }
        let query = normalize(embedding)
        let scored = library.profiles.compactMap { profile -> (VoiceProfile, Float)? in
            guard let centroid = centroid(profile.embeddings) else { return nil }
            return (profile, cosineDistance(query, centroid))
        }.sorted { $0.1 < $1.1 }

        guard let best = scored.first, best.1 <= threshold else { return nil }
        let margin = scored.count > 1 ? scored[1].1 - best.1 : 1
        guard margin >= requiredMargin else { return nil }
        return VoiceMatch(
            profileID: best.0.id,
            name: best.0.name,
            distance: best.1,
            margin: margin
        )
    }

    static func centroid(_ embeddings: [[Float]]) -> [Float]? {
        let valid = embeddings.filter { $0.count == 256 && $0.allSatisfy(\.isFinite) }
        guard !valid.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: 256)
        for embedding in valid {
            let normalized = normalize(embedding)
            for index in sum.indices { sum[index] += normalized[index] }
        }
        return normalize(sum)
    }

    static func normalize(_ vector: [Float]) -> [Float] {
        let squared = vector.reduce(Float(0)) { $0 + $1 * $1 }
        guard squared.isFinite, squared > 0 else {
            return [Float](repeating: 0, count: vector.count)
        }
        let norm = sqrt(squared)
        return vector.map { $0 / norm }
    }

    static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .infinity }
        let left = normalize(lhs), right = normalize(rhs)
        let similarity = zip(left, right).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        return 1 - min(max(similarity, -1), 1)
    }
}
