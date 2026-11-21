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

            Toggle("Start Audiobookshelf Automatically", isOn: $serverManager.startServerAutomatically)

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
