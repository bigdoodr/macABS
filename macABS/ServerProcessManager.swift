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

import AppKit
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

    /// Symbol for the menu bar icon itself, so the server's state is visible
    /// without opening the menu.
    var menuBarSymbolName: String {
        switch self {
        case .stopped: return "pause.circle"
        case .starting: return "arrow.triangle.2.circlepath"
        case .running: return "headphones"
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
    ///
    /// Which runtime actually launches (an updated payload in Application
    /// Support, or this bundled copy as a fallback) is decided per launch
    /// by ABSRuntime.active(); see ABSRuntime.swift / ABSUpdater.swift.
    /// Native arm64 static ffmpeg/ffprobe (see vendor-audiobookshelf.sh for
    /// why) live next to the server in whichever runtime is active, so
    /// Audiobookshelf's own BinaryManager never fetches Intel-only builds.
    /// The entry point comes from the runtime too: index.js up to v2.36,
    /// dist-server/index.js from v2.37 (server is now compiled TypeScript).

    /// Version of the runtime most recently launched (or the one that will
    /// launch next, before the first start). Shown in the menu.
    @Published private(set) var activeVersion: String = ABSRuntime.active().version
    /// The native (non-Docker) server defaults to port 3333, not 13378 --
    /// that 13378 was specifically Docker's external port mapping. Setting
    /// PORT explicitly below keeps it consistent with the port used
    /// elsewhere (e.g. if you later put this behind the same cloudflared
    /// tunnel pattern as the podcast feed).
    static let defaultPort = 13378
    private static let serverPortKey = "serverPort"
    private static let validPorts = 1024...65535 // below 1024 needs root

    /// The port the server will use on its next start. Persisted; an
    /// out-of-range stored value falls back to the default.
    @Published private(set) var serverPort: Int = ServerProcessManager.storedPort()
    /// The port the live process was actually launched with (nil when it
    /// isn't running). Health checks and the web UI URL follow this, so a
    /// port change that's waiting for a restart doesn't break them.
    @Published private(set) var runningPort: Int?

    private nonisolated static func storedPort() -> Int {
        let value = UserDefaults.standard.integer(forKey: serverPortKey)
        return validPorts.contains(value) ? value : defaultPort
    }
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

    /// The Audiobookshelf web UI. Single source of truth for the menu's
    /// "Open Web UI" button and the first-run auto-open.
    var webUIURL: URL { URL(string: "http://localhost:\(runningPort ?? serverPort)")! }

    private var healthCheckURL: URL { URL(string: "http://localhost:\(runningPort ?? serverPort)/healthcheck")! }
    // ----------------------------------------

    private var process: Process?

    // --- Automatic crash recovery ---
    /// Restart budget. Reset by a passing health check (a server that
    /// answered HTTP has proven it can run) or by a manual Start.
    private var crashRetryCount = 0
    private let maxCrashRetries = 5
    private var crashRetryTask: Task<Void, Never>?
    /// The updater sets this while it swaps versions so a crash during its
    /// own verification window is handled by its rollback, not by a retry.
    var suppressAutoRestart = false

    /// True when this launch is the first one (no database exists yet), so
    /// the web UI should open once the server is up and the user lands in
    /// Audiobookshelf's setup wizard.
    private var openWebUIWhenRunning = false
    private var healthCheckTask: Task<Void, Never>?
    private let maxLogLines = 500
    /// Set right before we call process?.terminate() so the termination
    /// handler can tell "we asked it to stop" apart from "it died on its
    /// own." Without this, a normal Stop (SIGTERM, exit code 15) gets
    /// misreported as a crash, since the handler otherwise only looks at
    /// the raw exit code.
    private var isIntentionalStop = false

    func start(isAutoRetry: Bool = false) {
        guard process == nil else { return }
        // Fail fast with a readable message instead of a Node EADDRINUSE
        // buried in the log.
        guard Self.isPortFree(serverPort) else {
            state = .crashed("port \(serverPort) in use")
            appendLog("Port \(serverPort) is already in use by another program. Pick a different port in the menu, or quit the other program and Start again.")
            return
        }
        crashRetryTask?.cancel()
        crashRetryTask = nil
        if !isAutoRetry { crashRetryCount = 0 }
        if !isAutoRetry { openWebUIWhenRunning = !hasExistingDatabase }
        isIntentionalStop = false
        state = .starting
        appendLog("Starting server…")

        let runtime = ABSRuntime.active()
        activeVersion = runtime.version
        appendLog("Using Audiobookshelf \(runtime.version) (\(runtime.isBundled ? "bundled" : "updated")).")

        let task = Process()
        task.executableURL = runtime.nodeExecutable
        task.arguments = [runtime.entry]
        task.currentDirectoryURL = runtime.workingDirectory

        // Start from the launching process's own environment (so PATH
        // etc. are intact) and layer ABS-specific config on top.
        var env = ProcessInfo.processInfo.environment
        env["PORT"] = String(serverPort)
        runningPort = serverPort
        // Audiobookshelf shows this as the install type in its web UI
        // footer and defaults to "debian", which is misleading here.
        env["SOURCE"] = "macABS"
        env["CONFIG_PATH"] = configPath
        env["METADATA_PATH"] = metadataPath
        // Point Audiobookshelf directly at the vendored arm64 ffmpeg/ffprobe
        // and skip its own BinaryManager binary check entirely -- that
        // check hard-requires a `-version` string starting with "5.1",
        // which a modern static build won't report, so leaving the check
        // enabled would cause it to consider our binaries "invalid" and
        // silently replace them with a downloaded Intel build on every
        // launch. SKIP_BINARIES_CHECK=1 trusts *_PATH as given instead.
        env["SKIP_BINARIES_CHECK"] = "1"
        env["FFMPEG_PATH"] = runtime.workingDirectory.appendingPathComponent("ffmpeg").path
        env["FFPROBE_PATH"] = runtime.workingDirectory.appendingPathComponent("ffprobe").path
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
            guard let self else { return }
            Task { @MainActor in
                self.process = nil
                self.runningPort = nil
                self.healthCheckTask?.cancel()
                if self.isIntentionalStop {
                    self.state = .stopped
                    self.appendLog("Server stopped.")
                } else if proc.terminationStatus != 0 {
                    self.state = .crashed("exit code \(proc.terminationStatus)")
                    self.appendLog("Server exited with code \(proc.terminationStatus)")
                    self.scheduleCrashRetry()
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
            runningPort = nil
            state = .crashed(error.localizedDescription)
            appendLog("Failed to launch: \(error.localizedDescription)")
        }
    }

    func stop() {
        crashRetryTask?.cancel()
        crashRetryTask = nil
        isIntentionalStop = true
        healthCheckTask?.cancel()
        process?.terminate()
    }

    /// Stops the server and suspends until the process has really exited
    /// (escalating to SIGKILL if it ignores SIGTERM), so callers can safely
    /// swap runtimes or restore config files afterwards.
    func stopAndWait(timeout: TimeInterval = 20) async {
        guard process != nil else { return }
        stop()
        let deadline = Date().addingTimeInterval(timeout)
        while process != nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if let stuck = process {
            appendLog("Server ignored SIGTERM -- sending SIGKILL.")
            kill(stuck.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(5)
            while process != nil && Date() < killDeadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// After start(): true once the health check passes, false if the
    /// process dies or the timeout elapses first.
    func waitUntilRunning(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch state {
            case .running: return true
            case .crashed, .stopped: return false
            case .starting: break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    var isRunningOrStarting: Bool {
        switch state {
        case .running, .starting: return true
        default: return false
        }
    }

    func log(_ line: String) { appendLog(line) }

    func restart() {
        stop()
        // Give the terminationHandler a moment to fire and clear `process`
        // before starting again.
        Task {
            try? await Task.sleep(for: .seconds(1))
            start()
        }
    }

    // MARK: - Port

    enum PortChangeResult: Equatable {
        case applied          // saved; nothing to restart
        case needsRestart     // saved; the running server is on the old port
        case unchanged
        case invalid
        case inUse(Int)
    }

    /// Validates, probes for conflicts, persists, and says whether a restart
    /// is needed to take effect.
    func setPort(_ port: Int) -> PortChangeResult {
        guard Self.validPorts.contains(port) else { return .invalid }
        guard port != serverPort else { return .unchanged }
        // Our own running server legitimately holds its port.
        if port != runningPort, !Self.isPortFree(port) { return .inUse(port) }
        UserDefaults.standard.set(port, forKey: Self.serverPortKey)
        serverPort = port
        if let running = runningPort, running != port { return .needsRestart }
        return .applied
    }

    /// True unless something already listens on the port. Binds the IPv4
    /// wildcard address like Node does, with SO_REUSEADDR so leftover
    /// TIME_WAIT sockets after a quick restart don't read as "in use". Only
    /// EADDRINUSE counts as a conflict; any other failure is inconclusive
    /// and never blocks the user.
    private nonisolated static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { Darwin.close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0 || errno != EADDRINUSE
    }

    // MARK: - Crash recovery

    /// Retries after an unexpected non-zero exit: 2 s, 4 s, 8 s, 16 s, 32 s,
    /// then gives up (a human is needed). Stop / Quit / a manual Start cancel
    /// a pending retry, and every retry goes through the normal start() path.
    private func scheduleCrashRetry() {
        guard !suppressAutoRestart else { return }
        guard crashRetryCount < maxCrashRetries else {
            appendLog("Not auto-restarting after \(maxCrashRetries) attempts -- check the log, fix the cause, and start manually.")
            return
        }
        crashRetryCount += 1
        let delay = min(1 << crashRetryCount, 60)
        appendLog("Auto-restarting in \(delay)s (attempt \(crashRetryCount)/\(maxCrashRetries))…")
        crashRetryTask?.cancel()
        crashRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.start(isAutoRetry: true)
        }
    }

    // MARK: - First run

    /// Audiobookshelf creates its SQLite database on first start, so no
    /// *.sqlite file in config/ means nothing has been set up yet.
    private var hasExistingDatabase: Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: configPath)) ?? []
        return files.contains { $0.hasSuffix(".sqlite") }
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
                    crashRetryCount = 0
                    appendLog("Health check passed -- server is up.")
                    if openWebUIWhenRunning {
                        openWebUIWhenRunning = false
                        NSWorkspace.shared.open(webUIURL)
                    }
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
