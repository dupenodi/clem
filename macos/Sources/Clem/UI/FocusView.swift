import SwiftUI

struct DayScore: Identifiable {
    var day: Date
    var score: Double?      // nil = not enough tracked time that day
    var activeSeconds: Double
    var id: Date { day }
}

@MainActor
final class FocusVM: ObservableObject {
    @Published var report = FocusReport()
    @Published var dayScores: [DayScore] = []   // last 7 days, oldest first
    @Published var selectedDay = Calendar.current.startOfDay(for: Date())
    @Published var todayLabels: [AppSpan] = []
    @Published var coachTips: [String] = FocusCoach.cached
    @Published var coachLoading = false
    @Published var loaded = false

    private var history: [FocusSegment] = []

    var isToday: Bool { Calendar.current.isDateInToday(selectedDay) }

    /// Score of the day before the selected one (for the "vs yesterday" delta).
    var previousScore: Double? {
        guard let i = dayScores.firstIndex(where: { $0.day == selectedDay }), i > 0 else { return nil }
        return dayScores[i - 1].score
    }

    func refresh(settings: Settings) {
        let distractors = settings.distractingLabels
        Task {
            self.history = await Store.shared.focusSegments(daysBack: 14)
            self.todayLabels = await Store.shared.todayAppTime()
            await self.rebuild(distractors: distractors)
            self.loaded = true
        }
    }

    func select(day: Date, settings: Settings) {
        guard day != selectedDay else { return }
        selectedDay = day
        let distractors = settings.distractingLabels
        Task { await self.rebuild(distractors: distractors) }
    }

    private func rebuild(distractors: [String]) async {
        let cal = Calendar.current
        let daySegs = history.filter { cal.startOfDay(for: $0.startedAt) == selectedDay }
        var r = FocusService.analyze(segments: daySegs, distractors: distractors)
        r.sessions = await FocusService.enrich(r.sessions)
        // Cross-day patterns only make sense on the live day.
        if isToday {
            r.suggestions = FocusService.habitSuggestions(history: history, distractors: distractors)
                + r.suggestions
        }
        var scores: [DayScore] = []
        for back in stride(from: 6, through: 0, by: -1) {
            let day = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: Date()))!
            let segs = history.filter { cal.startOfDay(for: $0.startedAt) == day }
            let rep = FocusService.analyze(segments: segs, distractors: distractors)
            scores.append(DayScore(day: day, score: rep.activeSeconds >= 600 ? rep.focusScore : nil,
                                   activeSeconds: rep.activeSeconds))
        }
        report = r
        dayScores = scores
    }

    func refreshCoach(settings: Settings) {
        guard !coachLoading else { return }
        coachLoading = true
        let r = report
        Task {
            let tips = await FocusCoach.generate(settings: settings, report: r)
            await MainActor.run {
                self.coachTips = tips
                self.coachLoading = false
            }
        }
    }
}

/// "Focus" — where your attention actually went: how often you got pulled
/// away, what did the pulling, which tasks fragmented, and what to do about it.
struct FocusView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var vm = FocusVM()
    @ObservedObject private var sessionCenter = FocusSessionCenter.shared
    @State private var pickTarget = ""
    @State private var pickMinutes = 25
    @State private var editingDistractors = false
    @State private var limitsSet: Set<String> = []
    @State private var expandedSessions: Set<String> = []
    @State private var selectedHour: Int?

    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var dateLine: String {
        if vm.isToday { return "TODAY" }
        if Calendar.current.isDateInYesterday(vm.selectedDay) { return "YESTERDAY" }
        let f = DateFormatter(); f.dateFormat = "EEEE, d MMMM"
        return f.string(from: vm.selectedDay).uppercased()
    }

    var body: some View {
        // Full-window two-pane layout: the story on the left, the ambient
        // "embers" field + reference charts on the right rail.
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    focusSessionCard
                    if vm.report.isEmpty {
                        emptyState
                        exampleTaskCard
                    } else {
                        heroRow
                        statRow
                        if !vm.report.dayTimeline.isEmpty { timelineSection }
                        if !vm.report.sessions.isEmpty { sessionsSection }
                        if !vm.report.pulls.isEmpty { pullsSection }
                        suggestionsSection
                    }
                }
                .padding(.horizontal, 44)
                .padding(.top, 40).padding(.bottom, 44)
                .frame(maxWidth: 900, alignment: .leading)
                // Stretch the scroll content to the pane so the scrollbar
                // sits against the rail divider, not the text column.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(Theme.line).frame(width: 1)

            rightRail
        }
        .onAppear { vm.refresh(settings: engine.settings) }
        .onReceive(ticker) { _ in vm.refresh(settings: engine.settings) }
    }

    // MARK: right rail — embers + reference charts

    private var rightRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ZStack {
                    AttentionOrbit(
                        pulls: vm.report.pulls.reduce(0) { $0 + $1.count },
                        score: vm.report.focusScore,
                        locked: sessionCenter.session != nil
                    )
                    if let s = sessionCenter.session {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            VStack(spacing: 3) {
                                Text(clock(max(0, s.endsAt.timeIntervalSinceNow)))
                                    .font(Theme.mono(22, .medium)).foregroundStyle(Theme.ink)
                                Text(s.target).font(Theme.ui(10)).foregroundStyle(Theme.ink(0.5))
                            }
                        }
                    }
                }
                .frame(height: 280)
                .frame(maxWidth: .infinity)

                Text(embersCaption)
                    .font(Theme.ui(10)).foregroundStyle(Theme.ink(0.35)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                trendPicker
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tablet(padding: 14)

                hourlySection
                distractorEditor
                eyesOnScreenCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 36).padding(.bottom, 30)
        }
        .frame(width: 340)
        .background(Theme.bg.opacity(0.4))
    }

    private var embersCaption: String {
        let pulls = vm.report.pulls.reduce(0) { $0 + $1.count }
        if sessionCenter.session != nil {
            return "Locked in. The core holds your timer — every orange ember around it is a time you drifted today."
        }
        if pulls == 0 {
            return "Your attention in orbit. No embers yet — every time something pulls you away, one ignites."
        }
        return "Your attention in orbit — each of the \(min(pulls, 26)) orange embers is a time you got pulled away today. Focused days draw the dust tight to the core."
    }

    private func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    // MARK: header + day trend

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dateLine).font(Theme.ui(10, .semibold)).kerning(2).foregroundStyle(Theme.ink(0.4))
            Text("Where your attention went").font(Theme.display(30, .medium)).foregroundStyle(Theme.ink)
        }
    }

    /// 7-day focus-score bars that double as the day switcher.
    private var trendPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(vm.dayScores) { d in
                    let selected = d.day == vm.selectedDay
                    let hasData = d.score != nil
                    Button { vm.select(day: d.day, settings: engine.settings) } label: {
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(selected ? scoreColor(d.score ?? 0)
                                      : hasData ? Theme.ink(0.25) : Theme.ink(0.07))
                                .frame(width: 16, height: hasData ? max(6, 34 * (d.score ?? 0)) : 5)
                            Text(weekdayLetter(d.day))
                                .font(Theme.mono(8))
                                .foregroundStyle(selected ? Theme.ink(0.85) : Theme.ink(0.35))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasData && !Calendar.current.isDateInToday(d.day))
                    .help(hasData ? "\(dayName(d.day)) — focus score \(Int((d.score ?? 0) * 100))%"
                          : "\(dayName(d.day)) — not enough tracked time")
                }
            }
            HStack(spacing: 4) {
                Text("LAST 7 DAYS · CLICK A DAY").font(Theme.ui(7, .semibold)).kerning(1).foregroundStyle(Theme.ink(0.3))
                InfoDot(title: "Focus score by day",
                        text: "Each bar is that day's focus score — the share of active screen time NOT spent inside apps and sites you've marked distracting. Click a bar to replay that day; grey stubs had under 10 minutes of tracked time.")
            }
        }
    }

    // MARK: focus session (lock in)

    private var focusSessionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "scope").font(.system(size: 11)).foregroundStyle(Theme.accent)
                Text("FOCUS SESSION").font(Theme.ui(9, .semibold)).kerning(1.5).foregroundStyle(Theme.ink(0.4))
                InfoDot(title: "Focus session",
                        text: "Pick one app or site and a timer. While it runs, everything else counts as a distraction. Clem checks what's in front of you every ~8 seconds and nudges you with a banner over whatever you're doing — instantly from your third detour, or any time you stay away from the target for more than a minute.")
                Spacer()
            }
            if let s = sessionCenter.session {
                activeSession(s)
            } else {
                sessionSetup
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tablet(padding: 16)
    }

    private func activeSession(_ s: FocusSessionCenter.Session) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let remaining = max(0, s.endsAt.timeIntervalSinceNow)
            let progress = 1 - remaining / max(s.totalSeconds, 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Locked in: \(s.target)").font(Theme.display(17)).foregroundStyle(Theme.ink(0.92))
                        HStack(spacing: 8) {
                            Text(countdown(remaining)).font(Theme.mono(12, .medium)).foregroundStyle(Theme.accent2)
                            Text("·").foregroundStyle(Theme.ink(0.3))
                            detourDots(s.excursions)
                        }
                    }
                    Spacer()
                    Button { sessionCenter.end() } label: {
                        Text("End session").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.ink(0.55))
                            .padding(.vertical, 6).padding(.horizontal, 11)
                            .background(Theme.ink(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.ink(0.08))
                        Capsule().fill(Theme.accent2.opacity(0.8))
                            .frame(width: max(4, geo.size.width * progress))
                    }
                }
                .frame(height: 4)
            }
        }
    }

    private func detourDots(_ n: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(i < n ? Theme.accent : Theme.ink(0.15)).frame(width: 6, height: 6)
            }
            Text(n == 0 ? "no detours yet" : n > 2 ? "\(n) detours — nudging you now" : "\(n) detour\(n == 1 ? "" : "s") — stay away over a minute and I speak up")
                .font(Theme.ui(10)).foregroundStyle(n > 2 ? Theme.accent : Theme.ink(0.45))
        }
    }

    private var sessionSetup: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(sessionTargets, id: \.self) { t in
                    Button(t) { pickTarget = t }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(pickTarget.isEmpty ? "Pick your one thing" : pickTarget)
                        .font(Theme.ui(12, .medium))
                        .foregroundStyle(pickTarget.isEmpty ? Theme.ink(0.45) : Theme.ink(0.9))
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.ink(0.4))
                }
                .padding(.vertical, 7).padding(.horizontal, 12)
                .background(Theme.ink(0.05), in: Capsule())
                .overlay(Capsule().stroke(Theme.line))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()

            HStack(spacing: 4) {
                ForEach([15, 25, 45, 60], id: \.self) { m in
                    Button {
                        pickMinutes = m
                    } label: {
                        Text("\(m)m")
                            .font(Theme.ui(11, pickMinutes == m ? .semibold : .regular))
                            .foregroundStyle(pickMinutes == m ? Theme.ink(0.95) : Theme.ink(0.45))
                            .padding(.vertical, 6).padding(.horizontal, 9)
                            .background(pickMinutes == m ? Theme.ink(0.1) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            Button {
                guard !pickTarget.isEmpty else { return }
                sessionCenter.start(target: pickTarget, minutes: pickMinutes)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 9))
                    Text("Lock in").font(Theme.ui(12, .semibold))
                }
                .foregroundStyle(pickTarget.isEmpty ? Theme.ink(0.35) : Theme.bg)
                .padding(.vertical, 7).padding(.horizontal, 14)
                .background(pickTarget.isEmpty ? Theme.ink(0.08) : Theme.accent2, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(pickTarget.isEmpty)
            .help(pickTarget.isEmpty ? "Pick an app or site first" : "Start the focus timer")
        }
    }

    /// Everything you've touched today, busiest first — candidates for "the
    /// one thing".
    private var sessionTargets: [String] {
        var seen = Set<String>()
        return vm.todayLabels.filter { seen.insert($0.app.lowercased()).inserted }.prefix(14).map(\.app)
    }

    private func countdown(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%02d:%02d left", t / 60, t % 60)
    }

    // MARK: hero — score ring + plain-English narrative

    private var heroRow: some View {
        HStack(spacing: 24) {
            scoreRing
            VStack(alignment: .leading, spacing: 8) {
                Text(narrative)
                    .font(Theme.display(17)).foregroundStyle(Theme.ink(0.9)).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if let prev = vm.previousScore {
                        let delta = Int((vm.report.focusScore - prev) * 100)
                        HStack(spacing: 4) {
                            Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 9, weight: .bold))
                            Text("\(abs(delta)) pts vs previous day").font(Theme.ui(11, .medium))
                        }
                        .foregroundStyle(delta >= 0 ? Theme.accent2 : Theme.accent)
                    }
                    InfoDot(title: "How the focus score works",
                            text: "Focus score = time outside distractions ÷ total active screen time. Clem tracks the app or site in front of you every few seconds (pausing when you're idle or locked). You decide what counts as a distraction in the list at the bottom of this page.")
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tablet(padding: 20)
    }

    private var scoreRing: some View {
        let score = vm.report.focusScore
        return ZStack {
            Circle().stroke(Theme.ink(0.08), lineWidth: 9)
            Circle()
                .trim(from: 0, to: max(0.02, score))
                .stroke(scoreColor(score), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: score)
            VStack(spacing: 1) {
                Text("\(Int(score * 100))%").font(Theme.display(24)).foregroundStyle(Theme.ink)
                Text("FOCUS").font(Theme.ui(7, .semibold)).kerning(1.4).foregroundStyle(Theme.ink(0.4))
            }
        }
        .frame(width: 104, height: 104)
    }

    private var narrative: String {
        let r = vm.report
        let pulls = r.pulls.reduce(0) { $0 + $1.count }
        var line = "Of \(fmt(r.activeSeconds)) on screen, \(fmt(r.distractedSeconds)) drifted into distractions"
        line += pulls > 0 ? " across \(pulls) pulls." : "."
        if r.longestStreakSeconds >= 300 {
            line += " Your longest clean run was \(fmt(r.longestStreakSeconds))."
        }
        return line
    }

    // MARK: stats

    private var statRow: some View {
        HStack(spacing: 12) {
            stat(icon: "bolt.fill", value: fmt(vm.report.longestStreakSeconds), label: "LONGEST STREAK",
                 help: "Your longest stretch of screen time without a distraction lasting 45 seconds or more. Quick glances don't break it.")
            stat(icon: "arrow.left.arrow.right", value: "\(vm.report.switches)", label: "SWITCHES",
                 help: "How many times you changed app or site. Every switch costs re-entry time — studies put it at up to 20 minutes to fully refocus.")
            stat(icon: "wind", value: fmt(vm.report.distractedSeconds), label: "DRIFTED",
                 help: "Total time spent inside apps and sites you've marked as distracting.")
            stat(icon: "magnet", value: "\(vm.report.pulls.reduce(0) { $0 + $1.count })", label: "TIMES PULLED",
                 help: "How many times a distraction yanked you away from something you were working on — switching from work into a distracting app or site.")
        }
    }

    private func stat(icon: String, value: String, label: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.accent.opacity(0.8))
                Spacer()
                InfoDot(title: label.capitalized, text: help)
            }
            Text(value).font(Theme.display(24)).foregroundStyle(Theme.ink)
            Text(label).font(Theme.ui(8, .semibold)).kerning(1.2).foregroundStyle(Theme.ink(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tablet(padding: 14)
        .help(help)
    }

    // MARK: day timeline

    @State private var showAllBlocks = false

    private var timelineSection: some View {
        let blocks = vm.report.dayTimeline
        let majors = blocks.filter { $0.seconds >= 180 }
        let shown = showAllBlocks ? blocks : Array(majors.suffix(12))
        return VStack(alignment: .leading, spacing: 10) {
            sectionLabel("calendar.day.timeline.left", "THE DAY, MINUTE BY MINUTE",
                         info: "Your whole day as one strip — every block is a continuous stretch on a single app or site. Orange blocks are distractions; pale blocks are everything else; gaps are time away from the screen. Hover the strip for details, or expand the list below it.")
            VStack(alignment: .leading, spacing: 12) {
                dayRibbon(blocks)
                if !shown.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(shown) { b in timelineRow(b) }
                    }
                }
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showAllBlocks.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showAllBlocks ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                        Text(showAllBlocks ? "Show highlights only" : "Show all \(blocks.count) blocks")
                            .font(Theme.ui(10, .medium))
                    }
                    .foregroundStyle(Theme.ink(0.45))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tablet(padding: 16)
        }
    }

    /// The whole day as a proportional strip — embers on dust.
    private func dayRibbon(_ blocks: [TimelineBlock]) -> some View {
        let hf = DateFormatter(); hf.dateFormat = "HH:mm"
        let start = blocks.first?.start ?? Date()
        let end = blocks.last?.end ?? Date()
        let span = max(end.timeIntervalSince(start), 60)
        return VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink(0.05))
                    ForEach(blocks) { b in
                        Rectangle()
                            .fill(b.kind == .distraction ? Theme.accent.opacity(0.9) : Theme.ink(0.3))
                            .frame(width: max(1.5, geo.size.width * b.seconds / span))
                            .offset(x: geo.size.width * b.start.timeIntervalSince(start) / span)
                            .help("\(hf.string(from: b.start))–\(hf.string(from: b.end))  \(b.label) · \(fmt(b.seconds))")
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)
            HStack {
                Text(hf.string(from: start)).font(Theme.mono(9)).foregroundStyle(Theme.ink(0.35))
                Spacer()
                Text(hf.string(from: end)).font(Theme.mono(9)).foregroundStyle(Theme.ink(0.35))
            }
        }
    }

    private func timelineRow(_ b: TimelineBlock) -> some View {
        let hf = DateFormatter(); hf.dateFormat = "HH:mm"
        return HStack(spacing: 10) {
            Text("\(hf.string(from: b.start))–\(hf.string(from: b.end))")
                .font(Theme.mono(10)).foregroundStyle(Theme.ink(0.4))
                .frame(width: 82, alignment: .leading)
            Circle()
                .fill(b.kind == .distraction ? Theme.accent : Theme.ink(0.35))
                .frame(width: 5, height: 5)
            Text(b.label)
                .font(Theme.ui(11, b.kind == .distraction ? .medium : .regular))
                .foregroundStyle(b.kind == .distraction ? Theme.ink(0.85) : Theme.ink(0.55))
                .lineLimit(1)
            Spacer()
            Text(fmt(b.seconds)).font(Theme.mono(10)).foregroundStyle(Theme.ink(0.4))
        }
        .padding(.vertical, 4)
    }

    // MARK: fragmented sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("timeline.selection", "WHERE FOCUS LEAKED",
                         info: "Clem notices when you keep returning to the same app or site — that's one task. These cards show tasks where real time leaked into detours. \"Expected\" estimates how long the content actually needed, from its word count at a normal reading speed.")
            VStack(spacing: 10) {
                ForEach(vm.report.sessions) { s in sessionCard(s) }
            }
        }
    }

    private func sessionCard(_ s: InterruptedSession) -> some View {
        let hf = DateFormatter(); hf.dateFormat = "HH:mm"
        let expanded = expandedSessions.contains(s.id)
        return VStack(alignment: .leading, spacing: 12) {
            // task header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.title ?? s.anchor)
                        .font(Theme.display(17)).foregroundStyle(Theme.ink(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(s.anchor) · \(hf.string(from: s.start))–\(hf.string(from: s.end))")
                        .font(Theme.mono(10)).foregroundStyle(Theme.ink(0.35))
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(s.efficiency * 100))%")
                        .font(Theme.display(22))
                        .foregroundStyle(scoreColor(s.efficiency))
                    Text("ATTENTION").font(Theme.ui(7, .semibold)).kerning(1).foregroundStyle(Theme.ink(0.35))
                }
            }

            // expected vs actual vs on-task vs away
            HStack(spacing: 0) {
                if let exp = s.expectedSeconds {
                    miniStat("EXPECTED", "~" + fmt(exp))
                }
                miniStat("ACTUAL", fmt(s.elapsedSeconds))
                miniStat("ON IT", fmt(s.onTaskSeconds))
                miniStat("AWAY", fmt(s.awaySeconds), hot: s.awaySeconds > s.onTaskSeconds)
            }

            // elapsed bar: filled part = time on task, hollow = leaked
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink(0.08))
                    Capsule().fill(scoreColor(s.efficiency).opacity(0.8))
                        .frame(width: max(6, geo.size.width * s.efficiency))
                }
            }
            .frame(height: 5)

            // timeline (expandable)
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if expanded { expandedSessions.remove(s.id) } else { expandedSessions.insert(s.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text("TIMELINE").font(Theme.ui(8, .semibold)).kerning(1.2)
                    Spacer()
                    Text("pulled away \(s.detourCount)× — \(s.detours.map { "\($0.label) ×\($0.count)" }.joined(separator: ", "))")
                        .font(Theme.ui(10)).foregroundStyle(Theme.ink(0.4)).lineLimit(1)
                }
                .foregroundStyle(Theme.ink(0.45))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 0) {
                    ForEach(s.timeline) { b in
                        HStack(spacing: 10) {
                            Text("\(hf.string(from: b.start))–\(hf.string(from: b.end))")
                                .font(Theme.mono(10)).foregroundStyle(Theme.ink(0.4))
                                .frame(width: 82, alignment: .leading)
                            Circle()
                                .fill(b.kind == .onTask ? Theme.accent2
                                      : b.kind == .distraction ? Theme.accent : Theme.ink(0.3))
                                .frame(width: 5, height: 5)
                            Text(b.kind == .onTask ? "\(b.label)  ·  on task" : b.label)
                                .font(Theme.ui(11, b.kind == .distraction ? .medium : .regular))
                                .foregroundStyle(b.kind == .distraction ? Theme.ink(0.85) : Theme.ink(0.55))
                            Spacer()
                            Text(fmt(b.seconds)).font(Theme.mono(10)).foregroundStyle(Theme.ink(0.4))
                        }
                        .padding(.vertical, 5)
                    }
                }
                .padding(.leading, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tablet(padding: 16)
    }

    private func miniStat(_ label: String, _ value: String, hot: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.ui(13, .semibold)).foregroundStyle(hot ? Theme.accent : Theme.ink(0.85))
            Text(label).font(Theme.ui(7, .semibold)).kerning(1).foregroundStyle(Theme.ink(0.35))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: pulls

    private var pullsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("magnet", "WHAT PULLS YOU AWAY",
                         info: "Ranked by how many times each one yanked you off a task — not just total time. \"Set a limit\" creates a daily-limit Goal (see the Goals tab) sized to roughly half of what it took today.")
            VStack(spacing: 0) {
                ForEach(Array(vm.report.pulls.prefix(6).enumerated()), id: \.element.id) { i, p in
                    if i > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 16) }
                    pullRow(p)
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .grain(cornerRadius: 12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
        }
    }

    private func pullRow(_ p: DistractionPull) -> some View {
        let hasGoal = limitsSet.contains(p.label) || GoalStore.shared.goals.contains { $0.target == p.label && $0.kind == .limit }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.label).font(Theme.ui(13, .medium)).foregroundStyle(Theme.ink(0.85))
                Text("pulled you \(p.count)× · \(fmt(p.totalSeconds)) total · ~\(fmt(p.avgSeconds)) a visit")
                    .font(Theme.ui(11)).foregroundStyle(Theme.ink(0.45))
            }
            Spacer()
            if hasGoal {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    Text("Limit set").font(Theme.ui(11, .medium))
                }
                .foregroundStyle(Theme.ink(0.45))
            } else {
                Button {
                    let minutes = max(10, min(30, Int(p.totalSeconds / 120)))
                    GoalStore.shared.add(Goal(kind: .limit, target: p.label, minutes: minutes, createdAt: Date()))
                    limitsSet.insert(p.label)
                } label: {
                    Text("Set a limit").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.accent)
                        .padding(.vertical, 5).padding(.horizontal, 10)
                        .background(Theme.accent.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Create a daily limit goal for \(p.label)")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: hourly strip (click a bar for the culprits)

    private var hourlySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("chart.bar.xaxis", "DISTRACTION BY HOUR",
                         info: "How many distracted minutes fell in each hour of the day. Click a bar to see exactly what did the damage in that hour.")
            VStack(alignment: .leading, spacing: 8) {
                let maxVal = max(vm.report.hourlyDistraction.max() ?? 1, 60)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(0..<24, id: \.self) { h in
                        let v = vm.report.hourlyDistraction[h]
                        VStack(spacing: 4) {
                            Button { if v > 0 { selectedHour = selectedHour == h ? nil : h } } label: {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(v > 0 ? Theme.accent.opacity(0.25 + 0.75 * v / maxVal) : Theme.ink(0.08))
                                    .frame(height: max(4, 44 * v / maxVal))
                                    .frame(maxHeight: 44, alignment: .bottom)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: Binding(
                                get: { selectedHour == h },
                                set: { if !$0 { selectedHour = nil } }
                            ), arrowEdge: .bottom) { hourDetail(h) }
                            .help(v > 0 ? "\(String(format: "%02d:00", h)) — \(fmt(v)) drifted · click for details" : String(format: "%02d:00", h))
                            Text(h % 6 == 0 ? String(format: "%02d", h) : " ")
                                .font(Theme.mono(8)).foregroundStyle(Theme.ink(0.3))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .tablet(padding: 16)
        }
    }

    private func hourDetail(_ h: Int) -> some View {
        let items = vm.report.hourlyDetail[h].sorted { $0.value > $1.value }.prefix(5)
        return VStack(alignment: .leading, spacing: 8) {
            Text(String(format: "%02d:00–%02d:00", h, (h + 1) % 24))
                .font(Theme.ui(11, .semibold)).foregroundStyle(Theme.ink)
            ForEach(Array(items), id: \.key) { label, secs in
                HStack(spacing: 8) {
                    Circle().fill(Theme.accent).frame(width: 4, height: 4)
                    Text(label).font(Theme.ui(11)).foregroundStyle(Theme.ink(0.8))
                    Spacer(minLength: 16)
                    Text(fmt(secs)).font(Theme.mono(10)).foregroundStyle(Theme.ink(0.5))
                }
            }
        }
        .padding(12)
        .frame(minWidth: 190, alignment: .leading)
    }

    // MARK: suggestions

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("lightbulb.max", "WHAT TO DO ABOUT IT",
                             info: "Rule-based suggestions from today's data, plus recurring patterns spotted across your last 14 days (marked ↻). \"Ask Clem\" adds personalised tips from your configured model.")
                Spacer()
                if vm.isToday {
                    if vm.coachLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button { vm.refreshCoach(settings: engine.settings) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "wand.and.stars").font(.system(size: 10))
                                Text(vm.coachTips.isEmpty ? "Ask Clem" : "Refresh").font(Theme.ui(11, .medium))
                            }.foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .help("Personalised coaching from your configured model")
                    }
                }
            }
            VStack(spacing: 0) {
                let rows: [(String, String)] = vm.report.suggestions.map { ($0.icon, $0.text) }
                    + (vm.isToday ? vm.coachTips.map { ("wand.and.stars", $0) } : [])
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 46) }
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: row.0).font(.system(size: 13)).foregroundStyle(Theme.accent).frame(width: 20)
                        Text(row.1).font(Theme.ui(12.5)).foregroundStyle(Theme.ink(0.8)).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .grain(cornerRadius: 12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
        }
    }

    // MARK: distractor editor

    private var distractorEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.15)) { editingDistractors.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: editingDistractors ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("WHAT COUNTS AS A DISTRACTION")
                        .font(Theme.ui(9, .semibold)).kerning(1.5)
                }
                .foregroundStyle(Theme.ink(0.4))
            }
            .buttonStyle(.plain)

            if editingDistractors {
                let labels = editorLabels
                VStack(alignment: .leading, spacing: 10) {
                    Text("Everything above is measured against this list. Tap anything you used today to flip it — flames are distractions, everything else counts as focus.")
                        .font(Theme.ui(11)).foregroundStyle(Theme.ink(0.45))
                    FlowChips(labels: labels, isOn: { label in
                        FocusService.isDistracting(label, distractors: engine.settings.distractingLabels)
                    }, toggle: { label in
                        toggleDistractor(label)
                    })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tablet(padding: 16)
            }
        }
    }

    private var editorLabels: [String] {
        var seen = Set<String>()
        return vm.todayLabels.filter {
            // Off-screen is a built-in bucket, always distracting — not editable.
            $0.app != GazeService.offScreenLabel
                && $0.seconds >= 60 && seen.insert($0.app.lowercased()).inserted
        }
        .prefix(24).map(\.app)
    }

    // MARK: eyes on screen (webcam idle arbitration)

    private var eyesOnScreenCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "eye").font(.system(size: 11)).foregroundStyle(Theme.accent)
                Text("EYES ON SCREEN").font(Theme.ui(9, .semibold)).kerning(1.5).foregroundStyle(Theme.ink(0.4))
                Text("BETA").font(Theme.ui(7, .semibold)).kerning(0.8)
                    .foregroundStyle(Theme.accent2)
                    .padding(.vertical, 2).padding(.horizontal, 5)
                    .background(Theme.accent2.opacity(0.12), in: Capsule())
                Spacer()
                Toggle("", isOn: Binding(
                    get: { engine.settings.gazeCheckEnabled },
                    set: { engine.settings.gazeCheckEnabled = $0 }
                ))
                .toggleStyle(.switch).controlSize(.mini).tint(Theme.accent2)
            }
            Text("Normally, 2 minutes without typing or clicking counts as \u{201C}away\u{201D} — even mid-video or deep in a long read. With this on, Clem glances through the webcam when you go idle: still looking at the screen keeps counting as focus; looking elsewhere becomes an \u{201C}Off-screen\u{201D} distraction (it can even trigger focus-session nudges).")
                .font(Theme.ui(10.5)).foregroundStyle(Theme.ink(0.45)).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Text("On-device only. No frames are ever stored or sent anywhere — the camera light blinks for ~2 s per check, at most once every 45 s, and only while you're idle.")
                .font(Theme.ui(9.5)).foregroundStyle(Theme.ink(0.32)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tablet(padding: 14)
    }

    private func toggleDistractor(_ label: String) {
        var list = engine.settings.distractingLabels
        if FocusService.isDistracting(label, distractors: list) {
            // Remove every rule that matches this label (default lists use
            // loose matches like "whatsapp").
            list.removeAll { FocusService.isDistracting(label, distractors: [$0]) }
        } else {
            list.append(label.lowercased())
        }
        engine.settings.distractingLabels = list
        vm.refresh(settings: engine.settings)
    }

    // MARK: bits

    private func sectionLabel(_ icon: String, _ text: String, info: String? = nil) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.accent)
            Text(text).font(Theme.ui(9, .semibold)).kerning(1.5).foregroundStyle(Theme.ink(0.4))
            if let info { InfoDot(title: text.capitalized, text: info) }
        }
    }

    /// One colour for every score/percentage — the theme's amber. Judgment is
    /// carried by the number, not a traffic light.
    private func scoreColor(_ score: Double) -> Color { Theme.accent2 }

    private func weekdayLetter(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEEE"
        return f.string(from: d).uppercased()
    }

    private func dayName(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter(); f.dateFormat = "EEEE"
        return f.string(from: d)
    }

    private func fmt(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    // MARK: empty state + example

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(vm.loaded ? (vm.isToday ? "Nothing to measure yet" : "No tracked time that day")
                 : "Reading your day…")
                .font(Theme.display(20)).foregroundStyle(Theme.ink(0.8))
            Text(vm.isToday
                 ? "Keep Clem running and go work. I'll map every time your attention drifted — which article took twice as long as it should have, what kept pulling you away, and what to change."
                 : "Clem wasn't tracking then. Pick another day in the trend above.")
                .font(Theme.ui(13)).foregroundStyle(Theme.ink(0.5)).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }

    /// A clearly-labelled, dimmed sample so a first-time user sees exactly
    /// what this tab will produce — never mistakable for real data.
    private var exampleTaskCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "eye").font(.system(size: 10))
                Text("EXAMPLE — WHAT A FRAGMENTED TASK LOOKS LIKE").font(Theme.ui(9, .semibold)).kerning(1.1)
            }
            .foregroundStyle(Theme.ink(0.4))

            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Read \u{201C}AI Safety Newsletter\u{201D}").font(Theme.display(15)).foregroundStyle(Theme.ink(0.65))
                        Text("substack.com · 10:00–10:31").font(Theme.mono(9)).foregroundStyle(Theme.ink(0.3))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("45%").font(Theme.display(19)).foregroundStyle(Theme.accent.opacity(0.75))
                        Text("ATTENTION").font(Theme.ui(6, .semibold)).kerning(1).foregroundStyle(Theme.ink(0.3))
                    }
                }
                HStack(spacing: 0) {
                    ForEach([("EXPECTED", "~12m"), ("ACTUAL", "31m"), ("ON IT", "14m"), ("AWAY", "17m")], id: \.0) { l, v in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.ink(0.55))
                            Text(l).font(Theme.ui(6, .semibold)).kerning(1).foregroundStyle(Theme.ink(0.3))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(spacing: 4) {
                    exampleRow("10:00–10:05", "substack.com · on task", true)
                    exampleRow("10:05–10:13", "x.com", false)
                    exampleRow("10:13–10:16", "WhatsApp", false)
                    exampleRow("10:16–10:23", "substack.com · on task", true)
                }
                Text("You always open x.com within 5 minutes of reading long articles. Try blocking it for the first 15 minutes.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.ink(0.45)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .opacity(0.9)
        .allowsHitTesting(false)
        .frame(maxWidth: 480)
    }

    private func exampleRow(_ time: String, _ label: String, _ onTask: Bool) -> some View {
        HStack(spacing: 8) {
            Text(time).font(Theme.mono(9)).foregroundStyle(Theme.ink(0.3)).frame(width: 72, alignment: .leading)
            Circle().fill(onTask ? Theme.accent2.opacity(0.6) : Theme.accent.opacity(0.6)).frame(width: 4, height: 4)
            Text(label).font(Theme.ui(10)).foregroundStyle(Theme.ink(onTask ? 0.4 : 0.55))
            Spacer()
        }
    }
}

/// Small "?" that pops a plain-language explanation of a metric.
private struct InfoDot: View {
    var title: String
    var text: String
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink(0.35))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.ui(11, .semibold)).foregroundStyle(Theme.ink)
                Text(text).font(Theme.ui(11)).foregroundStyle(Theme.ink(0.75)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 270, alignment: .leading)
        }
    }
}

/// A simple wrapping row of toggle chips.
private struct FlowChips: View {
    var labels: [String]
    var isOn: (String) -> Bool
    var toggle: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(labels, id: \.self) { label in
                let on = isOn(label)
                Button { toggle(label) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: on ? "flame.fill" : "circle")
                            .font(.system(size: 9))
                            .foregroundStyle(on ? Theme.accent : Theme.ink(0.35))
                        Text(label).font(Theme.ui(11, on ? .medium : .regular))
                            .foregroundStyle(on ? Theme.ink(0.9) : Theme.ink(0.55))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .background(on ? Theme.accent.opacity(0.12) : Theme.ink(0.04), in: Capsule())
                    .overlay(Capsule().stroke(on ? Theme.accent.opacity(0.35) : Theme.line))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
