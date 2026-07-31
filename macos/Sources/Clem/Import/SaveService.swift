import AppKit
import CoreGraphics
import Foundation

/// Deliberate "save this as a memory" — the reliability ladder:
/// 1. selected text (clipboard round-trip ⌘C — works in every app)
/// 2. browser URL enrichment (YouTube oEmbed / article og-tags)
/// 3. interactive region screenshot + Vision OCR
struct SavedDraft {
    var text: String
    var source: String // "selection" | "region-ocr" | "url"
    var app: String
    var appBundleID: String
    var windowTitle: String
    var url: String?
    var pageTitle: String?
    var note: String = ""
    var thumbPath: String? // kept region screenshot (visual saves)
}

enum SaveService {
    // MARK: capture

    @MainActor
    static func capture() async -> SavedDraft? {
        let ctx = await ContextService().current()
        var draft = SavedDraft(
            text: "", source: "selection",
            app: ctx.appName, appBundleID: ctx.bundleID,
            windowTitle: ctx.windowTitle, url: ctx.url
        )

        if let selection = selectedTextViaClipboard(), !selection.isEmpty {
            draft.text = selection
            draft.source = "selection"
        } else if let region = await regionScreenshot() {
            // Non-selectable content: keep the image AND whatever text it holds.
            draft.text = region.text
            draft.thumbPath = region.thumbPath
            draft.source = "region-ocr"
        } else if draft.url == nil {
            return nil // nothing to save
        } else {
            draft.source = "url"
        }

        if let url = draft.url {
            draft.pageTitle = await pageInfo(url: url)
        }
        return draft
    }

    /// Simulate ⌘C, read the pasteboard, restore the previous clipboard.
    private static func selectedTextViaClipboard() -> String? {
        let pb = NSPasteboard.general
        let oldString = pb.string(forType: .string)
        let oldCount = pb.changeCount

        guard let src = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true), // C
              let up = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false) else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        // Wait up to 400ms for the app to service the copy.
        for _ in 0..<8 {
            usleep(50_000)
            if pb.changeCount != oldCount { break }
        }
        guard pb.changeCount != oldCount else { return nil }
        let text = pb.string(forType: .string)

        pb.clearContents()
        if let oldString { pb.setString(oldString, forType: .string) }
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ⌘⇧4-style crosshair; user draws a box around the thing to remember.
    /// The image is KEPT (as a thumbnail) — visual content is the memory.
    private static func regionScreenshot() async -> (text: String, thumbPath: String?)? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clem-save-\(Int(Date().timeIntervalSince1970)).png")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-i", "-x", tmp.path]
        try? proc.run()
        proc.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard FileManager.default.fileExists(atPath: tmp.path),
              let img = NSImage(contentsOf: tmp),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let text = await OCRService().recognize(image: cg, minConfidence: 0.3)
        let thumb = Thumbnailer.save(image: cg, quality: 0.6)
        return (text, thumb)
    }

    /// Best-effort page title: YouTube oEmbed, else <title>/og:title.
    private static func pageInfo(url: String) async -> String? {
        guard let u = URL(string: url) else { return nil }
        var req: URLRequest
        if url.contains("youtube.com/watch") || url.contains("youtu.be/") {
            guard let oembed = URL(string: "https://www.youtube.com/oembed?format=json&url=\(url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url)") else { return nil }
            req = URLRequest(url: oembed)
            req.timeoutInterval = 5
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let title = obj["title"] as? String {
                let author = obj["author_name"] as? String
                return author.map { "\(title) — \($0)" } ?? title
            }
            return nil
        }
        req = URLRequest(url: u)
        req.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data.prefix(200_000), encoding: .utf8) else { return nil }
        if let m = html.range(of: #"<meta[^>]+property="og:title"[^>]+content="([^"]+)""#, options: .regularExpression) {
            let tag = String(html[m])
            if let c = tag.range(of: #"content="([^"]+)""#, options: .regularExpression) {
                return String(tag[c]).replacingOccurrences(of: "content=\"", with: "").dropLast().description
            }
        }
        if let m = html.range(of: #"<title[^>]*>([^<]+)</title>"#, options: .regularExpression) {
            return String(html[m])
                .replacingOccurrences(of: #"<title[^>]*>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "</title>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: ingest

    /// Topic tags power the graph's hub nodes — best effort, never blocks a save.
    private static func quickTags(_ draft: SavedDraft, settings: Settings) async -> (tags: [String], category: String) {
        let llm = settings.llm
        guard await llm.isUp() else { return ([], "other") }
        let system = """
        You tag a snippet the user saved as a memory. Respond ONLY with JSON:
        {"tags": [2-5 short lowercase topic words — the SUBJECT of the content (e.g. "gym", "fitness", "supermemory", "pricing"), never generic words like "text" or "message"],
         "category": one of \(EnrichmentService.categories)}
        """
        let user = [draft.note, draft.pageTitle ?? "", String(draft.text.prefix(1500))].filter { !$0.isEmpty }.joined(separator: "\n")
        struct TagResult: Decodable {
            var tags: [String]
            var category: String
        }
        guard let data = try? await llm.completeJSON(system: system, user: user, timeout: 30),
              let r = try? JSONDecoder().decode(TagResult.self, from: data) else { return ([], "other") }
        return (Array(r.tags.prefix(5)), EnrichmentService.categories.contains(r.category) ? r.category : "other")
    }

    static func ingest(_ draft: SavedDraft, settings: Settings) async throws {
        let sm = SupermemoryClient(baseURL: settings.supermemoryURLValue, apiKey: settings.supermemoryKey)
        let iso = ISO8601DateFormatter().string(from: Date())
        let (tags, category) = await quickTags(draft, settings: settings)

        var lines: [String] = []
        if !draft.note.isEmpty { lines.append("My note: \(draft.note)") }
        if let title = draft.pageTitle { lines.append("Saved from: \(title)") }
        if !draft.text.isEmpty { lines.append(draft.text) }
        if draft.text.isEmpty, draft.thumbPath != nil {
            lines.append("(Saved a visual snippet — image kept locally.)")
        }
        lines.append("(Saved from \(draft.app)\(draft.windowTitle.isEmpty ? "" : " — \(draft.windowTitle)") on \(iso))")

        var metadata: [String: Any] = [
            "source": "saved",
            "kind": draft.source,
            "ref": "saved-\(Int(Date().timeIntervalSince1970 * 1000))",
            "app": draft.appBundleID,
            "app_name": draft.app,
            "captured_at": iso,
            "day": String(iso.prefix(10)),
            "tags": tags.joined(separator: ","),
            "category": category,
        ]
        if !draft.windowTitle.isEmpty { metadata["window_title"] = String(draft.windowTitle.prefix(200)) }
        if let url = draft.url { metadata["url"] = String(url.prefix(500)) }
        if let title = draft.pageTitle { metadata["page_title"] = String(title.prefix(200)) }
        if let thumb = draft.thumbPath { metadata["thumb"] = thumb }

        _ = try await sm.addDocument(
            content: lines.joined(separator: "\n\n"),
            containerTag: Settings.savedTag,
            metadata: metadata
        )
    }
}
