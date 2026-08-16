import AppKit

/// Checks a proposed hotkey against the shortcuts macOS has already claimed.
///
/// `RegisterEventHotKey` is not a reliable conflict detector — it happily
/// succeeds for a combination the system already owns, and the system just
/// wins. So the real check reads the same preference file System Settings
/// writes, `com.apple.symbolichotkeys`, and looks for an *enabled* shortcut
/// using the same key.
enum SystemHotKeys {
    /// Well-known symbolic hotkey identifiers. Anything not listed still
    /// produces a warning, just a less specific one.
    private static let names: [Int: String] = [
        7: "Screen zoom", 15: "Zoom toggle",
        28: "Save picture of screen to file", 29: "Copy picture of screen",
        30: "Save picture of selected area", 31: "Copy picture of selected area",
        32: "Mission Control", 33: "Mission Control (down)",
        36: "Application windows", 37: "Show Desktop",
        57: "Move focus to the Dock", 59: "Move focus to the menu bar",
        60: "Select the previous input source", 61: "Select the next input source",
        62: "Move focus to the window toolbar", 64: "Spotlight search",
        65: "Spotlight Finder window search",
        79: "Move left a space", 81: "Move right a space",
        98: "Show Help menu", 160: "Launchpad",
        162: "Notification Centre", 175: "Focus",
        118: "Switch to Desktop 1", 119: "Switch to Desktop 2",
        120: "Switch to Desktop 3", 121: "Switch to Desktop 4",
        184: "Switch to Desktop 1", 185: "Switch to Desktop 2"
    ]

    struct Conflict {
        let description: String
    }

    /// Returns a conflict if an enabled system shortcut already uses this
    /// combination.
    static func conflict(for combo: HotKeyCombo) -> Conflict? {
        guard let hotKeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .persistentDomain(forName: "com.apple.symbolichotkeys")?["AppleSymbolicHotKeys"]
            as? [String: Any] else { return nil }

        for (identifier, raw) in hotKeys {
            guard let entry = raw as? [String: Any],
                  entry["enabled"] as? Bool == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Any],
                  parameters.count >= 3,
                  let keyCode = (parameters[1] as? NSNumber)?.intValue,
                  let mask = (parameters[2] as? NSNumber)?.uintValue
            else { continue }

            guard UInt32(exactly: max(keyCode, 0)) == combo.keyCode else { continue }
            // Arrow and keypad keys carry incidental function/numericPad bits
            // that aren't part of what the user pressed, so compare only the
            // four modifiers that matter.
            guard significantModifiers(mask) == combo.cocoaModifierMask else { continue }

            // Reads inside a sentence, so the fallback stays lowercase.
            let name = names[Int(identifier) ?? -1] ?? "another macOS shortcut"
            return Conflict(description: name)
        }
        return nil
    }

    private static func significantModifiers(_ mask: UInt) -> UInt {
        let significant: [NSEvent.ModifierFlags] = [.command, .option, .control, .shift]
        return significant.reduce(into: UInt(0)) { result, flag in
            if mask & flag.rawValue != 0 { result |= flag.rawValue }
        }
    }
}
