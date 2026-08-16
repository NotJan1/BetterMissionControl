import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKeyManager: HotKeyManager?
    private var settings: SettingsWindowController?
    private let overlay = OverlayController()
    private let welcome = WelcomeWindowController()

    private enum DefaultsKey {
        static let hasLaunchedBefore = "HasLaunchedBefore"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar utility: no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        if SelfTest.isRequested {
            Task { await SelfTest.run() }
            return
        }

        let hotKeyManager = HotKeyManager { [weak self] in
            self?.overlay.toggle()
        }
        hotKeyManager.register()
        self.hotKeyManager = hotKeyManager
        overlay.updateHotKeyDisplay(hotKeyManager.displayString)

        // Constructing this also restores the trackpad gesture if it was left
        // switched on, so the swipe works without opening Settings first.
        settings = SettingsWindowController(
            hotKeyManager: hotKeyManager,
            onHotKeyChanged: { [weak self] in self?.hotKeyDidChange() },
            onGesture: { [weak self] in self?.overlay.toggle() }
        )
        overlay.onOpenSettings = { [weak self] in self?.showSettings() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showWelcome),
            name: .bmcShowWelcome,
            object: nil
        )

        setUpMainMenu()
        setUpStatusItem()
        showWelcomeIfNeeded(hotKeyDisplay: hotKeyManager.displayString)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyManager?.unregister()
    }

    // MARK: - Menus

    /// An accessory app shows no menu bar, but the main menu is still what
    /// makes ⌘, work whenever one of our windows is key (R12). Deliberately no
    /// ⌘Q item: inside the overlay ⌘Q must quit the app under the selected
    /// tile, and a menu key equivalent could shadow that.
    private func setUpMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "square.grid.2x2",
            accessibilityDescription: "Better Mission Control"
        )
        statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        guard let statusItem, let hotKeyManager else { return }
        let hotKey = hotKeyManager.displayString
        statusItem.button?.toolTip = "Better Mission Control (\(hotKey))"

        let menu = NSMenu()

        let show = NSMenuItem(title: "Show Overview", action: #selector(showOverview), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let hint: NSMenuItem
        if hotKeyManager.registrationFailed {
            hint = NSMenuItem(title: "\(hotKey) is unavailable — another app has it", action: nil, keyEquivalent: "")
        } else if let conflict = hotKeyManager.systemConflict {
            hint = NSMenuItem(title: "\(hotKey) clashes with \(conflict)", action: nil, keyEquivalent: "")
        } else {
            hint = NSMenuItem(title: "Hotkey: \(hotKey)", action: nil, keyEquivalent: "")
        }
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let permissions = NSMenuItem(title: "Permissions & Help…", action: #selector(showWelcome), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        let reset = NSMenuItem(title: "Reset Saved Layout", action: #selector(resetLayout), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Better Mission Control", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func hotKeyDidChange() {
        guard let hotKeyManager else { return }
        overlay.updateHotKeyDisplay(hotKeyManager.displayString)
        rebuildStatusMenu()
    }

    // MARK: - Actions

    @objc private func showOverview() {
        overlay.show()
    }

    @objc private func showSettings() {
        settings?.show()
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
