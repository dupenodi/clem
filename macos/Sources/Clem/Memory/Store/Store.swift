import Foundation
import GRDB

struct FrameRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "frames"
    var id: Int64? // nil until inserted — GRDB assigns the rowid
    var capturedAt: Date
    var lastSeenAt: Date
    var appBundleID: String
    var appName: String
    var windowTitle: String
    var url: String?
    var phash: Int64
    var ocrText: String
    var thumbPath: String?
    var supermemoryDocID: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct AppSpan: Identifiable, Equatable {
    var app: String
    var seconds: Double
    var id: String { app }
}

struct DayStats {
    var captured = 0
    var deduped = 0
    var kept = 0
    var blocked = 0
    var dedupeRate: Double {
        captured > 0 ? Double(deduped) / Double(captured) : 0
    }
}

actor Store {
    static let shared = Store()

    nonisolated static var dataDir: URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let clem = support.appendingPathComponent("Clem", isDirectory: true)
        let legacy = support.appendingPathComponent("Recall", isDirectory: true)
        if !fm.fileExists(atPath: clem.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: clem)
        }
        try? fm.createDirectory(at: clem, withIntermediateDirectories: true)
        let db = clem.appendingPathComponent("clem.sqlite")
        let legacyDB = clem.appendingPathComponent("recall.sqlite")
        if !fm.fileExists(atPath: db.path), fm.fileExists(atPath: legacyDB.path) {
            try? fm.moveItem(at: legacyDB, to: db)
        }
        return clem
    }

    private var dbQueue: DatabaseQueue!

    init() {
        do {
            let path = Store.dataDir.appendingPathComponent("clem.sqlite").path
            var config = Configuration()
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode=WAL")
                try db.execute(sql: "PRAGMA busy_timeout=5000")
                try db.execute(sql: "PRAGMA foreign_keys=ON")
            }
            dbQueue = try DatabaseQueue(path: path, configuration: config)
            try Self.runMigrations(on: dbQueue)
        } catch {
            fatalError("Clem could not open its database: \(error)")
        }
    }

    nonisolated private static func runMigrations(on dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "frames") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("capturedAt", .datetime).notNull().indexed()
                t.column("lastSeenAt", .datetime).notNull()
                t.column("appBundleID", .text).notNull().indexed()
                t.column("appName", .text).notNull()
                t.column("windowTitle", .text).notNull()
                t.column("url", .text)
                t.column("phash", .integer).notNull()
                t.column("ocrText", .text).notNull()
                t.column("thumbPath", .text)
                t.column("supermemoryDocID", .text)
            }
            try db.create(table: "pending_memories") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("frameID", .integer).notNull().references("frames", onDelete: .cascade)
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "day_stats") { t in
                t.column("day", .text).primaryKey()
                t.column("captured", .integer).notNull().defaults(to: 0)
                t.column("deduped", .integer).notNull().defaults(to: 0)
                t.column("kept", .integer).notNull().defaults(to: 0)
                t.column("blocked", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("v2-graph-cache") { db in
            try db.create(table: "graph_edges") { t in
                t.column("cacheKey", .text).primaryKey()
                t.column("neighbors", .text).notNull() // JSON [{id, score}]
            }
        }
        migrator.registerMigration("v3-sessions") { db in
            try db.create(table: "pending_sessions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("frameIDs", .text).notNull() // JSON [Int64]
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v4-app-time") { db in
            try db.create(table: "app_time") { t in
                t.column("day", .text).notNull()
                t.column("app", .text).notNull()
                t.column("seconds", .double).notNull().defaults(to: 0)
                t.primaryKey(["day", "app"])
            }
        }
        migrator.registerMigration("v5-focus-segments") { db in
            // Timeline of contiguous foreground segments (app or site label) —
            // the raw material for distraction analysis. app_time keeps the
            // daily totals; this keeps the ORDER and timing of switches.
            try db.create(table: "focus_segments") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("day", .text).notNull().indexed()
                t.column("app", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime).notNull()
            }
        }
        try migrator.migrate(dbQueue)
    }

    private static func todayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: frames

    func insertFrame(_ frame: FrameRecord) throws -> FrameRecord {
        var f = frame
        try dbQueue.write { db in
            try f.insert(db)
        }
        return f
    }

    func lastFrame() -> FrameRecord? {
        try? dbQueue.read { db in
            try FrameRecord.order(Column("id").desc).fetchOne(db)
        }
    }

    func touchLastSeen(frameID: Int64) {
        try? dbQueue.write { db in
            try db.execute(sql: "UPDATE frames SET lastSeenAt = ? WHERE id = ?", arguments: [Date(), frameID])
        }
    }

    func frameCount() -> Int {
        (try? dbQueue.read { db in try FrameRecord.fetchCount(db) }) ?? 0
    }

    func containsApp(nameLike pattern: String) -> Bool {
        let count = (try? dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM frames WHERE appName LIKE ? OR appBundleID LIKE ? OR windowTitle LIKE ?",
                arguments: ["%\(pattern)%", "%\(pattern)%", "%\(pattern)%"]
            )
        }) ?? 0
        return count > 0
    }

    // MARK: pending queue

    struct PendingItem {
        var id: Int64
        var frameID: Int64
        var attempts: Int
    }

    func enqueuePending(frameID: Int64) {
        try? dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO pending_memories (frameID, attempts, createdAt) VALUES (?, 0, ?)",
                arguments: [frameID, Date()]
            )
        }
    }

    /// Oldest items whose exponential backoff has elapsed (2^attempts minutes).
    func duePending(limit: Int) -> [PendingItem] {
        (try? dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, frameID, attempts, createdAt FROM pending_memories
                WHERE attempts < 10
                ORDER BY id ASC LIMIT 50
                """
            )
            let now = Date()
            return rows.compactMap { row -> PendingItem? in
                let attempts: Int = row["attempts"] ?? 0
                let created: Date = row["createdAt"] ?? now
                let nextTry = created.addingTimeInterval(pow(2, Double(attempts)) * 60 - 60)
                guard attempts == 0 || nextTry < now else { return nil }
                return PendingItem(id: row["id"] ?? 0, frameID: row["frameID"] ?? 0, attempts: attempts)
            }
            .prefix(limit)
            .map { $0 }
        }) ?? []
    }

    func deletePending(id: Int64) {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pending_memories WHERE id = ?", arguments: [id])
        }
    }

    func bumpAttempts(pendingID: Int64) {
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE pending_memories SET attempts = attempts + 1, createdAt = ? WHERE id = ?",
                arguments: [Date(), pendingID]
            )
        }
    }

    func pendingCount() -> Int {
        (try? dbQueue.read { db in
            let legacy = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_memories WHERE attempts < 10") ?? 0
            let sessions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_sessions WHERE attempts < 8") ?? 0
            return legacy + sessions
        }) ?? 0
    }

    func deadLetterCount() -> Int {
        (try? dbQueue.read { db in
            let legacy = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_memories WHERE attempts >= 10") ?? 0
            let sessions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_sessions WHERE attempts >= 8") ?? 0
            return legacy + sessions
        }) ?? 0
    }

    func frame(id: Int64) -> FrameRecord? {
        try? dbQueue.read { db in
            try FrameRecord.fetchOne(db, key: id)
        }
    }

    func markIngested(frameID: Int64, docID: String) {
        try? dbQueue.write { db in
            try db.execute(sql: "UPDATE frames SET supermemoryDocID = ? WHERE id = ?", arguments: [docID, frameID])
        }
    }

    // MARK: stats

    func bumpStat(_ key: WritableKeyPath<DayStats, Int>) {
        let column: String
        switch key {
        case \DayStats.captured: column = "captured"
        case \DayStats.deduped: column = "deduped"
        case \DayStats.kept: column = "kept"
        case \DayStats.blocked: column = "blocked"
        default: return
        }
        let day = Store.todayKey()
        try? dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO day_stats (day, \(column)) VALUES (?, 1)
                ON CONFLICT(day) DO UPDATE SET \(column) = \(column) + 1
                """,
                arguments: [day]
            )
        }
    }

    func todayStats() -> DayStats {
        let day = Store.todayKey()
        return (try? dbQueue.read { db -> DayStats in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM day_stats WHERE day = ?", arguments: [day]) else {
                return DayStats()
            }
            return DayStats(
                captured: row["captured"] ?? 0,
                deduped: row["deduped"] ?? 0,
                kept: row["kept"] ?? 0,
                blocked: row["blocked"] ?? 0
            )
        }) ?? DayStats()
    }

    // MARK: timeline

    func frames(onDay day: Date) -> [FrameRecord] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        return (try? dbQueue.read { db in
            try FrameRecord
                .filter(Column("capturedAt") >= start && Column("capturedAt") < end)
                .order(Column("capturedAt").asc)
                .fetchAll(db)
        }) ?? []
    }

    func daysWithFrames(limit: Int = 60) -> [Date] {
        (try? dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT DISTINCT date(capturedAt) AS d FROM frames ORDER BY d DESC LIMIT ?",
                arguments: [limit]
            )
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return rows.compactMap { f.date(from: $0["d"] ?? "") }
        }) ?? []
    }

    func pruneThumbnails(olderThanDays days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let old: [FrameRecord] = (try? dbQueue.read { db in
            try FrameRecord
                .filter(Column("capturedAt") < cutoff && Column("thumbPath") != nil)
                .fetchAll(db)
        }) ?? []
        for frame in old {
            if let thumb = frame.thumbPath {
                try? FileManager.default.removeItem(at: Thumbnailer.thumbsDir.appendingPathComponent(thumb))
            }
        }
        try? dbQueue.write { db in
            try db.execute(sql: "UPDATE frames SET thumbPath = NULL WHERE capturedAt < ?", arguments: [cutoff])
        }
    }

    func pruneFocusSegments(olderThanDays days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM focus_segments WHERE endedAt < ?", arguments: [cutoff])
            try db.execute(
                sql: "DELETE FROM app_time WHERE day < ?",
                arguments: [Store.dayKey(for: cutoff)]
            )
        }
    }

    private static func dayKey(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: session queue (one memory per app-session, not per frame)

    struct PendingSession {
        var id: Int64
        var frameIDs: [Int64]
        var attempts: Int
    }

    func enqueueSession(frameIDs: [Int64]) {
        guard !frameIDs.isEmpty, let json = try? JSONEncoder().encode(frameIDs) else { return }
        try? dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO pending_sessions (frameIDs, attempts, createdAt) VALUES (?, 0, ?)",
                arguments: [String(data: json, encoding: .utf8), Date()]
            )
        }
    }

    func dueSessions(limit: Int) -> [PendingSession] {
        (try? dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, frameIDs, attempts, createdAt FROM pending_sessions WHERE attempts < 8 ORDER BY id ASC LIMIT 20"
            )
            let now = Date()
            return rows.compactMap { row -> PendingSession? in
                let attempts: Int = row["attempts"] ?? 0
                let created: Date = row["createdAt"] ?? now
                let nextTry = created.addingTimeInterval(pow(2, Double(attempts)) * 60 - 60)
                guard attempts == 0 || nextTry < now else { return nil }
                let ids = (try? JSONDecoder().decode([Int64].self, from: Data((row["frameIDs"] as String? ?? "[]").utf8))) ?? []
                return PendingSession(id: row["id"] ?? 0, frameIDs: ids, attempts: attempts)
            }
            .prefix(limit)
            .map { $0 }
        }) ?? []
    }

    func deleteSession(id: Int64) {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pending_sessions WHERE id = ?", arguments: [id])
        }
    }

    func bumpSessionAttempts(id: Int64) {
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE pending_sessions SET attempts = attempts + 1, createdAt = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }

    func sessionCount() -> Int {
        (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_sessions") ?? 0
        }) ?? 0
    }

    func frames(ids: [Int64]) -> [FrameRecord] {
        (try? dbQueue.read { db in
            try FrameRecord.filter(ids.contains(Column("id"))).order(Column("capturedAt").asc).fetchAll(db)
        }) ?? []
    }

    // MARK: graph edge cache

    func cachedNeighbors(key: String) -> [GraphService.Neighbor]? {
        guard let json: String = try? dbQueue.read({ db in
            try String.fetchOne(db, sql: "SELECT neighbors FROM graph_edges WHERE cacheKey = ?", arguments: [key])
        }) ?? nil else { return nil }
        return try? JSONDecoder().decode([GraphService.Neighbor].self, from: Data(json.utf8))
    }

    func cacheNeighbors(key: String, neighbors: [GraphService.Neighbor]) {
        guard let data = try? JSONEncoder().encode(neighbors) else { return }
        try? dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO graph_edges (cacheKey, neighbors) VALUES (?, ?)",
                arguments: [key, String(data: data, encoding: .utf8)]
            )
        }
    }

    // MARK: export & forget

    func exportJSONL(to url: URL) throws {
        let frames: [FrameRecord] = (try? dbQueue.read { db in
            try FrameRecord.order(Column("id").asc).fetchAll(db)
        }) ?? []
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var out = Data()
        for frame in frames {
            out.append(try encoder.encode(frame))
            out.append(0x0A)
        }
        try out.write(to: url)
    }

    func forgetFrames(from: Date, to: Date) -> [String] {
        let victims: [FrameRecord] = (try? dbQueue.read { db in
            try FrameRecord
                .filter(Column("capturedAt") >= from && Column("capturedAt") <= to)
                .fetchAll(db)
        }) ?? []
        let victimIDs = Set(victims.compactMap(\.id))
        for v in victims {
            if let thumb = v.thumbPath {
                try? FileManager.default.removeItem(at: Thumbnailer.thumbsDir.appendingPathComponent(thumb))
            }
        }
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM frames WHERE capturedAt >= ? AND capturedAt <= ?", arguments: [from, to])
            try db.execute(sql: "DELETE FROM pending_memories WHERE frameID NOT IN (SELECT id FROM frames)")
            let sessions = try Row.fetchAll(db, sql: "SELECT id, frameIDs FROM pending_sessions")
            for row in sessions {
                let id: Int64 = row["id"] ?? 0
                let raw: String = row["frameIDs"] ?? "[]"
                let ids = (try? JSONDecoder().decode([Int64].self, from: Data(raw.utf8))) ?? []
                let remaining = ids.filter { !victimIDs.contains($0) }
                if remaining.isEmpty {
                    try db.execute(sql: "DELETE FROM pending_sessions WHERE id = ?", arguments: [id])
                } else if remaining.count != ids.count, let json = try? JSONEncoder().encode(remaining),
                          let s = String(data: json, encoding: .utf8) {
                    try db.execute(sql: "UPDATE pending_sessions SET frameIDs = ? WHERE id = ?", arguments: [s, id])
                }
            }
        }
        return victims.compactMap(\.supermemoryDocID)
    }

    // MARK: per-app time

    func addAppTime(app: String, seconds: Double) {
        let day = Store.todayKey()
        try? dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO app_time (day, app, seconds) VALUES (?, ?, ?)
                ON CONFLICT(day, app) DO UPDATE SET seconds = seconds + ?
                """,
                arguments: [day, app, seconds, seconds]
            )
        }
    }

    func todayAppTime() -> [AppSpan] {
        let day = Store.todayKey()
        return (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT app, seconds FROM app_time WHERE day = ? ORDER BY seconds DESC", arguments: [day])
                .map { AppSpan(app: $0["app"] ?? "?", seconds: $0["seconds"] ?? 0) }
        }) ?? []
    }

    // MARK: focus segments (attention timeline)

    /// Open a new foreground segment; returns its row id so the tracker can
    /// keep extending it while the same app/site stays in front.
    func openFocusSegment(app: String, at date: Date) -> Int64? {
        let day = Store.todayKey()
        return try? dbQueue.write { db -> Int64 in
            try db.execute(
                sql: "INSERT INTO focus_segments (day, app, startedAt, endedAt) VALUES (?, ?, ?, ?)",
                arguments: [day, app, date, date]
            )
            return db.lastInsertedRowID
        }
    }

    func extendFocusSegment(id: Int64, to date: Date) {
        try? dbQueue.write { db in
            try db.execute(sql: "UPDATE focus_segments SET endedAt = ? WHERE id = ?", arguments: [date, id])
        }
    }

    func todayFocusSegments() -> [FocusSegment] {
        let day = Store.todayKey()
        return (try? dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT app, startedAt, endedAt FROM focus_segments WHERE day = ? ORDER BY startedAt ASC",
                arguments: [day]
            ).compactMap { row -> FocusSegment? in
                guard let app: String = row["app"],
                      let start: Date = row["startedAt"],
                      let end: Date = row["endedAt"] else { return nil }
                return FocusSegment(app: app, startedAt: start, endedAt: end)
            }
        }) ?? []
    }

    /// Segments for the last N days (today included), oldest first — the
    /// material for cross-day habit detection.
    func focusSegments(daysBack: Int) -> [FocusSegment] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -daysBack, to: Calendar.current.startOfDay(for: Date()))!
        return (try? dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT app, startedAt, endedAt FROM focus_segments WHERE startedAt >= ? ORDER BY startedAt ASC",
                arguments: [cutoff]
            ).compactMap { row -> FocusSegment? in
                guard let app: String = row["app"],
                      let start: Date = row["startedAt"],
                      let end: Date = row["endedAt"] else { return nil }
                return FocusSegment(app: app, startedAt: start, endedAt: end)
            }
        }) ?? []
    }

    /// Captured frames overlapping a time window — used to name a focus
    /// session (window titles) and estimate its reading load (OCR text).
    func frames(from: Date, to: Date) -> [FrameRecord] {
        (try? dbQueue.read { db in
            try FrameRecord
                .filter(Column("capturedAt") >= from && Column("capturedAt") <= to)
                .order(Column("capturedAt").asc)
                .fetchAll(db)
        }) ?? []
    }

    func databaseSizeBytes() -> Int64 {
        let path = Store.dataDir.appendingPathComponent("clem.sqlite").path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int64) ?? 0
    }
}
