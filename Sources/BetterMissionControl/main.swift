import AppKit

// SwiftPM runs top-level code in `main.swift`, so the app is bootstrapped by
// hand here instead of with `@main` — the two can't coexist in one target.
// Top-level code isn't main-actor isolated, hence the explicit hops.

// Held in a global on purpose: NSApplication doesn't retain its delegate.
private let appDelegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.delegate = appDelegate
    application.run()
}
