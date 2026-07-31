import SwiftUI

@MainActor
final class BriefingVM: ObservableObject {
    @Published var briefing: Briefing?
    @Published var looseEnds: [LooseEnd] = []
    @Published var loading = false

    init() { apply(BriefingService.cached) }

    private func apply(_ b: Briefing?) {
        briefing = b
        let dismissed = BriefingService.dismissed
        looseEnds = (b?.looseEnds ?? []).filter { !dismissed.contains($0.key) }
    }

    func loadIfStale(engine: Engine) {
        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let staleDay = briefing?.day != today
        let staleTime = BriefingService.generatedAt.map { Date().timeIntervalSince($0) > 2 * 3600 } ?? true
        if briefing == nil || staleDay || staleTime { refresh(engine: engine) }
    }

    func refresh(engine: Engine) {
        guard !loading else { return }
        loading = true
        let settings = engine.settings
        let times = engine.appTimes
        Task {
            let b = await BriefingService.generate(settings: settings, appTimes: times)
            self.apply(b)
            self.loading = false
        }
    }

    func dismiss(_ end: LooseEnd) {
        BriefingService.dismiss(end)
        looseEnds.removeAll { $0.id == end.id }
    }
}

/// "Today" — the daily briefing: an auto-written recap of your day and the
/// loose ends you left behind. The reason to keep monitoring on.
struct TodayView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var vm = BriefingVM()

    private var dateLine: String {
        let f = DateFormatter(); f.dateFormat = "EEEE, d MMMM"
        return f.string(from: Date()).uppercased()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                // Main content on the left, the example column always on the
                // right — so users see what to expect whether or not they have
                // data yet.
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 22) {
                        if vm.briefing == nil && vm.loading {
                            loadingState
                        } else if let b = vm.briefing {
                            digestCard(b)
                            if !vm.looseEnds.isEmpty { looseEndsSection }
                        } else {
                            emptyState
                        }
                    }
                    .frame(maxWidth: 560, alignment: .leading)

                    Spacer(minLength: 24)

                    examplePreview.frame(width: 340)
                }
            }
            .padding(.horizontal, 44)
            .padding(.top, 40).padding(.bottom, 44)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { vm.loadIfStale(engine: engine) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(dateLine).font(Theme.ui(10, .semibold)).kerning(2).foregroundStyle(Theme.ink(0.4))
                Text("Your day, so far").font(Theme.display(30, .medium)).foregroundStyle(Theme.ink)
            }
            Spacer()
            if vm.loading {
                ProgressView().controlSize(.small)
            } else {
                Button { vm.refresh(engine: engine) } label: {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12))
                }.buttonStyle(.plain).foregroundStyle(Theme.ink(0.5)).help("Re-read today")
            }
        }
    }

    // MARK: digest

    private func digestCard(_ b: Briefing) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(Theme.accent)
                Text("THE RECAP").font(Theme.ui(9, .semibold)).kerning(1.5).foregroundStyle(Theme.ink(0.4))
            }
            Text(b.digest.isEmpty ? "Nothing notable captured yet today." : b.digest)
                .font(Theme.display(17)).foregroundStyle(Theme.ink(0.9)).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

            if !b.highlights.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(b.highlights, id: \.self) { h in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(Theme.accent).frame(width: 5, height: 5).padding(.top, 6)
                            Text(h).font(Theme.ui(13)).foregroundStyle(Theme.ink(0.7)).lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .grain(cornerRadius: 14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }

    // MARK: loose ends

    private var looseEndsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "checklist").font(.system(size: 11)).foregroundStyle(Theme.accent)
                Text("LOOSE ENDS").font(Theme.ui(9, .semibold)).kerning(1.5).foregroundStyle(Theme.ink(0.4))
                Text("\(vm.looseEnds.count)").font(Theme.mono(10)).foregroundStyle(Theme.ink(0.35))
            }
            VStack(spacing: 0) {
                ForEach(Array(vm.looseEnds.enumerated()), id: \.element.id) { i, end in
                    if i > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 46) }
                    looseEndRow(end)
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .grain(cornerRadius: 14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
        }
    }

    private func looseEndRow(_ end: LooseEnd) -> some View {
        HStack(spacing: 14) {
            Image(systemName: end.icon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(end.label.uppercased()).font(Theme.ui(8, .semibold)).kerning(0.8).foregroundStyle(Theme.ink(0.35))
                Text(end.text).font(Theme.ui(13)).foregroundStyle(Theme.ink(0.85)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { withAnimation(.easeOut(duration: 0.15)) { vm.dismiss(end) } } label: {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink(0.5))
                    .frame(width: 26, height: 26)
                    .background(Theme.ink(0.06), in: Circle())
            }.buttonStyle(.plain).help("Mark done")
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    // MARK: states

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Reading your day…").font(Theme.ui(13)).foregroundStyle(Theme.ink(0.5))
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }

    // MARK: example preview (shown when there's no data yet)

    /// A clearly-labelled, dimmed sample so a first-time user sees exactly what
    /// Clem will produce — never mistakable for their real data.
    private var examplePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "eye").font(.system(size: 10))
                Text("EXAMPLE — WHAT YOU'LL SEE HERE").font(Theme.ui(9, .semibold)).kerning(1.1)
            }
            .foregroundStyle(Theme.ink(0.4))

            // sample recap
            VStack(alignment: .leading, spacing: 10) {
                Text("THE RECAP").font(Theme.ui(8, .semibold)).kerning(1.4).foregroundStyle(Theme.ink(0.35))
                Text("You spent the morning refining the onboarding flow in Figma, read up on usage-based pricing, then tracked down a flaky deploy test in your terminal.")
                    .font(Theme.display(14)).foregroundStyle(Theme.ink(0.65)).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(["Shipped the new sign-up screen", "Saved a thread on pricing strategy", "Fixed the failing CI job"], id: \.self) { h in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(Theme.accent.opacity(0.55)).frame(width: 4, height: 4).padding(.top, 6)
                        Text(h).font(Theme.ui(11)).foregroundStyle(Theme.ink(0.5))
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))

            // sample loose ends
            VStack(spacing: 0) {
                exampleEnd("checkmark.circle", "TO-DO", "Re-run the deploy pipeline after the config change")
                Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 42)
                exampleEnd("hand.raised", "YOU SAID YOU'D", "Send the design review notes to the team")
                Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 42)
                exampleEnd("questionmark.bubble", "WAITING ON YOU", "Reply to the rate-limit question in Slack")
            }
            .background(Theme.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .opacity(0.9)
        .allowsHitTesting(false)
    }

    private func exampleEnd(_ icon: String, _ label: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.accent.opacity(0.7)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.ui(7, .semibold)).kerning(0.7).foregroundStyle(Theme.ink(0.3))
                Text(text).font(Theme.ui(11)).foregroundStyle(Theme.ink(0.6)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing to brief yet").font(Theme.display(20)).foregroundStyle(Theme.ink(0.8))
            Text("Flip on monitoring and go live your day. Tonight I'll hand you the recap and every loose end you dropped — that's my job as your cofounder.")
                .font(Theme.ui(13)).foregroundStyle(Theme.ink(0.5)).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Circle().fill(engine.isMonitoring ? Color(hex: "5Fb37e") : Theme.ink(0.3)).frame(width: 6, height: 6)
                Text(engine.isMonitoring ? "Monitoring is on" : "Monitoring is off")
                    .font(Theme.ui(12)).foregroundStyle(Theme.ink(0.5))
                if !engine.isMonitoring {
                    Button("Turn on") { engine.toggleMonitoring() }
                        .buttonStyle(.plain).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }
}
