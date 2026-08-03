import Foundation

struct AttributedTranscriptSegment: Sendable, Equatable {
    let speaker: String
    let speakerID: String?
    let clusterID: String?
    let match: VoiceMatch?
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct AttributedSpeaker: Sendable, Equatable {
    let clusterID: String
    let speakerID: String
    let label: String
    let match: VoiceMatch?
}

struct SpeakerAttributionResult: Sendable, Equatable {
    let segments: [AttributedTranscriptSegment]
    let speakers: [AttributedSpeaker]
}

enum SpeakerAttribution {
    /// Stable user-facing participant IDs are assigned by first appearance,
    /// not by a model's arbitrary cluster number.
    static func participantIDs(for turns: [SpeakerTurn]) -> [String: String] {
        var result: [String: String] = [:]
        for turn in turns.sorted(by: { lhs, rhs in
            lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
        }) where result[turn.clusterID] == nil {
            result[turn.clusterID] = "participant_\(result.count + 1)"
        }
        return result
    }

    static func attribute(
        _ transcript: [TranscriptSegment],
        turns: [SpeakerTurn],
        matches: [String: VoiceMatch] = [:]
    ) -> SpeakerAttributionResult {
        guard !turns.isEmpty else {
            return SpeakerAttributionResult(
                segments: transcript.map {
                    AttributedTranscriptSegment(
                        speaker: "them",
                        speakerID: nil,
                        clusterID: nil,
                        match: nil,
                        start: $0.start,
                        end: $0.end,
                        text: $0.text
                    )
                },
                speakers: []
            )
        }

        let ids = participantIDs(for: turns)
        let speakers = ids.map { cluster, speakerID in
            let match = matches[cluster]
            return AttributedSpeaker(
                clusterID: cluster,
                speakerID: speakerID,
                label: match?.name ?? speakerID,
                match: match
            )
        }.sorted { participantNumber($0.speakerID) < participantNumber($1.speakerID) }
        let byCluster = Dictionary(uniqueKeysWithValues: speakers.map { ($0.clusterID, $0) })

        var output: [AttributedTranscriptSegment] = []
        for segment in transcript {
            let fallback = bestCluster(from: segment.start, to: segment.end, turns: turns)
            guard !segment.words.isEmpty else {
                output.append(makeSegment(
                    clusterID: fallback,
                    start: segment.start,
                    end: segment.end,
                    text: segment.text,
                    speakers: byCluster
                ))
                continue
            }

            var group: [(word: TranscriptWord, cluster: String?)] = []

            func flush() {
                guard let first = group.first, let last = group.last else { return }
                let words = group.map(\.word.text)
                output.append(makeSegment(
                    clusterID: first.cluster,
                    start: first.word.start,
                    end: last.word.end,
                    text: join(words: words),
                    speakers: byCluster
                ))
                group.removeAll(keepingCapacity: true)
            }

            for word in segment.words {
                let cluster = bestCluster(from: word.start, to: word.end, turns: turns)
                    ?? nearestCluster(to: (word.start + word.end) / 2, turns: turns)
                    ?? fallback
                if let current = group.first?.cluster, current != cluster {
                    flush()
                } else if !group.isEmpty, group.first?.cluster == nil, cluster != nil {
                    flush()
                }
                group.append((word, cluster))
            }
            flush()
        }

        return SpeakerAttributionResult(segments: output, speakers: speakers)
    }

    private static func makeSegment(
        clusterID: String?,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        speakers: [String: AttributedSpeaker]
    ) -> AttributedTranscriptSegment {
        guard let clusterID, let speaker = speakers[clusterID] else {
            return AttributedTranscriptSegment(
                speaker: "them",
                speakerID: nil,
                clusterID: clusterID,
                match: nil,
                start: start,
                end: end,
                text: text
            )
        }
        return AttributedTranscriptSegment(
            speaker: speaker.label,
            speakerID: speaker.speakerID,
            clusterID: clusterID,
            match: speaker.match,
            start: start,
            end: end,
            text: text
        )
    }

    private static func bestCluster(
        from start: TimeInterval,
        to end: TimeInterval,
        turns: [SpeakerTurn]
    ) -> String? {
        guard end > start else { return nearestCluster(to: start, turns: turns) }
        var overlapByCluster: [String: TimeInterval] = [:]
        for turn in turns {
            let overlap = max(0, min(end, turn.end) - max(start, turn.start))
            if overlap > 0 { overlapByCluster[turn.clusterID, default: 0] += overlap }
        }
        return overlapByCluster.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
    }

    /// ASR and diarization boundaries can differ by a few hundred ms. Bridge
    /// only a small gap; a large unaligned span should stay honest `them`.
    private static func nearestCluster(
        to time: TimeInterval,
        turns: [SpeakerTurn],
        tolerance: TimeInterval = 0.75
    ) -> String? {
        let nearest = turns.map { turn -> (String, TimeInterval) in
            let distance: TimeInterval
            if time < turn.start { distance = turn.start - time }
            else if time > turn.end { distance = time - turn.end }
            else { distance = 0 }
            return (turn.clusterID, distance)
        }.min { $0.1 < $1.1 }
        guard let nearest, nearest.1 <= tolerance else { return nil }
        return nearest.0
    }

    private static func join(words: [String]) -> String {
        var result = ""
        let noLeadingSpace = CharacterSet(charactersIn: ".,!?;:)]}»…")
        for raw in words {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            if result.isEmpty || word.unicodeScalars.first.map(noLeadingSpace.contains) == true {
                result += word
            } else {
                result += " " + word
            }
        }
        return result
    }

    private static func participantNumber(_ id: String) -> Int {
        Int(id.split(separator: "_").last ?? "0") ?? 0
    }
}
