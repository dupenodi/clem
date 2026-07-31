import AppKit
import ScreenCaptureKit

/// Grabs single frames of the display containing the frontmost window
/// using ScreenCaptureKit (no CLI, no video stream).
final class CaptureService {
    func captureActiveDisplay() async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = activeDisplay(in: content) else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.showsCursor = false
            config.captureResolution = .best

            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            return nil
        }
    }

    /// Display containing the frontmost window (fall back to main display).
    private func activeDisplay(in content: SCShareableContent) -> SCDisplay? {
        let frontApp = NSWorkspace.shared.frontmostApplication
        if let pid = frontApp?.processIdentifier,
           let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.isOnScreen }),
           let display = content.displays.first(where: { CGDisplayBounds($0.displayID).intersects(window.frame) }) {
            return display
        }
        let mainID = CGMainDisplayID()
        return content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first
    }
}
