import CoreText
import SwiftUI
import UserNotifications

@main
struct ClemApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine = Engine.shared

    var body: some Scene {
        SwiftUI.Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().delegate = self
        Self.registerBundledFonts()
        Engine.shared.startIfPermitted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if Permissions.screenRecordingGranted() {
                MainWindowController.shared.show(engine: Engine.shared)
            } else {
                OnboardingWindowController.shared.show(engine: Engine.shared)
            }
        }
    }

    static func registerBundledFonts() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            if Permissions.screenRecordingGranted() {
                MainWindowController.shared.show(engine: Engine.shared)
            } else {
                OnboardingWindowController.shared.show(engine: Engine.shared)
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Engine.shared.shutdown()
        Thread.sleep(forTimeInterval: 0.4)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
