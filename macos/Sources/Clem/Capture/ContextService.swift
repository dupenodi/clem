import AppKit
import ApplicationServices

struct BrowserTab {
    var url: String
    var title: String
}

struct CaptureContext {
    var bundleID: String
    var appName: String
    var windowTitle: String
    var url: String?
    // Active tab of every browser window — the correct one is chosen after OCR.
    var tabCandidates: [BrowserTab] = []
}

/// Frontmost app (NSWorkspace), window title (Accessibility), browser tabs (AppleScript).
final class ContextService {
    // Each script emits "url\ntitle\n---\n" per window's active tab.
    private let chromiumScript = """
    set out to ""
    tell application "%@"
      repeat with w in windows
        try
          set t to active tab of w
          set out to out & (URL of t) & linefeed & (title of t) & linefeed & "---" & linefeed
        end try
      end repeat
    end tell
    return out
    """
    private let browserApps: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.brave.Browser": "Brave Browser",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Microsoft Edge",
    ]

    func current() async -> CaptureContext {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier ?? "unknown"
        let appName = app?.localizedName ?? "Unknown"
        let title = app.map { focusedWindowTitle(pid: $0.processIdentifier) } ?? ""

        var candidates: [BrowserTab] = []
        if let appName = browserApps[bundleID] {
            let out = await runAppleScript(String(format: chromiumScript, appName)) ?? ""
            candidates = Self.parseTabs(out)
        } else if bundleID == "com.apple.Safari" {
            let out = await runAppleScript(#"tell application "Safari" to return (URL of front document) & linefeed & (name of front document)"#) ?? ""
            let parts = out.components(separatedBy: "\n")
            if parts.count >= 1, parts[0].hasPrefix("http") {
                candidates = [BrowserTab(url: parts[0], title: parts.count > 1 ? parts[1] : "")]
            }
        }
        return CaptureContext(
            bundleID: bundleID, appName: appName, windowTitle: title,
            url: candidates.first?.url, tabCandidates: candidates
        )
    }

    private static func parseTabs(_ raw: String) -> [BrowserTab] {
        var tabs: [BrowserTab] = []
        for entry in raw.components(separatedBy: "---") {
            let lines = entry.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let url = lines.first, url.hasPrefix("http") else { continue }
            tabs.append(BrowserTab(url: url, title: lines.count > 1 ? lines[1] : ""))
        }
        return tabs
    }

    /// Pick the tab the screen actually shows: match a candidate's hostname or
    /// title words against the OCR text. Falls back to the front-window tab.
    static func pickTab(candidates: [BrowserTab], ocr: String) -> BrowserTab? {
        guard !candidates.isEmpty else { return nil }
        let lower = ocr.lowercased()
        if !lower.isEmpty {
            // hostname visible on screen (e.g. "youtube.com", "substack.com")
            if let hit = candidates.first(where: { c in
                guard let host = URL(string: c.url)?.host?.replacingOccurrences(of: "www.", with: "").lowercased() else { return false }
                return lower.contains(host)
            }) { return hit }
            // enough distinctive title words present on screen
            if let hit = candidates.max(by: { titleScore($0, lower) < titleScore($1, lower) }),
               titleScore(hit, lower) >= 2 { return hit }
        }
        return candidates.first
    }

    private static func titleScore(_ tab: BrowserTab, _ ocr: String) -> Int {
        tab.title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 4 }
            .reduce(0) { ocr.contains($1) ? $0 + 1 : $0 }
    }

    private func focusedWindowTitle(pid: pid_t) -> String {
        let appEl = AXUIElementCreateApplication(pid)
        var window: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let win = window else { return "" }
        var title: AnyObject?
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else {
            return ""
        }
        return (title as? String) ?? ""
    }

    private func runAppleScript(_ source: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                let result = script?.executeAndReturnError(&error)
                cont.resume(returning: error == nil ? result?.stringValue : nil)
            }
        }
    }
}
