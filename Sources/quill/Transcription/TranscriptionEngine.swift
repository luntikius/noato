import Foundation

/// One recognized word with a track-relative time range. Diarization happens
/// independently from ASR, so word timings are the join key between "what was
/// said" and "who spoke when".
struct TranscriptWord: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// One timed span of recognized speech from a single track, relative to that
/// track's own start.
struct TranscriptSegment: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let words: [TranscriptWord]

    init(
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        words: [TranscriptWord] = []
    ) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

/// A speech-to-text engine quill can run locally. Engines are prepared lazily
/// (model download + load) when the transcription queue has work and released
/// when it drains, so quill never idles holding gigabytes of model weights.
protocol TranscriptionEngine: Sendable {
    /// Short engine identifier recorded as transcript.json provenance.
    var name: String { get }
    /// Concrete model identifier recorded as transcript.json provenance.
    var model: String { get }
    func prepare() async throws
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment]
    func release() async
}
