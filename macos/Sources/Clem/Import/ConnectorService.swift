import AppKit
import Foundation
import UniformTypeIdentifiers

/// One importable thing from an external service.
struct ImportItem: Sendable {
    var ref: String // stable per-item id → re-imports never duplicate
    var content: String
    var url: String?
    var title: String?
    var appName: String
    var category: String
    var tags: String
    var capturedAt: Date?
}

/// The services Clem can pull memories from.
enum ConnectorKind: String, CaseIterable, Identifiable {
    case chrome, safari, xBookmarks, youtube

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chrome: return "Browser Bookmarks"
        case .safari: return "Safari Bookmarks"
        case .xBookmarks: return "X Bookmarks"
        case .youtube: return "YouTube"
        }
    }

    var blurb: String {
        switch self {
        case .chrome: return "Chrome, Brave & Edge — every profile, one click."
        case .safari: return "Bookmarks & Reading List (needs Full Disk Access)."
        case .xBookmarks: return "The JSON or CSV from any X bookmarks exporter."
        case .youtube: return "Takeout playlists (Watch Later, Likes) or watch history — titles fetched automatically."
        }
    }

    var icon: String {
        switch self {
        case .chrome: return "globe"
        case .safari: return "safari"
        case .xBookmarks: return "bookmark.fill"
        case .youtube: return "play.rectangle.fill"
        }
    }

    var buttonLabel: String { needsFile ? "Choose file…" : "Import" }

    var needsFile: Bool {
        switch self {
        case .chrome, .safari: return false
        case .xBookmarks, .youtube: return true
        }
    }

    /// Shown behind the ⓘ button — how to obtain the export file (or fix access).
    var howTo: String? {
        switch self {
        case .chrome:
            return nil
        case .safari:
            return """
            No export needed — Clem reads Safari's bookmarks straight from your Mac.

            If the import fails, macOS is blocking access:
            1. Open System Settings → Privacy & Security → Full Disk Access
            2. Enable Clem (add it with + if it's not listed)
            3. Come back and hit Import again
            """
        case .xBookmarks:
            return """
            X has no built-in bookmarks export. Best free, unlimited option — twitter-web-exporter (open source):

            1. Install the Tampermonkey extension in Chrome
            2. Install "Twitter Web Exporter" from greasyfork.org (one click)
            3. Open x.com/i/bookmarks and scroll — the floating panel captures every bookmark as it loads
            4. Export as JSON from the panel, then choose that file here

            Also good: the "xarchive" Chrome extension (open source, keeps folders). Clem understands both formats — and most others.
            """
        case .youtube:
            return """
            Export via Google Takeout (free, ~2 minutes):

            1. Go to takeout.google.com and sign in
            2. "Deselect all", then tick only YouTube
            3. Click "All YouTube data included" and keep playlists (add history if you want watch history too)
            4. Export → download the zip → unzip it
            5. Choose a playlist CSV (e.g. "Watch later-videos.csv") or "watch-history.json" here

            Video titles and channels are fetched automatically — no API key needed.
            """
        }
    }

    var source: String {
        switch self {
        case .chrome: return "chrome-bookmarks"
        case .safari: return "safari-bookmarks"
        case .xBookmarks: return "x-bookmarks"
        case .youtube: return "youtube"
        }
    }
}

/// Parsers + the deduped ingest pipeline. All imports share one container
/// tag; `metadata.source` says which service a memory came from.
enum ConnectorImport {
    static let tag = "imported"
    /// A single run never ingests more than this (keeps huge watch-history
    /// exports snappy); files are newest-first so the cap keeps recent items.
    static let maxPerRun = 3000

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Chromium browsers (Chrome, Brave, Edge — same Bookmarks format)

    private static let chromiumRoots: [(app: String, path: String)] = [
        ("Chrome", "Library/Application Support/Google/Chrome"),
        ("Brave", "Library/Application Support/BraveSoftware/Brave-Browser"),
        ("Edge", "Library/Application Support/Microsoft Edge"),
    ]

    static func chromeItems() throws -> [ImportItem] {
        var items: [ImportItem] = []
        var foundAny = false

        for browser in chromiumRoots {
            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(browser.path)
            let profiles = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            let files = profiles.map { $0.appendingPathComponent("Bookmarks") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            for file in files {
                guard let data = try? Data(contentsOf: file),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let roots = obj["roots"] as? [String: Any] else { continue }
                foundAny = true
                for root in roots.values {
                    walkChromeNode(root as? [String: Any], folders: [], app: browser.app, into: &items)
                }
            }
        }
        guard foundAny else {
            throw Failure(message: "No Chrome, Brave, or Edge bookmarks found on this Mac.")
        }
        return dedupedByRef(items)
    }

    private static func walkChromeNode(_ node: [String: Any]?, folders: [String], app: String, into items: inout [ImportItem]) {
        guard let node else { return }
        let name = node["name"] as? String ?? ""
        if node["type"] as? String == "url", let url = node["url"] as? String {
            // date_added is microseconds since 1601 (Windows epoch), as a string.
            var when: Date?
            if let us = Double(node["date_added"] as? String ?? "") {
                when = Date(timeIntervalSince1970: us / 1_000_000 - 11_644_473_600)
            }
            items.append(bookmarkItem(title: name, url: url, folders: folders, app: app, when: when))
        }
        for child in node["children"] as? [[String: Any]] ?? [] {
            walkChromeNode(child, folders: name.isEmpty ? folders : folders + [name], app: app, into: &items)
        }
    }

    // MARK: Safari

    static func safariItems() throws -> [ImportItem] {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/Bookmarks.plist")
        guard let data = try? Data(contentsOf: file) else {
            throw Failure(message: "Couldn't read Safari bookmarks — grant Clem Full Disk Access in System Settings → Privacy & Security, then retry.")
        }
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure(message: "Safari bookmarks file couldn't be parsed.")
        }
        var items: [ImportItem] = []
        walkSafariNode(root, folders: [], into: &items)
        guard !items.isEmpty else { throw Failure(message: "No bookmarks found in Safari.") }
        return dedupedByRef(items)
    }

    private static func walkSafariNode(_ node: [String: Any], folders: [String], into items: inout [ImportItem]) {
        if node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf",
           let url = node["URLString"] as? String {
            let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
            items.append(bookmarkItem(title: title, url: url, folders: folders, app: "Safari", when: nil))
            return
        }
        let name = node["Title"] as? String ?? ""
        let label = name == "com.apple.ReadingList" ? "Reading List" : name
        for child in node["Children"] as? [[String: Any]] ?? [] {
            walkSafariNode(child, folders: label.isEmpty ? folders : folders + [label], into: &items)
        }
    }

    private static func bookmarkItem(title: String, url: String, folders: [String], app: String, when: Date?) -> ImportItem {
        let shownTitle = title.isEmpty ? url : title
        var lines = ["Browser bookmark: \(shownTitle)"]
        let path = folders.filter { !["Bookmarks Bar", "Other Bookmarks", "bookmark_bar", "other", "synced"].contains($0) }
        if !path.isEmpty { lines.append("Folder: \(path.joined(separator: " / "))") }
        lines.append("")
        lines.append(url)
        return ImportItem(
            ref: "bm-\(stableHash(url))",
            content: lines.joined(separator: "\n"),
            url: url, title: shownTitle, appName: app,
            category: "other", tags: "bookmark,\(app.lowercased())",
            capturedAt: when
        )
    }

    // MARK: X bookmarks (exporter JSON or CSV)

    static func xItems(from file: URL) throws -> [ImportItem] {
        let data = try Data(contentsOf: file)
        let text = String(data: data, encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        var rawTweets: [[String: Any]] = []
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            let json = try JSONSerialization.jsonObject(with: data)
            if let arr = json as? [[String: Any]] {
                rawTweets = arr
            } else if let dict = json as? [String: Any] {
                // Exporters wrap the list under different keys — take any array of objects.
                for key in ["bookmarks", "tweets", "data", "items"] + dict.keys.sorted() {
                    if let arr = dict[key] as? [[String: Any]] {
                        rawTweets = arr
                        break
                    }
                }
            }
            guard !rawTweets.isEmpty else {
                throw Failure(message: "No tweets found in that JSON — expected an array of bookmarks.")
            }
            return dedupedByRef(rawTweets.compactMap(tweetItem))
        }

        // CSV path
        let rows = parseCSV(trimmed)
        guard rows.count > 1 else { throw Failure(message: "That CSV looks empty.") }
        let header = rows[0].map { $0.lowercased() }
        func col(_ needles: [String]) -> Int? {
            header.firstIndex { h in needles.contains { h.contains($0) } }
        }
        let textCol = col(["text", "content", "tweet"])
        let urlCol = col(["url", "link"])
        let authorCol = col(["screen", "handle", "author", "user", "name"])
        let idCol = col(["id"])
        let dateCol = col(["date", "created", "time"])
        guard textCol != nil || urlCol != nil else {
            throw Failure(message: "Couldn't find a text or URL column in that CSV.")
        }
        let items = rows.dropFirst().compactMap { row -> ImportItem? in
            func cell(_ i: Int?) -> String? {
                guard let i, i < row.count else { return nil }
                let v = row[i].trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
            var dict: [String: Any] = [:]
            dict["text"] = cell(textCol)
            dict["url"] = cell(urlCol)
            dict["author"] = cell(authorCol)
            dict["id"] = cell(idCol)
            dict["created_at"] = cell(dateCol)
            return tweetItem(dict)
        }
        return dedupedByRef(items)
    }

    private static func tweetItem(_ raw: [String: Any]) -> ImportItem? {
        func str(_ keys: [String], in dict: [String: Any]) -> String? {
            for k in keys {
                if let v = dict[k] as? String, !v.isEmpty { return v }
                if let n = dict[k] as? NSNumber { return n.stringValue }
            }
            return nil
        }
        let text = str(["full_text", "text", "tweet_text", "content", "note"], in: raw)
        var url = str(["url", "tweet_url", "tweetURL", "link", "expanded_url", "href"], in: raw)
        let id = str(["id_str", "id", "rest_id", "tweet_id", "tweetId"], in: raw)

        var author = str(["screen_name", "username", "handle", "author_handle"], in: raw)
        if author == nil {
            for key in ["user", "author", "account"] {
                if let u = raw[key] as? [String: Any] {
                    author = str(["screen_name", "username", "handle", "name"], in: u)
                    if author != nil { break }
                } else if let s = raw[key] as? String, !s.isEmpty {
                    author = s
                    break
                }
            }
        }
        if url == nil, let id { url = "https://x.com/i/status/\(id)" }
        guard text != nil || url != nil else { return nil }

        var when: Date?
        if let ds = str(["created_at", "date", "timestamp", "time"], in: raw) {
            when = ISO8601DateFormatter().date(from: ds) ?? twitterDate.date(from: ds)
        }

        var lines: [String] = []
        let handle = author.map { $0.hasPrefix("@") ? $0 : "@\($0)" }
        lines.append("Bookmarked tweet\(handle.map { " from \($0)" } ?? ""):")
        if let text { lines.append(""); lines.append(text) }
        if let url { lines.append(""); lines.append(url) }

        let ref = "x-" + (id ?? stableHash(url ?? text ?? ""))
        return ImportItem(
            ref: ref,
            content: lines.joined(separator: "\n"),
            url: url,
            title: text.map { String($0.prefix(90)) },
            appName: "X",
            category: "article",
            tags: "x,bookmark,tweet",
            capturedAt: when
        )
    }

    private static let twitterDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return f
    }()

    // MARK: YouTube (Takeout playlist CSVs or history JSON)

    static func youtubeItems(from file: URL, phase: @escaping @MainActor @Sendable (String) -> Void) async throws -> [ImportItem] {
        let data = try Data(contentsOf: file)
        let text = String(data: data, encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // watch-history.json / liked videos JSON from Takeout
        if trimmed.hasPrefix("[") {
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw Failure(message: "Couldn't parse that JSON.")
            }
            let items = arr.compactMap { entry -> ImportItem? in
                guard let url = entry["titleUrl"] as? String else { return nil }
                var title = entry["title"] as? String ?? url
                title = title.replacingOccurrences(of: "Watched ", with: "")
                let channel = ((entry["subtitles"] as? [[String: Any]])?.first?["name"] as? String)
                let when = (entry["time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                return youtubeItem(url: url, title: title, channel: channel, list: "watch history", when: when)
            }
            guard !items.isEmpty else { throw Failure(message: "No videos found in that JSON.") }
            return dedupedByRef(items)
        }

        // Takeout playlist CSV: has a "Video ID" column, no titles.
        let rows = parseCSV(trimmed)
        guard let header = rows.first else { throw Failure(message: "That CSV looks empty.") }
        guard let idCol = header.firstIndex(where: { $0.lowercased().contains("video id") }) else {
            throw Failure(message: "Couldn't find a \"Video ID\" column — export playlists via Google Takeout (YouTube → playlists).")
        }
        let listName = file.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-videos", with: "")
        let ids = rows.dropFirst().compactMap { row -> String? in
            guard idCol < row.count else { return nil }
            let v = row[idCol].trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        guard !ids.isEmpty else { throw Failure(message: "No videos found in that CSV.") }
        let capped = Array(ids.prefix(maxPerRun))

        // Titles via oEmbed — free, no API key. Fetch a few at a time.
        var items: [ImportItem] = []
        var done = 0
        for chunk in stride(from: 0, to: capped.count, by: 6).map({ Array(capped[$0..<min($0 + 6, capped.count)]) }) {
            let fetched = await withTaskGroup(of: ImportItem.self, returning: [ImportItem].self) { group in
                for id in chunk {
                    group.addTask {
                        let url = "https://www.youtube.com/watch?v=\(id)"
                        let meta = await oembed(videoURL: url)
                        return youtubeItem(url: url, title: meta?.title ?? url, channel: meta?.author, list: listName, when: nil)
                    }
                }
                var out: [ImportItem] = []
                for await item in group { out.append(item) }
                return out
            }
            items.append(contentsOf: fetched)
            done += chunk.count
            let progress = "fetching titles \(done)/\(capped.count)…"
            await MainActor.run { phase(progress) }
        }
        return dedupedByRef(items)
    }

    private static func youtubeItem(url: String, title: String, channel: String?, list: String, when: Date?) -> ImportItem {
        var lines = ["YouTube video: \(title)"]
        if let channel { lines.append("Channel: \(channel)") }
        lines.append("Saved in: \(list)")
        lines.append("")
        lines.append(url)
        let id = url.components(separatedBy: "v=").last ?? url
        return ImportItem(
            ref: "yt-\(stableHash(id))",
            content: lines.joined(separator: "\n"),
            url: url, title: title, appName: "YouTube",
            category: "video", tags: "youtube,video,\(list.lowercased())",
            capturedAt: when
        )
    }

    private static func oembed(videoURL: String) async -> (title: String, author: String?)? {
        guard let encoded = videoURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let u = URL(string: "https://www.youtube.com/oembed?format=json&url=\(encoded)") else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = obj["title"] as? String else { return nil }
        return (title, obj["author_name"] as? String)
    }

    // MARK: Ingest

    /// Pushes items into supermemory, skipping anything already imported.
    static func ingest(
        _ allItems: [ImportItem], source: String, settings: Settings,
        progress: @escaping @MainActor @Sendable (Int, Int) -> Void
    ) async throws -> (imported: Int, skipped: Int, failed: Int) {
        let sm = SupermemoryClient(baseURL: settings.supermemoryURLValue, apiKey: settings.supermemoryKey)
        guard await sm.isUp() else {
            throw Failure(message: "The supermemory engine isn't running — open Settings and check the service dots.")
        }

        let items = Array(allItems.prefix(maxPerRun))
        let existing = await sm.refToDocID(containerTags: [tag])
        let fresh = items.filter { existing[$0.ref] == nil }
        let skipped = items.count - fresh.count

        let iso = ISO8601DateFormatter()
        var imported = 0
        var failed = 0
        var processed = 0

        for chunk in stride(from: 0, to: fresh.count, by: 5).map({ Array(fresh[$0..<min($0 + 5, fresh.count)]) }) {
            let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for item in chunk {
                    group.addTask {
                        var metadata: [String: Any] = [
                            "source": source,
                            "kind": "import",
                            "ref": item.ref,
                            "app": source,
                            "app_name": item.appName,
                            "category": item.category,
                            "tags": item.tags,
                            "captured_at": iso.string(from: item.capturedAt ?? Date()),
                            "day": String(iso.string(from: item.capturedAt ?? Date()).prefix(10)),
                        ]
                        if let url = item.url { metadata["url"] = String(url.prefix(500)) }
                        if let title = item.title { metadata["page_title"] = String(title.prefix(200)) }
                        do {
                            _ = try await sm.addDocument(content: item.content, containerTag: tag, metadata: metadata)
                            return true
                        } catch {
                            return false
                        }
                    }
                }
                var out: [Bool] = []
                for await ok in group { out.append(ok) }
                return out
            }
            imported += results.filter { $0 }.count
            failed += results.filter { !$0 }.count
            processed += chunk.count
            let p = processed
            let total = fresh.count
            await MainActor.run { progress(p, total) }
        }
        return (imported, skipped, failed)
    }

    // MARK: helpers

    private static func dedupedByRef(_ items: [ImportItem]) -> [ImportItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.ref).inserted }
    }

    /// FNV-1a — stable across launches (Swift's hashValue is not).
    private static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return String(h, radix: 16)
    }

    /// Minimal RFC-4180 CSV parser (quotes, escaped quotes, CRLF).
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\r": break
                case "\n":
                    row.append(field)
                    field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            i = text.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

/// Drives connector runs and publishes per-connector progress for the UI.
@MainActor
final class ConnectorCenter: ObservableObject {
    struct Status {
        var running = false
        var phase = ""
        var progress = 0
        var total = 0
        var summary: String?
        var error: String?
    }

    @Published var status: [ConnectorKind: Status] = [:]

    func run(_ kind: ConnectorKind, settings: Settings) {
        guard status[kind]?.running != true else { return }

        var fileURL: URL?
        if kind.needsFile {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json, .commaSeparatedText, .plainText]
            panel.allowsMultipleSelection = false
            panel.message = "Pick the export file for \(kind.title)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            fileURL = url
        }

        status[kind] = Status(running: true, phase: "reading…")
        Task {
            do {
                let items: [ImportItem]
                switch kind {
                case .chrome:
                    items = try ConnectorImport.chromeItems()
                case .safari:
                    items = try ConnectorImport.safariItems()
                case .xBookmarks:
                    items = try ConnectorImport.xItems(from: fileURL!)
                case .youtube:
                    items = try await ConnectorImport.youtubeItems(from: fileURL!) { [weak self] p in
                        self?.status[kind]?.phase = p
                    }
                }
                status[kind]?.phase = "importing…"
                let result = try await ConnectorImport.ingest(items, source: kind.source, settings: settings) { [weak self] done, total in
                    self?.status[kind]?.progress = done
                    self?.status[kind]?.total = total
                    self?.status[kind]?.phase = "importing \(done)/\(total)…"
                }
                var bits = ["✓ \(result.imported) imported"]
                if result.skipped > 0 { bits.append("\(result.skipped) already in memory") }
                if result.failed > 0 { bits.append("\(result.failed) failed") }
                if items.count > ConnectorImport.maxPerRun { bits.append("capped at \(ConnectorImport.maxPerRun)") }
                status[kind] = Status(summary: bits.joined(separator: " · "))
            } catch {
                status[kind] = Status(error: error.localizedDescription)
            }
        }
    }
}
