import AppKit
import SwiftUI

/// The app proper — an Obsidian-style shell: sidebar navigation on the left,
/// full views on the right. Opens on app-icon click.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private var window: NSWindow?

    func show(engine: Engine, tab: MainTab = .home) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .clemSwitchTab, object: tab)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.title = "Clem"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(calibratedRed: 0.115, green: 0.105, blue: 0.095, alpha: 1)
        w.minSize = NSSize(width: 900, height: 600)
        w.collectionBehavior = [.fullScreenPrimary] // enables the green fullscreen button
        w.delegate = self
        w.contentView = NSHostingView(rootView: MainView(initialTab: tab).environmentObject(engine))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        // Size a generous, centered window that always fits the current
        // display (multi-monitor safe — never runs an edge off-screen). The
        // green button still gives true fullscreen.
        DispatchQueue.main.async {
            guard let vf = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
            let width = min(1320, vf.width - 60)
            let height = min(900, vf.height - 40)
            let frame = NSRect(x: vf.midX - width / 2, y: vf.midY - height / 2, width: width, height: height)
            w.setFrame(frame, display: true, animate: false)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

extension Notification.Name {
    static let clemSwitchTab = Notification.Name("clemSwitchTab")
}

enum MainTab: String, CaseIterable {
    case home = "Home"
    case today = "Today"
    case focus = "Focus"
    case discover = "Discover"
    case graph = "Memory Graph"
    case canvas = "Canvas"
    case goals = "Goals"
    case connectors = "Connectors"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .home: return "sparkle"
        case .today: return "sun.max"
        case .focus: return "gauge.with.needle"
        case .discover: return "sparkles.rectangle.stack"
        case .graph: return "circle.hexagongrid.fill"
        case .canvas: return "scribble.variable"
        case .goals: return "target"
        case .connectors: return "tray.and.arrow.down"
        case .settings: return "gearshape"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var goalStore = GoalStore.shared
    @State var tab: MainTab

    init(initialTab: MainTab = .home) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        // MarbleBackground paints behind via .background (it ignores safe area
        // for the visual only); the HStack drives layout and stays within the
        // window so bottom-anchored controls are never pushed under the Dock.
        GeometryReader { geo in
            HStack(spacing: 0) {
                sidebar.frame(height: geo.size.height) // bounded height → Spacer pins bottom controls
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) { breachBanner }
        .background(MarbleBackground(grainy: tab != .home))
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: .clemSwitchTab)) { note in
            if let t = note.object as? MainTab { tab = t }
        }
    }

    /// Global nudge when a limit goal is over budget — dismissible, and jumps
    /// to the Goals tab on tap. Only shows off the Goals tab (which shows its
    /// own breach cards).
    @ViewBuilder private var breachBanner: some View {
        if tab != .goals, let g = goalStore.activeBreaches.first {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
                Text("You've passed your \(g.minutes)-min limit on \(g.target).")
                    .font(Theme.ui(12, .medium)).foregroundStyle(Theme.ink)
                Spacer()
                Button("View") { tab = .goals }
                    .buttonStyle(.plain).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.accent)
                Button { goalStore.acknowledge(g) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }.buttonStyle(.plain).foregroundStyle(Theme.ink(0.5))
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(Theme.accent.opacity(0.4)))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            .padding(.top, 14)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Plain wordmark — small, uppercase, tracked (Are.na restraint).
            Text("CLEM")
                .font(Theme.ui(13, .semibold))
                .kerning(3)
                .foregroundStyle(Theme.ink)
                .padding(.top, 40)
                .padding(.horizontal, 20)
            Text("the cofounder of your life")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.ink(0.4))
                .padding(.horizontal, 20)
                .padding(.bottom, 24)

            ForEach(MainTab.allCases, id: \.self) { t in
                navItem(t)
            }

            CharacterWidget()
                .padding(.horizontal, 14)
                .padding(.top, 18)

            Spacer()

            Rectangle().fill(Theme.line).frame(height: 1).padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 14) {
                Button {
                    SavePanelController.shared.trigger(engine: engine)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                        Text("Save a memory").font(Theme.ui(12, .medium))
                        Spacer()
                        Text(engine.saveHotkeyLabel).font(Theme.mono(10)).foregroundStyle(Theme.ink(0.4))
                    }
                    .padding(.vertical, 9).padding(.horizontal, 12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                    .foregroundStyle(Theme.ink(0.85))
                }
                .buttonStyle(.plain)

                HStack(spacing: 8) {
                    Circle()
                        .fill(engine.isMonitoring ? Color.green.opacity(0.8) : Theme.ink(0.25))
                        .frame(width: 6, height: 6)
                    Text(engine.isMonitoring ? "Watching screen" : "Monitoring off")
                        .font(Theme.ui(11)).foregroundStyle(Theme.ink(0.5))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { engine.isMonitoring },
                        set: { _ in engine.toggleMonitoring() }
                    ))
                    .toggleStyle(.switch).controlSize(.mini).tint(Theme.ink(0.5))
                }
                .padding(.horizontal, 2)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
        .frame(width: 224)
        .background(Theme.bg)
        .grain()
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private func navItem(_ t: MainTab) -> some View {
        let active = tab == t
        return Button { tab = t } label: {
            HStack(spacing: 11) {
                Image(systemName: t.icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(t.rawValue).font(Theme.ui(13, active ? .medium : .regular))
                Spacer()
                if t == .goals, !goalStore.activeBreaches.isEmpty {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(active ? Theme.ink(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(active ? Theme.ink : Theme.ink(0.55))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .home: ChatView()
        case .today: TodayView()
        case .focus: FocusView()
        case .graph: GraphView()
        case .canvas: CanvasBoardView()
        case .goals: GoalsView()
        case .discover: DiscoverView()
        case .connectors: ConnectorsView()
        case .settings: SettingsView()
        }
    }
}
