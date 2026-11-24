import ArgumentParser
import Foundation
import ServiceManagement

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Configure launch at login for the installed noato app.")
    @Flag(name: .long) var launchAtLogin = false
    @Flag(name: .long) var uninstall = false
    func run() throws {
        guard launchAtLogin != uninstall else { throw ValidationError("Specify --launch-at-login or --uninstall") }
        guard Bundle.main.bundleIdentifier == "io.github.luntikius.noato", Bundle.main.bundleURL.pathExtension == "app" else {
            throw ValidationError("Use the executable inside the installed noato.app, or Settings → General.")
        }
        if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        print("Login item status: \(SMAppService.mainApp.status.rawValue)")
    }
}
