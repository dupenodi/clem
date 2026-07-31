import AppKit
import SwiftUI

/// A deliberate focus window: ONE app/site is the task and everything else is
/// a distraction by definition. Fed the live foreground label by
/// ActivityTracker, it counts departures from the target and — once you've
/// drifted more than twice — nudges you with a floating panel that appears
/// over whatever you're doing, anywhere on the Mac.
@MainActor
final class FocusSessionCenter: ObservableObject {
    static let shared = FocusSessionCenter()

    struct Session: Codable, Equatable {
        var target: String
        var startedAt: Date
        var endsAt: Date
        var excursions: Int = 0
        var totalSeconds: Double { endsAt.timeIntervalSince(startedAt) }
    }

    @Published private(set) var session: Session?
    private var onTarget = true    // departure-edge detection
    private var offSince: Date?    // when the current excursion began
    private var lastNudgeAt: Date?
    private var endTimer: Timer?

    // Dwell rule: away from the target this long → nudge, and keep re-nudging
    // while still away. Complements the "3rd departure" rule, which alone
    // misses ONE long continuous drift.
    private let dwellNudgeAfter: TimeInterval = 60
    private let renudgeEvery: TimeInterval = 90

    private let d = UserDefaults.standard
    private let key = "clemFocusSession"

    private init() {
        // Survive an app restart mid-session.
        if let data = d.data(forKey: key),
           let s = try? JSONDecoder().decode(Session.self, from: data) {
            if s.endsAt > Date() {
                session = s
                scheduleEnd(at: s.endsAt)
            } else {
                d.removeObject(forKey: key)
            }
        }
    }

    var remainingSeconds: Double { session.map { max(0, $0.endsAt.timeIntervalSinceNow) } ?? 0 }

    func start(target: String, minutes: Int) {
        let s = Session(target: target, startedAt: Date(), endsAt: Date().addingTimeInterval(Double(minutes) * 60))
        session = s
        onTarget = true
        offSince = nil
        lastNudgeAt = nil
        persist()
        scheduleEnd(at: s.endsAt)
        NudgeCenter.shared.show(
            title: "Locked in: \(target)",
            message: "\(minutes) minutes. Everything else counts as a distraction now.",
            tone: .calm
        )
    }

    func end(completed: Bool = false) {
        guard let s = session else { return }
        session = nil
        endTimer?.invalidate()
        endTimer = nil
        d.removeObject(forKey: key)
        if completed {
            let verdict = s.excursions == 0 ? "Zero detours. Monk mode."
                : s.excursions <= 2 ? "\(s.excursions) detour\(s.excursions == 1 ? "" : "s") — solid."
                : "\(s.excursions) detours — the pull is real. Try a shorter window next time."
            NudgeCenter.shared.show(title: "Focus session done — \(s.target)", message: verdict, tone: .calm)
        }
    }

    /// Called by ActivityTracker with every foreground label it resolves
    /// (site-aware for browsers), ~every 8s and on each app switch.
    func observe(label: String, now: Date) {
        guard var s = session else { return }
        guard now < s.endsAt else { end(completed: true); return }
        if matches(label, target: s.target) {
            onTarget = true
            offSince = nil
            return
        }
        guard label != "Clem" else { return } // checking in on Clem is not a detour
        let mins = Int((remainingSeconds / 60).rounded())

        if onTarget {
            // Fresh departure.
            onTarget = false
            offSince = now
            s.excursions += 1
            session = s
            persist()
            // "More than twice" → from the 3rd departure on, nudge instantly.
            if s.excursions > 2, lastNudgeAt.map({ now.timeIntervalSince($0) > 45 }) ?? true {
                lastNudgeAt = now
                NudgeCenter.shared.show(
                    title: "\(label) is not \(s.target)",
                    message: "Detour #\(s.excursions). \(mins) min left on your focus timer — go back.",
                    tone: .hot
                )
            }
        } else {
            // Still away. One long drift is worse than three quick glances —
            // nudge after a minute off-target, then keep nudging while away.
            if offSince == nil { offSince = now }
            guard let off = offSince, now.timeIntervalSince(off) >= dwellNudgeAfter,
                  lastNudgeAt.map({ now.timeIntervalSince($0) >= renudgeEvery }) ?? true else { return }
            lastNudgeAt = now
            let awayMin = max(1, Int((now.timeIntervalSince(off) / 60).rounded()))
            NudgeCenter.shared.show(
                title: "Still on \(label)?",
                message: "You've been away from \(s.target) for \(awayMin) min. \(mins) min left on your focus timer — go back.",
                tone: .hot
            )
        }
    }

    private func matches(_ label: String, target: String) -> Bool {
        let l = label.lowercased(), t = target.lowercased()
        if l == t { return true }
        if t.contains(".") { return l.hasSuffix("." + t) }
        return l.contains(t)
    }

    private func scheduleEnd(at date: Date) {
        endTimer?.invalidate()
        endTimer = Timer.scheduledTimer(withTimeInterval: max(1, date.timeIntervalSinceNow), repeats: false) { _ in
            Task { @MainActor in FocusSessionCenter.shared.end(completed: true) }
        }
    }

    private func persist() {
        if let s = session, let data = try? JSONEncoder().encode(s) { d.set(data, forKey: key) }
    }
}

/// Floating, non-activating nudge that appears top-centre of the screen over
/// ANY app (joins all Spaces, shows over fullscreen) and dismisses itself.
@MainActor
final class NudgeCenter {
    static let shared = NudgeCenter()
    enum Tone { case calm, hot }

    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?

    func show(title: String, message: String, tone: Tone) {
        dismissWork?.cancel()
        panel?.close()
        panel = nil

        let host = NSHostingView(rootView: NudgeView(title: title, message: message, tone: tone) { [weak self] in
            self?.hide()
        })
        let size = host.fittingSize
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.contentView = host
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - 20))
        }
        p.orderFrontRegardless()
        panel = p

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
    }

    private func hide() {
        dismissWork?.cancel()
        dismissWork = nil
        panel?.close()
        panel = nil
    }
}

private struct NudgeView: View {
    var title: String
    var message: String
    var tone: NudgeCenter.Tone
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tone == .hot ? "flame.fill" : "scope")
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.ui(13, .semibold)).foregroundStyle(Theme.ink)
                Text(message).font(Theme.ui(11.5)).foregroundStyle(Theme.ink(0.65)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.ink(0.45))
                    .frame(width: 20, height: 20)
                    .background(Theme.ink(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(width: 400, alignment: .leading)
        .background(Theme.bgHi, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(tone == .hot ? Theme.accent.opacity(0.45) : Theme.line))
    }
}
