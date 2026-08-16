import AppKit
import ApplicationServices
import CoreGraphics

/// Headless exercise of the real enumeration and action code paths.
///
/// There's no Xcode on this machine and therefore no test target, so this runs
/// the actual `WindowEnumerator` and `WindowActions` in-process and reports
/// what happened:
///
///     BMC_SELFTEST=close BMC_SELFTEST_APP=TextEdit \
///       dist/BetterMissionControl.app/Contents/MacOS/BetterMissionControl
@MainActor
enum SelfTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BMC_SELFTEST"] != nil
    }

    static func run() async -> Never {
        let env = ProcessInfo.processInfo.environment
        let mode = env["BMC_SELFTEST"] ?? "list"
        let targetApp = env["BMC_SELFTEST_APP"]

        log("accessibility=\(AXIsProcessTrusted()) screenRecording=\(CGPreflightScreenCaptureAccess())")

        guard let snapshot = try? await WindowEnumerator.snapshot() else {
            log("FAIL: WindowEnumerator.snapshot() threw")
            exit(1)
        }
        log("enumerated \(snapshot.windows.count) window(s)")
        for window in snapshot.windows {
            log("  id=\(window.id) app='\(window.appName)' title='\(window.title)' frame=\(shortFrame(window.frame))")
        }

        // Non-destructive: report what matching would decide for every window.
        if mode == "match" {
            for window in snapshot.windows {
                log("\(window.appName) '\(window.title)' -> \(WindowActions.debugMatchDescription(for: window))")
            }
            exit(0)
        }

        // Drives the real overlay and pushes a synthetic Cmd-W through the
        // real key handler, which is the part a headless action test misses.
        if mode == "key" {
            guard let targetApp else { log("FAIL: set BMC_SELFTEST_APP"); exit(1) }
            let controller = OverlayController()
            controller.show()
            try? await Task.sleep(for: .seconds(2))
            let model = controller.debugModel
            log("overlay windows=\(model.windows.count)")
            guard let target = model.windows.first(where: { $0.appName == targetApp }) else {
                log("FAIL: no window for '\(targetApp)' in overlay"); exit(1)
            }
            model.selectedID = target.id
            log("selected id=\(target.id) '\(target.title)'")

            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                context: nil, characters: "w", charactersIgnoringModifiers: "w",
                isARepeat: false, keyCode: 13
            ) else { log("FAIL: could not build event"); exit(1) }

            log("event: mods=\(event.modifierFlags.rawValue) chars='\(event.charactersIgnoringModifiers ?? "")' keyCode=\(event.keyCode)")
            let handled = controller.debugHandleKey(event)
            log("handler returned handled=\(handled)")

            try? await Task.sleep(for: .milliseconds(1200))
            log("overlay now has \(model.windows.count) window(s)")
            if let after = try? await WindowEnumerator.snapshot() {
                let stillOpen = after.windows.contains { $0.id == target.id }
                log(stillOpen ? "RESULT: window STILL OPEN" : "RESULT: window closed")
                if let idx = model.windows.firstIndex(where: { $0.id == target.id }) {
                    log("RESULT: tile still present at index \(idx) of \(model.windows.count)")
                }
            }
            exit(0)
        }

        // Does the overlay actually take keyboard focus? If the panel never
        // becomes key, the local monitor never sees a keystroke.
        if mode == "focus" {
            let controller = OverlayController()
            controller.show()
            try? await Task.sleep(for: .seconds(2))
            log("NSApp.isActive=\(NSApp.isActive)")
            for window in NSApp.windows where window is OverlayPanel {
                log("panel visible=\(window.isVisible) key=\(window.isKeyWindow) main=\(window.isMainWindow) level=\(window.level.rawValue)")
                log("panel canBecomeKey=\(window.canBecomeKey) acceptsFirstResponder=\(window.contentView?.acceptsFirstResponder ?? false)")
            }
            log("NSApp.keyWindow=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil")")
            exit(0)
        }

        guard mode != "list" else { exit(0) }

        guard let targetApp else {
            log("FAIL: set BMC_SELFTEST_APP to choose a target")
            exit(1)
        }
        guard let target = snapshot.windows.first(where: { $0.appName == targetApp }) else {
            log("FAIL: no window owned by '\(targetApp)'")
            exit(1)
        }
        log("target: id=\(target.id) '\(target.title)' frame=\(shortFrame(target.frame))")

        switch mode {
        case "close":
            let matched = WindowActions.debugMatchDescription(for: target)
            log("match: \(matched)")
            let ok = WindowActions.close(target)
            log("WindowActions.close returned \(ok)")
            // Give the app a moment, then confirm the window really went away.
            try? await Task.sleep(for: .milliseconds(700))
            if let after = try? await WindowEnumerator.snapshot() {
                let stillThere = after.windows.contains { $0.id == target.id }
                log(stillThere ? "RESULT: window STILL OPEN" : "RESULT: window closed")
            }
        case "minimize":
            let ok = WindowActions.minimize(target)
            log("WindowActions.minimize returned \(ok)")
        default:
            log("FAIL: unknown mode '\(mode)'")
            exit(1)
        }
        exit(0)
    }

    private static func shortFrame(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("SELFTEST: \(message)\n".utf8))
    }
}
