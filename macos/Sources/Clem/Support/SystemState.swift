import AppKit
import CoreGraphics
import IOKit.ps

enum SystemState {
    /// Seconds since the user last moved the mouse / pressed a key.
    static func isIdle(threshold: TimeInterval) -> Bool {
        let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
        let idle = types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
        return idle > threshold
    }

    static func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    static func isOnLowBattery(below fraction: Double) -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            let onBattery = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            if onBattery,
               let current = info[kIOPSCurrentCapacityKey] as? Int,
               let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 {
                return Double(current) / Double(max) < fraction
            }
        }
        return false
    }
}
