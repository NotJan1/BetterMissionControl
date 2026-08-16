import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKeyManager: HotKeyManager?
    private let overlay = OverlayController()
    private let welcome = WelcomeWindowController()

    private enum DefaultsKey {
        static let hasLaunchedBefore = "HasLaunchedBefore"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar utility: no Dock icon, no main menu.
        NSApp.setActivationPolicy(.accessory)

        if SelfTest.isRequested {
            Task { await SelfTest.run() }
            return
        }

        let hotKeyManager = HotKeyManager { [weak self] in
            self?.overlay.toggle()
        }
        let registered = hotKeyManager.register()
        self.hotKeyManager = hotKeyManager
        overlay.updateHotKeyDisplay(hotKeyManager.displayString)

        setUpStatusItem(hotKeyDisplay: hotKeyManager.displayString, hotKeyRegistered: registered)
        showWelcomeIfNeeded(hotKeyDisplay: hotKeyManager.displayString)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyManager?.unregister()
    }

    // MARK: - Menu bar

    private func setUpStatusItem(hotKeyDisplay: String, hotKeyRegistered: Bool) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "square.grid.2x2",
            accessibilityDescription: "Better Mission Control"
        )
        item.button?.toolTip = "Better Mission Control (\(hotKeyDisplay))"

        let menu = NSMenu()

        let show = NSMenuItem(
            title: "Show Overview",
            action: #selector(showOverview),
            keyEquivalent: ""
        )
        show.target = self
        menu.addItem(show)

        if !hotKeyRegistered {
            let warning = NSMenuItem(
                title: "\(hotKeyDisplay) is unavailable — another app has it",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.addItem(warning)
        } else {
            let hint = NSMenuItem(title: "Hotkey: \(hotKeyDisplay)", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(.separator())

        let permissions = NSMenuItem(
            title: "Permissions & Help…",
            action: #selector(showWelcome),
            keyEquivalent: ""
        )
        permissions.target = self
        menu.addItem(permissions)

        let reset = NSMenuItem(
            title: "Reset Saved Layout",
            action: #selector(resetLayout),
            keyEquivalent: ""
        )
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())

        // Deliberately no ⌘Q key equivalent: inside the overlay, ⌘Q must quit
        // the app under the selected tile, not this one.
        let quit = NSMenuItem(title: "Quit Better Mission Control", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    // MARK: - Actions

    @objc private func showOverview() {
        overlay.show()
    }

    @objc private func showWelcome() {
        welcome.show(hotKeyDisplay: hotKeyManager?.displayString ?? "")
    }

    @objc private func resetLayout() {
        overlay.resetLayout()
        LayoutStore().reset()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Show the explanation on first launch, and on any later launch where a
    /// permission still isn't granted — otherwise the hotkey would appear to
    /// do nothing.
    private func showWelcomeIfNeeded(hotKeyDisplay: String) {
        let defaults = UserDefaults.standard
        let firstLaunch = !defaults.bool(forKey: DefaultsKey.hasLaunchedBefore)
        defaults.set(true, forKey: DefaultsKey.hasLaunchedBefore)

        if firstLaunch || !PermissionsManager.allGranted {
            welcome.show(hotKeyDisplay: hotKeyDisplay)
        }
    }
}
