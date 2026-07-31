import AppKit
import Foundation
import GRDB

/// Reads macOS's own app-usage from the private knowledgeC database
/// (`/app/usage` stream) — the same data Screen Time uses, so it reflects
/// real activity for the whole day, not just time since Clem launched.
/// Requires Full Disk Access; returns [] (caller falls back) without it.
enum ScreenTimeReader {
    private static var dbPath: String {
        NSHomeDirectory() + "/Library/Application Support/Knowledge/knowledgeC.db"
    }

    private static var cache: [(bundle: String, seconds: Double)] = []
    private static var cacheTime: Date?
    private static var nameCache: [String: String] = [:]

    /// Is the DB reachable (Full Disk Access granted)?
    static var available: Bool { FileManager.default.isReadableFile(atPath: dbPath) }

    /// Per-app seconds for today, keyed by bundle id. Cached for 60s.
    static func todayUsageRaw() -> [(bundle: String, seconds: Double)] {
        if let t = cacheTime, Date().timeIntervalSince(t) < 60 { return cache }
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: dbPath) else { return [] }

        // Work on a copy — the live DB uses WAL and may be locked.
        let tmp = fm.temporaryDirectory.appendingPathComponent("clem-kc.db")
        try? fm.removeItem(at: tmp)
        do {
            try fm.copyItem(atPath: dbPath, toPath: tmp.path)
            for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: dbPath + suffix) {
                try? fm.removeItem(atPath: tmp.path + suffix)
                try? fm.copyItem(atPath: dbPath + suffix, toPath: tmp.path + suffix)
            }
            var config = Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: tmp.path, configuration: config)
            // knowledgeC timestamps are seconds since 2001-01-01 (Cocoa epoch).
            let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate
            let rows = try queue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT ZVALUESTRING AS bundle, SUM(ZENDDATE - ZSTARTDATE) AS secs
                    FROM ZOBJECT
                    WHERE ZSTREAMNAME = '/app/usage'
                      AND ZENDDATE >= ?
                      AND ZVALUESTRING IS NOT NULL
                    GROUP BY ZVALUESTRING
                    HAVING secs > 0
                    ORDER BY secs DESC
                    """, arguments: [startOfDay])
            }
            let result = rows.compactMap { row -> (String, Double)? in
                guard let b: String = row["bundle"], let s: Double = row["secs"] else { return nil }
                return (b, s)
            }
            try? fm.removeItem(at: tmp)
            cache = result
            cacheTime = Date()
            return result
        } catch {
            try? fm.removeItem(at: tmp)
            return []
        }
    }

    /// Whole-day per-app usage as display-name spans (merged across bundles),
    /// sorted busiest first. Empty without Full Disk Access.
    static func todayByApp() -> [AppSpan] {
        let raw = todayUsageRaw()
        guard !raw.isEmpty else { return [] }
        var byName: [String: Double] = [:]
        for r in raw { byName[name(for: r.bundle), default: 0] += r.seconds }
        return byName.map { AppSpan(app: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
    }

    /// Friendly app name for a bundle id (cached).
    static func name(for bundle: String) -> String {
        if let c = nameCache[bundle] { return c }
        var name = bundle.components(separatedBy: ".").last ?? bundle
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            let display = FileManager.default.displayName(atPath: url.path)
            if !display.isEmpty { name = display.replacingOccurrences(of: ".app", with: "") }
        }
        nameCache[bundle] = name
        return name
    }
}
