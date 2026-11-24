import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem

    private var applicationItems: [CallApplication: NSMenuItem] = [:]
    private let microphoneItem = NSMenuItem(title: L10n.text("Microphone"), action: nil, keyEquivalent: "")
    private let soundItem = NSMenuItem(title: L10n.text("Audio"), action: nil, keyEquivalent: "")
    private var sources = AudioSources()
    private var microphones: [MicrophoneDevice] = []
    var onMicrophone: ((String?) -> Void)?
    var onSystemAudio: ((SystemAudioSource) -> Void)?
    var onRefreshSources: (() -> Void)?
    private var captureMode: AudioCaptureMode = .system
    private var available: Set<CallApplication> = []
    private var automaticPaused = false
    private var recording = false
    private var recordingError: String?
    private var idleImage: NSImage?
    var onStartApplication: ((CallApplication) -> Void)?
    var onToggle: (() -> Void)?
    var onToggleAutomaticPause: (() -> Void)?
    private let pauseItem = NSMenuItem(title: L10n.text("Pause automatic detection"), action: #selector(pauseClicked), keyEquivalent: "")
    let transcriptions = TranscriptionMenuController()
    var onCleanup: ((MeetingAge) -> Void)?
    var onOpenFolder: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: L10n.text("Ready"), action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: L10n.text("Start recording"),
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        super.init()
        menu.delegate = self
        menu.addItem(toggleItem)
        for app in CallApplication.allCases {
            let item = NSMenuItem(
                title: L10n.format("Start %@ recording", app.title), action: #selector(applicationClicked(_:)),
                keyEquivalent: ""
            )
            item.representedObject = app.rawValue
            item.target = self
            menu.addItem(item)
            applicationItems[app] = item
        }

        pauseItem.target = self
        pauseItem.toolTip = L10n.text("Pauses new automatic recordings. Current recordings and manual recording continue.")
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(microphoneItem)
        menu.addItem(soundItem)
        rebuildSourceMenus()
        menu.addItem(.separator())

        let progress = NSMenuItem(title: L10n.text("Transcripts"), action: nil, keyEquivalent: "")
        progress.submenu = transcriptions.menu
        menu.addItem(progress)
        let cleanup = NSMenuItem(title: L10n.text("Delete meetings older than…"), action: nil, keyEquivalent: "")
        let ages = NSMenu()
        for age in MeetingAge.allCases {
            let item = NSMenuItem(title: age.title, action: #selector(cleanupClicked(_:)), keyEquivalent: "")
            item.representedObject = age.rawValue
            item.target = self
            ages.addItem(item)
        }
        cleanup.submenu = ages
        menu.addItem(cleanup)

        let openFolder = NSMenuItem(
            title: L10n.text("Open transcripts folder"),
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: L10n.text("Settings…"), action: #selector(settingsClicked), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        let mainMenu = NSMenu(); let application = NSMenuItem(); let applicationMenu = NSMenu()
        let settingsShortcut = NSMenuItem(title: L10n.text("Settings…"), action: #selector(settingsClicked), keyEquivalent: ",")
        settingsShortcut.target = self; applicationMenu.addItem(settingsShortcut)
        application.submenu = applicationMenu; mainMenu.addItem(application); NSApp.mainMenu = mainMenu

        let quit = NSMenuItem(
            title: L10n.text("Quit noato"),
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, openFolder, quit] {
            item.target = self
        }

        statusItem.menu = menu

        statusItem.length = NSStatusItem.squareLength
        statusItem.autosaveName = "noato"
        statusItem.isVisible = true
        if let button = statusItem.button {
            idleImage = StatusBarLogo.image(recording: false)
            button.image = idleImage
            if idleImage == nil { button.title = "n" }
            button.setAccessibilityLabel("noato")
            button.toolTip = L10n.text("noato — local meeting recorder")
        }
    }

    /// Reflect recording state in the icon tint and menu item titles. The
    /// menu bar shows the noato logo (red while recording); the elapsed
    /// counter lives in the menu's state label. Call once a second while
    /// recording.
    func configure(sources: AudioSources) {
        self.sources = sources
        captureMode = sources.systemAudio.captureMode
        rebuildSourceMenus()
        updateAvailable(available)
    }

    func setMicrophones(_ microphones: [MicrophoneDevice]) {
        self.microphones = microphones
        rebuildSourceMenus()
    }

    static func recordingImage() -> NSImage? { StatusBarLogo.image(recording: true) }

    var menuForReview: NSMenu { statusItem.menu! }

    func showAtPointer() {
        NSApp.activate(ignoringOtherApps: true)
        statusItem.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func menuWillOpen(_ menu: NSMenu) { onRefreshSources?() }

    private func rebuildSourceMenus() {
        let microphoneMenu = NSMenu(title: L10n.text("Microphone"))
        let defaultItem = NSMenuItem(title: L10n.text("System default"), action: #selector(microphoneClicked(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = ""
        defaultItem.state = sources.microphoneUID == nil ? .on : .off
        microphoneMenu.addItem(defaultItem)
        for device in microphones {
            let item = NSMenuItem(title: device.name, action: #selector(microphoneClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = sources.microphoneUID == device.uid ? .on : .off
            microphoneMenu.addItem(item)
        }
        if let uid = sources.microphoneUID, !microphones.contains(where: { $0.uid == uid }) {
            let missing = NSMenuItem(title: L10n.text("Selected microphone unavailable"), action: nil, keyEquivalent: "")
            missing.state = .on
            missing.isEnabled = false
            microphoneMenu.addItem(missing)
        }
        microphoneItem.submenu = microphoneMenu
        let soundMenu = NSMenu(title: L10n.text("Audio"))
        for source in SystemAudioSource.allCases {
            let item = NSMenuItem(title: source.title, action: #selector(soundClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = source.rawValue
            item.state = sources.systemAudio == source ? .on : .off
            soundMenu.addItem(item)
        }
        soundItem.submenu = soundMenu
        microphoneItem.title = recording ? L10n.text("Microphone for next recording") : L10n.text("Microphone")
        soundItem.title = recording ? L10n.text("Audio for next recording") : L10n.text("Audio")
    }

    func updateAvailable(_ apps: Set<CallApplication>) {
        available = apps
        for (app, item) in applicationItems {
            item.isEnabled = !recording && apps.contains(app) && sources.systemAudio.applications.contains(app)
        }
    }

    func updateAutomaticDetection(paused: Bool) {
        automaticPaused = paused
        pauseItem.state = paused ? .on : .off
        if !recording { stateLabel.title = idleTitle }
    }

    private var idleTitle: String {
        recordingError.map { "Error: " + $0 } ?? (automaticPaused ? L10n.text("Automatic detection paused") : L10n.text("Ready"))
    }

    func showRecordingError(_ message: String) {
        recordingError = message
        if !recording { stateLabel.title = "Error: " + message }
    }

    func clearRecordingError() {
        recordingError = nil
        if !recording { stateLabel.title = idleTitle }
    }

    func update(recording: Bool, elapsed: String?, application: CallApplication? = nil, microphone: String? = nil) {
        self.recording = recording
        microphoneItem.title = recording ? L10n.text("Microphone for next recording") : L10n.text("Microphone")
        soundItem.title = recording ? L10n.text("Audio for next recording") : L10n.text("Audio")
        if recording { recordingError = nil }
        stateLabel.title = recording
            ? "● \(application?.title ?? "system") · \(microphone ?? L10n.text("microphone")) · \(elapsed ?? "0:00")"
            : idleTitle
        toggleItem.isHidden = !recording && captureMode == .callApp
        updateAvailable(available)
        toggleItem.title = recording ? L10n.text("Stop recording") : L10n.text("Start recording")
        statusItem.button?.contentTintColor = nil
        statusItem.button?.image = recording ? Self.recordingImage() : idleImage
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    @objc private func microphoneClicked(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        onMicrophone?(uid.isEmpty ? nil : uid)
    }

    @objc private func soundClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let source = SystemAudioSource(rawValue: raw) else { return }
        onSystemAudio?(source)
    }

    @objc private func applicationClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let app = CallApplication(rawValue: raw) else { return }
        onStartApplication?(app)
    }

    @objc private func pauseClicked() { onToggleAutomaticPause?() }
    @objc private func toggleClicked() { onToggle?() }
    @objc private func cleanupClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let age = MeetingAge(rawValue: raw) else { return }
        onCleanup?(age)
    }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func settingsClicked() { onSettings?() }
    @objc private func quitClicked() { onQuit?() }
}
