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
    @State private var showingLogs = false

    // Matches ServerProcessManager.serverPort (13378) -- keep these in
    // sync if you change the port there.
    private let webUIURL = URL(string: "http://localhost:13378")!

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
                Text("Audiobookshelf \(serverManager.activeVersion)")
                    .font(.caption)
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
                NSWorkspace.shared.open(webUIURL)
            }
            .disabled(!isRunning)

            Button("View Logs…") {
                showingLogs = true
            }

            Toggle("Open at Login", isOn: Binding(
                get: { serverManager.launchAtLoginEnabled },
                set: { serverManager.setLaunchAtLogin($0) }
            ))

            Toggle("Start Server Automatically", isOn: $serverManager.startServerAutomatically)

            Divider()

            Button("Quit") {
                serverManager.stop()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 260)
        .sheet(isPresented: $showingLogs) {
            LogWindow(lines: serverManager.logLines)
        }
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

struct LogWindow: View {
    let lines: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            Text("Server Log").font(.headline).padding(.bottom, 4)
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding()
        .frame(width: 500, height: 400)
    }
}
