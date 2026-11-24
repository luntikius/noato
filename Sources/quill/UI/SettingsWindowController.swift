import AppKit
import AVFoundation
import FluidAudio
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSTabViewDelegate {
    var onChange: ((AppSettings) -> Void)?
    var onRetentionChange: ((MeetingAge?, @escaping @MainActor @Sendable (Bool) -> Void) -> Void)?
    var onPrepareModels: ((@escaping @MainActor @Sendable (String) -> Void) -> Void)?
    private var bindings: [ObjectIdentifier: (NSControl, inout AppSettings) -> Void] = [:]
    private let tabs = NSTabView()
    private let permissionReturn = PermissionWindowReturn()
    private let navigation = NSSegmentedControl()
    private var retentionPopup: NSPopUpButton?
    private var loginToggle: NSButton?
    private let status = NSTextField(wrappingLabelWithString: "")
    private let modelStatus = NSTextField(wrappingLabelWithString: "")
    private let permissionStatus = NSTextField(wrappingLabelWithString: "")
    private var folderLabel: NSTextField?
    private var modelButton: NSButton?
    private var folderPath = ""
    private let spinner = NSProgressIndicator()
    private var timingFields: NSStackView?
    private var timingExpanded = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = L10n.text("noato Settings")
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
        permissionReturn.attach(to: window)
        window.center()
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func presentIfVisible() { if window?.isVisible == true { rebuild() } }

    func present() {
        rebuild()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func text(_ value: String, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: L10n.text(value))
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.font = .systemFont(ofSize: secondary ? 12 : 13)
        label.preferredMaxLayoutWidth = 570
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    private func section(_ name: String) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 14)
        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.drawsBackground = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        let item = NSTabViewItem(identifier: name); item.label = L10n.text(name); item.view = scroll
        tabs.addTabViewItem(item)
        let index = tabs.numberOfTabViewItems - 1
        navigation.segmentCount = tabs.numberOfTabViewItems
        navigation.setLabel(L10n.text(name), forSegment: index)
        navigation.setWidth(200, forSegment: index)
        return stack
    }

    private func group(_ title: String, in stack: NSStackView, separator: Bool = false) {
        if separator {
            let line = NSBox(); line.boxType = .separator
            line.widthAnchor.constraint(equalToConstant: 552).isActive = true
            stack.addArrangedSubview(line)
            stack.setCustomSpacing(12, after: line)
        }
        let heading = text(title); heading.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(heading)
    }

    private func row(_ title: String, _ control: NSView, in stack: NSStackView) {
        let label = text(title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 132).isActive = true
        control.setAccessibilityLabel(L10n.text(title))
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: 410).isActive = true
        let row = NSStackView(views: [label, control]); row.alignment = .centerY; row.spacing = 10
        stack.addArrangedSubview(row)
    }
    private func bind(_ control: NSControl, _ edit: @escaping (NSControl, inout AppSettings) -> Void) {
        bindings[ObjectIdentifier(control)] = edit
        control.target = self; control.action = #selector(changed(_:))
        if let field = control as? NSTextField { field.delegate = self; field.action = nil }
    }
    private func toggle(_ title: String, value: Bool, edit: @escaping (inout AppSettings, Bool) -> Void) -> NSButton {
        let button = NSButton(checkboxWithTitle: L10n.text(title), target: nil, action: nil)
        button.state = value ? .on : .off
        bind(button) { control, settings in edit(&settings, (control as! NSButton).state == .on) }
        return button
    }
    private func number(_ title: String, value: Double, range: String, in stack: NSStackView,
                        edit: @escaping (inout AppSettings, Double) -> Void) {
        let field = NSTextField(string: String(format: "%g", value)); field.placeholderString = range
        field.setAccessibilityLabel(L10n.text(title))
        field.toolTip = L10n.format("Allowed range: %@", range)
        bind(field) { control, settings in edit(&settings, Double(control.stringValue) ?? .nan) }
        row(title, field, in: stack)
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: L10n.text(title), target: self, action: action)
    }

    private func rebuild() {
        let selection = tabs.selectedTabViewItem?.identifier as? String
        bindings.removeAll()
        navigation.segmentCount = 0
        navigation.trackingMode = .selectOne
        navigation.segmentStyle = .automatic
        navigation.font = .systemFont(ofSize: 12)
        navigation.target = self; navigation.action = #selector(selectSection(_:))
        tabs.tabViewType = .noTabsNoBorder; tabs.delegate = self
        for item in tabs.tabViewItems { tabs.removeTabViewItem(item) }
        let settings = Config.current
        folderPath = settings.transcriptsDirectory
        let general = section("General")
        group("Files & application", in: general)
        let folder = NSTextField(labelWithString: settings.destination.path)
        folder.lineBreakMode = .byTruncatingMiddle; folder.toolTip = settings.destination.path
        folderLabel = folder
        row("Save transcripts to", folder, in: general)
        let folders = NSStackView(views: [button("Choose Folder…", #selector(chooseFolder)), button("Open in Finder", #selector(openFolder))])
        general.addArrangedSubview(folders)
        general.addArrangedSubview(text("Changing the folder affects new meetings. Existing files stay where they are.", secondary: true))
        let login = NSButton(checkboxWithTitle: L10n.text("Launch at login"), target: self, action: #selector(changeLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginToggle = login; general.addArrangedSubview(login)
        if SMAppService.mainApp.status == .requiresApproval {
            general.addArrangedSubview(text("Approval is required in System Settings.", secondary: true))
            general.addArrangedSubview(button("Open Login Items", #selector(openLoginItems)))
        }


        group("Automatic deletion", in: general, separator: true)
        let retention = NSPopUpButton(); retention.addItem(withTitle: L10n.text("Never delete automatically"))
        for age in MeetingAge.allCases { retention.addItem(withTitle: L10n.format("Older than %@", age.title)); retention.lastItem?.representedObject = age.rawValue }
        if let age = settings.retention { retention.selectItem(at: (MeetingAge.allCases.firstIndex(of: age) ?? 0) + 1) }
        retention.target = self; retention.action = #selector(changeRetention(_:)); retentionPopup = retention
        row("Delete meetings", retention, in: general)
        general.addArrangedSubview(text("Measured from meeting start. Checked at launch, after wake and hourly. Deletion is permanent.", secondary: true))

        general.addArrangedSubview(text("Includes queued audio and failed work. Active meetings are protected.", secondary: true))
        general.addArrangedSubview(text("noato 0.1.0-beta.1 · Based on kukutz/quill", secondary: true))

        let recording = section("Recording")
        group("Audio sources", in: recording)
        let microphones = NSPopUpButton(); microphones.addItem(withTitle: L10n.text("System default")); microphones.lastItem?.representedObject = ""
        for device in (try? MicrophoneDevice.available()) ?? [] {
            microphones.addItem(withTitle: device.name); microphones.lastItem?.representedObject = device.uid
        }
        if let uid = settings.microphoneUID {
            if let item = microphones.itemArray.first(where: { $0.representedObject as? String == uid }) { microphones.select(item) }
            else { microphones.addItem(withTitle: L10n.text("Selected microphone unavailable")); microphones.lastItem?.representedObject = uid; microphones.selectItem(at: microphones.numberOfItems - 1) }
        }
        bind(microphones) { control, settings in
            let value = (control as! NSPopUpButton).selectedItem?.representedObject as? String
            settings.microphoneUID = value?.isEmpty == false ? value : nil
        }
        row("Microphone", microphones, in: recording)
        let audio = NSPopUpButton()
        for source in SystemAudioSource.allCases { audio.addItem(withTitle: source.title); audio.lastItem?.representedObject = source.rawValue }
        audio.selectItem(at: SystemAudioSource.allCases.firstIndex(of: settings.systemAudio) ?? 0)
        bind(audio) { control, settings in
            if let raw = (control as! NSPopUpButton).selectedItem?.representedObject as? String, let value = SystemAudioSource(rawValue: raw) { settings.systemAudio = value }
        }
        row("Capture audio from", audio, in: recording)
        permissionStatus.stringValue = permissionSummary(); permissionStatus.font = .systemFont(ofSize: 12); permissionStatus.textColor = .secondaryLabelColor
        recording.addArrangedSubview(permissionStatus)
        let permissions = NSStackView(views: [button("Microphone Access…", #selector(requestMicrophone)), button("System Audio Access…", #selector(checkSystemAudio)), button("Privacy Settings…", #selector(openPrivacy))])
        permissions.spacing = 6
        for case let button as NSButton in permissions.arrangedSubviews { button.controlSize = .small; button.font = .systemFont(ofSize: 11) }
        recording.addArrangedSubview(permissions)
        recording.addArrangedSubview(text("Access checks do not record audio. Verify both tracks in a test meeting.", secondary: true))

        group("Automatic recording", in: recording, separator: true)
        let apps = NSStackView(views: [toggle("Zoom", value: settings.zoom) { $0.zoom = $1 }, toggle("Telemost", value: settings.telemost) { $0.telemost = $1 }])
        apps.spacing = 24
        recording.addArrangedSubview(apps)
        recording.addArrangedSubview(toggle("Pause automatic detection", value: settings.automaticPaused) { $0.automaticPaused = $1 })
        recording.addArrangedSubview(text("Audio activity can trigger false starts. Use manual recording for reliability.", secondary: true))

        let transcription = section("Transcription")
        group("Speech recognition", in: transcription)
        let language = NSTextField(string: settings.language); language.placeholderString = L10n.text("ru, en, or leave empty for automatic detection")
        bind(language) { control, settings in settings.language = control.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        row("Language code", language, in: transcription)
        transcription.addArrangedSubview(toggle("Separate remote speakers", value: settings.diarization) { $0.diarization = $1 })
        number("Maximum speakers", value: Double(settings.maxSpeakers), range: "2–20", in: transcription) { if $1.isFinite, (2...20).contains($1), $1.rounded() == $1 { $0.maxSpeakers = Int($1) } else { $0.maxSpeakers = 0 } }
        transcription.addArrangedSubview(text("Microphone: me · Remote voices: participant_N. Names are not identified.", secondary: true))

        number("Silence (dBFS)", value: settings.silenceThreshold, range: "−80 to −10", in: transcription) { $0.silenceThreshold = $1 }
        group("Local models", in: transcription, separator: true)
        modelStatus.font = .systemFont(ofSize: 13); modelStatus.maximumNumberOfLines = 3
        modelStatus.stringValue = modelSummary()
        transcription.addArrangedSubview(modelStatus)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let prepare = button("Download & Prepare Models", #selector(prepareModels)); modelButton = prepare
        transcription.addArrangedSubview(NSStackView(views: [prepare, spinner]))

        let timings = NSStackView(); timings.orientation = .vertical; timings.alignment = .leading; timings.spacing = 8
        timingFields = timings; timings.isHidden = !timingExpanded
        let disclosure = NSButton(title: L10n.text("Timing & minimum duration"), target: self, action: #selector(toggleTiming(_:)))
        disclosure.isBordered = false; disclosure.font = .systemFont(ofSize: 12)
        disclosure.image = NSImage(systemSymbolName: timingExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        disclosure.imagePosition = .imageLeading; disclosure.state = timingExpanded ? .on : .off
        recording.addArrangedSubview(disclosure); recording.addArrangedSubview(timings)
        number("Start delay (seconds)", value: settings.startDelay, range: "0–60", in: timings) { $0.startDelay = $1 }
        number("Stop delay (seconds)", value: settings.stopDelay, range: "1–300", in: timings) { $0.stopDelay = $1 }
        number("Minimum duration (s)", value: settings.minimumDuration, range: "0–3600", in: timings) { $0.minimumDuration = $1 }
        timings.addArrangedSubview(text("Shorter recordings are discarded with a notification.", secondary: true))

        if let selection, let item = tabs.tabViewItems.first(where: { $0.identifier as? String == selection }) { tabs.selectTabViewItem(item) }
        tabView(tabs, didSelect: tabs.selectedTabViewItem)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        // Standard navigation controls adopt Liquid Glass on macOS 26,
        // while the window's content stays opaque and readable.
        let toolbar = navigation
        let content = NSStackView(views: [toolbar, tabs, status])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 40, left: 14, bottom: 12, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        window?.contentView = host
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor), content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor), content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 32), toolbar.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            tabs.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28), tabs.heightAnchor.constraint(equalToConstant: 300),
        ])
    }

    @objc private func toggleTiming(_ sender: NSButton) {
        timingExpanded.toggle(); timingFields?.isHidden = !timingExpanded
        sender.state = timingExpanded ? .on : .off
        sender.image = NSImage(systemSymbolName: timingExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let control = notification.object as? NSControl { changed(control) }
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if let tabViewItem, let index = tabs.tabViewItems.firstIndex(of: tabViewItem) { navigation.selectedSegment = index }
    }

    @objc private func selectSection(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0, sender.selectedSegment < tabs.numberOfTabViewItems else { return }
        tabs.selectTabViewItem(at: sender.selectedSegment)
    }

    @objc private func changed(_ sender: NSControl) {
        guard let edit = bindings[ObjectIdentifier(sender)] else { return }
        do {
            let value = try SettingsStore.shared.update { edit(sender, &$0) }
            status.stringValue = L10n.text("Saved. Changes apply to new meetings."); status.textColor = .secondaryLabelColor
            onChange?(value)
        } catch { showError(error) }
    }
    private func showError(_ error: Error) { status.stringValue = String(describing: error); status.textColor = .systemRed }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = Config.current.destination
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard FileManager.default.isWritableFile(atPath: url.path), url.resolvingSymlinksInPath() == url.standardizedFileURL else { throw SettingsError.invalid }
            let value = try SettingsStore.shared.update { $0.transcriptsDirectory = url.path }
            folderPath = value.destination.path; folderLabel?.stringValue = folderPath; folderLabel?.toolTip = folderPath
            onChange?(value)
        } catch { showError(error) }
    }
    @objc private func openFolder() {
        do { try FileManager.default.createDirectory(at: Config.current.destination, withIntermediateDirectories: true); NSWorkspace.shared.open(Config.current.destination) }
        catch { showError(error) }
    }
    @objc private func changeLogin(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { sender.state = SMAppService.mainApp.status == .enabled ? .on : .off; showError(error) }
    }
    @objc private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func changeRetention(_ sender: NSPopUpButton) {
        let age = (sender.selectedItem?.representedObject as? String).flatMap(MeetingAge.init(rawValue:))
        let old = Config.current.retention
        let shortening = age.map { value in old.map { value.cutoff(from: Date()) > $0.cutoff(from: Date()) } ?? true } ?? false
        let commit: @MainActor @Sendable (Bool) -> Void = { [weak self] accepted in
            guard let self else { return }
            if !accepted { sender.selectItem(at: old.map { (MeetingAge.allCases.firstIndex(of: $0) ?? 0) + 1 } ?? 0); return }
            do { let value = try SettingsStore.shared.update { $0.retention = age }; self.onChange?(value) }
            catch { self.showError(error) }
        }
        if shortening { onRetentionChange?(age, commit) } else { commit(true) }
    }
    @objc private func prepareModels() {
        modelButton?.isEnabled = false; spinner.startAnimation(nil)
        onPrepareModels? { [weak self] message in
            guard let self else { return }
            self.modelStatus.stringValue = message
            if message == "done" { self.modelStatus.stringValue = self.modelSummary() }
            if message == "done" || message.hasPrefix("Error:") { self.modelButton?.isEnabled = true; self.spinner.stopAnimation(nil) }
        }
    }
    private func modelSummary() -> String {
        let location = WhisperEngine.modelStore
        let size = ((try? FileManager.default.subpathsOfDirectory(atPath: location.path)) ?? []).reduce(Int64(0)) { total, path in
            total + (((try? FileManager.default.attributesOfItem(atPath: location.appendingPathComponent(path).path)[.size]) as? NSNumber)?.int64Value ?? 0)
        }
        let speakerState: String
        if !Config.current.diarization { speakerState = L10n.text("Off") }
        else if case .ok = DoctorReport.checkDiarization().status { speakerState = L10n.text("Downloaded") }
        else { speakerState = L10n.text("Not downloaded") }
        let speakerRoot = OfflineDiarizerModels.defaultModelsDirectory()
        modelStatus.toolTip = location.path + "\n" + speakerRoot.path
        return L10n.format("Whisper: %@ · %@ on disk\nSpeaker separation: %@", L10n.text(WhisperEngine.modelsCached ? "Downloaded" : "Not downloaded"), ByteCountFormatter.string(fromByteCount: size, countStyle: .file), speakerState)
    }
    private func permissionSummary() -> String {
        L10n.format("Microphone: %@ · System audio: check required", L10n.text(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "Allowed" : "Not authorized"))
    }
    @objc private func requestMicrophone() {
        let request = permissionReturn.begin()
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            BackgroundWork.deliverToMainRunLoop {
                guard let self, self.permissionReturn.restore(request) else { return }
                self.permissionStatus.stringValue = self.permissionSummary()
            }
        }
    }
    @objc private func checkSystemAudio() {
        let request = permissionReturn.begin()
        BackgroundWork.start { [weak self] in
            let result = Result { try SystemAudioRecorder.checkProcessTap(processIDs: []) }
            BackgroundWork.deliverToMainRunLoop {
                guard let self, self.permissionReturn.restore(request) else { return }
                switch result {
                case .success: self.permissionStatus.stringValue = L10n.text("System audio access check succeeded. Verify both tracks in a test meeting.")
                case .failure(let error): self.showError(error)
                }
            }
        }
    }
    @objc private func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
    }
}

@MainActor
private final class SettingsDocumentView: NSView { override var isFlipped: Bool { true } }
