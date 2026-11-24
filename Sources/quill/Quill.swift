import AppKit
import ArgumentParser
import Foundation

/// AppKit must own the original main-thread stack, outside a suspended Swift
/// MainActor task or main-dispatch block. Otherwise ordinary macOS notification
/// and Foundation callbacks can starve inside NSApplication.run().
@main
enum QuillMain {
    static func main() {
        do {
            if let run = try Quill.parseAsRoot() as? Run {
                try MainActor.assumeIsolated { try run.runMain() }
            } else {
                // Async CLI commands retain ArgumentParser's normal dispatch.
                Task {
                    await Quill.main(nil)
                    Quill.exit()
                }
                dispatchMain()
            }
        } catch {
            if case ApplicationInstance.InstanceError.running = error {
                DistributedNotificationCenter.default().postNotificationName(openMenuNotification, object: nil, userInfo: nil, deliverImmediately: true)
                return
            }
            if Bundle.main.bundleURL.pathExtension == "app", CommandLine.arguments.count == 1 || CommandLine.arguments.dropFirst().first == "run" {
                MainActor.assumeIsolated {
                    _ = NSApplication.shared
                    let alert = NSAlert(); alert.messageText = L10n.text("noato could not start")
                    alert.informativeText = String(describing: error)
                    NSApp.activate(ignoringOtherApps: true); alert.runModal()
                }
            }
            Quill.exit(withError: error)
        }
    }
}

struct Quill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "noato",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        version: "0.1.0-beta.1",
        subcommands: [Run.self, Doctor.self, Reprocess.self, Install.self, OpenSettings.self, Voices.self, AudioStatus.self, PrepareModels.self, CheckCapture.self, OpenMenu.self, OpenProgress.self, StopDaemon.self, ListMicrophones.self],
        defaultSubcommand: Run.self
    )
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    mutating func run() async throws {
        // The async root command may invoke subcommands from a cooperative
        // executor. Hop explicitly to the main actor before touching AppKit;
        // `assumeIsolated` traps when a LaunchAgent starts us off-main.
        try await runMain()
    }

    @MainActor
    fileprivate func runMain() throws {
        let instance = try ApplicationInstance()
        let root = Config.resolveRoot(cliOverride: out)
        _ = try Config.audioSources()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Denied permissions must not prevent opening Settings to repair them.
        DoctorReport.print(DoctorReport.run(recordingsRoot: root))

        if !FileManager.default.fileExists(atPath: Config.path.path),
           ProcessInfo.processInfo.environment["NOATO_DATA_DIR"] == nil,
           FileManager.default.fileExists(atPath: Config.legacyPath.path) {
            let alert = NSAlert()
            alert.messageText = L10n.text("Import your Quill setup?")
            alert.informativeText = L10n.text("Keep your transcript folder, audio sources and pending recordings. Existing models will be reused. Quill must be closed before using noato.")
            alert.addButton(withTitle: L10n.text("Import Quill")); alert.addButton(withTitle: L10n.text("Start Fresh"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: Config.legacyPath))
                guard let values = object as? [String: Any] else { throw SettingsError.invalid }
                let imported = try AppSettings.importing(values)
                _ = try SettingsStore.shared.update { $0 = imported }
            }
        }
        let controller = AppController(root: root, sources: try Config.audioSources())

        let signals = [SIGINT, SIGTERM].map { number in
            BackgroundWork.signalSource(number) {
                FileHandle.standardError.write(Data("\nshutting down\n".utf8))
                controller.shutdown()
            }
        }

        FileHandle.standardError.write(Data(
            "noato up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        withExtendedLifetime((controller, signals, instance)) { app.run() }
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        _ = try Config.audioSources()
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

private let openMenuNotification = Notification.Name("io.github.luntikius.noato.open-menu")

struct OpenMenu: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "menu", abstract: "Open the running noato menu at the pointer, even if its icon is hidden."
    )
    func run() {
        DistributedNotificationCenter.default().postNotificationName(
            openMenuNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
    }
}

private let openSettingsNotification = Notification.Name("io.github.luntikius.noato.open-settings")
struct OpenSettings: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "settings", abstract: "Open Settings in the running noato app.")
    func run() {
        DistributedNotificationCenter.default().postNotificationName(openSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

private let openProgressNotification = Notification.Name("io.github.luntikius.noato.open-progress")

struct OpenProgress: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "progress", abstract: "Open the transcription submenu in the running noato.")
    func run() {
        DistributedNotificationCenter.default().postNotificationName(
            openProgressNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
    }
}

struct StopDaemon: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop noato, keeping launch-at-login configured.")
    func run() throws {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("io.github.luntikius.noato.stop"), object: nil, userInfo: nil, deliverImmediately: true)
        print("Stop requested; current recording will be saved and pending work will be recoverable.")
    }
}

struct ListMicrophones: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "microphones", abstract: "List input devices and the saved microphone selection.")
    func run() throws {
        let sources = try Config.audioSources()
        print("Selected: \(sources.microphoneUID ?? "system default")")
        for device in try MicrophoneDevice.available() {
            print("\(device.name) · \(device.uid)")
        }
    }
}

struct AudioStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List verified call audio processes without recording.")

    @MainActor
    mutating func run() async throws {
        let snapshot = try await CallAudioSnapshot.read()
        for app in CallApplication.allCases {
            print("\(app.rawValue): active=\(snapshot.activeApplications.contains(app))")
            for process in snapshot.processes[app] ?? [] {
                print("  id=\(process.id) input=\(process.inputActive) output=\(process.outputActive) \(process.executablePath)")
            }
        }
    }
}

struct CheckCapture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check app-scoped tap creation/updates without recording audio.")
    @Argument(help: "telemost or zoom") var application: String

    @MainActor
    mutating func run() async throws {
        guard let app = CallApplication(rawValue: application) else {
            throw ValidationError("application must be telemost or zoom")
        }
        let snapshot = try await CallAudioSnapshot.read()
        let ids = snapshot.processIDs(for: app)
        guard !ids.isEmpty else { throw CallAudioError.unavailable(app) }
        try SystemAudioRecorder.checkProcessTap(processIDs: ids)
        print("✓ \(app.title): inclusive tap created, emptied, restored and destroyed; no audio recorded")
    }
}

struct PrepareModels: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Download and prepare Whisper and configured diarization models without recording.")

    mutating func run() async throws {
        guard Config.transcriptionEngine() == "whisper" else {
            throw ValidationError("prepare-models requires transcription.engine=whisper")
        }
        let engine = WhisperEngine()
        try await engine.prepare()
        await engine.release()
        if Config.diarizationEnabled() { try await SpeakerDiarizer().prepare() }
        print("✓ models prepared")
    }
}

struct Reprocess: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Regenerate a finished session transcript with the current config."
    )

    @Argument(help: "Session directory containing meta.json and recorded audio.")
    var session: String

    mutating func run() async throws {
        let dir = URL(
            fileURLWithPath: (session as NSString).expandingTildeInPath,
            isDirectory: true
        )
        guard FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("meta.json").path
        ) else {
            throw ValidationError("meta.json not found in \(dir.path)")
        }
        guard Config.transcriptionEnabled() else {
            throw ValidationError("transcription is disabled in \(Config.path.path)")
        }
        if let output = try await TranscriptionCoordinator().processNow(dir) {
            print("✓ transcript saved: \(output.path)")
        } else { print(L10n.text("Recording too short — no transcript will be created")) }
    }
}

/// Sole owner of recording lifecycle; the monitor supplies observations only.
@MainActor
final class AppController {
    private let root: URL
    private var sources: AudioSources
    private var refreshingSources = false
    private let menuBar = MenuBarController()
    private var recordingRevision = 0
    private var cleanupBusy = false
    private var progressObserver: NSObjectProtocol?
    private let transcription = TranscriptionCoordinator()
    private let monitor = CallMonitor()
    private var policy: CallRecordingPolicy
    private var session: RecordingSession?
    private var automatic = false
    private var manualStartTask: Task<Void, Never>?
    private var audioStatusFailed = false
    private var audioMonitoringReady = false
    private var shuttingDown = false
    private var menuObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var stopObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var retentionTimer: Timer?
    private var detectionSettings = Config.current
    private let settingsWindow = SettingsWindowController()
    private let welcomeWindow = WelcomeWindowController()
    private var preparingModels = false

    init(root: URL, sources: AudioSources) {
        self.root = root
        self.sources = sources
        var enabled: Set<CallApplication> = []
        if Config.telemostAutoRecordEnabled() { enabled.insert(.telemost) }
        if Config.zoomAutoRecordEnabled() { enabled.insert(.zoom) }
        policy = CallRecordingPolicy(
            enabled: enabled, startDelay: Config.zoomAutoRecordStartDelay(),
            stopDelay: Config.zoomAutoRecordStopDelay(), paused: Config.autoRecordPaused()
        )
        menuBar.onSettings = { [weak self] in self?.settingsWindow.present() }
        settingsWindow.onChange = { [weak self] in self?.applySettings($0) }
        settingsWindow.onRetentionChange = { [weak self] age, completion in self?.confirmRetention(age, completion: completion) }
        settingsWindow.onPrepareModels = { [weak self] in self?.prepareModels(status: $0) }
        welcomeWindow.onSettings = { [weak self] in self?.settingsWindow.present() }
        welcomeWindow.onPrepare = { [weak self] in self?.prepareModels(status: $0) }
        welcomeWindow.onComplete = { [weak self] in self?.applySettings(Config.current) }
        menuBar.configure(sources: sources)
        menuBar.onRefreshSources = { [weak self] in self?.refreshSources() }
        menuBar.onMicrophone = { [weak self] uid in
            guard let self else { return }
            var sources = self.sources
            sources.microphoneUID = uid
            self.changeSources(sources)
        }
        menuBar.onSystemAudio = { [weak self] source in
            guard let self else { return }
            var sources = self.sources
            sources.systemAudio = source
            self.changeSources(sources)
        }
        menuBar.onStartApplication = { [weak self] app in self?.startManual(app) }
        menuBar.onToggle = { [weak self] in
            guard let self else { return }
            if self.session == nil {
                self.startManual(nil)
            } else {
                self.policy.suppressActive()
                if let app = self.session?.application { self.policy.suppress(app) }
                self.stopSession()
            }
        }
        menuBar.onToggleAutomaticPause = { [weak self] in self?.toggleAutomaticPause() }
        menuBar.transcriptions.onDeleteCompleted = { [weak self] in self?.deleteCompleted($0) }
        menuBar.onCleanup = { [weak self] age in self?.previewCleanup(age) }
        menuBar.transcriptions.onRetry = { [transcription] id in
            BackgroundWork.start { await transcription.retry(id) }
        }
        menuBar.transcriptions.onDelete = { [weak self] id in self?.deleteFailed(id) }
        menuBar.transcriptions.onRefresh = { [transcription] in
            BackgroundWork.start { await transcription.refreshCompleted() }
        }
        menuBar.transcriptions.onOpenTranscript = { file in
            if ArtifactFiles.isRegular(file) { NSWorkspace.shared.open(file) }
        }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        monitor.onSnapshot = { [weak self] snapshot in self?.observe(snapshot) }
        monitor.onError = { [weak self] error in
            guard let self else { return }
            self.policy.suppressActive()
            self.audioStatusFailed = true
            self.menuBar.updateAvailable([])
            // Fail closed for a scoped capture whose process list cannot be verified.
            if self.session?.captureMode == .callApp { self.stopSession() }
            self.report(error)
        }
        refreshMenu()
        menuObserver = DistributedNotificationCenter.default().addObserver(
            forName: openMenuNotification, object: nil, queue: nil
        ) { @Sendable [weak self] _ in
            BackgroundWork.deliverToMainRunLoop { self?.menuBar.showAtPointer() }
        }
        progressObserver = DistributedNotificationCenter.default().addObserver(
            forName: openProgressNotification, object: nil, queue: nil
        ) { @Sendable [weak self] _ in
            BackgroundWork.deliverToMainRunLoop { self?.menuBar.transcriptions.showAtPointer() }
        }
        settingsObserver = DistributedNotificationCenter.default().addObserver(forName: openSettingsNotification, object: nil, queue: nil) { @Sendable [weak self] _ in
            BackgroundWork.deliverToMainRunLoop { self?.settingsWindow.present() }
        }
        stopObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("io.github.luntikius.noato.stop"), object: nil, queue: nil) { @Sendable [weak self] _ in
            BackgroundWork.deliverToMainRunLoop { self?.shutdown() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { @Sendable [weak self] _ in
            BackgroundWork.deliverToMainRunLoop { self?.runRetention() }
        }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.runRetention() } }
        timer.tolerance = 60; RunLoop.main.add(timer, forMode: .common); retentionTimer = timer
        monitor.start()
        refreshSources()

        BackgroundWork.start { [transcription, root] in
            await transcription.setIdleHandler { [weak self] in BackgroundWork.deliverToMainRunLoop { self?.runRetention() } }
            await transcription.setStatusHandler { status in
                BackgroundWork.deliverToMainRunLoop { [weak self] in
                    self?.showTranscription(status)
                }
            }
            for legacy in Config.current.legacyRecordingDirectories { await transcription.resumePending(root: URL(fileURLWithPath: legacy)) }
            await transcription.resumePending(root: root)
            BackgroundWork.deliverToMainRunLoop { [weak self] in
                self?.runRetention()
                if !Config.current.setupCompleted { self?.welcomeWindow.present() }
            }
        }
    }

    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        if let menuObserver { DistributedNotificationCenter.default().removeObserver(menuObserver) }
        if let progressObserver { DistributedNotificationCenter.default().removeObserver(progressObserver) }
        retentionTimer?.invalidate()
        if let settingsObserver { DistributedNotificationCenter.default().removeObserver(settingsObserver) }
        if let stopObserver { DistributedNotificationCenter.default().removeObserver(stopObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        monitor.stop()
        manualStartTask?.cancel()
        if let admission = stopSession() {
            // Finish the short-recording decision and cleanup before exiting.
            BackgroundWork.start {
                await admission.value
                BackgroundWork.deliverToMainRunLoop { NSApp.terminate(nil) }
            }
        } else { NSApp.terminate(nil) }
    }

    private func startManual(_ app: CallApplication?) {
        guard session == nil, manualStartTask == nil else { return }
        let applications = CallAudioSnapshot.installedApplications()
        manualStartTask = BackgroundWork.start { [weak self] in
            let result = Result { try CallAudioSnapshot.read(applications: applications) }
            guard !Task.isCancelled else { return }
            BackgroundWork.deliverToMainRunLoop {
                guard let self, !self.shuttingDown else { return }
                self.manualStartTask = nil
                do {
                    try self.startSession(
                        application: app, automatic: false, snapshot: result.get()
                    )
                } catch { self.report(error) }
            }
        }
    }

    private func observe(_ snapshot: CallAudioSnapshot) {
        if !audioMonitoringReady || audioStatusFailed {
            FileHandle.standardError.write(Data("audio monitoring ready\n".utf8))
            audioMonitoringReady = true
        }
        if audioStatusFailed {
            menuBar.clearRecordingError()
            audioStatusFailed = false
        }
        menuBar.updateAvailable(snapshot.availableApplications)
        policy.observe(active: snapshot.activeApplications, at: ProcessInfo.processInfo.systemUptime)
        do {
            if let session, let app = session.application {
                session.reportInputSignalIfReady()
                try session.updateProcesses(snapshot.processIDs(for: app))
                if automatic, !policy.isActive(app) { stopSession() }
            }
            if session == nil, !preparingModels, Config.current.setupCompleted, manualStartTask == nil, let app = policy.candidate(allowing: sources.systemAudio.applications) {
                do {
                    try startSession(application: app, automatic: true, snapshot: snapshot)
                } catch {
                    policy.suppress(app)
                    throw error
                }
            }
        } catch {
            if let app = session?.application { policy.suppress(app) }
            stopSession()
            report(error)
        }
        refreshMenu()
    }

    private func startSession(
        application: CallApplication?, automatic: Bool, snapshot: CallAudioSnapshot
    ) throws {
        guard session == nil else { return }
        guard !preparingModels else { throw ValidationError("Wait for model preparation to finish before recording.") }
        guard Config.current.setupCompleted else { welcomeWindow.present(); return }
        let newSession = try RecordingSession(
            root: root, application: application, captureMode: sources.systemAudio.captureMode,
            processIDs: application.map { snapshot.processIDs(for: $0) } ?? [],
            microphoneUID: sources.microphoneUID
        )
        try newSession.start()
        session = newSession
        self.automatic = automatic
        recordingRevision += 1
        let revision = recordingRevision
        let meeting = newSession.meeting
        BackgroundWork.start { [transcription] in await transcription.setRecording(meeting, revision: revision) }
        FileHandle.standardError.write(Data(
            "● recording \(application?.title ?? "system") · \(sources.systemAudio.captureMode.rawValue) · auto=\(automatic) → \(newSession.dir.path)\n".utf8
        ))
        refreshMenu()
    }

    @discardableResult
    private func stopSession() -> Task<Void, Never>? {
        guard let session else { return nil }
        session.stop()
        FileHandle.standardError.write(Data("○ stopped · \(session.dir.path)\n".utf8))
        self.session = nil
        automatic = false
        applyDetectionSettings(Config.current)
        refreshMenu()
        let dir = session.dir
        recordingRevision += 1
        let revision = recordingRevision
        return BackgroundWork.start { [transcription] in
            await transcription.setRecording(nil, revision: revision)
            await transcription.enqueue(dir)
            BackgroundWork.deliverToMainRunLoop { [weak self] in self?.runRetention() }
        }
    }

    private func toggleAutomaticPause() {
        let paused = !policy.isPaused
        do {
            try Config.saveAutoRecordPaused(paused)
            policy.setPaused(paused)
            settingsWindow.presentIfVisible()
            refreshMenu()
        } catch { report(error) }
    }

    private func changeSources(_ sources: AudioSources) {
        do {
            try Config.saveAudioSources(sources)
            applySettings(Config.current)
            settingsWindow.presentIfVisible()
        } catch { report(error) }
    }

    private func applyDetectionSettings(_ value: AppSettings) {
        guard session == nil else { policy.setPaused(value.automaticPaused); return }
        if value.zoom != detectionSettings.zoom || value.telemost != detectionSettings.telemost || value.startDelay != detectionSettings.startDelay || value.stopDelay != detectionSettings.stopDelay {
            var enabled: Set<CallApplication> = []
            if value.zoom { enabled.insert(.zoom) }; if value.telemost { enabled.insert(.telemost) }
            policy.reconfigure(enabled: enabled, startDelay: value.startDelay, stopDelay: value.stopDelay, paused: value.automaticPaused)
        }
        detectionSettings = value
        policy.setPaused(value.automaticPaused)
    }

    private func applySettings(_ value: AppSettings) {
        welcomeWindow.refreshSettings()
        sources = value.sources
        menuBar.configure(sources: sources)
        applyDetectionSettings(value)
        refreshMenu()
        BackgroundWork.start { [weak self, transcription] in
            await transcription.updateSettings(value)
            BackgroundWork.deliverToMainRunLoop { self?.runRetention() }
        }
    }

    private func runRetention() {
        guard !cleanupBusy, let age = Config.current.retention else { return }
        cleanupBusy = true
        let protecting = session?.dir
        BackgroundWork.start { [weak self, transcription, root] in
            let preview = await transcription.previewDeletion(root: root, age: age, now: Date(), protecting: protecting)
            BackgroundWork.deliverToMainRunLoop {
                guard let self else { return }
                let current = self.session?.dir
                BackgroundWork.start { [weak self, transcription] in
                    let result = await transcription.delete(preview, protecting: current)
                    BackgroundWork.deliverToMainRunLoop {
                        self?.cleanupBusy = false
                        if !result.errors.isEmpty { self?.showDeletionError(result.errors.joined(separator: "\n")) }
                    }
                }
            }
        }
    }

    private func confirmRetention(_ age: MeetingAge?, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let age else { completion(true); return }
        let protecting = session?.dir
        BackgroundWork.start { [weak self, transcription, root] in
            let preview = await transcription.previewDeletion(root: root, age: age, now: Date(), protecting: protecting)
            BackgroundWork.deliverToMainRunLoop {
                guard self != nil else { completion(false); return }
                let alert = DeletionAlerts.retention(preview, automatic: true)
                completion(alert.runModal() == .alertFirstButtonReturn)
            }
        }
    }

    private func prepareModels(status: @escaping @MainActor @Sendable (String) -> Void) {
        guard !preparingModels, session == nil else { status(L10n.text("Error: Finish the current recording or model setup first.")); return }
        preparingModels = true
        let settings = Config.current
        BackgroundWork.start { [weak self, transcription] in
            if await transcription.isBusy() {
                BackgroundWork.deliverToMainRunLoop { self?.preparingModels = false; status(L10n.text("Error: Wait for queued transcription to finish before preparing models.")) }; return
            }
            do {
                try await MeetingSettings.$current.withValue(settings) {
                    BackgroundWork.deliverToMainRunLoop { status(L10n.text("Downloading or preparing Whisper…")) }
                    let engine = WhisperEngine(); try await engine.prepare(); await engine.release()
                    if settings.diarization {
                        BackgroundWork.deliverToMainRunLoop { status(L10n.text("Downloading or preparing speaker separation…")) }
                        try await SpeakerDiarizer().prepare()
                    }
                }
                BackgroundWork.deliverToMainRunLoop { self?.preparingModels = false; status("done") }
            } catch {
                let message = "Error: " + String(describing: error)
                BackgroundWork.deliverToMainRunLoop { self?.preparingModels = false; status(message) }
            }
        }
    }

    private func refreshSources() {
        guard !refreshingSources else { return }
        refreshingSources = true
        BackgroundWork.start { [weak self] in
            let result = Result { try MicrophoneDevice.available() }
            BackgroundWork.deliverToMainRunLoop {
                guard let self, !self.shuttingDown else { return }
                self.refreshingSources = false
                do { self.menuBar.setMicrophones(try result.get()) }
                catch { self.report(error) }
            }
        }
    }

    private func refreshMenu() {
        menuBar.updateAutomaticDetection(paused: policy.isPaused)
        let elapsed = session.map { Self.format(Date().timeIntervalSince($0.startedAt)) }
        menuBar.update(
            recording: session != nil, elapsed: elapsed,
            application: session?.application, microphone: session?.microphoneName
        )
    }

    private func report(_ error: Error) {
        FileHandle.standardError.write(Data("recording error: \(error)\n".utf8))
        menuBar.showRecordingError(String(describing: error))
        notifyUser(title: L10n.text("noato — recording error"), body: String(describing: error))
    }

    private func showTranscription(_ state: TranscriptionState) {
        let jobs = state.jobs
        menuBar.transcriptions.update(state)
        menuBar.updateTranscription(jobs.isEmpty ? nil : L10n.format("Transcripts: %d · %@", jobs.count, jobs[0].phase.title))
    }

    private func previewCleanup(_ age: MeetingAge) {
        guard !cleanupBusy else { return }
        cleanupBusy = true
        let protecting = session?.dir
        BackgroundWork.start { [weak self, transcription, root] in
            let preview = await transcription.previewDeletion(root: root, age: age, now: Date(), protecting: protecting)
            BackgroundWork.deliverToMainRunLoop {
                guard let self else { return }
                let alert = DeletionAlerts.retention(preview, automatic: false)
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn, !preview.candidates.isEmpty else {
                    self.cleanupBusy = false
                    return
                }
                let current = self.session?.dir
                BackgroundWork.start { [weak self, transcription] in
                    let result = await transcription.delete(preview, protecting: current)
                    BackgroundWork.deliverToMainRunLoop {
                        guard let self else { return }
                        self.cleanupBusy = false
                        let done = NSAlert()
                        done.messageText = L10n.format("Meetings deleted: %d", result.deleted)
                        done.informativeText = L10n.format("Changed or active meetings skipped: %d.", result.skipped) + (result.errors.isEmpty ? "" : "\n" + result.errors.joined(separator: "\n"))
                        done.runModal()
                    }
                }
            }
        }
    }

    private func deleteCompleted(_ transcript: CompletedTranscript) {
        BackgroundWork.start { [weak self, transcription] in
            do {
                let preview = try await transcription.previewCompletedDeletion(transcript)
                BackgroundWork.deliverToMainRunLoop { [weak self] in
                    guard let self else { return }
                    let alert = DeletionAlerts.transcript(transcript.file)
                    NSApp.activate(ignoringOtherApps: true)
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    BackgroundWork.start { [weak self, transcription] in
                        if let error = await transcription.deleteCompleted(preview) {
                            BackgroundWork.deliverToMainRunLoop { self?.showDeletionError(error) }
                        }
                    }
                }
            } catch {
                let message = String(describing: error)
                BackgroundWork.deliverToMainRunLoop { self?.showDeletionError(message) }
            }
        }
    }

    private func showDeletionError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.text("Could not delete transcript")
        alert.informativeText = message
        alert.runModal()
    }

    private func deleteFailed(_ id: String) {
        let alert = NSAlert()
        alert.messageText = L10n.text("Delete saved recording?")
        alert.informativeText = L10n.text("This meeting’s audio will be permanently deleted. Transcription cannot be retried.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.text("Delete"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        BackgroundWork.start { [transcription] in
            let error = await transcription.deleteFailed(id)
            if let error {
                BackgroundWork.deliverToMainRunLoop {
                    let alert = NSAlert()
                    alert.messageText = L10n.text("Could not delete recording")
                    alert.informativeText = error
                    alert.runModal()
                }
            }
        }
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = Config.transcriptsDir()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
