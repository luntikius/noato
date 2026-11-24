import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

enum SystemAudioSource: String, CaseIterable, Codable, Sendable {
    case callApp = "call_app"
    case telemost
    case zoom
    case system

    var title: String {
        switch self {
        case .callApp: return L10n.text("Current call application")
        case .telemost: return L10n.text("Telemost")
        case .zoom: return "Zoom"
        case .system: return L10n.text("All Mac audio")
        }
    }

    var captureMode: AudioCaptureMode { self == .system ? .system : .callApp }
    var applications: Set<CallApplication> {
        switch self {
        case .telemost: return [.telemost]
        case .zoom: return [.zoom]
        case .callApp, .system: return Set(CallApplication.allCases)
        }
    }
}

struct AudioSources: Equatable, Sendable {
    var microphoneUID: String?
    var systemAudio: SystemAudioSource

    init(microphoneUID: String? = nil, systemAudio: SystemAudioSource = .callApp) {
        self.microphoneUID = microphoneUID
        self.systemAudio = systemAudio
    }

    static func parse(_ json: [String: Any]) throws -> Self {
        let raw = json["system_audio_source"] ?? json["audio_capture"] ?? "system"
        guard let raw = raw as? String, let source = SystemAudioSource(rawValue: raw) else {
            throw SourceError.invalidSettings
        }
        var uid: String?
        if let value = json["microphone_uid"] {
            guard let string = value as? String, !string.isEmpty else { throw SourceError.invalidSettings }
            uid = string
        }
        return Self(microphoneUID: uid, systemAudio: source)
    }
}

enum SourceError: Error, CustomStringConvertible {
    case invalidSettings
    case unavailableMicrophone
    case audioProperty(OSStatus)
    case noInputUnit

    var description: String {
        switch self {
        case .invalidSettings: return L10n.text("Invalid audio source settings")
        case .unavailableMicrophone: return L10n.text("The selected microphone is unavailable. Connect it or choose another microphone.")
        case .audioProperty(let status): return L10n.format("Could not select audio device (OSStatus %d)", status)
        case .noInputUnit: return L10n.text("The audio engine did not provide a microphone input")
        }
    }
}

struct MicrophoneDevice: Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static func available() throws -> [Self] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size))
        guard size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        try check(status)
        var devices: [Self] = []
        for id in ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size) {
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bytes: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes)
            if status == kAudioHardwareBadObjectError { continue }
            try check(status)
            guard bytes > 0 else { continue }
            do {
                devices.append(Self(
                    id: id, uid: try string(kAudioDevicePropertyDeviceUID, on: id),
                    name: try string(kAudioObjectPropertyName, on: id)
                ))
            } catch SourceError.audioProperty(kAudioHardwareBadObjectError) { continue }
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func resolve(uid: String?) throws -> Self {
        let devices = try available()
        if let uid {
            guard let device = devices.first(where: { $0.uid == uid }) else {
                throw SourceError.unavailableMicrophone
            }
            return device
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id))
        guard let device = devices.first(where: { $0.id == id }) else { throw SourceError.unavailableMicrophone }
        return device
    }

    func select(on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { throw SourceError.noInputUnit }
        var device = id
        try Self.check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)
        ))
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw SourceError.audioProperty(status) }
    }

    private static func string(_ selector: AudioObjectPropertySelector, on id: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value))
        guard let value else { throw SourceError.unavailableMicrophone }
        return value.takeRetainedValue() as String
    }
}
