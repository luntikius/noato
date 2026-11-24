import AppKit
import AVFoundation

@MainActor
final class WelcomeWindowController: NSWindowController {
    var onSettings: (() -> Void)?
    var onPrepare: ((@escaping @MainActor @Sendable (String) -> Void) -> Void)?
    var onComplete: (() -> Void)?
    private let permissionReturn = PermissionWindowReturn()
    private let microphoneAllowed: @MainActor () -> Bool
    private var progress = SetupProgress()
    private var rows: [SetupStep: SetupStepRow] = [:]
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let folder = NSTextField(labelWithString: "")
    private let finish = NSButton(title: L10n.text("Finish Setup"), target: nil, action: nil)

    init(microphoneAllowed: @escaping @MainActor () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }) {
        self.microphoneAllowed = microphoneAllowed
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("Welcome to noato"); window.isReleasedWhenClosed = false
        super.init(window: window)
        permissionReturn.attach(to: window)
        let heading = NSTextField(labelWithString: L10n.text("Set up noato")); heading.font = .systemFont(ofSize: 24, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: L10n.text("Three steps. Your meetings stay on your Mac."))
        intro.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingMiddle; folder.font = .systemFont(ofSize: 12)
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let settings = NSButton(title: L10n.text("Change Folder…"), target: self, action: #selector(openSettings))
        settings.controlSize = .small
        let folderRow = NSStackView(views: [folder, settings]); folderRow.spacing = 12
        folderRow.widthAnchor.constraint(equalToConstant: 512).isActive = true
        let checklist = NSStackView(); checklist.orientation = .vertical; checklist.alignment = .leading; checklist.spacing = 8
        for step in SetupStep.allCases {
            let row = SetupStepRow(step: step)
            row.onAction = { [weak self] in self?.start(step) }
            checklist.addArrangedSubview(row); rows[step] = row
        }
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor; detail.maximumNumberOfLines = 3
        detail.preferredMaxLayoutWidth = 512
        finish.target = self; finish.action = #selector(finishSetup); finish.keyEquivalent = "\r"
        let stack = NSStackView(views: [heading, intro, folderRow, checklist, detail, finish])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let view = window.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24)])
        }
        window.center(); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() {
        refresh()
        showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func refreshSettings() { refresh() }

    private func refresh() {
        progress.refresh(microphoneAllowed: microphoneAllowed(), diarization: Config.current.diarization)
        folder.stringValue = Config.current.destination.path; folder.toolTip = folder.stringValue
        for step in SetupStep.allCases { rows[step]?.update(progress) }
        finish.isEnabled = progress.canFinish
        detail.textColor = .secondaryLabelColor
        detail.stringValue = L10n.text(progress.canFinish
            ? "All steps are complete. You can start using noato."
            : "Complete the steps in order. Existing model downloads are reused; new downloads need internet.")
    }
    @objc private func openSettings() { onSettings?() }
    private func start(_ step: SetupStep) {
        refresh()
        guard progress.begin(step) else { return }
        refresh()
        switch step { case .microphone: microphone(); case .systemAudio: systemAudio(); case .models: models() }
    }
    private func microphone() {
        let request = permissionReturn.begin()
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            BackgroundWork.deliverToMainRunLoop {
                guard let self, self.progress.complete(.microphone, success: granted, message: granted ? nil : L10n.text("Access denied. Enable noato in Privacy & Security → Microphone, then try again.")) else { return }
                self.refresh()
                self.permissionReturn.restore(request)
            }
        }
    }
    private func systemAudio() {
        let request = permissionReturn.begin()
        BackgroundWork.start { [weak self] in
            let result = Result { try SystemAudioRecorder.checkProcessTap(processIDs: []) }
            BackgroundWork.deliverToMainRunLoop {
                guard let self else { return }
                let success: Bool
                let message: String?
                switch result { case .success: success = true; message = nil
                case .failure(let error): success = false; message = String(describing: error) }
                guard self.progress.complete(.systemAudio, success: success, message: message) else { return }
                self.refresh(); self.permissionReturn.restore(request)
            }
        }
    }
    private func models() {
        guard let onPrepare else {
            progress.complete(.models, success: false, message: L10n.text("Model setup is unavailable. Reopen noato and try again.")); refresh(); return
        }
        let diarization = Config.current.diarization
        onPrepare { [weak self] message in
            guard let self else { return }
            if message == "done" { self.progress.complete(.models, success: true, diarization: diarization) }
            else if message.hasPrefix("Error:") { self.progress.complete(.models, success: false, message: message) }
            else { self.progress.report(message, for: .models) }
            self.refresh()
        }
    }
    @objc private func finishSetup() {
        refresh()
        guard progress.canFinish else { return }
        do { _ = try SettingsStore.shared.update { $0.setupCompleted = true }; close(); onComplete?() }
        catch { detail.stringValue = String(describing: error); detail.textColor = .systemRed }
    }
}

@MainActor
private final class SetupStepRow: NSStackView {
    var onAction: (() -> Void)?
    private let step: SetupStep
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)

    init(step: SetupStep) {
        self.step = step
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("setup-step-\(step.rawValue)")
        orientation = .horizontal; alignment = .centerY; spacing = 12
        let slot = NSView(); slot.translatesAutoresizingMaskIntoConstraints = false
        for view in [icon, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false; slot.addSubview(view)
            NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: slot.centerXAnchor), view.centerYAnchor.constraint(equalTo: slot.centerYAnchor), view.widthAnchor.constraint(equalToConstant: 20), view.heightAnchor.constraint(equalToConstant: 20)])
        }
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let title = NSTextField(labelWithString: step.title); title.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2; subtitle.preferredMaxLayoutWidth = 330
        let labels = NSStackView(views: [title, subtitle]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 4
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionButton.target = self; actionButton.action = #selector(clicked); actionButton.controlSize = .small
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        for view in [slot, labels, actionButton] { addArrangedSubview(view) }
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 512), heightAnchor.constraint(equalToConstant: 62), slot.widthAnchor.constraint(equalToConstant: 22), slot.heightAnchor.constraint(equalToConstant: 22)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ progress: SetupProgress) {
        let phase = progress.phase(step)
        let completed = phase == .completed, running = phase == .running
        icon.isHidden = running
        if running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let symbol = completed ? "checkmark.circle.fill" : phase == .failed ? "exclamationmark.circle" : "\(step.rawValue + 1).circle"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: step.title)
        icon.contentTintColor = completed ? .systemGreen : phase == .failed ? .systemOrange : phase == .ready || running ? .controlAccentColor : .tertiaryLabelColor
        actionButton.isHidden = completed
        actionButton.isEnabled = progress.canBegin(step)
        actionButton.title = L10n.text(phase == .failed ? "Retry" : step == .microphone ? "Allow…" : step == .systemAudio ? "Check Access…" : "Prepare Models")
        let caption: String
        if completed { caption = L10n.text(step == .microphone ? "Allowed" : step == .systemAudio ? "Access check passed. Verify both tracks in a test meeting." : "Ready for offline use") }
        else if phase == .running { caption = progress.message ?? L10n.text(step == .models ? "Preparing models…" : "Waiting for macOS…") }
        else if phase == .failed { caption = progress.message ?? L10n.text("Try this step again.") }
        else if phase == .waiting { caption = L10n.text("Complete the previous step first") }
        else { caption = L10n.text(step == .microphone ? "Record your voice" : step == .systemAudio ? "Record the other side of the meeting" : "Download once, then process locally") }
        subtitle.stringValue = caption; subtitle.toolTip = caption
        subtitle.textColor = phase == .failed ? .systemRed : .secondaryLabelColor
        setAccessibilityLabel(step.title + ": " + caption)
    }
    @objc private func clicked() { onAction?() }
}
