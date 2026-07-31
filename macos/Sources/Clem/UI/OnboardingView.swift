import AppKit
import SwiftUI

/// Themed onboarding window, shown only on first run (or when Screen Recording
/// isn't granted yet). AppKit-managed so it never auto-opens the way a SwiftUI
/// Window scene does.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    func show(engine: Engine) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 780),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.title = "Welcome to Clem"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(Theme.bg)
        w.delegate = self
        w.contentView = NSHostingView(
            rootView: OnboardingView(close: { [weak self] in self?.window?.close() })
                .environmentObject(engine)
        )
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

struct OnboardingView: View {
    @EnvironmentObject var engine: Engine
    var close: () -> Void
    @State private var timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    @State private var appear = false
    private let bg: NSImage? = {
        guard let url = Bundle.main.url(forResource: "clem-launch", withExtension: "jpg") else { return nil }
        return NSImage(contentsOf: url)
    }()

    private var ready: Bool { engine.hasScreenPermission }
    private var grantedCount: Int { (engine.hasScreenPermission ? 1 : 0) + (engine.hasAXPermission ? 1 : 0) }

    var body: some View {
        ZStack(alignment: .top) {
            backdrop

            VStack(alignment: .leading, spacing: 0) {
                Text("CLEM")
                    .font(Theme.ui(30, .bold)).kerning(5).foregroundStyle(Theme.ink)
                    .padding(.top, 4)

                Text("Clem is the cofounder of your life — it remembers everything you see, keeps the threads you drop, and hands your day back to you. Nothing leaves this Mac. Grant two permissions and let's get to work.")
                    .font(Theme.ui(13)).italic()
                    .foregroundStyle(Theme.ink(0.55)).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 430, alignment: .leading)
                    .padding(.top, 18)

                Spacer(minLength: 26)

                VStack(spacing: 0) {
                    permissionRow(
                        icon: "rectangle.dashed.badge.record",
                        title: "Screen Recording",
                        detail: "So Clem can read what's on screen.",
                        required: true,
                        granted: engine.hasScreenPermission
                    ) {
                        Permissions.requestScreenRecording()
                        Permissions.openScreenRecordingSettings()
                    }
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 52)
                    permissionRow(
                        icon: "accessibility",
                        title: "Accessibility",
                        detail: "Reads window titles & the active browser tab.",
                        required: false,
                        granted: engine.hasAXPermission
                    ) {
                        Permissions.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
                .grain(cornerRadius: 14)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 12)

                if !engine.hasScreenPermission {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                        Text("After enabling Screen Recording, macOS needs Clem to relaunch.")
                    }
                    .font(Theme.ui(11)).foregroundStyle(Theme.ink(0.45))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                }

                Spacer(minLength: 26)

                headline
                    .frame(maxWidth: .infinity)

                Spacer(minLength: 22)
                footer
            }
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 600, height: 780)
        .preferredColorScheme(.dark)
        .opacity(appear ? 1 : 0)
        .animation(.easeOut(duration: 0.4), value: appear)
        .onAppear { appear = true }
        .onReceive(timer) { _ in
            engine.hasScreenPermission = Permissions.screenRecordingGranted()
            engine.hasAXPermission = Permissions.accessibilityGranted()
        }
    }

    /// Signature flame-statue art, bottom-anchored and faded into the dark, with
    /// a scrim so the floating cards and text stay readable.
    private var backdrop: some View {
        ZStack {
            MarbleBackground(grainy: true)
            if let bg {
                Image(nsImage: bg)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 600, height: 780)
                    .opacity(0.5)
                    .mask(
                        LinearGradient(
                            colors: [.clear, .black, .black, .black.opacity(0.6)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)
            }
            LinearGradient(
                colors: [Theme.bg.opacity(0.55), Theme.bg.opacity(0.2), Theme.bg.opacity(0.75)],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    /// Big italic serif closer, mirroring the app's editorial voice.
    private var headline: some View {
        VStack(spacing: -6) {
            Text("Capture, Remember")
            (Text("& ") + Text("Create").foregroundColor(Theme.accent))
        }
        .font(Theme.display(46)).italic()
        .foregroundStyle(Theme.ink)
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }

    /// A minimal permission line: thin status glyph, title + one-line detail,
    /// and an accent "Grant" text link (no heavy pills or badges).
    private func permissionRow(
        icon: String, title: String, detail: String,
        required: Bool, granted: Bool, request: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : icon)
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(granted ? Color(hex: "5Fb37e") : Theme.ink(0.55))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(Theme.ui(13, .medium)).foregroundStyle(Theme.ink)
                    if !required {
                        Text("optional").font(Theme.ui(10)).foregroundStyle(Theme.ink(0.35))
                    }
                }
                Text(detail).font(Theme.ui(11)).foregroundStyle(Theme.ink(0.45))
            }
            Spacer(minLength: 8)
            if granted {
                Text("Granted").font(Theme.ui(11, .medium)).foregroundStyle(Theme.ink(0.4))
            } else {
                Button(action: request) {
                    Text("Grant").font(Theme.ui(12, .semibold)).foregroundStyle(Theme.accent)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .fill(i < grantedCount ? Theme.accent : Theme.ink(0.15))
                        .frame(width: 6, height: 6)
                }
                Text("\(grantedCount) of 2 granted")
                    .font(Theme.ui(11)).foregroundStyle(Theme.ink(0.4)).padding(.leading, 2)
            }
            Spacer()
            Button("Relaunch") { relaunch() }
                .buttonStyle(.plain)
                .font(Theme.ui(12, .medium)).foregroundStyle(Theme.ink(0.55))

            Button {
                engine.startIfPermitted()
                MainWindowController.shared.show(engine: engine)
                close()
            } label: {
                HStack(spacing: 6) {
                    Text("Enter Clem").font(Theme.ui(13, .semibold))
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(ready ? Theme.accent : Theme.ink(0.12), in: Capsule())
                .foregroundStyle(ready ? .black : Theme.ink(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!ready)
        }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
