//
//  ServerProcessManager.swift
//
//  Owns the Audiobookshelf server subprocess: start/stop/restart, log
//  capture, and a periodic health check against its HTTP port.
//
//  This version points at the bundled, self-contained runtime produced by
//  vendor-audiobookshelf.sh -- node and audiobookshelf both ship inside
//  the .app itself, so there's no dependency on Homebrew, a specific
//  system Node version, or any external drive.
//
//  XCODE SETUP -- get this exactly right, it's a one-way path match with
//  the code below:
//  1. Run vendor-audiobookshelf.sh. It produces a Vendor/ folder
//     containing Vendor/node and Vendor/audiobookshelf.
//  2. Drag the INNER folders -- node and audiobookshelf themselves, NOT
//     the parent Vendor folder -- into the Xcode project.
//  3. When prompted, choose "Create folder references" (blue folder
//     icon), not "Create groups" (yellow) -- groups flatten/reorganize
//     files, folder references preserve the exact directory structure
//     Node and npm expect.
//  4. Confirm both are checked under the target's "Copy Bundle
//     Resources" build phase.
//  Done correctly, this lands them at Contents/Resources/node and
//  Contents/Resources/audiobookshelf -- exactly what
//  Bundle.main.resourceURL below expects. No "Vendor" in the final path.
//
//  CONFIG_PATH/METADATA_PATH (the app's own database/settings -- not your
//  actual audiobook files, those are configured separately inside
//  Audiobookshelf's own web UI) live in Application Support, since a
//  signed app bundle's Resources are expected to stay read-only.
//

import Combine
import Foundation
import ServiceManagement

enum ServerState {
    case stopped
    case starting
    case running
    case crashed(String)

    var symbolName: String {
        switch self {
        case .stopped: return "stop.circle"
        case .starting: return "circle.dotted"
        case .running: return "checkmark.circle.fill"
        case .crashed: return "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .crashed(let reason): return "Crashed: \(reason)"
        }
    }
}

@MainActor
final class ServerProcessManager: ObservableObject {
    @Published private(set) var state: ServerState = .stopped
    @Published private(set) var logLines: [String] = []

    /// Mirrors SMAppService.mainApp.status -- kept as its own @Published
    /// value (rather than reading the service directly from the view)
    /// so the toggle can revert itself if register()/unregister() fails.
    @Published private(set) var launchAtLoginEnabled: Bool = SMAppService.mainApp.status == .enabled

    private static let startServerAutomaticallyKey = "startServerAutomatically"
    @Published var startServerAutomatically: Bool = UserDefaults.standard.bool(forKey: ServerProcessManager.startServerAutomaticallyKey) {
        didSet {
            UserDefaults.standard.set(startServerAutomatically, forKey: Self.startServerAutomaticallyKey)
        }
    }

    // --- Bundled runtime paths (produced by vendor-audiobookshelf.sh) ---
    /// Bundle.main.resourceURL is Contents/Resources inside the running
    /// .app -- resolved at runtime, so this works regardless of where the
    /// app itself is installed (Applications, ~/Downloads, wherever).
    private var workingDirectory: URL {
        Bundle.main.resourceURL!.appendingPathComponent("audiobookshelf", isDirectory: true)
    }
    private var nodeExecutable: URL {
        Bundle.main.resourceURL!.appendingPathComponent("node/bin/node")
    }
    /// Entry point is index.js at the repo root, not server/index.js.
    private let startArgs = ["index.js"]
    /// The native (non-Docker) server defaults to port 3333, not 13378 --
    /// that 13378 was specifically Docker's external port mapping. Setting
    /// PORT explicitly below keeps it consistent with the port used
    /// elsewhere (e.g. if you later put this behind the same cloudflared
    /// tunnel pattern as the podcast feed).
    private let serverPort = 13378
    /// CONFIG_PATH/METADATA_PATH: the app's own database/settings, not
    /// your audiobook library locations (those are configured inside
    /// Audiobookshelf's own web UI, unrelated to this). Application
    /// Support is the correct macOS home for this -- a signed app
    /// bundle's own Resources should stay read-only.
    private var configPath: String { Self.applicationSupportSubdirectory("config") }
    private var metadataPath: String { Self.applicationSupportSubdirectory("metadata") }

    private static func applicationSupportSubdirectory(_ name: String) -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "Audiobookshelf", isDirectory: true)
        let dir = appFolder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private var healthCheckURL: URL { URL(string: "http://localhost:\(serverPort)/healthcheck")! }
    // ----------------------------------------

    private var process: Process?
    private var healthCheckTask: Task<Void, Never>?
    private let maxLogLines = 500
    /// Set right before we call process?.terminate() so the termination
    /// handler can tell "we asked it to stop" apart from "it died on its
    /// own." Without this, a normal Stop (SIGTERM, exit code 15) gets
    /// misreported as a crash, since the handler otherwise only looks at
    /// the raw exit code.
    private var isIntentionalStop = false

    func start() {
        guard process == nil else { return }
        isIntentionalStop = false
        state = .starting
        appendLog("Starting server…")

        let task = Process()
        task.executableURL = nodeExecutable
        task.arguments = startArgs
        task.currentDirectoryURL = workingDirectory

        // Start from the launching process's own environment (so PATH
        // etc. are intact) and layer ABS-specific config on top.
        var env = ProcessInfo.processInfo.environment
        env["PORT"] = String(serverPort)
        env["CONFIG_PATH"] = configPath
        env["METADATA_PATH"] = metadataPath
        task.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }

        task.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                self.healthCheckTask?.cancel()
                if self.isIntentionalStop {
                    self.state = .stopped
                    self.appendLog("Server stopped.")
                } else if proc.terminationStatus != 0 {
                    self.state = .crashed("exit code \(proc.terminationStatus)")
                    self.appendLog("Server exited with code \(proc.terminationStatus)")
                } else {
                    self.state = .stopped
                    self.appendLog("Server stopped cleanly.")
                }
                self.isIntentionalStop = false
            }
        }

        do {
            try task.run()
            process = task
            beginHealthChecking()
        } catch {
            state = .crashed(error.localizedDescription)
            appendLog("Failed to launch: \(error.localizedDescription)")
        }
    }

    func stop() {
        isIntentionalStop = true
        healthCheckTask?.cancel()
        process?.terminate()
    }

    func restart() {
        stop()
        // Give the terminationHandler a moment to fire and clear `process`
        // before starting again.
        Task {
            try? await Task.sleep(for: .seconds(1))
            start()
        }
    }

    // MARK: - Login item

    /// Registers/unregisters the app as a login item via SMAppService.
    /// Reverts to the actual service status on failure (e.g. user denied
    /// it in System Settings) instead of leaving the toggle showing a
    /// state that was never actually applied.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = enabled
        } catch {
            appendLog("Failed to update Open at Login: \(error.localizedDescription)")
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Health checking

    private func beginHealthChecking() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            guard let self else { return }
            // Give the server a few seconds to actually bind its port
            // before the first check, so "starting" isn't instantly
            // reported as a failure.
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                await self.checkHealth()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func checkHealth() async {
        do {
            let (_, response) = try await URLSession.shared.data(from: healthCheckURL)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                if case .running = state { /* already running, no-op */ } else {
                    state = .running
                    appendLog("Health check passed -- server is up.")
                }
            }
        } catch {
            // Don't flip to .crashed on a single failed health check --
            // the process termination handler is the authoritative
            // source for "actually crashed." This just means "not
            // responding yet" while starting up.
        }
    }

    // MARK: - Logging

    nonisolated private func consume(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").map(String.init)
        Task { @MainActor in
            self.appendLog(contentsOf: lines)
        }
    }

    private func appendLog(_ line: String) {
        appendLog(contentsOf: [line])
    }

    private func appendLog(contentsOf lines: [String]) {
        logLines.append(contentsOf: lines)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }
}
