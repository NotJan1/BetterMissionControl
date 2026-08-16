import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// R12: the Settings window, opened with ⌘,.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel

    init(
        hotKeyManager: HotKeyManager,
        onHotKeyChanged: @escaping () -> Void,
        onGesture: @escaping () -> Void,
        onGestureUp: @escaping () -> Void,
        onGestureDown: @escaping () -> Void
    ) {
        model = SettingsModel(hotKeyManager: hotKeyManager, onHotKeyChanged: onHotKeyChanged)
        model.onGesture = onGesture
        model.onGestureUp = onGestureUp
        model.onGestureDown = onGestureDown
        // Restore both toggles' effects across launches.
        model.applyTrackpadGesture()
        model.applyMissionControlKey()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Better Mission Control Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: SettingsView(model: model, onDone: { [weak self] in self?.close() })
        )
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        model.cancelRecording()
        window?.orderOut(nil)
        window = nil
    }
}

@MainActor
@Observable
final class SettingsModel {
    let hotKeyManager: HotKeyManager
    private(set) var isRecording = false
    private(set) var message: String?
    private(set) var messageIsWarning = false

    private var monitor: Any?
    private let onHotKeyChanged: () -> Void

    private enum DefaultsKey {
        static let trackpadGesture = "TrackpadGestureEnabled"
        static let missionControlKey = "MissionControlKeyEnabled"
    }

    /// Off by default — it swallows a system key, so it's opted into.
    var missionControlKeyEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKey.missionControlKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.missionControlKey)
            applyMissionControlKey()
        }
    }

    private(set) var f3Status: String?
    private(set) var f3StatusIsWarning = false

    func applyMissionControlKey() {
        guard missionControlKeyEnabled else {
            MissionControlKeyTap.shared.stop()
            f3Status = nil
            return
        }
        let started = MissionControlKeyTap.shared.start { [weak self] in
            self?.onGesture?()
        }
        if started {
            f3Status = "F3 now opens this instead of Mission Control."
            f3StatusIsWarning = false
        } else {
            f3Status = MissionControlKeyTap.shared.lastError ?? "Couldn't take over the F3 key."
            f3StatusIsWarning = true
            UserDefaults.standard.set(false, forKey: DefaultsKey.missionControlKey)
        }
    }

    /// Off by default: it's the one feature built on a private framework, so
    /// it's something you opt into rather than inherit.
    var trackpadGestureEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKey.trackpadGesture) }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.trackpadGesture)
            applyTrackpadGesture()
        }
    }

    private(set) var trackpadStatus: String?
    private(set) var trackpadStatusIsWarning = false

    /// Starts or stops the recogniser to match the toggle, reporting failure
    /// rather than leaving a switch that silently does nothing.
    func applyTrackpadGesture() {
        guard trackpadGestureEnabled else {
            TrackpadGestureMonitor.shared.stop()
            trackpadStatus = nil
            return
        }
        let started = TrackpadGestureMonitor.shared.start(
            onSwipeUp: { [weak self] in self?.onGestureUp?() },
            onSwipeDown: { [weak self] in self?.onGestureDown?() }
        )
        if started {
            trackpadStatus = "Swipe up to open, down to close."
            trackpadStatusIsWarning = false
        } else {
            trackpadStatus = TrackpadGestureMonitor.shared.lastError
                ?? "Couldn't read the trackpad on this version of macOS."
            trackpadStatusIsWarning = true
            UserDefaults.standard.set(false, forKey: DefaultsKey.trackpadGesture)
        }
    }

    /// Set by the app delegate — what recognised input should do.
    var onGesture: (() -> Void)?
    var onGestureUp: (() -> Void)?
    var onGestureDown: (() -> Void)?

    init(hotKeyManager: HotKeyManager, onHotKeyChanged: @escaping () -> Void) {
        self.hotKeyManager = hotKeyManager
        self.onHotKeyChanged = onHotKeyChanged
        refreshConflictNotice()
    }

    var comboDisplay: String { hotKeyManager.displayString }

    // MARK: - Recording

    /// Captures the next key combination the user presses. A local monitor is
    /// used so the keystroke never reaches the rest of the UI — otherwise
    /// recording ⌘W would close the Settings window.
    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            self.handle(event)
            return nil
        }
    }

    func cancelRecording() {
        stopMonitor()
        guard isRecording else { return }
        isRecording = false
        refreshConflictNotice()
    }

    private func handle(_ event: NSEvent) {
        // Modifiers alone aren't a shortcut; wait for a real key.
        guard event.type == .keyDown else { return }

        if Int(event.keyCode) == kVK_Escape {
            cancelRecording()
            return
        }

        let combo = HotKeyCombo(event: event)
        guard combo.isUsable else {
            set(
                message: "Add a modifier — \u{2303}, \u{2325}, \u{21E7} or \u{2318}. Function keys like F3 can be used on their own.",
                warning: true
            )
            return
        }
        apply(combo)
    }

    private func apply(_ combo: HotKeyCombo) {
        stopMonitor()
        isRecording = false

        guard hotKeyManager.update(to: combo) else {
            set(message: "\(combo.displayString) was refused — another app already holds it", warning: true)
            return
        }
        onHotKeyChanged()

        // Registration can succeed even when macOS owns the same combination,
        // so warn separately rather than pretending it took cleanly.
        if let conflict = hotKeyManager.systemConflict {
            set(
                message: "\(combo.displayString) is also \u{201C}\(conflict)\u{201D} in System Settings — one of them will win. Pick another, or turn that one off.",
                warning: true
            )
        } else {
            set(message: "Hotkey set to \(combo.displayString)", warning: false)
        }
    }

    func resetHotKey() {
        hotKeyManager.resetToDefault()
        onHotKeyChanged()
        refreshConflictNotice()
    }

    private func refreshConflictNotice() {
        if let conflict = hotKeyManager.systemConflict {
            set(
                message: "\(hotKeyManager.displayString) is also \u{201C}\(conflict)\u{201D} in System Settings — one of them will win.",
                warning: true
            )
        } else if hotKeyManager.registrationFailed {
            set(message: "\(hotKeyManager.displayString) couldn't be registered — another app already holds it.", warning: true)
        } else {
            message = nil
        }
    }

    private func set(message: String, warning: Bool) {
        self.message = message
        messageIsWarning = warning
    }

    private func stopMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    // MARK: - System Settings deep links

    /// Both anchors verified on macOS 27: the first opens Keyboard with the
    /// Keyboard Shortcuts sheet up, the second lands directly on Trackpad's
    /// More Gestures tab.
    enum Destination {
        case keyboardShortcuts
        case trackpadGestures

        var url: URL {
            switch self {
            case .keyboardShortcuts:
                return URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")!
            case .trackpadGestures:
                return URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension?MoreGestures")!
            }
        }
    }

    func open(_ destination: Destination) {
        // Falls back to System Settings generally if the anchor ever stops
        // resolving — these have shifted between macOS releases before.
        if !NSWorkspace.shared.open(destination.url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}

struct SettingsView: View {
    let model: SettingsModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hotKeySection
                    Divider()
                    functionKeySection
                    Divider()
                    trackpadSection
                    Divider()
                    missionControlSection
                }
                .padding(24)
            }
            Divider()
            HStack {
                Button("Permissions & Help…") {
                    NotificationCenter.default.post(name: .bmcShowWelcome, object: nil)
                }
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 700)
    }

    // MARK: - Hotkey

    private var hotKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Global hotkey")
                .font(.system(size: 15, weight: .semibold))
            Text("The keystroke that opens the overview from anywhere.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(action: { model.startRecording() }) {
                    Text(model.isRecording ? "Press a key combination\u{2026}" : model.comboDisplay)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .frame(minWidth: 150)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
                .tint(model.isRecording ? .accentColor : nil)

                if model.isRecording {
                    Button("Cancel") { model.cancelRecording() }
                } else {
                    Button("Reset") { model.resetHotKey() }
                }
                Spacer()
            }

            if model.isRecording {
                Text("Esc cancels. At least one modifier is required.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let message = model.message {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: model.messageIsWarning
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.messageIsWarning ? .orange : .green)
                    Text(message)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (model.messageIsWarning ? Color.orange : Color.green).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
    }

    // MARK: - F3 key

    private var functionKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { model.missionControlKeyEnabled },
                set: { model.missionControlKeyEnabled = $0 }
            )) {
                Text("Open with the F3 key")
                    .font(.system(size: 15, weight: .semibold))
            }
            .toggleStyle(.switch)

            Text("Takes F3 for this app and stops macOS opening its own Mission Control. Nothing in System Settings needs changing, and every other function key — brightness, volume — keeps working exactly as before.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let status = model.f3Status {
                HStack(spacing: 6) {
                    Image(systemName: model.f3StatusIsWarning
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.f3StatusIsWarning ? .orange : .green)
                    Text(status).font(.system(size: 12))
                }
            }

            Text("Unticking Mission Control in Keyboard Shortcuts does not free up F3 — that setting only controls the ⌘↑ combination. The F3 key itself is claimed further down, which is why this intercepts it directly.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Trackpad gesture

    private var trackpadSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { model.trackpadGestureEnabled },
                set: { model.trackpadGestureEnabled = $0 }
            )) {
                Text("Open with a four-finger swipe up")
                    .font(.system(size: 15, weight: .semibold))
            }
            .toggleStyle(.switch)

            Text("macOS never hands four-finger swipes to other apps, so this reads the trackpad directly through a private Apple interface — the same route BetterTouchTool and Swish take. It's off by default for that reason.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.trackpadGestureEnabled {
                // Not advice — a consequence. Reading contacts is passive, so
                // Apple still acts on the same swipe.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Turn Apple's own gesture off, or both will open at once.")
                            .font(.system(size: 12, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("This can watch the swipe but can't take it — macOS acts on it either way. Set Mission Control to Off under More Gestures.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Trackpad Gestures") { model.open(.trackpadGestures) }
                            .controlSize(.small)
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let status = model.trackpadStatus {
                HStack(spacing: 6) {
                    Image(systemName: model.trackpadStatusIsWarning
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.trackpadStatusIsWarning ? .orange : .green)
                    Text(status).font(.system(size: 12))
                }
            }

            Text("If a macOS update ever breaks this, the switch turns itself off and says so — nothing else in the app is affected.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Mission Control guide

    private var missionControlSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Make this your Mission Control")
                    .font(.system(size: 15, weight: .semibold))
                Text("macOS keeps F3 and the four-finger swipe wired to its own Mission Control. Freeing them up takes two changes in System Settings — they can't be done from here (see below).")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            step(
                number: 1,
                title: "Free up F3",
                detail: "In Keyboard Shortcuts, choose Mission Control in the list, then untick \u{201C}Mission Control\u{201D} — or double-click its shortcut and set it to something else. F3 is then free for this app.",
                buttonTitle: "Open Keyboard Shortcuts",
                action: { model.open(.keyboardShortcuts) }
            )

            step(
                number: 2,
                title: "Change the trackpad gesture",
                detail: "Under More Gestures, set Mission Control to Off — or leave it if you're happy for both to coexist.",
                buttonTitle: "Open Trackpad Gestures",
                action: { model.open(.trackpadGestures) }
            )

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("Why not automatic? macOS has no public API for reassigning F3 or capturing the trackpad gesture. The only way in is Apple's private MultitouchSupport framework — exactly the sort of thing that breaks on an OS update, which this app avoids on principle.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    private func step(
        number: Int,
        title: String,
        detail: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.tint))

            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(buttonTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension Notification.Name {
    static let bmcShowWelcome = Notification.Name("BMCShowWelcome")
}
