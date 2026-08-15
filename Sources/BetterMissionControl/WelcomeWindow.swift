import AppKit
import Observation
import SwiftUI

/// R11: explains each permission in plain English, in our own words, *before*
/// the user ever sees a macOS system prompt. Each "Allow" button is what
/// finally triggers the real prompt.
@MainActor
final class WelcomeWindowController {
    private var window: NSWindow?
    private let status = PermissionStatus()

    func show(hotKeyDisplay: String) {
        status.refresh()

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let view = WelcomeView(
            status: status,
            hotKeyDisplay: hotKeyDisplay,
            onDone: { [weak self] in self?.close() }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Better Mission Control"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        self.window = window

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

/// Tracks which permissions are granted. An observable object rather than view
/// state, because the answer changes while the user is away in System Settings.
@MainActor
@Observable
final class PermissionStatus {
    private(set) var granted: Set<Permission> = []

    func refresh() {
        granted = Set(Permission.allCases.filter { PermissionsManager.isGranted($0) })
    }

    var allGranted: Bool { granted.count == Permission.allCases.count }
}

struct WelcomeView: View {
    let status: PermissionStatus
    let hotKeyDisplay: String
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Permission.allCases) { permission in
                        row(for: permission)
                    }
                }
                .padding(22)
            }
            Divider()
            footer
        }
        .frame(width: 540, height: 500)
        // Re-check when the user comes back from System Settings.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            status.refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Welcome to Better Mission Control")
                .font(.system(size: 20, weight: .semibold))
            Text("Press \(hotKeyDisplay) anywhere to open the overview. Click a window to jump to it, or close, minimize and quit without leaving the grid.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(for permission: Permission) -> some View {
        let isGranted = status.granted.contains(permission)
        return HStack(alignment: .top, spacing: 13) {
            Image(systemName: permission.symbolName)
                .font(.system(size: 18))
                .frame(width: 26)
                .foregroundStyle(isGranted ? Color.green : Color.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(permission.title).font(.system(size: 14, weight: .medium))
                Text(permission.explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isGranted, permission.requiresRelaunchAfterGranting {
                    Text("Takes effect after you quit and reopen the app.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if isGranted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            } else {
                Button("Allow…") {
                    // Our explanation has been read by this point — only now
                    // does the system prompt appear.
                    PermissionsManager.request(permission)
                    if permission == .screenRecording {
                        // This one only reliably deep-links, so open Settings too.
                        PermissionsManager.openSettings(for: permission)
                    }
                }
            }
        }
        .padding(14)
        .background(
            .quaternary.opacity(0.4),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private var footer: some View {
        HStack {
            Text(status.allGranted
                 ? "All set — press \(hotKeyDisplay) to try it."
                 : "You can grant these later from the menu bar icon.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done", action: onDone).keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
