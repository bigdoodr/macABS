//
//  MenuContentView.swift
//
//  The dropdown content shown when the menu bar icon is clicked: status,
//  start/stop/restart, open the web UI in the default browser, view logs,
//  login item + auto-start toggles, quit. The embedded WKWebView window
//  is a later milestone.
//

import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var serverManager: ServerProcessManager
    @EnvironmentObject private var updater: ABSUpdater
    @State private var portText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: serverManager.state.symbolName)
                Text(serverManager.state.label)
                    .font(.headline)
            }

            Divider()

            HStack {
                Button("Start") { serverManager.start() }
                    .disabled(isRunningOrStarting || updater.isBusy)
                Button("Stop") { serverManager.stop() }
                    .disabled(!isRunningOrStarting || updater.isBusy)
                Button("Restart") { serverManager.restart() }
                    .disabled(updater.isBusy)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Audiobookshelf \(serverManager.activeVersion)")
                        .font(.caption)
                    if let notes = releaseNotesURL {
                        Link("What's new", destination: notes)
                            .font(.caption)
                    }
                }
                if !updater.statusLine.isEmpty {
                    Text(updater.statusLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button("Check for Audiobookshelf Update") {
                Task { await updater.checkNow() }
            }
            .disabled(updater.isBusy)

            Button("Open Web UI") {
                NSWorkspace.shared.open(serverManager.webUIURL)
            }
            .disabled(!isRunning)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Port")
                    TextField("", text: $portText, prompt: Text(verbatim: String(serverManager.serverPort)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .onChange(of: portText) { _, newValue in
                            let digits = String(newValue.filter(\.isNumber).prefix(5))
                            if digits != newValue { portText = digits }
                        }
                        .onSubmit(commitPort)
                    Spacer()
                }
                if let running = serverManager.runningPort, running != serverManager.serverPort {
                    Text("Running on \(String(running)) until restart")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Button("View Logs…") {
                LogWindowController.shared.show(server: serverManager)
            }

            Button("Show Data Folder in Finder") {
                NSWorkspace.shared.open(ABSRuntime.supportDirectory)
            }

            Toggle("Open macABS at Login", isOn: Binding(
                get: { serverManager.launchAtLoginEnabled },
                set: { serverManager.setLaunchAtLogin($0) }
            ))

            Toggle("Auto-start Audiobookshelf", isOn: $serverManager.startServerAutomatically)

            Divider()

            HStack {
                Button("Quit") {
                    serverManager.stop()
                    NSApplication.shared.terminate(nil)
                }
                Spacer()
                Text("macABS \(appVersion)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 260)
    }

    /// Return in the port field. Empty resets to the default port.
    private func commitPort() {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        let port = trimmed.isEmpty ? ServerProcessManager.defaultPort : Int(trimmed)
        portText = ""
        guard let port else { return }
        switch serverManager.setPort(port) {
        case .unchanged, .applied:
            break
        case .invalid:
            showAlert("Invalid port", "Use a number from 1024 to 65535.")
        case .inUse(let used):
            showAlert("Port \(used) is in use", "Another program is already listening on that port. Choose a different one.")
        case .needsRestart:
            if showAlert("Port changed", "Audiobookshelf has to restart to use port \(serverManager.serverPort).",
                         buttons: ["Restart Now", "Later"]) == .alertFirstButtonReturn {
                serverManager.restart()
            }
        }
    }

    @discardableResult
    private func showAlert(_ title: String, _ message: String, buttons: [String] = ["OK"]) -> NSApplication.ModalResponse {
        // The app is a menu bar agent; come forward so the alert isn't hidden.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }

    /// macABS's own version (the Audiobookshelf version is shown separately).
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// Upstream release notes for the Audiobookshelf version in use.
    private var releaseNotesURL: URL? {
        URL(string: "https://github.com/advplyr/audiobookshelf/releases/tag/\(serverManager.activeVersion)")
    }

    private var isRunning: Bool {
        if case .running = serverManager.state { return true }
        return false
    }

    private var isRunningOrStarting: Bool {
        switch serverManager.state {
        case .running, .starting: return true
        default: return false
        }
    }
}
