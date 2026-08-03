import Testing
@testable import quill

@Suite("Speaker attribution")
struct SpeakerAttributionTests {
    @Test func wordsSplitAtSpeakerBoundary() {
        let transcript = [
            TranscriptSegment(
                start: 0,
                end: 4,
                text: "hello there yes",
                words: [
                    TranscriptWord(start: 0.2, end: 0.8, text: "hello"),
                    TranscriptWord(start: 0.9, end: 1.5, text: "there"),
                    TranscriptWord(start: 2.2, end: 2.8, text: "yes"),
                ]
            )
        ]
        let turns = [
            SpeakerTurn(clusterID: "S7", start: 0, end: 2),
            SpeakerTurn(clusterID: "S2", start: 2, end: 4),
        ]

        let result = SpeakerAttribution.attribute(transcript, turns: turns)

        #expect(result.segments.count == 2)
        #expect(result.segments[0].speaker == "participant_1")
        #expect(result.segments[0].text == "hello there")
        #expect(result.segments[1].speaker == "participant_2")
        #expect(result.segments[1].text == "yes")
    }

    @Test func participantNumbersFollowFirstAppearance() {
        let turns = [
            SpeakerTurn(clusterID: "S9", start: 10, end: 12),
            SpeakerTurn(clusterID: "S1", start: 1, end: 3),
        ]
        #expect(SpeakerAttribution.participantIDs(for: turns)
            == ["S1": "participant_1", "S9": "participant_2"])
    }

    @Test func segmentWithoutWordsUsesMaximumOverlap() {
        let transcript = [TranscriptSegment(start: 1, end: 5, text: "whole segment")]
        let turns = [
            SpeakerTurn(clusterID: "A", start: 0, end: 2),
            SpeakerTurn(clusterID: "B", start: 2, end: 6),
        ]
        let result = SpeakerAttribution.attribute(transcript, turns: turns)
        #expect(result.segments.map(\.speaker) == ["participant_2"])
    }

    @Test func acceptedVoiceMatchReplacesAnonymousLabel() {
        let transcript = [TranscriptSegment(start: 0, end: 1, text: "hello")]
        let turns = [SpeakerTurn(clusterID: "A", start: 0, end: 1)]
        let match = VoiceMatch(
            profileID: "maria",
            name: "Maria",
            distance: 0.2,
            margin: 0.3
        )
        let result = SpeakerAttribution.attribute(
            transcript,
            turns: turns,
            matches: ["A": match]
        )
        #expect(result.segments.first?.speaker == "Maria")
        #expect(result.segments.first?.speakerID == "participant_1")
        #expect(result.speakers.first?.match == match)
    }

    @Test func emptyDiarizationPreservesLegacyThem() {
        let transcript = [TranscriptSegment(start: 0, end: 1, text: "hello")]
        let result = SpeakerAttribution.attribute(transcript, turns: [])
        #expect(result.segments.first?.speaker == "them")
        #expect(result.segments.first?.speakerID == nil)
    }
}
