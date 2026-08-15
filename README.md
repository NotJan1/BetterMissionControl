# Better Mission Control

A macOS menu-bar overlay that looks like Mission Control but lets you close,
minimize, quit and rearrange windows directly from the overview.

See [CLAUDE.md](CLAUDE.md) for the full product requirements.

## Build and run

```bash
./build.sh run
```

That compiles, assembles `dist/BetterMissionControl.app`, ad-hoc signs it and
launches it. `./build.sh` alone builds without launching; `./build.sh release`
makes an optimised build.

The app has no Dock icon — look for the grid icon in the menu bar.

## First run: two permissions

macOS keeps both switched off until you turn them on by hand. The welcome
window that appears on first launch explains each one and has an **Allow**
button, which is what triggers the system prompt.

| Permission | Why it's needed | Without it |
|---|---|---|
| Screen Recording | Draws each window's thumbnail | Overlay explains what's missing instead of showing tiles |
| Accessibility | Close / minimize / raise other apps' windows | You can look but not act |

**Screen Recording only takes effect after a relaunch** — macOS reads that
consent once, at launch. Quit from the menu bar item and run `./build.sh run`
again after granting it.

You can reopen the explanation any time from the menu bar icon →
**Permissions & Help…**

## Using it

Press **⌃⌥↑** (Control-Option-Up) anywhere to open the overview. It's
deliberately one modifier away from Mission Control's own ⌃↑ so both don't fire
at once.

| Action | What it does |
|---|---|
| Click a tile | Activate that window, dismiss the overlay |
| Click the ✕ badge | Close that window, stay in the overlay |
| Arrow keys / Tab | Move the selection |
| Return | Activate the selected window |
| ⌘W | Close the selected window |
| ⌘M | Minimize it (its tile disappears) |
| ⌘Q | Quit the owning app and all its tiles |
| Esc, or click the background | Dismiss with nothing changed |
| Drag a tile onto another | Reorder — remembered for next time |

Layout is saved to
`~/Library/Application Support/BetterMissionControl/layout.json`. Menu bar icon
→ **Reset Saved Layout** returns to the automatic app-grouped arrangement.

### Remapping the hotkey

No Preferences window yet, so it's a `defaults` key. Values are Carbon key
codes and modifier masks:

```bash
defaults write com.janszalinski.BetterMissionControl HotKeyKeyCode -int 49
```

`49` is Space. Modifiers are a bitmask — `4096` control, `2048` option, `512`
shift, `256` command; add them together:

```bash
defaults write com.janszalinski.BetterMissionControl HotKeyModifiers -int 6144
```

Restart the app for either to take effect. If the combination is already owned
by another app, the menu bar item says so instead of failing silently.

## How it's built

| Need | What's used |
|---|---|
| Overlay window | `NSPanel` above the menu bar level, `.canJoinAllSpaces` |
| Window list + thumbnails | ScreenCaptureKit (`SCShareableContent`, `SCScreenshotManager`) |
| Close / minimize / raise | Accessibility API (`AXUIElement`) |
| Quit an app | `NSRunningApplication.terminate()` |
| Global hotkey | Carbon `RegisterEventHotKey` |
| Saved layout | JSON in Application Support |

### Notable decisions

- **SwiftPM, not an Xcode project.** Only the Command Line Tools are installed
  on this machine, so there's no `xcodebuild`. `build.sh` assembles the `.app`
  bundle by hand, which is what macOS requires before it will grant TCC
  permissions to the binary.

- **No `@State` anywhere.** In the macOS 26+ SDK SwiftUI's `@State` is a macro,
  and its compiler plugin (`libSwiftUIMacros.dylib`) ships only with full
  Xcode. Hover state lives on the `@Observable` model instead — `@Observable`
  works because `libObservationMacros.dylib` *is* bundled with the CLT.
  Installing Xcode would lift this constraint.

- **Window matching uses public API only.** ScreenCaptureKit gives a
  `CGWindowID`; the Accessibility API speaks `AXUIElement`, and no *public*
  call bridges them. `_AXUIElementGetWindow` does, but it's private SPI — the
  kind of dependency that got HyperDock broken. Instead `WindowActions` scores
  candidates on owning process, frame and title; both APIs report frames in the
  same coordinate space, so an exact frame match is a strong signal.

- **Thumbnails refresh on a 1s poll**, rather than running a live `SCStream`
  per window. Far cheaper, and the overlay is typically only open for seconds.
  The interval is `refreshInterval` in `OverviewModel`.

- **The dimmed backdrop is the real desktop**, captured by filtering out every
  window at or above the normal layer. A plain blur would show the windows
  sitting behind the overlay, which reads quite differently from native Mission
  Control.

- **Ad-hoc code signature.** The signature changes whenever the code does, and
  macOS ties granted permissions to it — so after a rebuild you may have to
  re-tick the app in System Settings › Privacy & Security. A Developer ID
  certificate at release time removes this.

## Not in v1

Per the PRD: multiple Spaces, per-display overlays, a Preferences window, and
Mac App Store distribution. Release signing (`codesign` with a Developer ID +
`notarytool`) also isn't wired up — it needs an Apple Developer Program
membership and full Xcode.
