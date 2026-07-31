import AppKit
import Foundation

/// Rich thumbnails for memories that have a link but no screenshot.
/// YouTube links resolve instantly (deterministic thumbnail URLs); everything
/// else gets its social-preview image (og:image / twitter:image) scraped from
/// the page head. Results — including misses — are cached to disk so each
/// URL costs at most one fetch, ever.
@MainActor
final class LinkThumbs: ObservableObject {
    static let shared = LinkThumbs()

    @Published private var images: [String: NSImage] = [:]
    private var misses: Set<String> = []
    private var inflight: Set<String> = []

    private var cacheDir: URL {
        let dir = Store.dataDir.appendingPathComponent("linkthumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns immediately with whatever is cached; kicks off a background
    /// fetch when nothing is (views re-render via @Published when it lands).
    func thumb(for urlString: String?) -> NSImage? {
        guard let urlString, let url = URL(string: urlString), url.host != nil else { return nil }
        let key = Self.hash(urlString)
        if let img = images[key] { return img }
        if misses.contains(key) { return nil }

        let hit = cacheDir.appendingPathComponent("\(key).img")
        if let img = NSImage(contentsOf: hit) {
            images[key] = img
            return img
        }
        let miss = cacheDir.appendingPathComponent("\(key).miss")
        if FileManager.default.fileExists(atPath: miss.path) {
            misses.insert(key)
            return nil
        }

        guard !inflight.contains(key) else { return nil }
        inflight.insert(key)
        Task {
            defer { inflight.remove(key) }
            if let data = await Self.fetchThumbData(for: url), let img = NSImage(data: data), img.size.width > 32 {
                try? data.write(to: hit)
                images[key] = img
            } else {
                try? Data().write(to: miss)
                misses.insert(key)
            }
        }
        return nil
    }

    // MARK: fetching (off-main-actor helpers)

    private nonisolated static func fetchThumbData(for url: URL) async -> Data? {
        if let id = youtubeID(url) {
            // hqdefault exists for every video — no scraping, no API.
            return await download(URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")!)
        }
        guard let html = await pageHead(url),
              let imageURL = ogImageURL(in: html, base: url) else { return nil }
        return await download(imageURL)
    }

    private nonisolated static func youtubeID(_ url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        guard host.contains("youtube.com") || host.contains("youtu.be") else { return nil }
        if host.contains("youtu.be") {
            let id = url.lastPathComponent
            return id.isEmpty ? nil : id
        }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let v = items.first(where: { $0.name == "v" })?.value {
            return v
        }
        if url.path.hasPrefix("/shorts/") || url.path.hasPrefix("/embed/") {
            let id = url.lastPathComponent
            return id.isEmpty ? nil : id
        }
        return nil
    }

    private nonisolated static func pageHead(_ url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        // Some sites only serve social meta tags to "real" browsers.
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data.prefix(400_000), encoding: .utf8)
    }

    private nonisolated static func ogImageURL(in html: String, base: URL) -> URL? {
        // content= can come before or after property= — try both orders.
        let patterns = [
            #"<meta[^>]+(?:property|name)=["'](?:og:image|twitter:image)(?::src)?["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["'](?:og:image|twitter:image)(?::src)?["']"#,
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  m.numberOfRanges > 1,
                  let range = Range(m.range(at: 1), in: html) else { continue }
            let raw = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
            if let u = URL(string: raw, relativeTo: base)?.absoluteURL, u.scheme?.hasPrefix("http") == true {
                return u
            }
        }
        return nil
    }

    private nonisolated static func download(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              data.count > 500, data.count < 8_000_000 else { return nil }
        return data
    }

    private nonisolated static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return String(h, radix: 16)
    }
}
