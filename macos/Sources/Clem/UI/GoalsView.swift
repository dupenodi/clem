import SwiftUI

/// The Goals tab: create time intentions (limit / focus) and watch live
/// progress against today's tracked app + site time.
struct GoalsView: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var store = GoalStore.shared
    @ObservedObject private var iconStore = IconStore.shared

    @State private var editing: Goal?
    @State private var showEditor = false

    /// Live seconds for a target from the engine's per-app/site breakdown.
    private func seconds(_ target: String) -> Double {
        engine.appTimes.first { $0.app == target }?.seconds ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if !store.activeBreaches.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(store.activeBreaches) { g in breachCard(g) }
                    }
                }

                if store.goals.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 12) {
                        ForEach(store.goals) { g in goalCard(g) }
                    }
                }
            }
            .padding(.horizontal, 44)
            .padding(.top, 40).padding(.bottom, 40)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showEditor) {
            GoalEditor(goal: editing, suggestions: Array(engine.appTimes.prefix(12))) { saved in
                if editing == nil { store.add(saved) } else { store.update(saved) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Goals").font(Theme.display(30, .medium)).foregroundStyle(Theme.ink)
                Text("Set limits and focus targets — Clem nudges you as you go.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.ink(0.45))
            }
            Spacer()
            Button {
                editing = nil; showEditor = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    Text("New goal").font(Theme.ui(12, .medium))
                }
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(Theme.accent, in: Capsule())
                .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("No goals yet").font(Theme.display(20)).foregroundStyle(Theme.ink(0.8))
            Text("For example: get a notification after 25 min on substack.com, or spend at least 2 hours in your editor. Clem tracks apps and individual sites.")
                .font(Theme.ui(13)).foregroundStyle(Theme.ink(0.5)).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Button { editing = nil; showEditor = true } label: {
                Text("Create your first goal").font(Theme.ui(12, .medium))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .overlay(Capsule().stroke(Theme.accent.opacity(0.5)))
                    .foregroundStyle(Theme.accent)
            }.buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }

    // MARK: cards

    private func goalCard(_ g: Goal) -> some View {
        let secs = seconds(g.target)
        let target = Double(g.minutes * 60)
        let ratio = target > 0 ? secs / target : 0
        let over = g.kind == .limit && ratio >= 1
        let done = g.kind == .focus && ratio >= 1
        let barColor: Color = over ? Color(hex: "E5533D") : (done ? Color(hex: "5Fb37e") : Theme.accent)

        return HStack(spacing: 14) {
            icon(for: g.target)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(g.target).font(Theme.ui(14, .semibold)).foregroundStyle(Theme.ink)
                    Text(g.kind.title.uppercased())
                        .font(Theme.ui(8, .semibold)).kerning(0.8)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.ink(0.08), in: Capsule())
                        .foregroundStyle(Theme.ink(0.55))
                    Spacer()
                    Text(statusText(g, secs: secs, over: over, done: done))
                        .font(Theme.mono(11)).foregroundStyle(over ? barColor : Theme.ink(0.5))
                }
                progressBar(ratio: ratio, color: barColor)
                Text("\(g.kind.verb) \(g.minutes) min today").font(Theme.ui(10)).foregroundStyle(Theme.ink(0.4))
            }
            Menu {
                Button("Edit") { editing = g; showEditor = true }
                Button("Delete", role: .destructive) { store.delete(g) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(Theme.ink(0.4))
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .grain(cornerRadius: 12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(over ? barColor.opacity(0.45) : Theme.line))
    }

    private func breachCard(_ g: Goal) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Over your limit on \(g.target)").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.ink)
                Text("Past \(g.minutes) min — \(fmt(seconds(g.target))) so far today.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.ink(0.55))
            }
            Spacer()
            Button { store.acknowledge(g) } label: {
                Text("Dismiss").font(Theme.ui(11, .medium)).foregroundStyle(Theme.ink(0.6))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(Capsule().stroke(Theme.line))
            }.buttonStyle(.plain)
        }
        .padding(14)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.4)))
    }

    // MARK: pieces

    @ViewBuilder private func icon(for label: String) -> some View {
        if let img = iconStore.icon(forLabel: label) {
            Image(nsImage: img).resizable().frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        } else {
            RoundedRectangle(cornerRadius: 7).fill(Theme.ink(0.10))
                .frame(width: 30, height: 30)
                .overlay(Text(String(label.prefix(1)).uppercased()).font(Theme.ui(13, .semibold)).foregroundStyle(Theme.ink(0.5)))
        }
    }

    private func progressBar(ratio: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ink(0.08))
                Capsule().fill(color)
                    .frame(width: max(4, min(1, ratio) * geo.size.width))
            }
        }
        .frame(height: 6)
    }

    private func statusText(_ g: Goal, secs: Double, over: Bool, done: Bool) -> String {
        if over { return "over by \(fmt(secs - Double(g.minutes * 60)))" }
        if done { return "done ✓" }
        return "\(fmt(secs)) / \(g.minutes)m"
    }

    private func fmt(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }
}

/// Add / edit a goal.
struct GoalEditor: View {
    let goal: Goal?
    let suggestions: [AppSpan]
    let onSave: (Goal) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var kind: GoalKind
    @State private var target: String
    @State private var minutes: Int

    init(goal: Goal?, suggestions: [AppSpan], onSave: @escaping (Goal) -> Void) {
        self.goal = goal
        self.suggestions = suggestions
        self.onSave = onSave
        _kind = State(initialValue: goal?.kind ?? .limit)
        _target = State(initialValue: goal?.target ?? "")
        _minutes = State(initialValue: goal?.minutes ?? 25)
    }

    private let presets = [15, 25, 45, 60, 120]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(goal == nil ? "New goal" : "Edit goal").font(Theme.display(22)).foregroundStyle(Theme.ink)

            field("TYPE") {
                Picker("", selection: $kind) {
                    Text("Limit — stay under").tag(GoalKind.limit)
                    Text("Focus — reach at least").tag(GoalKind.focus)
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            field("APP OR SITE") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("e.g. substack.com or Slack", text: $target)
                        .textFieldStyle(.plain).font(Theme.ui(14)).foregroundStyle(Theme.ink).tint(Theme.accent)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                    if !suggestions.isEmpty {
                        Text("FROM TODAY").font(Theme.ui(8, .semibold)).kerning(1).foregroundStyle(Theme.ink(0.3))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(suggestions) { s in
                                    Button { target = s.app } label: {
                                        Text(s.app).font(Theme.ui(11)).lineLimit(1)
                                            .padding(.horizontal, 10).padding(.vertical, 5)
                                            .background(target == s.app ? Theme.accent.opacity(0.15) : Theme.ink(0.06), in: Capsule())
                                            .overlay(Capsule().stroke(target == s.app ? Theme.accent.opacity(0.5) : Theme.line))
                                            .foregroundStyle(target == s.app ? Theme.accent : Theme.ink(0.7))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }

            field("MINUTES PER DAY") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(presets, id: \.self) { p in
                            Button { minutes = p } label: {
                                Text(p >= 60 ? "\(p/60)h" : "\(p)m").font(Theme.ui(12, .medium))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(minutes == p ? Theme.accent.opacity(0.15) : Theme.ink(0.06), in: Capsule())
                                    .overlay(Capsule().stroke(minutes == p ? Theme.accent.opacity(0.5) : Theme.line))
                                    .foregroundStyle(minutes == p ? Theme.accent : Theme.ink(0.7))
                            }.buttonStyle(.plain)
                        }
                    }
                    Stepper("\(minutes) minutes", value: $minutes, in: 1...600, step: 5)
                        .font(Theme.ui(12)).foregroundStyle(Theme.ink(0.7))
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(Theme.ink(0.5))
                Button {
                    let t = target.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    var g = goal ?? Goal(kind: kind, target: t, minutes: minutes, createdAt: Date())
                    g.kind = kind; g.target = t; g.minutes = minutes
                    onSave(g); dismiss()
                } label: {
                    Text("Save").font(Theme.ui(12, .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Theme.accent, in: Capsule()).foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(target.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
        }
        .padding(26)
        .frame(width: 440)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(Theme.ui(9, .semibold)).kerning(1.2).foregroundStyle(Theme.ink(0.35))
            content()
        }
    }
}
