import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import ImageIO
import ScreenCaptureKit

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

        // Free-form positioning: drag a tile, then confirm the exact position
        // was kept and written to disk.
        if mode == "drag" {
            guard let targetApp else { log("FAIL: set BMC_SELFTEST_APP"); exit(1) }
            let controller = OverlayController()
            controller.show()
            try? await Task.sleep(for: .seconds(2))
            let model = controller.debugModel
            let size = model.overlaySize
            log("overlay size=\(Int(size.width))x\(Int(size.height)) windows=\(model.windows.count)")
            for window in model.windows {
                log("  '\(window.appName)' center=\(describe(window.normalizedCenter))")
            }
            guard let target = model.windows.first(where: { $0.appName == targetApp }) else {
                log("FAIL: no window for '\(targetApp)'"); exit(1)
            }
            let before = target.normalizedCenter
            log("dragging '\(target.appName)' from \(describe(before))")

            model.beginDrag(target)
            model.updateDrag(target, translation: CGSize(width: -260, height: 180), in: size)
            model.endDrag()

            let after = model.windows.first { $0.id == target.id }?.normalizedCenter
            log("after drag center=\(describe(after))")
            log(before == after ? "RESULT: position UNCHANGED (drag failed)" : "RESULT: position moved")

            // A grid would have snapped to a column; a free canvas should not.
            if let after {
                let automatic = OverlayLayout.automaticCenters(count: model.windows.count, in: size)
                let snapped = automatic.contains { abs($0.x - after.x) < 0.001 && abs($0.y - after.y) < 0.001 }
                log(snapped ? "RESULT: SNAPPED to a grid slot" : "RESULT: free position (no grid snap)")
            }

            let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BetterMissionControl/layout.json")
            if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                log("layout.json: \(text.prefix(400))")
            } else {
                log("RESULT: layout.json NOT written")
            }
            exit(0)
        }

        // Reopens the overlay and reports where tiles landed — run after
        // "drag" to confirm a custom layout survives between sessions.
        if mode == "persist" {
            let controller = OverlayController()
            controller.show()
            try? await Task.sleep(for: .seconds(2))
            for window in controller.debugModel.windows {
                log("restored '\(window.appName)' '\(window.title)' center=\(describe(window.normalizedCenter))")
            }
            exit(0)
        }

        // Are captures big enough for the size tiles are actually drawn at?
        if mode == "thumbs" {
            let controller = OverlayController()
            controller.show()
            try? await Task.sleep(for: .seconds(3))
            let model = controller.debugModel
            let size = model.overlaySize
            let scale = WindowEnumerator.screenUnderCursor().backingScaleFactor
            let cell = model.cellSize(in: size)
            log("overlay=\(Int(size.width))x\(Int(size.height)) backingScale=\(scale) windows=\(model.windows.count)")
            log("grid cell=\(Int(cell.width))x\(Int(cell.height)) points")

            for window in model.windows {
                guard let image = window.thumbnail else {
                    log("  '\(window.appName)' NO THUMBNAIL"); continue
                }
                let drawn = window.thumbnailSize(in: cell)
                // A tile that ignores the window's proportions is the bug that
                // stretched tiles to full screen height.
                let drawnAspect = drawn.width / max(drawn.height, 1)
                let matches = abs(drawnAspect - window.aspectRatio) < 0.02
                log(String(
                    format: "  '%@' aspect window=%.3f tile=%.3f %@",
                    window.appName, window.aspectRatio, drawnAspect,
                    matches ? "OK" : "MISMATCH (stretched)"
                ))
                let neededPx = drawn.width * scale
                let ratio = CGFloat(image.width) / neededPx
                let verdict = ratio >= 0.99 ? "sharp" : String(format: "SOFT (%.0f%% of needed)", ratio * 100)
                log(String(
                    format: "  '%@' captured=%dx%d px, drawn=%.0fx%.0f pt -> needs %.0f px : %@",
                    window.appName, image.width, image.height, drawn.width, drawn.height, neededPx, verdict
                ))
            }
            exit(0)
        }

        // Hotkey configuration, conflict detection and the Settings deep links.
        if mode == "hotkey" {
            let manager = HotKeyManager {}
            log("default combo=\(manager.displayString) registered=\(manager.register())")

            // Display strings for a spread of key types.
            for combo in [
                HotKeyCombo(keyCode: UInt32(kVK_UpArrow), carbonModifiers: UInt32(controlKey | optionKey)),
                HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey | shiftKey)),
                HotKeyCombo(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: UInt32(controlKey | cmdKey)),
                HotKeyCombo(keyCode: UInt32(kVK_F3), carbonModifiers: 0)
            ] {
                log("  combo \(combo.displayString) hasModifier=\(combo.hasModifier)")
            }

            // Change it, confirm it sticks in UserDefaults.
            let newCombo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(controlKey | optionKey))
            let ok = manager.update(to: newCombo)
            let storedKey = UserDefaults.standard.object(forKey: "HotKeyKeyCode") as? Int
            let storedMods = UserDefaults.standard.object(forKey: "HotKeyModifiers") as? Int
            log("update to \(newCombo.displayString) -> \(ok); persisted keyCode=\(storedKey ?? -1) mods=\(storedMods ?? -1)")
            log("re-read: \(HotKeyManager {}.displayString)")

            // Conflict detection against a shortcut macOS actually has enabled.
            if let enabled = firstEnabledSystemHotKey() {
                let detected = SystemHotKeys.conflict(for: enabled.combo)
                log("system shortcut id=\(enabled.id) \(enabled.combo.displayString) -> conflict=\(detected?.description ?? "NONE (detection failed)")")
            } else {
                log("no enabled system hotkey with parameters found to test against")
            }
            // A combination nothing owns should come back clean.
            let unlikely = HotKeyCombo(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(controlKey | optionKey | shiftKey))
            log("control-option-shift-J -> conflict=\(SystemHotKeys.conflict(for: unlikely)?.description ?? "none (correct)")")

            manager.resetToDefault()
            log("after reset: \(manager.displayString)")

            for destination in ["Keyboard-Settings.extension?Shortcuts", "Trackpad-Settings.extension?MoreGestures"] {
                let url = URL(string: "x-apple.systempreferences:com.apple.\(destination)")!
                let handler = NSWorkspace.shared.urlForApplication(toOpen: url)
                log("deep link \(destination) -> \(handler?.lastPathComponent ?? "NO HANDLER")")
            }
            exit(0)
        }

        // R12: does Cmd-, reach the overlay's handler and ask for Settings?
        if mode == "settings" {
            let controller = OverlayController()
            var opened = false
            controller.onOpenSettings = { opened = true }
            controller.show()
            try? await Task.sleep(for: .seconds(2))

            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                context: nil, characters: ",", charactersIgnoringModifiers: ",",
                isARepeat: false, keyCode: 43
            ) else { log("FAIL: could not build event"); exit(1) }

            let handled = controller.debugHandleKey(event)
            log("Cmd-, handled=\(handled) settingsRequested=\(opened)")
            log("overlay dismissed=\(!controller.isVisible)")
            exit(opened && handled ? 0 : 1)
        }

        // Does the Settings window actually build and lay out?
        if mode == "settingsui" {
            let manager = HotKeyManager {}
            manager.register()
            let controller = SettingsWindowController(
                hotKeyManager: manager, onHotKeyChanged: {}, onGesture: {}
            )
            controller.show()
            try? await Task.sleep(for: .seconds(2))

            let settingsWindows = NSApp.windows.filter { $0.title.contains("Settings") }
            if settingsWindows.isEmpty {
                log("FAIL: no Settings window")
                exit(1)
            }
            for window in settingsWindows {
                log("window '\(window.title)' visible=\(window.isVisible) size=\(Int(window.frame.width))x\(Int(window.frame.height))")
                // A SwiftUI view that failed to lay out collapses to nothing,
                // so a sane content size is the signal that it rendered.
                let content = window.contentView?.fittingSize ?? .zero
                log("content fitting size=\(Int(content.width))x\(Int(content.height)) subviews=\(window.contentView?.subviews.count ?? 0)")
            }
            exit(0)
        }

        // The most recently dragged tile should sit on top, and stay there.
        if mode == "zorder" {
            let controller = OverlayController()
            controller.show()
            try? await Task.sleep(for: .seconds(2))
            let model = controller.debugModel
            let size = model.overlaySize
            guard model.windows.count >= 2 else { log("FAIL: need 2+ windows"); exit(1) }

            log("initial z: " + model.windows.map { "\($0.appName)=\(Int(model.zIndex(for: $0)))" }.joined(separator: " "))

            // Drag the *first* tile; it should end up above the others.
            let first = model.windows[0]
            model.beginDrag(first)
            model.updateDrag(first, translation: CGSize(width: 40, height: 40), in: size)
            model.endDrag()
            let afterFirst = model.zIndex(for: first)
            let others = model.windows.dropFirst().map { model.zIndex(for: $0) }
            log("after dragging '\(first.appName)': its z=\(Int(afterFirst)), others=\(others.map { Int($0) })")
            log(others.allSatisfy { afterFirst > $0 } ? "RESULT: dragged tile is on top" : "RESULT: dragged tile NOT on top")

            // Now drag a different one; it should take the top instead.
            let second = model.windows[1]
            model.beginDrag(second)
            model.updateDrag(second, translation: CGSize(width: -40, height: 40), in: size)
            model.endDrag()
            let secondZ = model.zIndex(for: second)
            log("after dragging '\(second.appName)': its z=\(Int(secondZ)), previous=\(Int(model.zIndex(for: first)))")
            log(secondZ > model.zIndex(for: first)
                ? "RESULT: most recent drag wins" : "RESULT: stacking did NOT update")
            exit(0)
        }

        // Captures the overlay to a PNG so it can actually be looked at.
        // Only possible because the panel isn't excluded from screen capture.
        if mode == "screenshot" {
            let directory = env["BMC_SELFTEST_OUT"] ?? NSTemporaryDirectory()
            let controller = OverlayController()
            controller.show()
            try? await Task.sleep(for: .seconds(3))
            let model = controller.debugModel
            log("overlay showing with \(model.windows.count) window(s)")
            await capture(to: "\(directory)/overlay-1-auto.png")

            // Drag one tile over another so overlap and stacking are visible.
            if model.windows.count >= 2 {
                let size = model.overlaySize
                let target = model.windows[0]
                let neighbour = model.windows[1]
                if let from = target.normalizedCenter, let to = neighbour.normalizedCenter {
                    model.beginDrag(target)
                    model.updateDrag(
                        target,
                        translation: CGSize(
                            width: (to.x - from.x) * size.width * 0.75,
                            height: (to.y - from.y) * size.height * 0.75
                        ),
                        in: size
                    )
                    model.endDrag()
                    log("dragged '\(target.appName)' toward '\(neighbour.appName)'")
                }
                try? await Task.sleep(for: .milliseconds(900))
                await capture(to: "\(directory)/overlay-2-dragged.png")
            }
            exit(0)
        }

        // What does the once-a-second refresh actually cost? Anything
        // expensive here lands as a stutter mid-drag.
        if mode == "perf" {
            func time(_ label: String, _ work: () async -> Void) async {
                let start = Date()
                await work()
                log(String(format: "%@: %.0f ms", label, Date().timeIntervalSince(start) * 1000))
            }

            await time("WindowEnumerator.snapshot") {
                _ = try? await WindowEnumerator.snapshot()
            }

            guard let snap = try? await WindowEnumerator.snapshot() else { exit(1) }
            let scale = WindowEnumerator.screenUnderCursor().backingScaleFactor
            let cell = OverlayLayout.cellSize(count: snap.windows.count, in: WindowEnumerator.screenUnderCursor().frame.size)
            log("windows=\(snap.windows.count) backingScale=\(scale)")

            await time("capture ALL thumbnails (concurrent)") {
                await withTaskGroup(of: Void.self) { group in
                    for window in snap.windows {
                        guard let source = snap.sourceWindows[window.id] else { continue }
                        let target = window.thumbnailSize(in: cell)
                        group.addTask {
                            _ = await ThumbnailCapturer.capture(source, targetSize: target, backingScale: scale)
                        }
                    }
                }
            }

            if let display = snap.display {
                await time("capture desktop backdrop") {
                    _ = await ThumbnailCapturer.captureDesktop(display: display, excluding: snap.foregroundWindows)
                }
            }

            // A full cycle is what repeats every second while the overlay is up.
            await time("FULL refresh cycle (enumerate + all thumbnails)") {
                guard let s = try? await WindowEnumerator.snapshot() else { return }
                await withTaskGroup(of: Void.self) { group in
                    for window in s.windows {
                        guard let source = s.sourceWindows[window.id] else { continue }
                        let target = window.thumbnailSize(in: cell)
                        group.addTask {
                            _ = await ThumbnailCapturer.capture(source, targetSize: target, backingScale: scale)
                        }
                    }
                }
            }
            exit(0)
        }

        // Does the tile track the pointer exactly, and does the refresh loop
        // stay out of the way while dragging?
        if mode == "dragtrack" {
            let controller = OverlayController()
            controller.show()
            try? await Task.sleep(for: .seconds(2))
            let model = controller.debugModel
            let size = model.overlaySize
            guard let target = model.windows.first, let origin = target.normalizedCenter else {
                log("FAIL: no windows"); exit(1)
            }

            model.beginDrag(target)
            var worstError: CGFloat = 0
            // Walk the pointer in small steps, as a real drag would.
            for step in stride(from: 20, through: 300, by: 20) {
                let translation = CGSize(width: CGFloat(-step), height: CGFloat(step) / 2)
                model.updateDrag(target, translation: translation, in: size)
                guard let actual = model.windows.first(where: { $0.id == target.id })?.normalizedCenter else { continue }
                let expected = CGPoint(
                    x: origin.x + translation.width / size.width,
                    y: origin.y + translation.height / size.height
                )
                // Clamping legitimately stops the tile at the edges.
                let clamped = OverlayLayout.clampCenter(
                    expected, tile: target.tileSize(in: model.cellSize(in: size)), in: size
                )
                let error = max(abs(actual.x - clamped.x), abs(actual.y - clamped.y)) * size.width
                worstError = max(worstError, error)
            }
            log(String(format: "worst tracking error across drag: %.2f px", worstError))
            log(worstError < 0.5 ? "RESULT: tracks pointer 1:1" : "RESULT: tile LAGS the pointer")

            // Refresh must not fire mid-drag; a cycle costs ~200ms.
            let before = model.refreshCount
            log("refreshCount at drag start=\(before), holding drag for 2.5s…")
            try? await Task.sleep(for: .seconds(2.5))
            let during = model.refreshCount
            log("refreshCount while dragging=\(during)")
            log(during == before ? "RESULT: refresh suspended during drag" : "RESULT: refresh STILL RUNNING during drag (\(during - before) cycles)")

            model.endDrag()
            try? await Task.sleep(for: .seconds(1.6))
            log("refreshCount after release=\(model.refreshCount)")
            log(model.refreshCount > during ? "RESULT: refresh resumes after drag" : "RESULT: refresh did NOT resume")
            exit(0)
        }

        // Open animation: check the start geometry matches each window's real
        // position, then capture the reveal in flight.
        if mode == "animate" {
            let directory = env["BMC_SELFTEST_OUT"] ?? NSTemporaryDirectory()
            let controller = OverlayController()
            controller.show()
            let model = controller.debugModel

            // Frames while the reveal plays out.
            for (index, delay) in [40, 90, 160, 260, 700].enumerated() {
                try? await Task.sleep(for: .milliseconds(delay))
                await capture(to: "\(directory)/reveal-\(index)-\(delay)ms.png")
            }

            let size = model.overlaySize
            let cell = model.cellSize(in: size)
            log("overlayOrigin=\(describe(model.overlayOrigin)) revealed=\(model.isRevealed)")
            for window in model.windows.prefix(4) {
                let source = model.sourceCenter(for: window)
                let expected = CGPoint(
                    x: window.frame.midX - model.overlayOrigin.x,
                    y: window.frame.midY - model.overlayOrigin.y
                )
                let matches = abs(source.x - expected.x) < 0.5 && abs(source.y - expected.y) < 0.5
                let scale = model.sourceScale(for: window, tile: window.tileSize(in: cell))
                log(String(
                    format: "  '%@' window=(%.0f,%.0f) start=(%.0f,%.0f) %@ scale=%.2f",
                    window.appName, window.frame.midX, window.frame.midY,
                    source.x, source.y, matches ? "OK" : "MISMATCH", scale
                ))
            }
            exit(0)
        }

        // What does macOS actually deliver for F3 and a four-finger swipe?
        if mode == "input" {
            let seconds = Int(env["BMC_SELFTEST_SECONDS"] ?? "25") ?? 25
            await InputProbe.run(seconds: seconds)
            exit(0)
        }

        // Swipe recognition, driven with synthetic contact frames using the
        // velocities the guided probe actually measured on this hardware.
        if mode == "gesture" {
            var fired = 0
            SwipeRecognizer.reset()
            SwipeRecognizer.fire = { fired += 1 }

            func feed(_ frames: Int, touches: Int, velocity: Float) {
                for _ in 0 ..< frames {
                    SwipeRecognizer.handle(touchCount: touches, meanVelocityY: velocity)
                }
            }

            // A real swipe up measured about +2.07.
            feed(8, touches: 4, velocity: 2.07)
            log("four-finger swipe up -> fired \(fired) time(s) \(fired == 1 ? "OK" : "WRONG")")

            // Still swiping: one gesture must not retrigger.
            feed(20, touches: 4, velocity: 2.07)
            log("held through a long swipe -> total \(fired) \(fired == 1 ? "OK (no retrigger)" : "WRONG")")

            // Fingers lift, then a second deliberate swipe.
            feed(3, touches: 0, velocity: 0)
            try? await Task.sleep(for: .milliseconds(600))
            feed(8, touches: 4, velocity: 2.07)
            log("second swipe after lifting -> total \(fired) \(fired == 2 ? "OK" : "WRONG")")

            // A swipe down measured about -0.58 and must never fire.
            let before = fired
            feed(3, touches: 0, velocity: 0)
            try? await Task.sleep(for: .milliseconds(600))
            feed(12, touches: 4, velocity: -0.58)
            log("swipe down -> fired \(fired - before) time(s) \(fired == before ? "OK (ignored)" : "WRONG")")

            // Three fingers is a different gesture and isn't ours.
            feed(3, touches: 0, velocity: 0)
            try? await Task.sleep(for: .milliseconds(600))
            feed(12, touches: 3, velocity: 2.07)
            log("three-finger swipe up -> fired \(fired - before) time(s) \(fired == before ? "OK (ignored)" : "WRONG")")

            // Resting fingers drift slightly and must not count.
            feed(3, touches: 0, velocity: 0)
            try? await Task.sleep(for: .milliseconds(600))
            feed(30, touches: 4, velocity: 0.15)
            log("four fingers resting -> fired \(fired - before) time(s) \(fired == before ? "OK (ignored)" : "WRONG")")

            SwipeRecognizer.fire = nil
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

    /// Picks a real, currently-enabled macOS shortcut to test conflict
    /// detection against, rather than assuming one exists.
    private static func firstEnabledSystemHotKey() -> (id: String, combo: HotKeyCombo)? {
        guard let hotKeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .persistentDomain(forName: "com.apple.symbolichotkeys")?["AppleSymbolicHotKeys"]
            as? [String: Any] else { return nil }

        for (identifier, raw) in hotKeys.sorted(by: { $0.key < $1.key }) {
            guard let entry = raw as? [String: Any],
                  entry["enabled"] as? Bool == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Any],
                  parameters.count >= 3,
                  let keyCode = (parameters[1] as? NSNumber)?.intValue, keyCode >= 0,
                  let mask = (parameters[2] as? NSNumber)?.uintValue
            else { continue }

            var carbon: UInt32 = 0
            if mask & NSEvent.ModifierFlags.command.rawValue != 0 { carbon |= UInt32(cmdKey) }
            if mask & NSEvent.ModifierFlags.option.rawValue != 0 { carbon |= UInt32(optionKey) }
            if mask & NSEvent.ModifierFlags.control.rawValue != 0 { carbon |= UInt32(controlKey) }
            if mask & NSEvent.ModifierFlags.shift.rawValue != 0 { carbon |= UInt32(shiftKey) }
            guard carbon != 0 else { continue }

            return (identifier, HotKeyCombo(keyCode: UInt32(keyCode), carbonModifiers: carbon))
        }
        return nil
    }

    /// Screenshots the whole display, overlay included, and writes a PNG.
    private static func capture(to path: String) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first else {
            log("capture failed: no display")
            return
        }
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false

        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration
        ) else {
            log("capture failed: SCScreenshotManager returned nil")
            return
        }

        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else {
            log("capture failed: could not create destination at \(path)")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        log(CGImageDestinationFinalize(destination) ? "wrote \(path)" : "capture failed: could not finalize")
    }

    private static func describe(_ point: CGPoint?) -> String {
        guard let point else { return "nil" }
        return String(format: "(%.3f, %.3f)", point.x, point.y)
    }

    private static func shortFrame(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("SELFTEST: \(message)\n".utf8))
    }
}
