import Foundation

struct AudioSignalReport: Codable, Sendable {
    let sample_count: Int
    let rms_db: Double
    let peak_db: Double
    let max_window_rms_db: Double
    let write_errors: Int
}

/// PCM diagnostics only; no audio samples are retained by this accumulator.
struct AudioSignalAccumulator {
    private var count = 0
    private var sumSquares = 0.0
    private var peak = 0.0
    private var windowCount = 0
    private var windowSquares = 0.0
    private var maxWindowMeanSquare = 0.0
    var writeErrors = 0

    mutating func observe(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        let windowSize = max(1, Int(sampleRate / 10))
        for sample in samples {
            let value = Double(sample)
            let square = value * value
            count += 1
            sumSquares += square
            peak = max(peak, abs(value))
            windowCount += 1
            windowSquares += square
            if windowCount == windowSize {
                maxWindowMeanSquare = max(maxWindowMeanSquare, windowSquares / Double(windowCount))
                windowCount = 0
                windowSquares = 0
            }
        }
    }

    var report: AudioSignalReport {
        let partial = windowCount > 0 ? windowSquares / Double(windowCount) : 0
        return AudioSignalReport(
            sample_count: count,
            rms_db: Self.db(count > 0 ? sqrt(sumSquares / Double(count)) : 0),
            peak_db: Self.db(peak),
            max_window_rms_db: Self.db(sqrt(max(maxWindowMeanSquare, partial))),
            write_errors: writeErrors
        )
    }

    private static func db(_ amplitude: Double) -> Double { 20 * log10(max(amplitude, 0.00000001)) }
}
