import AVFoundation
import CoreAudio
import Foundation

/// Input-only IO on the exact selected Core Audio device. No AVAudioEngine,
/// default input, output unit or Bluetooth output route is opened implicitly.
final class MicRecorder: @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case noInputStream
        case formatUnsupported
        case audio(OSStatus)

        var description: String {
            switch self {
            case .noInputStream: return L10n.text("The selected microphone has no available input stream")
            case .formatUnsupported: return L10n.text("Unsupported microphone format")
            case .audio(let status): return L10n.format("Microphone capture failed (OSStatus %d)", status)
            }
        }
    }

    private let queue = DispatchQueue(label: "com.digimata.quill.microphone")
    private var deviceID = AudioDeviceID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var signal = AudioSignalAccumulator()
    private(set) var isRecording = false
    private(set) var firstBufferAt: Date?
    private(set) var deviceName: String?
    private(set) var deviceUID: String?

    var signalReport: AudioSignalReport { queue.sync { signal.report } }

    func start(writingTo url: URL, microphoneUID: String? = nil) throws {
        guard !isRecording else { return }
        let device = try MicrophoneDevice.resolve(uid: microphoneUID)
        deviceID = device.id
        deviceName = device.name
        deviceUID = device.uid
        signal = AudioSignalAccumulator()
        firstBufferAt = nil
        let format = try Self.inputFormat(on: device.id)
        guard let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
            channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: format, to: mono) else {
            throw RecorderError.formatUnsupported
        }
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: mono.sampleRate,
            AVNumberOfChannelsKey: 1,
        ], commonFormat: mono.commonFormat, interleaved: false)

        do {
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, queue) {
                [weak self] _, inputData, _, _, _ in
                guard let self, let file = self.file else { return }
                guard let raw = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData),
                      raw.frameLength > 0,
                      let output = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: raw.frameLength) else { return }
                do {
                    try converter.convert(to: output, from: raw)
                    guard output.frameLength > 0 else { return }
                    try file.write(from: output)
                    if self.firstBufferAt == nil { self.firstBufferAt = Date() }
                    if let samples = output.floatChannelData?[0] {
                        self.signal.observe(
                            UnsafeBufferPointer(start: samples, count: Int(output.frameLength)),
                            sampleRate: mono.sampleRate
                        )
                    }
                } catch {
                    self.signal.writeErrors += 1
                    if self.signal.writeErrors == 1 {
                        FileHandle.standardError.write(Data("mic write failed: \(error)\n".utf8))
                    }
                }
            })
            guard let procID else { throw RecorderError.noInputStream }
            try Self.check(AudioDeviceStart(device.id, procID))
            isRecording = true
        } catch {
            if let procID { AudioDeviceDestroyIOProcID(device.id, procID) }
            procID = nil
            file = nil
            throw error
        }
        FileHandle.standardError.write(Data(
            "mic: direct input device=\(device.name) uid=\(device.uid) format=\(format)\n".utf8
        ))
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        queue.sync { file = nil }
        let report = signalReport
        FileHandle.standardError.write(Data(
            "mic signal: samples=\(report.sample_count) peak=\(report.peak_db)dB max100ms=\(report.max_window_rms_db)dB errors=\(report.write_errors)\n".utf8
        ))
    }

    private static func inputFormat(on device: AudioDeviceID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var bytes: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &bytes))
        guard bytes > 0 else { throw RecorderError.noInputStream }
        var streams = [AudioStreamID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioStreamID>.size)
        try check(streams.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, $0.baseAddress!)
        })
        guard let stream = streams.first else { throw RecorderError.noInputStream }
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        bytes = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &bytes, &asbd))
        guard asbd.mChannelsPerFrame > 0, asbd.mSampleRate > 0,
              let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecorderError.formatUnsupported
        }
        return format
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw RecorderError.audio(status) }
    }
}
