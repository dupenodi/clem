import AppKit

/// Tracks per-app foreground time using the native frontmost-app signal —
/// independent of screen monitoring/captures. Accrues elapsed time to whatever
/// app is in front, pausing while the user is idle or the screen is locked.
/// No special permission required (NSWorkspace is public API).
@MainActor
final class ActivityTracker {
    private var timer: Timer?
    private var lastTick: Date?
    private var gazeInFlight = false
    private let settings: Settings
    private let interval: TimeInterval = 8

    init(settings: Settings) { self.settings = settings }

    func start() {
        stop()
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Also settle time immediately when the user switches apps.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appSwitched),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        closeSegment()
    }

    @objc private func appSwitched() { tick() }

    // Browsers whose foreground time we split by the active tab's site.
    private let browserScripts: [String: String] = [
        "com.google.Chrome": #"tell application "Google Chrome" to get URL of active tab of front window"#,
        "com.brave.Browser": #"tell application "Brave Browser" to get URL of active tab of front window"#,
        "company.thebrowser.Browser": #"tell application "Arc" to get URL of active tab of front window"#,
        "com.apple.Safari": #"tell application "Safari" to get URL of front document"#,
        "com.microsoft.edgemac": #"tell application "Microsoft Edge" to get URL of active tab of front window"#,
    ]

    private func tick() {
        guard !SystemState.isScreenLocked() else {
            lastTick = nil
            closeSegment()
            return
        }
        if SystemState.isIdle(threshold: 120) {
            // No input for 2+ minutes. Without the webcam check we must assume
            // the user left. With it, eyes on the screen keep the clock
            // running (video, long reads) and eyes elsewhere become the
            // "Off-screen" distraction bucket.
            guard settings.gazeCheckEnabled else {
                lastTick = nil
                closeSegment()
                return
            }
            guard !gazeInFlight else { return }
            gazeInFlight = true
            Task { @MainActor in
                defer { self.gazeInFlight = false }
                switch await GazeService.shared.attention() {
                case .screen:
                    self.accrueFrontmost()
                case .away:
                    self.accrueIdle(as: GazeService.offScreenLabel)
                case .absent, .unavailable:
                    self.lastTick = nil
                    self.closeSegment()
                }
            }
            return
        }
        accrueFrontmost()
    }

    /// Elapsed wall time since the last accrual (capped, so sleep/coalescing
    /// can't spike it); nil when too small to matter.
    private func takeElapsed(now: Date) -> Double? {
        let elapsed = min(lastTick.map { now.timeIntervalSince($0) } ?? interval, 30)
        lastTick = now
        return elapsed > 0.5 ? elapsed : nil
    }

    /// Credit elapsed time to a synthetic label (present but looking away).
    private func accrueIdle(as label: String) {
        let now = Date()
        guard let elapsed = takeElapsed(now: now) else { return }
        Task { await Store.shared.addAppTime(app: label, seconds: elapsed) }
        accrueSegment(label: label, now: now)
    }

    /// Credit elapsed time to whatever app/site is in front (the normal path).
    private func accrueFrontmost() {
        let now = Date()
        guard let elapsed = takeElapsed(now: now),
              let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName else { return }
        let bundleID = app.bundleIdentifier ?? ""
        let filter = PrivacyFilter(settings: settings)

        // For browsers, attribute time to the active tab's SITE (e.g.
        // "youtube.com"), not the browser itself.
        if let script = browserScripts[bundleID] {
            Task {
                let url = await Self.runScript(script)
                let host = Self.siteLabel(from: url)
                let label = host ?? name
                if filter.isBlocked(bundleID: bundleID, appName: name, windowTitle: "", url: url) { return }
                await Store.shared.addAppTime(app: label, seconds: elapsed)
                await MainActor.run { self.accrueSegment(label: label, now: now) }
            }
            return
        }

        if filter.isBlocked(bundleID: bundleID, appName: name, windowTitle: "", url: nil) { return }
        Task { await Store.shared.addAppTime(app: name, seconds: elapsed) }
        accrueSegment(label: name, now: now)
    }

    // MARK: attention timeline (focus segments)

    private var openSegID: Int64?
    private var openSegLabel: String?
    private var lastAccrual: Date?

    /// Extend the open focus segment while the same app/site stays in front;
    /// a change of label (or a gap — idle, lock, sleep) closes it and opens a
    /// fresh one. This is the raw timeline FocusService analyses.
    private func accrueSegment(label: String, now: Date) {
        // Live focus-session watchdog gets every resolved label.
        FocusSessionCenter.shared.observe(label: label, now: now)
        let gap = lastAccrual.map { now.timeIntervalSince($0) } ?? .infinity
        let stale = gap > 90 // missed several ticks → treat as a break, not one long segment
        lastAccrual = now
        if label == openSegLabel, !stale {
            // openSegID may still be nil while the INSERT is in flight — skip
            // the extend rather than opening a duplicate segment.
            if let id = openSegID { Task { await Store.shared.extendFocusSegment(id: id, to: now) } }
            return
        }
        openSegLabel = label
        openSegID = nil
        Task {
            let id = await Store.shared.openFocusSegment(app: label, at: now)
            await MainActor.run { if self.openSegLabel == label { self.openSegID = id } }
        }
    }

    private func closeSegment() {
        openSegID = nil
        openSegLabel = nil
        lastAccrual = nil
    }

    /// "https://www.youtube.com/watch?..." → "youtube.com" (nil if not web).
    private static func siteLabel(from url: String?) -> String? {
        guard let url, let host = URL(string: url)?.host?.lowercased() else { return nil }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    private static func runScript(_ source: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var err: NSDictionary?
                let out = NSAppleScript(source: source)?.executeAndReturnError(&err)
                cont.resume(returning: err == nil ? out?.stringValue : nil)
            }
        }
    }
}
