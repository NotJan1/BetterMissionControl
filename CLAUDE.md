# BetterMissionControl — Product Requirements

One-line goal: a macOS overlay that looks and feels like Apple's own Mission Control, but lets you close, minimize, quit, and rearrange windows directly from the overview — without switching into each app first.

## Overview

BetterMissionControl is a menu-bar utility, summoned by a global hotkey, that renders a window-overview grid closely mirroring the look of Apple's native Mission Control — dimmed desktop background, windows grouped by app, similar spacing and scale — but adds direct interactivity Apple's own version doesn't offer: click-to-close, per-window minimize/quit, keyboard-driven selection and actions, and drag-to-rearrange with a layout that's remembered between sessions.

It's a separate, self-contained overlay window — not a modification of the real Mission Control, which has no public API for third-party UI injection (see "Why not the real Mission Control" below). Looking like Mission Control and being Mission Control are different things — this app deliberately does the former, by building its own window.

## Goals

- Visually close to native Mission Control: dimmed background, app-grouped window thumbnails, familiar grid feel
- Every window individually actionable — open, minimize, close, quit — without leaving the overview
- Fully keyboard-navigable, not just mouse-driven
- Custom tile arrangement that persists across sessions

## Non-goals (v1)

- Modifying or hooking into the real Mission Control — not possible via public APIs
- Multiple desktop Spaces / moving windows between Spaces from the overlay (matches native single-display Mission Control behavior for v1; multi-Space support is a fast-follow)
- Mac App Store distribution — sandboxing would block the Accessibility/window-management APIs this depends on
- Intel Mac support — macOS 27 itself doesn't run on Intel
- Automatically capturing or reassigning F3 or the trackpad gesture — no public API supports this (would require Apple's private MultitouchSupport framework, the same fragile territory ruled out for Mission Control itself); the Settings page provides guided manual instructions instead

## Platform & environment

- Target OS: macOS 27 "Golden Gate" — Apple Silicon only, public beta since July 2026, ships publicly ~September/October 2026
- Deployment target: macOS 26 Tahoe and later — SwiftUI, ScreenCaptureKit, and the Accessibility API are all available there too, and supporting one extra OS version back costs nothing
- Architecture: arm64 only
- Dev machine: Apple Silicon (M-series)

## Distribution

Outside the Mac App Store — notarized direct download (.dmg or .zip).

- Requires an Apple Developer Program membership ($99/year) for a Developer ID Application certificate
- `codesign` + `notarytool` are part of the release build, not local dev/testing
- No App Store sandbox limits — but still request only the permissions actually used, and explain each on first launch

## Why not the real Mission Control

Mission Control is a sealed system surface — Apple gives third-party apps no way to draw into it or intercept clicks and drags on the real thing. Apps offering this kind of feature (Witch, Contexts, AltTab) all build their own overlay instead of hooking Apple's. The old HyperDock used private APIs to modify the real Mission Control directly; Apple broke it, and that path isn't worth repeating.

## Functional requirements

R1. WHEN the user presses the global hotkey THE SYSTEM SHALL display a floating overlay above all other windows, on the display containing the cursor.

R2. WHEN the overlay is open THE SYSTEM SHALL show a live thumbnail for every currently visible (non-minimized) window, grouped visually by owning app. Minimized windows are excluded — matching native Mission Control.

R3. WHEN the overlay opens with no saved custom layout THE SYSTEM SHALL arrange tiles using an automatic app-grouped layout approximating native Mission Control's own arrangement.

R4. WHEN the user drags a tile THE SYSTEM SHALL let it be placed freely anywhere within the overlay — not constrained to a grid — and persist its exact position for the next time the overlay opens, taking precedence over the automatic arrangement from then on.

R5. WHEN the user navigates with arrow keys or Tab THE SYSTEM SHALL move a visible selection highlight between tiles.

R6. WHEN a tile is selected THE SYSTEM SHALL respond to: Return (activate the window, dismiss the overlay), ⌘W (close that window), ⌘M (minimize that window and remove its tile from the current view), ⌘Q (quit the owning app entirely and remove all its tiles).

R7. WHEN the user clicks a tile's close control THE SYSTEM SHALL close that window without requiring prior keyboard selection.

R8. WHEN the user clicks a tile anywhere other than the close control THE SYSTEM SHALL activate that window and dismiss the overlay.

R9. WHEN the user presses Esc, or clicks outside every tile, THE SYSTEM SHALL dismiss the overlay with no action taken.

R10. WHEN a window closes or an app quits while the overlay is open — whether via this app or elsewhere — THE SYSTEM SHALL update the overlay's contents live, without requiring the user to reopen it.

R11. WHEN the app requests Accessibility, Screen Recording, or Input Monitoring for the first time THE SYSTEM SHALL show a plain-English explanation of why, before or alongside the system prompt.

R12. WHEN the user presses ⌘, THE SYSTEM SHALL open a Settings window offering a configurable global hotkey (replacing the hardcoded default) and instructions for freeing up F3 and the trackpad gesture in System Settings, with a deep-link button to the relevant pane where feasible.

## Edge cases

- Hotkey pressed with no windows open → overlay shows a brief "No open windows" state rather than a blank grid or nothing happening — the hotkey should always give feedback
- Accessibility or Screen Recording not yet granted → overlay explains what's missing and links to System Settings, rather than silently failing to populate
- The selected tile's window closes or its app quits by some other means while the overlay is open → selection moves to the next available tile rather than pointing at nothing
- User sets a custom hotkey already claimed by the system or another app → Settings page surfaces a conflict warning rather than silently failing to register

## Visual design

Reference: Apple's native Mission Control — dimmed/blurred desktop background, windows as scaled-down live thumbnails, app-grouped clustering, similar density and spacing. Close visual approximation is the v1 bar, not pixel-perfect matching — [assumed: following macOS's own window-shadow and corner-radius conventions gets it close enough; a dedicated polish pass can tighten spacing and animation later if it isn't]. Thumbnails should render at native/Retina sharpness — match ScreenCaptureKit's capture scale to the display's backing scale factor rather than under-sampling.

## Required macOS permissions

| Permission | Why | First triggered by |
|---|---|---|
| Accessibility | Read/control other apps' windows — list, move, close, minimize | First window action |
| Screen Recording | Live thumbnails of window contents | First overlay launch |
| Input Monitoring | Only if the global hotkey uses `CGEventTap` rather than Carbon's `RegisterEventHotKey` | Global hotkey registration, if applicable |

## Suggested technical approach

| Need | API |
|---|---|
| Floating overlay, visible on all Spaces | `NSPanel`/`NSWindow`, high window level, `.canJoinAllSpaces` |
| Tile grid + drag-to-rearrange | SwiftUI, local view state |
| Live window thumbnails | `ScreenCaptureKit` |
| Move/close/minimize another app's window | Accessibility API (`AXUIElement`) |
| Quit an app entirely | `NSRunningApplication.terminate()` |
| Global hotkey | `RegisterEventHotKey` (Carbon — lower permission cost) or `CGEventTap` |
| Remembered layout | A small local store (`UserDefaults` or a JSON file) keyed by a stable window identity — see Key Decisions |
| Configurable hotkey storage | `UserDefaults`; re-register via `RegisterEventHotKey`/`CGEventTap` whenever the Settings page changes it |

## Key decisions & assumptions

- **Window identity for persisted layout** — [assumed: key by bundle identifier + window title, since Accessibility API window references aren't stable across app relaunches. Two windows of the same app sharing a title would be treated as interchangeable for position assignment — tighten this later if it causes visible glitches]
- **Global hotkey default** — [assumed: Control+Option+Up Arrow as the starting default, distinct from Mission Control's own Control+Up Arrow so the two don't both fire — now user-configurable via the Settings page (R12)]
- **Multi-display** — [assumed: v1 shows the overlay on the display containing the cursor, single-display only; matching native Mission Control's per-display behavior is out of scope for v1]
- **Stale layout entries** — [assumed: a saved tile position referring to a window/app no longer open is silently dropped; new, never-seen windows are appended using the automatic arrangement]
- **Deployment target** — macOS 26 Tahoe and later (see Platform & environment)
- **System Settings deep-link** — [assumed: the Settings page attempts `x-apple.systempreferences:` deep-linking to the Keyboard Shortcuts and Trackpad panes; verify the exact anchor empirically since it has shifted across macOS versions — fall back to opening System Settings generally if it doesn't resolve]

## Developer context

New to native macOS/Swift — background is web (HTML/CSS/JS) and Firebase. SwiftUI's declarative, state-driven model is the nearest thing to React; the genuinely unfamiliar part is the system-level glue (Accessibility API, global hotkeys, window levels, ScreenCaptureKit), not the view layer.

## Suggested build order

1. Walking skeleton: hotkey → empty overlay window appears, Esc dismisses it (proves the riskiest plumbing — window level, all-Spaces visibility, global hotkey — before any real feature)
2. Populate the overlay with live tiles (ScreenCaptureKit + window enumeration), no interactivity yet
3. Wire up click-to-activate and the per-tile close control
4. Keyboard navigation plus the four selected-tile shortcuts
5. Free-form drag-to-reposition, in-memory only
6. Persist and restore each tile's custom position
7. Permission-request UX pass — plain-English explanations before each system prompt
8. Visual polish toward the Mission Control reference
9. Settings page (⌘,) — configurable hotkey, F3/gesture guidance with deep-link

## Working conventions

- Complete file replacements over diffs when showing changes
- Plain-English explanations paired with exact terminal commands
- Flag decisions explicitly rather than choosing silently
- Git: local repository as a restore point; no GitHub remote unless asked for
