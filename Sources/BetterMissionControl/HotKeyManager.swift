import AppKit
import Carbon.HIToolbox
import Observation

/// Registers the global summon hotkey through Carbon's `RegisterEventHotKey`.
///
/// Carbon is chosen over `CGEventTap` on purpose: it needs no Input Monitoring
/// permission, which keeps the app's permission footprint to two prompts
/// instead of three.
@MainActor
@Observable
final class HotKeyManager {
    private enum DefaultsKey {
        static let keyCode = "HotKeyKeyCode"
        static let modifiers = "HotKeyModifiers"
    }

    /// What the user has chosen (R12), falling back to the default.
    private(set) var combo: HotKeyCombo
    /// Set when `RegisterEventHotKey` refused the combination outright.
    private(set) var registrationFailed = false

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress

        let defaults = UserDefaults.standard
        let storedKey = defaults.object(forKey: DefaultsKey.keyCode) as? Int
        let storedModifiers = defaults.object(forKey: DefaultsKey.modifiers) as? Int
        if let storedKey, let storedModifiers, storedModifiers != 0 {
            combo = HotKeyCombo(keyCode: UInt32(storedKey), carbonModifiers: UInt32(storedModifiers))
        } else {
            combo = .fallback
        }
    }

    var displayString: String { combo.displayString }

    /// A shortcut macOS has already claimed, if any. Registration can appear to
    /// succeed for one of these while the system quietly wins, so this is
    /// checked separately and surfaced in Settings.
    var systemConflict: String? {
        SystemHotKeys.conflict(for: combo)?.description
    }

    // MARK: - Changing the hotkey

    /// Stores and re-registers a new combination. Returns false if the system
    /// refused it, in which case the previous hotkey is put back.
    @discardableResult
    func update(to newCombo: HotKeyCombo) -> Bool {
        let previous = combo
        combo = newCombo

        guard register() else {
            combo = previous
            _ = register()
            return false
        }

        let defaults = UserDefaults.standard
        defaults.set(Int(newCombo.keyCode), forKey: DefaultsKey.keyCode)
        defaults.set(Int(newCombo.carbonModifiers), forKey: DefaultsKey.modifiers)
        return true
    }

    func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: DefaultsKey.keyCode)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.modifiers)
        combo = .fallback
        _ = register()
    }

    // MARK: - Registration

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
            registrationFailed = true
            return false
        }

        // 'BMC1' as a four-char signature, per Carbon convention.
        let hotKeyID = EventHotKeyID(signature: 0x424D_4331, id: 1)
        let registerStatus = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            NSLog("BetterMissionControl: RegisterEventHotKey failed (\(registerStatus)) — another app may already own \(combo.displayString)")
            registrationFailed = true
            return false
        }
        registrationFailed = false
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
