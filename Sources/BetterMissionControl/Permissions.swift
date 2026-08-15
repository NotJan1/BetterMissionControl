import AppKit
import ApplicationServices
import CoreGraphics

/// The two system permissions the overlay actually needs. Input Monitoring is
/// deliberately absent: the global hotkey uses Carbon's `RegisterEventHotKey`,
/// which doesn't require it.
enum Permission: String, CaseIterable, Identifiable, Sendable {
    case screenRecording
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        }
    }

    var symbolName: String {
        switch self {
        case .screenRecording: return "rectangle.on.rectangle"
        case .accessibility: return "hand.tap"
        }
    }

    /// Plain-English reason, shown *before* the system prompt (R11).
    var explanation: String {
        switch self {
        case .screenRecording:
            return "Draws the picture of each window you see in the overview. Without it the overview can list your windows but every tile is blank."
        case .accessibility:
            return "Lets the overview close, minimize, and bring windows forward. Without it you can look but not touch."
        }
    }

    var settingsURL: URL {
        switch self {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }

    /// macOS only re-reads Screen Recording consent at launch, so granting it
    /// requires a restart of the app to take effect.
    var requiresRelaunchAfterGranting: Bool { self == .screenRecording }
}

@MainActor
enum PermissionsManager {
    static func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .accessibility: return AXIsProcessTrusted()
        }
    }

    static var missing: [Permission] {
        Permission.allCases.filter { !isGranted($0) }
    }

    static var allGranted: Bool { missing.isEmpty }

    /// Triggers the real system prompt. Only call this once the user has seen
    /// our own explanation and asked for it.
    static func request(_ permission: Permission) {
        switch permission {
        case .screenRecording:
            CGRequestScreenCaptureAccess()
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
    }

    static func openSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }
}
