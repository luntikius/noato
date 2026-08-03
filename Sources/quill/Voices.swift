import ArgumentParser
import Foundation

struct Voices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the local, user-labelled voiceprint library.",
        subcommands: [VoicesEnroll.self, VoicesLabel.self, VoicesList.self, VoicesRemove.self]
    )
}

struct VoicesEnroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enroll",
        abstract: "Create or extend a voice profile from clean audio samples."
    )

    @Argument(help: "Person name stored in the transcript when confidently matched.")
    var name: String

    @Argument(help: "One or more audio files containing this person only.")
    var samples: [String] = []

    mutating func run() async throws {
        guard !samples.isEmpty else {
            throw ValidationError("provide at least one voice sample")
        }
        let diarizer = SpeakerDiarizer(maxSpeakers: 4)
        var embeddings: [[Float]] = []
        for path in samples {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("sample not found: \(url.path)")
            }
            let snapshot = try await diarizer.process(url)
            embeddings.append(try VoiceEnrollment.dominantEmbedding(from: snapshot, source: url))
            print("✓ sample: \(url.lastPathComponent)")
        }
        let profile = try VoiceProfileStore().add(name: name, embeddings: embeddings)
        print("✓ voice profile \(profile.name): \(profile.embeddings.count) sample(s)")
        print("  \(VoiceProfileStore.defaultURL.path)")
    }
}

struct VoicesLabel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "label",
        abstract: "Name a participant cluster from an existing quill session."
    )

    @Argument(help: "Session directory containing system.caf.")
    var session: String

    @Argument(help: "Participant number or ID, for example 2 or participant_2.")
    var participant: String

    @Argument(help: "Person name to remember.")
    var name: String

    mutating func run() async throws {
        let dir = URL(
            fileURLWithPath: (session as NSString).expandingTildeInPath,
            isDirectory: true
        )
        let audio = dir.appendingPathComponent("system.caf")
        guard FileManager.default.fileExists(atPath: audio.path) else {
            throw ValidationError("system.caf not found in \(dir.path)")
        }
        let wanted = Self.normalizedParticipant(participant)
        guard wanted != nil else {
            throw ValidationError("participant must be a positive number or participant_N")
        }

        let snapshot = try await SpeakerDiarizer().process(audio)
        let ids = SpeakerAttribution.participantIDs(for: snapshot.turns)
        guard
            let wanted,
            let cluster = ids.first(where: { $0.value == wanted })?.key,
            let embedding = snapshot.embeddings[cluster]
        else {
            let available = ids.values.sorted().joined(separator: ", ")
            throw ValidationError(
                "\(participant) not found; available: \(available.isEmpty ? "none" : available)"
            )
        }
        let profile = try VoiceProfileStore().add(name: name, embeddings: [embedding])
        print("✓ \(wanted) remembered as \(profile.name)")
        print("  \(VoiceProfileStore.defaultURL.path)")
    }

    private static func normalizedParticipant(_ raw: String) -> String? {
        let lower = raw.lowercased()
        let numberText = lower.hasPrefix("participant_")
            ? String(lower.dropFirst("participant_".count))
            : lower
        guard let number = Int(numberText), number > 0 else { return nil }
        return "participant_\(number)"
    }
}

struct VoicesList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List enrolled voice profiles."
    )

    func run() throws {
        let library = try VoiceProfileStore().load()
        guard !library.profiles.isEmpty else {
            print("no voice profiles")
            return
        }
        for profile in library.profiles.sorted(by: { $0.name < $1.name }) {
            print("\(profile.id)\t\(profile.name)\t\(profile.embeddings.count) sample(s)")
        }
    }
}

struct VoicesRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Delete a voice profile by name or ID."
    )

    @Argument(help: "Profile name or ID.")
    var profile: String

    func run() throws {
        if try VoiceProfileStore().remove(profile) {
            print("✓ removed \(profile)")
        } else {
            throw ValidationError("voice profile not found: \(profile)")
        }
    }
}

enum VoiceEnrollment {
    /// Enrollment input should contain one person. A small secondary cluster
    /// is tolerated because diarizers occasionally split one voice, but mixed
    /// recordings are rejected instead of poisoning a biometric profile.
    static func dominantEmbedding(
        from snapshot: SpeakerDiarizationSnapshot,
        source: URL
    ) throws -> [Float] {
        var duration: [String: TimeInterval] = [:]
        for turn in snapshot.turns {
            duration[turn.clusterID, default: 0] += max(0, turn.end - turn.start)
        }
        let ranked = duration.sorted { $0.value > $1.value }
        guard
            let dominant = ranked.first,
            dominant.value >= 3,
            let embedding = snapshot.embeddings[dominant.key]
        else {
            throw ValidationError(
                "\(source.lastPathComponent): need at least 3 seconds of clear speech"
            )
        }
        let total = ranked.reduce(0) { $0 + $1.value }
        if ranked.count > 1, total > 0, dominant.value / total < 0.7 {
            throw ValidationError(
                "\(source.lastPathComponent): multiple substantial voices detected; use a cleaner sample"
            )
        }
        return embedding
    }
}
