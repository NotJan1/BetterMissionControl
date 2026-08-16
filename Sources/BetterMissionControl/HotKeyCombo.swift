import AppKit
import Carbon.HIToolbox

/// A global hotkey: one key plus its modifiers, in Carbon's terms.
struct HotKeyCombo: Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var carbonModifiers: UInt32

    /// Control+Option+Up — deliberately one modifier away from Mission
    /// Control's own Control+Up so both don't fire at once.
    static let fallback = HotKeyCombo(
        keyCode: UInt32(kVK_UpArrow),
        carbonModifiers: UInt32(controlKey | optionKey)
    )

    var hasModifier: Bool { carbonModifiers != 0 }

    /// Keys that are usable as a hotkey on their own.
    ///
    /// A bare letter would be swallowed system-wide, so modifiers are normally
    /// required — but a function key types nothing, and binding F3 by itself is
    /// the whole point of taking it back from Mission Control.
    var isStandaloneCapable: Bool {
        Self.functionKeys.contains(Int(keyCode))
    }

    /// A combination the recorder will accept.
    var isUsable: Bool { hasModifier || isStandaloneCapable }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7,
        kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14,
        kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ]

    var displayString: String {
        var parts = ""
        if carbonModifiers & UInt32(controlKey) != 0 { parts += "\u{2303}" }
        if carbonModifiers & UInt32(optionKey) != 0 { parts += "\u{2325}" }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts += "\u{21E7}" }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts += "\u{2318}" }
        return parts + KeyCodeNames.name(for: keyCode)
    }

    // MARK: - Bridging to AppKit

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Builds a combo from a recorded key event.
    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        carbonModifiers = Self.carbonModifiers(from: event.modifierFlags)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// The same modifiers expressed as `NSEvent.ModifierFlags` raw bits, which
    /// is how macOS records its own shortcuts in `com.apple.symbolichotkeys`.
    var cocoaModifierMask: UInt {
        var result: UInt = 0
        if carbonModifiers & UInt32(cmdKey) != 0 { result |= NSEvent.ModifierFlags.command.rawValue }
        if carbonModifiers & UInt32(optionKey) != 0 { result |= NSEvent.ModifierFlags.option.rawValue }
        if carbonModifiers & UInt32(controlKey) != 0 { result |= NSEvent.ModifierFlags.control.rawValue }
        if carbonModifiers & UInt32(shiftKey) != 0 { result |= NSEvent.ModifierFlags.shift.rawValue }
        return result
    }
}

/// Human-readable names for virtual key codes.
enum KeyCodeNames {
    private static let specials: [Int: String] = [
        kVK_UpArrow: "\u{2191}", kVK_DownArrow: "\u{2193}",
        kVK_LeftArrow: "\u{2190}", kVK_RightArrow: "\u{2192}",
        kVK_Space: "Space", kVK_Tab: "\u{21E5}", kVK_Return: "\u{21A9}",
        kVK_Escape: "\u{238B}", kVK_Delete: "\u{232B}", kVK_ForwardDelete: "\u{2326}",
        kVK_Home: "\u{2196}", kVK_End: "\u{2198}",
        kVK_PageUp: "\u{21DE}", kVK_PageDown: "\u{21DF}",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/"
    ]

    private static let letters: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9"
    ]

    static func name(for keyCode: UInt32) -> String {
        let code = Int(keyCode)
        return specials[code] ?? letters[code] ?? "Key \(keyCode)"
    }
}
