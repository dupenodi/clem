import Carbon.HIToolbox
import Foundation

/// Global hotkey via Carbon (works without Accessibility permission).
/// Each instance gets a unique id — the handler only fires for its own key.
final class HotKey {
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: () -> Void
    private let id: UInt32
    /// False when another app already owns this combo.
    private(set) var isRegistered = false

    /// ⌥Space by default.
    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey), handler: @escaping () -> Void) {
        self.handler = handler
        self.id = HotKey.nextID
        HotKey.nextID += 1

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var pressed = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &pressed
            )
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            if pressed.id == me.id {
                DispatchQueue.main.async { me.handler() }
            }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C454D) /* CLEM */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        isRegistered = status == noErr && ref != nil
    }

    /// Try combos in order until one registers (other apps may own the first).
    static func firstAvailable(
        _ combos: [(keyCode: UInt32, modifiers: UInt32, label: String)],
        handler: @escaping () -> Void
    ) -> (hotkey: HotKey, label: String)? {
        for combo in combos {
            let hk = HotKey(keyCode: combo.keyCode, modifiers: combo.modifiers, handler: handler)
            if hk.isRegistered { return (hk, combo.label) }
        }
        return nil
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
