//
//  ABSRuntime.swift
//
//  Decides WHICH Audiobookshelf runtime the app launches: a downloaded
//  payload installed under Application Support (written by ABSUpdater), or
//  the copy bundled inside the .app as a fallback.
//
//  A "payload" is exactly the layout vendor-audiobookshelf.sh produces:
//      <root>/node/bin/node
//      <root>/audiobookshelf/...   (server, client/dist, node_modules,
//                                   ffmpeg, ffprobe, macabs-payload.json)
//  so the bundled copy (Contents/Resources) and a downloaded copy
//  (Application Support/<bundle id>/versions/<tag>) look identical to the
//  rest of the app. The payload carries its OWN Node, so an Audiobookshelf
//  release that needs a newer Node major (v2.37.0 moved to Node 24) updates
//  without a macABS rebuild.
//

import Foundation

/// Written into <root>/audiobookshelf/macabs-payload.json by the vendor
/// script. Absent in older bundles, in which case defaults apply.
struct ABSPayloadInfo: Codable {
    var absVersion: String   // e.g. "v2.37.1"
    var nodeVersion: String  // e.g. "v24.21.0"
    var entry: String        // "index.js" (<= 2.36) or "dist-server/index.js" (>= 2.37)

    enum CodingKeys: String, CodingKey {
        case absVersion = "abs_version"
        case nodeVersion = "node_version"
        case entry
    }
}

/// Persisted updater state. `nil` for current/previous means "the copy
/// bundled inside the app".
struct ABSRuntimeState: Codable {
    var current: String?
    var previous: String?
    /// Tags that failed verification and were rolled back. Never retried,
    /// so a broken release can't cause an update/rollback loop.
    var bad: [String] = []
    var lastCheck: Date?
    var lastResult: String?
}

struct ABSResolvedRuntime {
    let root: URL
    let version: String
    let entry: String
    let isBundled: Bool

    var workingDirectory: URL { root.appendingPathComponent("audiobookshelf", isDirectory: true) }
    var nodeExecutable: URL { root.appendingPathComponent("node/bin/node") }
}

enum ABSRuntime {
    // MARK: - Locations

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Audiobookshelf", isDirectory: true)
    }
    static var versionsDirectory: URL { supportDirectory.appendingPathComponent("versions", isDirectory: true) }
    static var backupsDirectory: URL { supportDirectory.appendingPathComponent("backups", isDirectory: true) }
    static var configDirectory: URL { supportDirectory.appendingPathComponent("config", isDirectory: true) }
    private static var stateURL: URL { supportDirectory.appendingPathComponent("runtime-state.json") }

    // MARK: - State

    static func loadState() -> ABSRuntimeState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(ABSRuntimeState.self, from: data)
        else { return ABSRuntimeState() }
        return state
    }

    static func saveState(_ state: ABSRuntimeState) {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: - Resolution

    static func readPayloadInfo(at root: URL) -> ABSPayloadInfo? {
        let url = root.appendingPathComponent("audiobookshelf/macabs-payload.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ABSPayloadInfo.self, from: data)
    }

    /// Reads "version" out of audiobookshelf/package.json as "vX.Y.Z".
    private static func packageVersion(at root: URL) -> String? {
        let url = root.appendingPathComponent("audiobookshelf/package.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String
        else { return nil }
        return "v" + version
    }

    private static func describe(root: URL, tagHint: String?, isBundled: Bool) -> ABSResolvedRuntime {
        let info = readPayloadInfo(at: root)
        let version = info?.absVersion ?? packageVersion(at: root) ?? tagHint ?? "unknown"
        return ABSResolvedRuntime(root: root, version: version, entry: info?.entry ?? "index.js", isBundled: isBundled)
    }

    static func bundled() -> ABSResolvedRuntime {
        describe(root: Bundle.main.resourceURL!, tagHint: nil, isBundled: true)
    }

    /// The runtime to launch right now: the installed payload named by
    /// state.current if it is intact, otherwise the bundled copy.
    static func active() -> ABSResolvedRuntime {
        if let tag = loadState().current, let installed = installed(tag: tag) {
            return installed
        }
        return bundled()
    }

    static func installed(tag: String) -> ABSResolvedRuntime? {
        let root = versionsDirectory.appendingPathComponent(tag, isDirectory: true)
        let resolved = describe(root: root, tagHint: tag, isBundled: false)
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: resolved.nodeExecutable.path),
              fm.fileExists(atPath: resolved.workingDirectory.appendingPathComponent(resolved.entry).path)
        else { return nil }
        return resolved
    }

    // MARK: - Versions

    /// Numeric compare of "vX.Y.Z" strings. Returns nil if either is unparseable.
    static func compare(_ a: String, _ b: String) -> ComparisonResult? {
        func parts(_ s: String) -> [Int]? {
            let trimmed = s.hasPrefix("v") ? String(s.dropFirst()) : s
            let nums = trimmed.split(separator: ".").map { Int($0) }
            return nums.contains(where: { $0 == nil }) || nums.isEmpty ? nil : nums.map { $0! }
        }
        guard let pa = parts(a), let pb = parts(b) else { return nil }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
