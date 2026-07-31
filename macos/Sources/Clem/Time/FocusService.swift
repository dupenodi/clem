import Foundation

/// One contiguous stretch of foreground attention on a single app or site —
/// the raw rows of the `focus_segments` table.
struct FocusSegment: Equatable {
    var app: String
    var startedAt: Date
    var endedAt: Date
    var seconds: Double { endedAt.timeIntervalSince(startedAt) }
}

/// A distracting app/site and how often it pulled the user away today.
struct DistractionPull: Identifiable {
    var label: String
    var count: Int
    var totalSeconds: Double
    var avgSeconds: Double { count > 0 ? totalSeconds / Double(count) : 0 }
    var id: String { label }
}

/// One block of a session's timeline — "10:05–10:13 x.com".
struct TimelineBlock: Identifiable {
    enum Kind { case onTask, distraction, other }
    var id = UUID()
    var start: Date
    var end: Date
    var label: String
    var kind: Kind
    var seconds: Double { end.timeIntervalSince(start) }
}

/// A stretch of intended work that got fragmented — e.g. a 15-minute read
/// that took 31 minutes because of 4 detours to social feeds.
struct InterruptedSession: Identifiable {
    // Stable across re-analysis so UI expansion state survives refreshes.
    var id: String { "\(anchor)@\(Int(start.timeIntervalSince1970))" }
    var anchor: String            // the app/site you were trying to be on
    var start: Date
    var end: Date
    var onTaskSeconds: Double     // time actually on the anchor
    var lostSeconds: Double       // time inside distracting detours
    var detours: [(label: String, count: Int)] // distracting pulls, most frequent first
    var timeline: [TimelineBlock] = []
    var title: String?            // "AI Safety Newsletter" — from window titles
    var expectedSeconds: Double?  // estimated time the content actually needed

    var elapsedSeconds: Double { end.timeIntervalSince(start) }
    var awaySeconds: Double { max(0, elapsedSeconds - onTaskSeconds) }
    var detourCount: Int { detours.reduce(0) { $0 + $1.count } }
    /// 0…1 — how much of the elapsed window was actually on task.
    var efficiency: Double { elapsedSeconds > 0 ? onTaskSeconds / elapsedSeconds : 1 }
}

struct FocusSuggestion: Identifiable {
    var id = UUID()
    var icon: String
    var text: String
    /// When set, the UI offers a one-click "Set limit" that creates a Goal.
    var goalTarget: String?
    var goalMinutes: Int = 15
}

struct FocusReport {
    var activeSeconds: Double = 0
    var distractedSeconds: Double = 0
    var switches: Int = 0
    var longestStreakSeconds: Double = 0
    var pulls: [DistractionPull] = []
    var sessions: [InterruptedSession] = []
    var hourlyDistraction: [Double] = Array(repeating: 0, count: 24) // seconds per hour of day
    var hourlyDetail: [[String: Double]] = Array(repeating: [:], count: 24) // hour → distractor → seconds
    /// The whole day as chronological blocks (consecutive same-label segments
    /// merged): .distraction for marked distractors, .other for everything else.
    var dayTimeline: [TimelineBlock] = []
    var suggestions: [FocusSuggestion] = []

    /// 0…1 — share of active time NOT spent inside distractions.
    var focusScore: Double {
        activeSeconds > 0 ? max(0, 1 - distractedSeconds / activeSeconds) : 1
    }
    var isEmpty: Bool { activeSeconds < 60 }
}

/// Pure, deterministic analysis of the day's attention timeline: where focus
/// broke, what pulled it, and what to do about it. No LLM required — the
/// optional coach (below) adds personalised tips on top.
enum FocusService {

    // Segments separated by less than this are considered one continuous
    // stretch (tracker tick jitter, quick window juggling).
    private static let mergeGap: TimeInterval = 45
    // Returning to the same activity within this window keeps the session alive.
    private static let sessionGap: TimeInterval = 8 * 60
    // A distraction shorter than this is a glance, not a focus break.
    private static let streakBreaker: TimeInterval = 45
    // A session must run at least this long to count for habit patterns.
    private static let longSession: TimeInterval = 12 * 60

    static func isDistracting(_ label: String, distractors: [String]) -> Bool {
        let l = label.lowercased()
        // Looking away from the screen is a distraction by definition.
        if l == GazeService.offScreenLabel.lowercased() { return true }
        for raw in distractors {
            let d = raw.lowercased().trimmingCharacters(in: .whitespaces)
            guard !d.isEmpty else { continue }
            if d.contains(".") {
                if l == d || l.hasSuffix("." + d) { return true }
            } else if l.contains(d) {
                return true
            }
        }
        return false
    }

    static func analyze(segments raw: [FocusSegment], distractors: [String]) -> FocusReport {
        let segments = merge(raw)
        var report = FocusReport()
        guard !segments.isEmpty else { return report }

        let distracting = segments.map { isDistracting($0.app, distractors: distractors) }
        report.activeSeconds = segments.reduce(0) { $0 + $1.seconds }
        report.distractedSeconds = zip(segments, distracting).filter(\.1).reduce(0) { $0 + $1.0.seconds }

        // Switches + pulls (non-distracting → distracting transitions).
        var pullCount: [String: Int] = [:]
        var pullSeconds: [String: Double] = [:]
        for i in 1..<segments.count {
            report.switches += 1
            if distracting[i], !distracting[i - 1] {
                pullCount[segments[i].app, default: 0] += 1
            }
        }
        for (seg, isD) in zip(segments, distracting) where isD {
            pullSeconds[seg.app, default: 0] += seg.seconds
        }
        report.pulls = pullSeconds.map {
            DistractionPull(label: $0.key, count: max(pullCount[$0.key] ?? 0, 1), totalSeconds: $0.value)
        }
        .sorted { ($0.count, $0.totalSeconds) > ($1.count, $1.totalSeconds) }

        // Longest streak: wall time without a real (non-glance) distraction.
        var streakStart = segments[0].startedAt
        for (i, seg) in segments.enumerated() {
            let gapBefore = i > 0 ? seg.startedAt.timeIntervalSince(segments[i - 1].endedAt) : 0
            let broken = (distracting[i] && seg.seconds >= streakBreaker) || gapBefore > 10 * 60
            if broken {
                let end = distracting[i] ? seg.startedAt : segments[i - 1].endedAt
                report.longestStreakSeconds = max(report.longestStreakSeconds, end.timeIntervalSince(streakStart))
                streakStart = distracting[i] ? seg.endedAt : seg.startedAt
            }
        }
        report.longestStreakSeconds = max(
            report.longestStreakSeconds,
            segments[segments.count - 1].endedAt.timeIntervalSince(streakStart)
        )

        // Hour-of-day distraction load.
        let cal = Calendar.current
        for (seg, isD) in zip(segments, distracting) where isD {
            var cursor = seg.startedAt
            while cursor < seg.endedAt {
                let hour = cal.component(.hour, from: cursor)
                let hourEnd = cal.date(bySettingHour: hour, minute: 59, second: 59, of: cursor)!.addingTimeInterval(1)
                let sliceEnd = min(hourEnd, seg.endedAt)
                report.hourlyDistraction[hour] += sliceEnd.timeIntervalSince(cursor)
                report.hourlyDetail[hour][seg.app, default: 0] += sliceEnd.timeIntervalSince(cursor)
                cursor = sliceEnd
            }
        }

        // Whole-day chronological blocks for the day timeline.
        var dayBlocks: [TimelineBlock] = []
        for (seg, isD) in zip(segments, distracting) {
            let kind: TimelineBlock.Kind = isD ? .distraction : .other
            if var last = dayBlocks.last, last.label == seg.app, last.kind == kind,
               seg.startedAt.timeIntervalSince(last.end) < mergeGap {
                last.end = seg.endedAt
                dayBlocks[dayBlocks.count - 1] = last
            } else {
                dayBlocks.append(TimelineBlock(start: seg.startedAt, end: seg.endedAt, label: seg.app, kind: kind))
            }
        }
        report.dayTimeline = dayBlocks

        // Fragmented sessions worth showing: the user came back at least once
        // AND real time leaked away in between.
        report.sessions = clusters(segments: segments, distracting: distracting)
            .filter { $0.timeline.filter { $0.kind == .onTask }.count >= 2 && ($0.detourCount >= 2 || $0.lostSeconds >= 120) }
            .sorted { $0.lostSeconds > $1.lostSeconds }
            .prefix(6).map { $0 }

        report.suggestions = suggest(report: report)
        return report
    }

    /// Collapse tracker jitter: adjacent segments of the same label with a
    /// tiny gap become one.
    private static func merge(_ raw: [FocusSegment]) -> [FocusSegment] {
        var out: [FocusSegment] = []
        for seg in raw.sorted(by: { $0.startedAt < $1.startedAt }) {
            if var last = out.last, last.app == seg.app,
               seg.startedAt.timeIntervalSince(last.endedAt) < mergeGap {
                last.endedAt = max(last.endedAt, seg.endedAt)
                out[out.count - 1] = last
            } else {
                out.append(seg)
            }
        }
        // Sub-5s blips are attention noise, not activity.
        return out.filter { $0.seconds >= 5 }
    }

    /// Reconstruct work sessions: for every substantial non-distracting
    /// activity, cluster its recurrences (returns within `sessionGap`) and
    /// measure what happened in between — including a rendered timeline.
    private static func clusters(segments: [FocusSegment], distracting: [Bool]) -> [InterruptedSession] {
        var anchorTotals: [String: Double] = [:]
        for (seg, isD) in zip(segments, distracting) where !isD {
            anchorTotals[seg.app, default: 0] += seg.seconds
        }
        let anchors = anchorTotals.filter { $0.value >= 5 * 60 }.keys

        var sessions: [InterruptedSession] = []
        for anchor in anchors {
            let indices = segments.indices.filter { segments[$0].app == anchor }
            var cluster: [Int] = []
            func flush() {
                defer { cluster = [] }
                guard let first = cluster.first, let last = cluster.last else { return }
                let start = segments[first].startedAt
                let end = segments[last].endedAt
                let onTask = cluster.reduce(0.0) { $0 + segments[$1].seconds }
                var lost = 0.0
                var detourCounts: [String: Int] = [:]
                var blocks: [TimelineBlock] = []
                for i in first...last {
                    let seg = segments[i]
                    let kind: TimelineBlock.Kind =
                        seg.app == anchor ? .onTask : (distracting[i] ? .distraction : .other)
                    if kind == .distraction {
                        lost += seg.seconds
                        detourCounts[seg.app, default: 0] += 1
                    }
                    if var lastBlock = blocks.last, lastBlock.label == seg.app, lastBlock.kind == kind {
                        lastBlock.end = seg.endedAt
                        blocks[blocks.count - 1] = lastBlock
                    } else {
                        blocks.append(TimelineBlock(start: seg.startedAt, end: seg.endedAt, label: seg.app, kind: kind))
                    }
                }
                // Sub-45s "other" blips clutter the story; distractions stay.
                blocks.removeAll { $0.kind == .other && $0.seconds < 45 }
                sessions.append(InterruptedSession(
                    anchor: anchor, start: start, end: end,
                    onTaskSeconds: onTask, lostSeconds: lost,
                    detours: detourCounts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) },
                    timeline: blocks
                ))
            }
            for i in indices {
                if let prev = cluster.last,
                   segments[i].startedAt.timeIntervalSince(segments[prev].endedAt) > sessionGap {
                    flush()
                }
                cluster.append(i)
            }
            flush()
        }
        return sessions
    }

    // MARK: cross-day habits

    /// Recurring failure patterns over the last days — e.g. "you open x.com
    /// within the first 5 minutes of almost every long session."
    static func habitSuggestions(history: [FocusSegment], distractors: [String]) -> [FocusSuggestion] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: history) { cal.startOfDay(for: $0.startedAt) }

        var longSessions = 0
        var earlyPulls: [String: [Double]] = [:] // distractor → minutes-to-first-pull, one per session
        for (_, daySegs) in byDay {
            let segments = merge(daySegs)
            let distracting = segments.map { isDistracting($0.app, distractors: distractors) }
            for s in clusters(segments: segments, distracting: distracting)
            where s.elapsedSeconds >= longSession && s.onTaskSeconds >= 8 * 60 {
                longSessions += 1
                var seen = Set<String>()
                for block in s.timeline where block.kind == .distraction && seen.insert(block.label).inserted {
                    let delta = block.start.timeIntervalSince(s.start) / 60
                    if delta <= 8 { earlyPulls[block.label, default: []].append(delta) }
                }
            }
        }
        guard longSessions >= 3 else { return [] }

        var out: [FocusSuggestion] = []
        for (label, deltas) in earlyPulls.sorted(by: { $0.value.count > $1.value.count }) {
            let share = Double(deltas.count) / Double(longSessions)
            guard deltas.count >= 2, share >= 0.5 else { continue }
            let median = Int(deltas.sorted()[deltas.count / 2].rounded().clamped(to: 1...8))
            out.append(FocusSuggestion(
                icon: "repeat",
                text: "You open \(label) within the first \(median) minutes of a long focus session — it happened in \(deltas.count) of your last \(longSessions). Try blocking \(label) for the first 15 minutes of deep work.",
                goalTarget: label
            ))
            if out.count == 2 { break }
        }
        return out
    }

    // MARK: session enrichment (task name + expected duration)

    /// Names each session from captured window titles and estimates how long
    /// its content actually needed (word count ÷ reading speed). Uses the
    /// frames table, so it degrades gracefully when monitoring was off.
    static func enrich(_ sessions: [InterruptedSession]) async -> [InterruptedSession] {
        var out: [InterruptedSession] = []
        for var s in sessions {
            let frames = await Store.shared.frames(from: s.start, to: s.end)
            let anchorFrames = frames.filter { matches(frame: $0, anchor: s.anchor) }
            if let title = dominantTitle(in: anchorFrames, anchor: s.anchor) { s.title = title }
            // A reading estimate only makes sense for web content.
            if s.anchor.contains("."), !s.anchor.contains(" ") {
                var lines = Set<String>()
                for f in anchorFrames {
                    for line in f.ocrText.split(separator: "\n") {
                        let t = line.trimmingCharacters(in: .whitespaces)
                        if t.count > 12 { lines.insert(t) }
                    }
                }
                let words = lines.reduce(0) { $0 + $1.split(separator: " ").count }
                if words >= 400 {
                    s.expectedSeconds = max(180, Double(words) / 220 * 60) // ~220 wpm
                }
            }
            out.append(s)
        }
        return out
    }

    private static func matches(frame: FrameRecord, anchor: String) -> Bool {
        if anchor.contains("."), !anchor.contains(" ") {
            guard let url = frame.url, let host = URL(string: url)?.host?.lowercased() else { return false }
            let h = host.replacingOccurrences(of: "www.", with: "")
            return h == anchor || h.hasSuffix("." + anchor)
        }
        return frame.appName == anchor
    }

    private static let browserNames = [
        "google chrome", "brave", "safari", "arc", "microsoft edge", "firefox", "chromium",
    ]

    /// Most-seen window title in the session, stripped of browser suffixes.
    private static func dominantTitle(in frames: [FrameRecord], anchor: String) -> String? {
        var counts: [String: Int] = [:]
        for f in frames {
            let cleaned = cleanTitle(f.windowTitle, anchor: anchor)
            if cleaned.count >= 8 { counts[cleaned, default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    private static func cleanTitle(_ raw: String, anchor: String) -> String {
        var parts = raw.components(separatedBy: " - ")
            .flatMap { $0.components(separatedBy: " — ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while let last = parts.last?.lowercased(),
              browserNames.contains(last) || last == anchor.lowercased()
              || last.contains("audio playing") || last.hasPrefix("high memory") {
            parts.removeLast()
        }
        let title = parts.joined(separator: " - ")
        return title.count > 70 ? String(title.prefix(67)) + "…" : title
    }

    // MARK: suggestions

    private static let messagingHints = ["whatsapp", "telegram", "discord", "messages", "slack"]

    private static func suggest(report: FocusReport) -> [FocusSuggestion] {
        var out: [FocusSuggestion] = []
        let mins = { (s: Double) in Int((s / 60).rounded()) }

        if let top = report.pulls.first, top.count >= 3 {
            out.append(FocusSuggestion(
                icon: "target",
                text: "\(top.label) pulled you away \(top.count)× today (≈\(mins(top.totalSeconds)) min). A daily limit turns that into one conscious visit.",
                goalTarget: top.label,
                goalMinutes: max(10, min(30, mins(top.totalSeconds) / 2))
            ))
        }

        let messagingPulls = report.pulls.filter { p in messagingHints.contains { p.label.lowercased().contains($0) } }
        let checkIns = messagingPulls.reduce(0) { $0 + $1.count }
        if checkIns >= 5 {
            let avg = messagingPulls.reduce(0.0) { $0 + $1.totalSeconds } / Double(max(checkIns, 1))
            out.append(FocusSuggestion(
                icon: "bubble.left.and.bubble.right",
                text: "You checked messages \(checkIns) times (avg \(Int(avg / 60).clamped(to: 1...99)) min each). Batch them: three scheduled check-ins beat \(checkIns) interruptions."
            ))
        }

        if let worst = report.hourlyDistraction.enumerated().max(by: { $0.element < $1.element }),
           worst.element >= 10 * 60 {
            out.append(FocusSuggestion(
                icon: "clock.badge.exclamationmark",
                text: "\(String(format: "%02d:00–%02d:00", worst.offset, (worst.offset + 1) % 24)) is your leakiest hour (\(mins(worst.element)) min drifted). Guard it — or schedule shallow work there on purpose."
            ))
        }

        if let s = report.sessions.first, s.efficiency < 0.75 {
            out.append(FocusSuggestion(
                icon: "book",
                text: "Your \(s.title ?? s.anchor) session took \(mins(s.elapsedSeconds)) min for \(mins(s.onTaskSeconds)) min of actual attention. Try fullscreen + Do Not Disturb for stretches like that."
            ))
        }

        let activeHours = max(report.activeSeconds / 3600, 0.5)
        let perHour = Double(report.switches) / activeHours
        if perHour > 20 {
            out.append(FocusSuggestion(
                icon: "arrow.triangle.swap",
                text: "\(Int(perHour)) app switches per active hour. Each one costs re-entry time — group similar tasks and close what you're not using."
            ))
        }

        if out.isEmpty, !report.isEmpty {
            out.append(FocusSuggestion(
                icon: "checkmark.seal",
                text: "Clean day so far — no distraction pattern worth flagging. Keep the streak going."
            ))
        }
        return out
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

/// Optional LLM layer on top of the deterministic report: 2-4 personalised,
/// specific coaching tips. Cached like InsightsService so the tab stays instant.
enum FocusCoach {
    private static let cacheKey = "clemFocusCoach"
    private static let stampKey = "clemFocusCoachAt"

    static var cached: [String] { UserDefaults.standard.stringArray(forKey: cacheKey) ?? [] }
    static var generatedAt: Date? { UserDefaults.standard.object(forKey: stampKey) as? Date }

    private struct Wrap: Decodable { let tips: [String] }

    static func generate(settings: Settings, report: FocusReport) async -> [String] {
        let llm = settings.llm
        guard await llm.isUp(), !report.isEmpty else { return cached }

        let mins = { (s: Double) in "\(Int((s / 60).rounded()))m" }
        var ctx = "Today's attention report:\n"
        ctx += "- Active screen time: \(mins(report.activeSeconds)), inside distractions: \(mins(report.distractedSeconds)) (focus score \(Int(report.focusScore * 100))%)\n"
        ctx += "- App/site switches: \(report.switches), longest unbroken focus: \(mins(report.longestStreakSeconds))\n"
        if !report.pulls.isEmpty {
            ctx += "- Top pulls: " + report.pulls.prefix(5).map { "\($0.label) ×\($0.count) (\(mins($0.totalSeconds)))" }.joined(separator: ", ") + "\n"
        }
        for s in report.sessions.prefix(3) {
            let name = s.title.map { "\"\($0)\" on \(s.anchor)" } ?? s.anchor
            ctx += "- Fragmented session: \(name) — \(mins(s.elapsedSeconds)) elapsed for \(mins(s.onTaskSeconds)) on task, \(s.detourCount) detours (\(s.detours.map { "\($0.label) ×\($0.count)" }.joined(separator: ", ")))\n"
        }

        let system = """
        You are Clem's focus coach. From the user's attention report, give 2-4 concrete, personalised tips to reduce distraction tomorrow.
        Respond ONLY with JSON: {"tips":["...", "..."]}
        Rules:
        - Each tip is one sentence, specific to the data (name the actual apps/sites/hours), and actionable tomorrow.
        - No generic advice ("take breaks", "use a pomodoro") unless tied directly to a pattern in the data.
        - Warm, direct, zero filler.
        """
        guard let data = try? await llm.completeJSON(system: system, user: ctx, timeout: 60),
              let wrap = try? JSONDecoder().decode(Wrap.self, from: data), !wrap.tips.isEmpty else { return cached }
        UserDefaults.standard.set(wrap.tips, forKey: cacheKey)
        UserDefaults.standard.set(Date(), forKey: stampKey)
        return wrap.tips
    }
}
