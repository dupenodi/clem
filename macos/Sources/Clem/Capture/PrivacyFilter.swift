import Foundation

struct PrivacyFilter {
    let settings: Settings

    func isAppBlocked(bundleID: String, appName: String, windowTitle: String) -> Bool {
        let bid = bundleID.lowercased()
        let name = appName.lowercased()
        let title = windowTitle.lowercased()
        for pattern in settings.blockedApps {
            let p = pattern.lowercased()
            if p.isEmpty { continue }
            if bid.contains(p) || name.contains(p) || title.contains(p) { return true }
        }
        return false
    }

    /// Fail-closed: a non-empty URL that cannot be parsed is treated as blocked.
    func isDomainBlocked(url: String?) -> Bool {
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false
        }
        let lowered = raw.lowercased()
        let host = URL(string: lowered)?.host?.lowercased()
            ?? URL(string: "https://\(lowered)")?.host?.lowercased()
        guard let host, !host.isEmpty else { return true }

        for pattern in settings.blockedDomains {
            let p = pattern.lowercased().trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            let needle = p.replacingOccurrences(of: "*", with: "")
            if !needle.isEmpty, host.contains(needle) { return true }
        }
        return false
    }

    func isBlocked(bundleID: String, appName: String, windowTitle: String, url: String?) -> Bool {
        isAppBlocked(bundleID: bundleID, appName: appName, windowTitle: windowTitle)
            || isDomainBlocked(url: url)
    }
}
