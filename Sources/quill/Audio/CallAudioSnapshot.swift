import AppKit
import CoreAudio
import Darwin
import Foundation

enum CallApplication: String, CaseIterable, Sendable {
    // Ordering is the tie-breaker when both applications start together.
    case telemost
    case zoom

    var title: String { self == .telemost ? L10n.text("Telemost") : "Zoom" }
    var bundleID: String {
        self == .telemost ? "ru.yandex.desktop.telemost" : "us.zoom.xos"
    }
}

enum AudioCaptureMode: String, Sendable {
    case system
    case callApp = "call_app"

    static func parse(_ value: Any?) throws -> Self {
        guard let value else { return .system }
        guard let raw = value as? String, let mode = Self(rawValue: raw) else {
            throw CallAudioError.invalidCaptureMode
        }
        return mode
    }
}

enum CallAudioError: Error, CustomStringConvertible {
    case property(OSStatus)
    case unavailable(CallApplication)
    case invalidCaptureMode
    case unresponsive

    var description: String {
        switch self {
        case .property(let status): return "Core Audio process query failed (OSStatus \(status))"
        case .unavailable(let app): return "No verified audio processes for \(app.title)"
        case .unresponsive: return "Core Audio has not responded for 5 seconds; recording is unavailable until it recovers"
        case .invalidCaptureMode: return "audio_capture must be system or call_app; config must be valid JSON"
        }
    }
}

struct CallAudioProcess: Equatable, Sendable {
    let id: AudioObjectID
    let executablePath: String
    let inputActive: Bool
    let outputActive: Bool

    /// Includes helpers only inside the verified app bundle. In particular,
    /// another Qt app's QtWebEngineProcess must never match Telemost.
    func belongs(to applicationURL: URL) -> Bool {
        let root = applicationURL.resolvingSymlinksInPath().path + "/Contents/"
        let executable = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        return executable.hasPrefix(root)
    }
}

struct CallAudioSnapshot: Sendable {
    let processes: [CallApplication: [CallAudioProcess]]

    func processIDs(for app: CallApplication) -> [AudioObjectID] {
        (processes[app] ?? []).map(\.id).sorted()
    }

    var activeApplications: Set<CallApplication> {
        Set(CallApplication.allCases.filter { app in
            (processes[app] ?? []).contains { $0.inputActive || $0.outputActive }
        })
    }

    var availableApplications: Set<CallApplication> {
        Set(CallApplication.allCases.filter { !(processes[$0] ?? []).isEmpty })
    }

    static func matching(
        _ processes: [CallAudioProcess], applications: [CallApplication: URL]
    ) -> Self {
        Self(processes: applications.mapValues { url in processes.filter { $0.belongs(to: url) } })
    }

    @MainActor
    static func installedApplications() -> [CallApplication: URL] {
        Dictionary(uniqueKeysWithValues: CallApplication.allCases.compactMap { app in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID).map { (app, $0) }
        })
    }

    @MainActor
    static func read() async throws -> Self {
        let apps = installedApplications()
        return try await Task.detached { try read(applications: apps) }.value
    }

    static func read(applications apps: [CallApplication: URL]) throws -> Self {
        var processes: [CallAudioProcess] = []
        for object in try processObjectIDs() {
            do {
                let pid = try uint32Property(kAudioProcessPropertyPID, on: object)
                var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                let length = path.withUnsafeMutableBytes {
                    proc_pidpath(Int32(bitPattern: pid), $0.baseAddress, UInt32($0.count))
                }
                // Unrelated protected/exited processes are not capture candidates.
                guard length > 0 else { continue }
                let executable = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                let candidate = CallAudioProcess(
                    id: object, executablePath: executable, inputActive: false, outputActive: false
                )
                guard apps.values.contains(where: { candidate.belongs(to: $0) }) else { continue }
                processes.append(CallAudioProcess(
                    id: object,
                    executablePath: executable,
                    inputActive: try uint32Property(kAudioProcessPropertyIsRunningInput, on: object) != 0,
                    outputActive: try uint32Property(kAudioProcessPropertyIsRunningOutput, on: object) != 0
                ))
            } catch CallAudioError.property(kAudioHardwareBadObjectError) {
                // A process can disappear between enumeration and inspection.
                continue
            }
        }
        return matching(processes, applications: apps)
    }

    private static func processObjectIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard status == noErr else { throw CallAudioError.property(status) }
        guard size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = objects.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!
            )
        }
        guard status == noErr else { throw CallAudioError.property(status) }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func uint32Property(
        _ selector: AudioObjectPropertySelector, on object: AudioObjectID
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw CallAudioError.property(status) }
        return value
    }
}
