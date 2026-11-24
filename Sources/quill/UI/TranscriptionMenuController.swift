import AppKit

/// Native submenu, using the same NSMenu tracking lifecycle as cleanup.
@MainActor
final class TranscriptionMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: L10n.text("Transcripts"))
    var onRefresh: (() -> Void)?
    var onRetry: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var onDeleteCompleted: ((CompletedTranscript) -> Void)?
    var onOpenTranscript: ((URL) -> Void)?
    private var rows: [String: (item: NSMenuItem, view: MeetingMenuRow)] = [:]
    private var completedItems: [String: (item: NSMenuItem, view: CompletedTranscriptMenuRow)] = [:]
    private var animationTimer: Timer?
    private let activeHeader = NSMenuItem(title: L10n.text("In progress"), action: nil, keyEquivalent: "")
    private let emptyActive = NSMenuItem(title: L10n.text("No current transcriptions"), action: nil, keyEquivalent: "")
    private let divider = NSMenuItem.separator()
    private let completedHeader = NSMenuItem(title: L10n.text("Recently completed"), action: nil, keyEquivalent: "")
    private let emptyCompleted = NSMenuItem(title: L10n.text("No completed transcripts yet"), action: nil, keyEquivalent: "")

    override init() {
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        for item in [activeHeader, emptyActive, completedHeader, emptyCompleted] { item.isEnabled = false }
        update(TranscriptionState(jobs: [], completed: []))
    }

    func update(_ state: TranscriptionState) {
        let ids = Set(state.jobs.map(\.id))
        rows = rows.filter { ids.contains($0.key) }
        var items = [activeHeader]
        for job in state.jobs {
            let row: (item: NSMenuItem, view: MeetingMenuRow)
            if let existing = rows[job.id] { row = existing }
            else {
                let view = MeetingMenuRow()
                let item = NSMenuItem()
                item.view = view
                row = (item, view)
                rows[job.id] = row
                view.onRetry = { [weak self] in
                    self?.menu.cancelTracking()
                    BackgroundWork.deliverToMainRunLoop { [weak self] in self?.onRetry?(job.id) }
                }
                view.onDelete = { [weak self] in
                    self?.menu.cancelTracking()
                    BackgroundWork.deliverToMainRunLoop { [weak self] in self?.onDelete?(job.id) }
                }
            }
            row.item.title = job.meeting.title
            row.view.update(job)
            items.append(row.item)
        }
        if state.jobs.isEmpty { items.append(emptyActive) }
        items += [divider, completedHeader]
        let recent = state.completed
        let recentIDs = Set(recent.map(\.id))
        completedItems = completedItems.filter { recentIDs.contains($0.key) }
        for transcript in recent {
            let row: (item: NSMenuItem, view: CompletedTranscriptMenuRow)
            if let existing = completedItems[transcript.id] { row = existing }
            else {
                let item = NSMenuItem(title: transcript.title, action: #selector(openCompleted(_:)), keyEquivalent: "")
                let view = CompletedTranscriptMenuRow()
                item.view = view
                item.target = self
                row = (item, view)
                completedItems[transcript.id] = row
                view.onOpen = { [weak self] transcript in
                    self?.menu.cancelTracking()
                    BackgroundWork.deliverToMainRunLoop { [weak self] in self?.onOpenTranscript?(transcript.file) }
                }
                view.onDelete = { [weak self] transcript in
                    self?.menu.cancelTracking()
                    BackgroundWork.deliverToMainRunLoop { [weak self] in self?.onDeleteCompleted?(transcript) }
                }
            }
            row.item.title = transcript.title
            row.item.representedObject = transcript.file
            row.item.toolTip = transcript.file.lastPathComponent
            row.view.update(transcript)
            items.append(row.item)
        }
        if recent.isEmpty { items.append(emptyCompleted) }
        // Progress ticks keep existing items/views in place while tracking.
        for item in menu.items where !items.contains(where: { $0 === item }) { menu.removeItem(item) }
        for (index, item) in items.enumerated() {
            if menu.items.indices.contains(index), menu.items[index] === item { continue }
            if menu.items.contains(where: { $0 === item }) { menu.removeItem(item) }
            menu.insertItem(item, at: index)
        }
    }

    func showAtPointer() {
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        onRefresh?()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for row in self.rows.values where row.view.ring.isIndeterminate { row.view.ring.needsDisplay = true }
            }
        }
        animationTimer?.invalidate()
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func menuDidClose(_ menu: NSMenu) {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    @objc private func openCompleted(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? URL else { return }
        onOpenTranscript?(file)
    }
}

@MainActor
private final class CompletedTranscriptMenuRow: NSView {
    var onOpen: ((CompletedTranscript) -> Void)?
    var onDelete: ((CompletedTranscript) -> Void)?
    private var transcript: CompletedTranscript?
    private let open = NSButton(title: "", target: nil, action: #selector(openClicked))
    private let delete = NSButton(title: "", target: nil, action: #selector(deleteClicked))

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 30))
        open.target = self
        open.isBordered = false
        open.alignment = .left
        open.font = .menuFont(ofSize: 13)
        open.cell?.lineBreakMode = .byTruncatingTail
        open.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        open.imagePosition = .imageLeading
        open.contentTintColor = .labelColor
        delete.target = self
        delete.isBordered = false
        delete.controlSize = .small
        delete.toolTip = L10n.text("Delete transcript")
        delete.setAccessibilityLabel(L10n.text("Delete transcript"))
        if let image = NSImage(systemSymbolName: "trash", accessibilityDescription: L10n.text("Delete transcript")) {
            delete.image = image.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            delete.title = ""
        }
        delete.imageScaling = .scaleProportionallyDown
        delete.contentTintColor = .labelColor
        for button in [open, delete] {
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        NSLayoutConstraint.activate([
            open.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            open.centerYAnchor.constraint(equalTo: centerYAnchor),
            open.trailingAnchor.constraint(equalTo: delete.leadingAnchor, constant: -8),
            delete.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            delete.centerYAnchor.constraint(equalTo: centerYAnchor),
            delete.widthAnchor.constraint(equalToConstant: 18), delete.heightAnchor.constraint(equalToConstant: 18),
        ])
        open.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ transcript: CompletedTranscript) {
        self.transcript = transcript
        open.attributedTitle = NSAttributedString(string: transcript.title, attributes: [
            .font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ])
        open.toolTip = transcript.file.lastPathComponent
        open.setAccessibilityLabel(L10n.text("Open transcript: ") + transcript.title)
        delete.setAccessibilityLabel(L10n.text("Delete transcript: ") + transcript.file.lastPathComponent)
    }

    @objc private func openClicked() { if let transcript { onOpen?(transcript) } }
    @objc private func deleteClicked() { if let transcript { onDelete?(transcript) } }
}

@MainActor
private final class MeetingMenuRow: NSView {
    let ring = MeetingProgressRing()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: L10n.text("Retry"), target: nil, action: #selector(retryClicked))
    private let delete = NSButton(title: L10n.text("Delete"), target: nil, action: #selector(deleteClicked))
    var onRetry: (() -> Void)?
    var onDelete: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 68))
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        let actions = NSStackView(views: [retry, delete])
        actions.spacing = 6
        for button in [retry, delete] { button.target = self; button.controlSize = .small }
        let content = NSStackView(views: [text, ring, actions])
        content.alignment = .centerY
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 8), content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ring.widthAnchor.constraint(equalToConstant: 20), ring.heightAnchor.constraint(equalToConstant: 20),
        ])
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        ring.setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ job: MeetingJob) {
        title.stringValue = job.meeting.title
        subtitle.stringValue = job.subtitle
        subtitle.toolTip = job.subtitle
        subtitle.textColor = job.phase == .failed ? .systemRed : .secondaryLabelColor
        retry.isHidden = job.phase != .failed
        delete.isHidden = job.phase != .failed
        ring.isHidden = job.phase == .failed || job.phase == .queued
        ring.fraction = job.fraction
        ring.isIndeterminate = job.fraction == nil
        ring.needsDisplay = true
        ring.setAccessibilityLabel(job.phase.title)
        ring.setAccessibilityValue(job.fraction.map { "\(Int($0 * 100))%" } ?? job.phase.title)
    }

    @objc private func retryClicked() { onRetry?() }
    @objc private func deleteClicked() { onDelete?() }
}

@MainActor
final class MeetingProgressRing: NSView {
    var fraction: Double?
    var isIndeterminate = true
    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        NSColor.quaternaryLabelColor.setStroke()
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = 2.5
        track.stroke()
        let start = isIndeterminate ? 90 - ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360 : 90
        let sweep = isIndeterminate ? 95 : min(1, max(0, fraction ?? 0)) * 360
        guard sweep > 0 else { return }
        let arc = NSBezierPath()
        arc.lineWidth = 2.5
        arc.lineCapStyle = .round
        arc.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: rect.width / 2,
                      startAngle: start, endAngle: start - sweep, clockwise: true)
        NSColor.secondaryLabelColor.setStroke()
        arc.stroke()
    }
}
