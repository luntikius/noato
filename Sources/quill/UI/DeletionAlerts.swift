import AppKit

@MainActor
enum DeletionAlerts {
    static func retention(_ preview: MeetingDeletion, automatic: Bool) -> NSAlert {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = L10n.format(automatic ? "Automatically delete meetings older than %@?" : "Delete meetings older than %@?", preview.age.title)
        let size = ByteCountFormatter.string(fromByteCount: preview.bytes, countStyle: .file)
        alert.informativeText = L10n.format("Meetings: %d. Size: %@. Active meetings skipped: %d.\nDeletion is permanent.", preview.candidates.count, size, preview.skippedActive)
        if automatic {
            alert.informativeText += "\n\n" + L10n.text("Queued recordings and failed work are included. Their audio will be permanently deleted, even if it has not been transcribed.")
            alert.addButton(withTitle: L10n.text("Enable Automatic Deletion"))
        } else if !preview.candidates.isEmpty { alert.addButton(withTitle: L10n.text("Delete")) }
        alert.addButton(withTitle: L10n.text("Cancel"))
        return alert
    }
    static func transcript(_ file: URL) -> NSAlert {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = L10n.text("Delete transcript?")
        alert.informativeText = file.lastPathComponent + L10n.text("\nThe file will be permanently deleted.")
        alert.addButton(withTitle: L10n.text("Delete")); alert.addButton(withTitle: L10n.text("Cancel"))
        return alert
    }
}
