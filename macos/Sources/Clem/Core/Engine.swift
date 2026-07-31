import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published var isPaused = false
    @Published var isMonitoring = false
    @Published var pausedUntil: Date?
    @Published var hasScreenPermission = Permissions.screenRecordingGranted()
    @Published var hasAXPermission = Permissions.accessibilityGranted()
    @Published var stats = DayStats()
    @Published var appTimes: [AppSpan] = []
    @Published var screenTimeSeconds: Double = 0
    @Published var usingSystemTime = false
    @Published var lastKept: FrameRecord?
    @Published var supermemoryUp = false
    @Published var llmUp = false
    @Published var pendingCount = 0
    @Published var chatHotkeyLabel = "⌥Space"
    @Published var saveHotkeyLabel = "⌥S"

    let settings = Settings()
    private let capture = CaptureService()
    private let dedupe = DedupeService()
    private let context = ContextService()
    private let ocr = OCRService()
    private var privacy: PrivacyFilter { PrivacyFilter(settings: settings) }
    private lazy var ingest = IngestWorker(settings: settings)
    private lazy var activity = ActivityTracker(settings: settings)
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private var timer: Timer?
    private var healthTimer: Timer?
    private var ticking = false

    // One memory per app-session (Rewind-style), not per frame.
    private struct OpenSession {
        var appBundleID: String
        var frameIDs: [Int64] = []
        var startedAt = Date()
        var lastActivity = Date()
    }

    private var session: OpenSession?
    private let sessionIdleTimeout: TimeInterval = 300
    private let sessionMaxFrames = 40

    private func trackSession(frameID: Int64?, bundleID: String) {
        if var s = session {
            let switched = s.appBundleID != bundleID
            let idle = Date().timeIntervalSince(s.lastActivity) > sessionIdleTimeout
            let full = s.frameIDs.count >= sessionMaxFrames
            if switched || idle || full {
                closeSession()
            } else {
                if let id = frameID { s.frameIDs.append(id) }
                s.lastActivity = Date()
                session = s
                return
            }
        }
        var fresh = OpenSession(appBundleID: bundleID)
        if let id = frameID { fresh.frameIDs.append(id) }
        session = fresh
    }

    func closeSession() {
        guard let s = session, !s.frameIDs.isEmpty else {
            session = nil
            return
        }
        session = nil
        Task { await Store.shared.enqueueSession(frameIDs: s.frameIDs) }
    }

    func startIfPermitted() {
        hasScreenPermission = Permissions.screenRecordingGranted()
        hasAXPermission = Permissions.accessibilityGranted()
        if hasScreenPermission {
            // Passive monitoring is opt-in: only auto-start when enabled.
            if settings.autoStartMonitoring { start() }
        } else {
            // First run: trigger the system permission prompt; the menu bar
            // popover offers "Finish setup…" for the full onboarding flow.
            Permissions.requestScreenRecording()
        }
        refreshStats()

        activity.start()
        Task { await ingest.start() }
        Task {
            await Store.shared.pruneThumbnails(olderThanDays: settings.thumbnailRetentionDays)
            await Store.shared.pruneFocusSegments(olderThanDays: max(90, settings.thumbnailRetentionDays))
        }
        installHotkeys()
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollHealth() }
        }
        Task {
            await ServiceSupervisor.shared.startIfNeeded(settings: settings)
            await pollHealth()
        }
    }

    /// Full teardown on quit — timers, monitors, workers, owned child processes.
    func shutdown() {
        stop()
        healthTimer?.invalidate()
        healthTimer = nil
        if let g = globalKeyMonitor { NSEvent.removeMonitor(g); globalKeyMonitor = nil }
        if let l = localKeyMonitor { NSEvent.removeMonitor(l); localKeyMonitor = nil }
        activity.stop()
        Task { await ingest.stopWorker() }
        ServiceSupervisor.shared.shutdown()
    }

    /// Global + local key monitors for ⌥Space (quick ask) and ⌥S (save).
    /// NSEvent monitors reliably fire wherever the user is (Clem has
    /// Accessibility permission), unlike Carbon hotkeys that other apps steal.
    private func installHotkeys() {
        if let g = globalKeyMonitor { NSEvent.removeMonitor(g) }
        if let l = localKeyMonitor { NSEvent.removeMonitor(l) }

        let handle: (NSEvent) -> Bool = { [weak self] e in
            guard let self else { return false }
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == .option else { return false }
            if e.keyCode == 49 { // Space
                ChatPanelController.shared.toggle(engine: self)
                return true
            }
            if e.keyCode == 1 { // S
                SavePanelController.shared.trigger(engine: self)
                return true
            }
            return false
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ = handle($0) }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            handle(e) ? nil : e // swallow the event when we handle it
        }
        chatHotkeyLabel = "⌥Space"
        saveHotkeyLabel = "⌥S"
    }

    private func pollHealth() async {
        let sm = SupermemoryClient(baseURL: settings.supermemoryURLValue, apiKey: settings.supermemoryKey)
        let llm = settings.llm
        async let a = sm.isUp()
        async let b = llm.isUp()
        async let c = Store.shared.pendingCount()
        let (smUp, modelUp, pending) = await (a, b, c)
        supermemoryUp = smUp
        llmUp = modelUp
        pendingCount = pending
        if !smUp || !modelUp {
            Task { await ServiceSupervisor.shared.startIfNeeded(settings: settings) }
        }
        // Keep the Home time-spent view current even when monitoring is off.
        await refreshStatsAsync()
    }

    func start() {
        stop()
        let interval = settings.captureInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        isMonitoring = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
        closeSession()
    }

    func toggleMonitoring() {
        isMonitoring ? stop() : start()
    }

    func pause(for duration: TimeInterval?) {
        isPaused = true
        pausedUntil = duration.map { Date().addingTimeInterval($0) }
    }

    func resume() {
        isPaused = false
        pausedUntil = nil
    }

    func restartTimer() {
        if isMonitoring { start() }
    }

    private func tick() {
        guard !ticking else { return }
        if let until = pausedUntil, Date() > until { resume() }
        guard !isPaused, hasScreenPermission else { return }
        // Skip when idle, screen locked, or (configurable) low battery.
        guard !SystemState.isIdle(threshold: 120), !SystemState.isScreenLocked() else {
            closeSession() // user walked away — the session is over
            return
        }
        if settings.pauseOnLowBattery, SystemState.isOnLowBattery(below: 0.2) { return }

        ticking = true
        Task {
            defer { Task { @MainActor in self.ticking = false } }
            await self.processFrame()
        }
    }

    private func processFrame() async {
        var ctx = await context.current()
        let filter = privacy

        // App/title blocklist before capture — no pixels for password managers etc.
        if filter.isAppBlocked(bundleID: ctx.bundleID, appName: ctx.appName, windowTitle: ctx.windowTitle) {
            await Store.shared.bumpStat(\.blocked)
            await refreshStatsAsync()
            return
        }

        guard let image = await capture.captureActiveDisplay() else { return }
        await Store.shared.bumpStat(\.captured)

        guard let hash = dedupe.dHash(of: image) else { return }
        if dedupe.isDuplicate(hash) {
            await Store.shared.bumpStat(\.deduped)
            await MainActor.run { self.trackSession(frameID: nil, bundleID: ctx.bundleID) }
            await refreshStatsAsync()
            return
        }

        let text = await ocr.recognize(image: image, minConfidence: 0.3)

        // Resolve the on-screen tab via OCR, then apply domain privacy on the real URL.
        if let tab = ContextService.pickTab(candidates: ctx.tabCandidates, ocr: text) {
            ctx.url = tab.url
            if !tab.title.isEmpty { ctx.windowTitle = tab.title }
        }
        if filter.isDomainBlocked(url: ctx.url) {
            await Store.shared.bumpStat(\.blocked)
            await refreshStatsAsync()
            return
        }

        if let last = await Store.shared.lastFrame(),
           let lastID = last.id,
           last.appBundleID == ctx.bundleID,
           last.windowTitle == ctx.windowTitle,
           TextSimilarity.jaccard(text, last.ocrText) > 0.95 {
            await Store.shared.touchLastSeen(frameID: lastID)
            dedupe.remember(hash)
            await MainActor.run { self.trackSession(frameID: nil, bundleID: ctx.bundleID) }
            await refreshStatsAsync()
            return
        }

        dedupe.remember(hash)
        var thumbPath: String?
        if settings.keepThumbnails {
            thumbPath = Thumbnailer.save(image: image, quality: settings.thumbnailQuality)
        }

        let frame = FrameRecord(
            id: nil,
            capturedAt: Date(),
            lastSeenAt: Date(),
            appBundleID: ctx.bundleID,
            appName: ctx.appName,
            windowTitle: ctx.windowTitle,
            url: ctx.url,
            phash: Int64(bitPattern: hash),
            ocrText: text,
            thumbPath: thumbPath,
            supermemoryDocID: nil
        )
        do {
            let saved = try await Store.shared.insertFrame(frame)
            if let savedID = saved.id {
                await MainActor.run { self.trackSession(frameID: savedID, bundleID: ctx.bundleID) }
            }
            await Store.shared.bumpStat(\.kept)
            await MainActor.run { self.lastKept = saved }
        } catch {
            NSLog("Clem: failed to persist frame: \(error.localizedDescription)")
        }
        await refreshStatsAsync()
    }

    func refreshStats() {
        Task { await refreshStatsAsync() }
    }

    private func refreshStatsAsync() async {
        let s = await Store.shared.todayStats()
        // Clem's own tracker (only source that splits browser time by SITE,
        // e.g. youtube.com) — but only accrues while Clem is running.
        let tracker = await Store.shared.todayAppTime()
        // macOS's own whole-day per-app usage (Screen Time / knowledgeC), read
        // off-main. Requires Full Disk Access; empty otherwise.
        let system = await Task.detached { ScreenTimeReader.todayByApp() }.value
        let sysUsed = !system.isEmpty
        await MainActor.run {
            self.stats = s
            // Prefer the system's whole-day per-app numbers so usage reflects
            // the WHOLE day, not just since Clem launched. Fall back to the
            // tracker when Full Disk Access isn't granted.
            self.appTimes = sysUsed ? system : tracker
            self.screenTimeSeconds = self.appTimes.reduce(0) { $0 + $1.seconds }
            self.usingSystemTime = sysUsed
            // Goals need per-site granularity too: evaluate against the system
            // app totals PLUS the tracker's site-level entries (hosts), so both
            // "Slack" and "substack.com" goals resolve.
            let sites = tracker.filter { $0.app.contains(".") && !$0.app.contains(" ") }
            GoalStore.shared.evaluate(appTimes: sysUsed ? system + sites : tracker)
        }
    }

}
