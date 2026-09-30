//
//  ABSUpdater.swift
//
//  Keeps the Audiobookshelf server itself current WITHOUT shipping a new
//  macABS build. A GitHub Actions workflow in this repo
//  (.github/workflows/abs-payload.yml) watches upstream Audiobookshelf
//  releases, builds + smoke-tests an Apple Silicon "payload" for each
//  (Node runtime + server + client + ffmpeg -- the same layout as
//  vendor-audiobookshelf.sh) and publishes it as a release tagged
//  "abs-vX.Y.Z" with a manifest.json.
//
//  This class polls those releases and, when a newer one appears:
//    1. downloads the payload and verifies its SHA-256 against the manifest
//    2. unpacks it beside the current version (nothing is overwritten)
//    3. stops the server and backs up config/ (the SQLite database -- the
//       only thing an Audiobookshelf upgrade can migrate one-way)
//    4. points the app at the new version and starts it
//    5. requires /healthcheck to pass AND the process to still be alive
//       after a stability window; otherwise it restores the config backup,
//       switches back to the previous version, and marks the new tag "bad"
//       so it is never retried.
//
//  Updates apply automatically -- there is no prompt. Only a payload that
//  passed CI's own launch test is ever published, and a failed local launch
//  rolls back, but a bug that only shows up later (after the stability
//  window) is not caught here.
//

import CryptoKit
import Foundation

@MainActor
final class ABSUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case downloading(String)
        case installing(String)
        case verifying(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusLine: String

    var isBusy: Bool { phase != .idle }

    // MARK: Configuration

    private let releasesURL = URL(string: "https://api.github.com/repos/bigdoodr/macABS/releases?per_page=50")!
    private let tagPrefix = "abs-"
    private let supportedManifestFormat = 1
    private let checkInterval: TimeInterval = 6 * 3600
    private let startupDelay: TimeInterval = 45
    private let verifyTimeout: TimeInterval = 120
    private let stabilityWindow: TimeInterval = 45
    private let backupsToKeep = 3

    private let server: ServerProcessManager
    private var loopTask: Task<Void, Never>?

    init(server: ServerProcessManager) {
        self.server = server
        self.statusLine = ABSRuntime.loadState().lastResult ?? ""
    }

    // MARK: - Scheduling

    /// Checks shortly after launch, then every few hours while the app runs.
    func startAutomaticChecks() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.startupDelay))
            while !Task.isCancelled {
                await self.checkNow()
                try? await Task.sleep(for: .seconds(self.checkInterval))
            }
        }
    }

    // MARK: - Manifest / release models

    private struct GHRelease: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [GHAsset]
    }

    private struct GHAsset: Decodable {
        let name: String
        let browser_download_url: URL
    }

    private struct PayloadManifest: Decodable {
        let format: Int
        let abs_version: String
        let node_version: String
        let arch: String
        let asset: String
        let sha256: String
    }

    private nonisolated enum UpdateError: LocalizedError {
        case http(Int)
        case badManifest(String)
        case checksumMismatch
        case commandFailed(String)
        case incompletePayload
        case backupFailed(String)

        var errorDescription: String? {
            switch self {
            case .http(let code): return "HTTP \(code)"
            case .badManifest(let why): return "unusable manifest (\(why))"
            case .checksumMismatch: return "download failed checksum verification"
            case .commandFailed(let why): return "unpack failed (\(why))"
            case .incompletePayload: return "payload is missing node or the server entry point"
            case .backupFailed(let why): return "could not back up config (\(why))"
            }
        }
    }

    // MARK: - Check + apply

    func checkNow() async {
        guard !isBusy else { return }
        phase = .checking
        defer { phase = .idle }

        var state = ABSRuntime.loadState()
        state.lastCheck = Date()
        ABSRuntime.saveState(state)

        do {
            try await performCheck()
        } catch {
            let message = "Update check failed: \(error.localizedDescription)"
            server.log(message)
            record(message)
        }
    }

    private func performCheck() async throws {
        let installed = ABSRuntime.active().version

        let (listData, listResponse) = try await URLSession.shared.data(from: releasesURL)
        if let http = listResponse as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.http(http.statusCode)
        }
        let releases = try JSONDecoder().decode([GHRelease].self, from: listData)

        // Highest abs-vX.Y.Z among published, non-prerelease releases.
        var best: (version: String, release: GHRelease)?
        for release in releases where !release.draft && !release.prerelease && release.tag_name.hasPrefix(tagPrefix) {
            let version = String(release.tag_name.dropFirst(tagPrefix.count))
            guard ABSRuntime.compare(version, "v0") != nil else { continue }
            if let current = best, ABSRuntime.compare(version, current.version) != .orderedDescending { continue }
            best = (version, release)
        }

        guard let candidate = best else {
            record("No Audiobookshelf payloads published yet. Running \(installed).")
            return
        }

        guard ABSRuntime.compare(candidate.version, installed) == .orderedDescending else {
            record("Audiobookshelf \(installed) is up to date.")
            return
        }

        if ABSRuntime.loadState().bad.contains(candidate.version) {
            record("Skipping \(candidate.version): it failed to start here and was rolled back. Running \(installed).")
            return
        }

        guard let manifestAsset = candidate.release.assets.first(where: { $0.name == "manifest.json" }) else {
            throw UpdateError.badManifest("no manifest.json on release \(candidate.release.tag_name)")
        }
        let (manifestData, _) = try await URLSession.shared.data(from: manifestAsset.browser_download_url)
        let manifest = try JSONDecoder().decode(PayloadManifest.self, from: manifestData)

        guard manifest.format == supportedManifestFormat else {
            throw UpdateError.badManifest("format \(manifest.format) needs a newer macABS")
        }
        guard manifest.arch == "darwin-arm64" else { throw UpdateError.badManifest("arch \(manifest.arch)") }
        guard manifest.abs_version == candidate.version else {
            throw UpdateError.badManifest("manifest is for \(manifest.abs_version), release is \(candidate.version)")
        }
        guard let payloadAsset = candidate.release.assets.first(where: { $0.name == manifest.asset }) else {
            throw UpdateError.badManifest("asset \(manifest.asset) not found")
        }

        try await apply(candidate.version, manifest: manifest, payload: payloadAsset, from: installed)
    }

    private func apply(_ version: String, manifest: PayloadManifest, payload: GHAsset, from installedVersion: String) async throws {
        let fm = FileManager.default
        let wasRunning = server.isRunningOrStarting
        let versions = ABSRuntime.versionsDirectory
        let staging = versions.appendingPathComponent(".staging-\(version)", isDirectory: true)
        let destination = versions.appendingPathComponent(version, isDirectory: true)

        // 1. Download (the running server is untouched until step 3).
        phase = .downloading(version)
        server.log("Updating Audiobookshelf \(installedVersion) → \(version) (Node \(manifest.node_version))…")
        record("Downloading Audiobookshelf \(version)…", persist: false)
        let (downloaded, response) = try await URLSession.shared.download(from: payload.browser_download_url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.http(http.statusCode)
        }

        // 2. Verify + unpack next to the current version.
        phase = .installing(version)
        record("Installing Audiobookshelf \(version)…", persist: false)
        try fm.createDirectory(at: versions, withIntermediateDirectories: true)
        let expectedSHA = manifest.sha256
        do {
            try await Task.detached(priority: .utility) {
                try Self.verifyAndUnpack(archive: downloaded, expectedSHA256: expectedSHA, into: staging)
            }.value
        } catch {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: downloaded)
            throw error
        }
        try? fm.removeItem(at: downloaded)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: staging, to: destination)
        guard ABSRuntime.installed(tag: version) != nil else {
            try? fm.removeItem(at: destination)
            throw UpdateError.incompletePayload
        }

        // 3. Stop the server and back up its database.
        phase = .verifying(version)
        record("Restarting on Audiobookshelf \(version)…", persist: false)
        await server.stopAndWait()

        let backup: URL
        do {
            backup = try backUpConfig(labelled: installedVersion)
        } catch {
            // Nothing has been switched yet -- just bring the old version back.
            try? fm.removeItem(at: destination)
            if wasRunning { server.start() }
            throw error
        }

        // 4. Switch and launch.
        var state = ABSRuntime.loadState()
        let before = state
        state.previous = state.current
        state.current = version
        ABSRuntime.saveState(state)

        server.start()
        var healthy = await server.waitUntilRunning(timeout: verifyTimeout)
        if healthy {
            // A server that answers /healthcheck and then dies (a crash on
            // first library scan, a migration bug) still counts as failed.
            try? await Task.sleep(for: .seconds(stabilityWindow))
            if case .running = server.state { healthy = true } else { healthy = false }
        }

        if healthy {
            prune(keeping: [state.current, state.previous])
            if !wasRunning { await server.stopAndWait() }
            let message = "Updated Audiobookshelf \(installedVersion) → \(version)."
            server.log(message)
            record(message)
            return
        }

        // 5. Roll back.
        server.log("Audiobookshelf \(version) did not stay up -- rolling back to \(installedVersion).")
        await server.stopAndWait()
        restoreConfig(from: backup)
        var restored = before
        restored.bad.append(version)
        ABSRuntime.saveState(restored)
        try? fm.removeItem(at: destination)

        server.start()
        let recovered = await server.waitUntilRunning(timeout: verifyTimeout)
        if !wasRunning { await server.stopAndWait() }

        let message = recovered
            ? "Audiobookshelf \(version) failed to start and was rolled back to \(installedVersion). It won't be retried."
            : "Audiobookshelf \(version) failed and \(installedVersion) also won't start after rollback -- see View Logs."
        server.log(message)
        record(message)
    }

    // MARK: - Files

    /// Off the main actor: hashes the archive, then unpacks it with tar.
    private nonisolated static func verifyAndUnpack(archive: URL, expectedSHA256: String, into staging: URL) throws {
        let fm = FileManager.default

        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256.lowercased() else { throw UpdateError.checksumMismatch }

        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try run("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path])
        // URLSession downloads aren't quarantined, but be certain: a
        // quarantined node would be blocked by Gatekeeper on first launch.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging.path])
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let text = String(data: errorData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw UpdateError.commandFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Copies config/ (SQLite database + settings) to backups/. The server
    /// must already be stopped so the database files are consistent.
    private func backUpConfig(labelled version: String) throws -> URL {
        let fm = FileManager.default
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let backup = ABSRuntime.backupsDirectory
            .appendingPathComponent("config-\(stamp.string(from: Date()))-\(version)", isDirectory: true)
        do {
            try fm.createDirectory(at: ABSRuntime.backupsDirectory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: ABSRuntime.configDirectory.path) {
                try fm.copyItem(at: ABSRuntime.configDirectory, to: backup)
            } else {
                try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            }
        } catch {
            throw UpdateError.backupFailed(error.localizedDescription)
        }
        return backup
    }

    private func restoreConfig(from backup: URL) {
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: ABSRuntime.configDirectory)
            try fm.copyItem(at: backup, to: ABSRuntime.configDirectory)
            server.log("Restored config from \(backup.lastPathComponent).")
        } catch {
            server.log("Could not restore config backup: \(error.localizedDescription). Backup is still at \(backup.path).")
        }
    }

    /// Keeps the versions in use (and the newest few config backups).
    private func prune(keeping keep: [String?]) {
        let fm = FileManager.default
        let keepNames = Set(keep.compactMap { $0 })
        if let entries = try? fm.contentsOfDirectory(atPath: ABSRuntime.versionsDirectory.path) {
            for name in entries where !keepNames.contains(name) {
                try? fm.removeItem(at: ABSRuntime.versionsDirectory.appendingPathComponent(name))
            }
        }
        if let backups = try? fm.contentsOfDirectory(atPath: ABSRuntime.backupsDirectory.path) {
            // Names start with a sortable timestamp, so lexicographic == chronological.
            for name in backups.sorted().dropLast(backupsToKeep) {
                try? fm.removeItem(at: ABSRuntime.backupsDirectory.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Status

    /// `persist` writes the message to the state file so the menu can show
    /// the last outcome after a relaunch; progress messages aren't persisted.
    private func record(_ message: String, persist: Bool = true) {
        statusLine = message
        guard persist else { return }
        var state = ABSRuntime.loadState()
        state.lastResult = message
        ABSRuntime.saveState(state)
    }
}
