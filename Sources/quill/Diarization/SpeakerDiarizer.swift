import FluidAudio
import Foundation

/// A model-independent snapshot of FluidAudio's offline diarization result.
/// Keeping the rest of quill on these tiny value types makes attribution and
/// voice matching deterministic and unit-testable without loading Core ML.
struct SpeakerTurn: Sendable, Equatable {
    let clusterID: String
    let start: TimeInterval
    let end: TimeInterval
}

struct SpeakerDiarizationSnapshot: Sendable {
    let turns: [SpeakerTurn]
    let embeddings: [String: [Float]]
}

/// Serializes access to the Core ML diarizer and keeps its models warm while a
/// transcription queue drains. Dropping this actor releases the model stack.
actor SpeakerDiarizer {
    static let modelName = "pyannote-community-1-wespeaker-vbx"
    static let embeddingModelName = "wespeaker-v2-256"

    /// FluidAudio's manager is a mutable reference type without Sendable
    /// conformance. This actor is its sole owner and serializes every access;
    /// boxing records that invariant for Swift 6's region checker.
    private struct Manager: @unchecked Sendable {
        let value: OfflineDiarizerManager
    }

    private let maxSpeakers: Int
    private var manager: Manager?

    init(maxSpeakers: Int = Config.diarizationMaxSpeakers()) {
        self.maxSpeakers = min(max(maxSpeakers, 2), 20)
    }

    func process(_ audio: URL) async throws -> SpeakerDiarizationSnapshot {
        let manager = try await preparedManager()
        let result = try await manager.value.process(audio)

        var turns: [SpeakerTurn] = []
        for segment in result.segments where segment.endTimeSeconds > segment.startTimeSeconds {
            turns.append(SpeakerTurn(
                clusterID: segment.speakerId,
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds)
            ))
        }
        turns.sort { lhs, rhs in
            lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
        }

        // Current FluidAudio offline results expose a weighted embedding per
        // reconstructed speaker. Keep a fallback for older compatible builds.
        var embeddings = result.speakerDatabase ?? [:]
        if embeddings.isEmpty {
            var sums: [String: [Float]] = [:]
            var weights: [String: Float] = [:]
            for segment in result.segments where !segment.embedding.isEmpty {
                let weight = max(segment.durationSeconds, 0.001)
                var sum = sums[segment.speakerId]
                    ?? [Float](repeating: 0, count: segment.embedding.count)
                guard sum.count == segment.embedding.count else { continue }
                for index in sum.indices {
                    sum[index] += segment.embedding[index] * weight
                }
                sums[segment.speakerId] = sum
                weights[segment.speakerId, default: 0] += weight
            }
            for (speaker, sum) in sums {
                guard let weight = weights[speaker], weight > 0 else { continue }
                embeddings[speaker] = VoiceMatcher.normalize(sum.map { $0 / weight })
            }
        }

        return SpeakerDiarizationSnapshot(turns: turns, embeddings: embeddings)
    }

    private func preparedManager() async throws -> Manager {
        if let manager { return manager }
        var config = OfflineDiarizerConfig()
        config.clustering.maxSpeakers = maxSpeakers
        config.postProcessing.exclusiveSegments = true
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        let boxed = Manager(value: manager)
        self.manager = boxed
        return boxed
    }
}
