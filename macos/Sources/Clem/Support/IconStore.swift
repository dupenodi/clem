import AppKit
import SwiftUI

/// Real icons for graph source nodes: web sources get their favicon
/// (fetched once, cached to disk), local apps get their actual macOS icon.
@MainActor
final class IconStore: ObservableObject {
    static let shared = IconStore()

    @Published private var icons: [String: NSImage] = [:]
    private var inflight: Set<String> = []

    private var cacheDir: URL {
        let dir = Store.dataDir.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns immediately with whatever is available; kicks off a fetch
    /// in the background when it isn't (view re-renders via @Published).
    func icon(label: String, domain: String?, bundleID: String?) -> NSImage? {
        // Key by domain when there is one — keying by label made every
        // bookmark from the same source (e.g. "Chrome") share one favicon.
        let key = (domain?.isEmpty == false) ? domain! : label
        if let img = icons[key] { return img }

        // Web source → the site's own favicon (preferred over any app icon,
        // so a tweet shows the X mark, not the browser it was saved from).
        if let domain, !domain.isEmpty {
            let file = cacheDir.appendingPathComponent("\(domain).png")
            if let img = NSImage(contentsOf: file) {
                icons[key] = img
                return img
            }
            if !inflight.contains(key) {
                inflight.insert(key)
                Task {
                    defer { inflight.remove(key) }
                    guard let url = URL(string: "https://www.google.com/s2/favicons?sz=64&domain=\(domain)") else { return }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 6
                    guard let (data, resp) = try? await URLSession.shared.data(for: req),
                          (resp as? HTTPURLResponse)?.statusCode == 200,
                          let img = NSImage(data: data) else { return }
                    try? data.write(to: file)
                    icons[key] = img
                }
            }
            return nil
        }

        // Local app (no web source) → real app icon.
        if let bid = bundleID, !bid.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            let img = NSWorkspace.shared.icon(forFile: appURL.path)
            icons[key] = img
            return img
        }
        return nil
    }

    /// Icon for a time-tracker label, which is either a site host
    /// ("youtube.com") → favicon, or an app display name ("Xcode") → app icon.
    func icon(forLabel label: String) -> NSImage? {
        if label.contains(".") && !label.contains(" ") {
            return icon(label: label, domain: label, bundleID: nil)
        }
        if let img = icons[label] { return img }
        // Resolve an app by its display name to its icon.
        if let path = NSWorkspace.shared.fullPath(forApplication: label) {
            let img = NSWorkspace.shared.icon(forFile: path)
            icons[label] = img
            return img
        }
        return nil
    }
}
