import AppKit
import Foundation

/// Keeps the Dock on screen for as long as the overview is open.
///
/// There is no public API that reveals an auto-hidden Dock, so this turns the
/// Dock's own auto-hide setting off while the overlay is up and puts it back
/// afterwards. System Events is used rather than `defaults write` because the
/// Dock applies the change live; writing the preference directly would need
/// the Dock restarted, which flashes the screen.
///
/// Because this touches a real system setting, it is careful to put it back:
///
///   * restored when the overlay closes and again when the app quits,
///   * a flag on disk records that a change is outstanding, so if the app is
///     killed mid-overlay the next launch restores the setting rather than
///     leaving the Dock stuck visible,
///   * nothing is changed at all when auto-hide was already off.
///
/// Needs Automation permission for System Events, which macOS asks for once.
@MainActor
enum DockVisibility {
    private static let restorePendingKey = "DockAutohideRestorePending"

    private(set) static var lastError: String?

    /// True when auto-hide is currently on, i.e. the Dock hides itself.
    private static var autohideIsOn: Bool {
        UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
    }

    /// Shows the Dock, remembering that it needs putting back.
    static func show() {
        guard autohideIsOn else { return }
        UserDefaults.standard.set(true, forKey: restorePendingKey)
        setAutohide(false)
    }

    /// Puts auto-hide back, if this changed it.
    ///
    /// Returns true when the Dock was actually put back, so callers can wait
    /// for the screen to settle before doing anything that depends on how much
    /// room a window has.
    @discardableResult
    static func restore() -> Bool {
        guard UserDefaults.standard.bool(forKey: restorePendingKey) else { return false }
        setAutohide(true)
        UserDefaults.standard.set(false, forKey: restorePendingKey)
        return true
    }

    /// Called at launch: if a previous run was killed while the overlay was
    /// open, the Dock is still stuck visible and needs restoring.
    static func recoverIfInterrupted() {
        guard UserDefaults.standard.bool(forKey: restorePendingKey) else { return }
        restore()
    }

    private static func setAutohide(_ enabled: Bool) {
        let source = """
        tell application "System Events" to tell dock preferences \
        to set autohide to \(enabled)
        """
        guard let script = NSAppleScript(source: source) else { return }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            // -1743 is "not authorised to send Apple events".
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            lastError = code == -1743
                ? "Allow Better Mission Control to control System Events, in Privacy & Security › Automation"
                : (error[NSAppleScript.errorMessage] as? String ?? "Couldn't change the Dock setting")
            NSLog("BetterMissionControl: Dock autohide change failed (\(code)) — \(lastError ?? "")")
        } else {
            lastError = nil
        }
    }
}
