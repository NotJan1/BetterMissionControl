import AppKit
import Carbon.HIToolbox

/// Registers the global summon hotkey through Carbon's `RegisterEventHotKey`.
///
/// Carbon is chosen over `CGEventTap` on purpose: it needs no Input Monitoring
/// permission, which keeps the app's permission footprint to two prompts
/// instead of three.
@MainActor
final class HotKeyManager {
    /// Remappable before a Preferences window exists, e.g.
    /// `defaults write com.janszalinski.BetterMissionControl HotKeyKeyCode -int 49`
    private enum DefaultsKey {
        static let keyCode = "HotKeyKeyCode"
        static let modifiers = "HotKeyModifiers"
    }

    /// Control+Option+Up — deliberately one modifier away from Mission
    /// Control's own Control+Up so both don't fire at once.
    private static let fallbackKeyCode = UInt32(kVK_UpArrow)
    private static let fallbackModifiers = UInt32(controlKey | optionKey)

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    var keyCode: UInt32 {
        let stored = UserDefaults.standard.integer(forKey: DefaultsKey.keyCode)
        return stored > 0 ? UInt32(stored) : Self.fallbackKeyCode
    }

    var modifiers: UInt32 {
        let stored = UserDefaults.standard.integer(forKey: DefaultsKey.modifiers)
        return stored > 0 ? UInt32(stored) : Self.fallbackModifiers
    }

    /// Human-readable form of the current hotkey, for the menu bar item.
    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("\u{2303}") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("\u{2325}") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("\u{21E7}") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("\u{2318}") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    private static func keyName(for code: UInt32) -> String {
        switch Int(code) {
        case kVK_UpArrow: return "\u{2191}"
        case kVK_DownArrow: return "\u{2193}"
        case kVK_LeftArrow: return "\u{2190}"
        case kVK_RightArrow: return "\u{2192}"
        case kVK_Space: return "Space"
        case kVK_Tab: return "\u{21E5}"
        default: return "Key \(code)"
        }
    }

    @discardableResult
    func register() -> Bool {
        unregister()

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            // The Carbon callback isn't guaranteed to be on the main actor's
            // terms, so hop explicitly before touching any UI.
            DispatchQueue.main.async { manager.onPress() }
            return noErr
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard installStatus == noErr else {
            NSLog("BetterMissionControl: InstallEventHandler failed (\(installStatus))")
            return false
        }

        // 'BMC1' as a four-char signature, per Carbon convention.
        let hotKeyID = EventHotKeyID(signature: 0x424D_4331, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            NSLog("BetterMissionControl: RegisterEventHotKey failed (\(registerStatus)) — another app may already own this combination")
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}
