import AppKit

/// Hands over to Apple's own Mission Control.
///
/// Mission Control ships as an ordinary app bundle, so launching it is enough
/// — no symbolic hotkey to synthesise and no private API. If the F3 tap is
/// switched on, this is the only way left to reach Apple's version, so it
/// deliberately doesn't route through the key.
@MainActor
enum AppleMissionControl {
    private static let bundlePath = "/System/Applications/Mission Control.app"

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: bundlePath)
    }

    static func open() {
        guard isAvailable else {
            NSLog("BetterMissionControl: Mission Control.app not found at \(bundlePath)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: bundlePath),
            configuration: configuration
        ) { _, error in
            if let error {
                NSLog("BetterMissionControl: couldn't open Mission Control — \(error.localizedDescription)")
            }
        }
    }
}
