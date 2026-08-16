import AppKit
import Foundation

/// Recognises a four-finger swipe up from raw trackpad contacts.
///
/// This is the only feature built on [MultitouchBridge], and it is opt-in and
/// off by default. Two things about it are worth knowing before relying on it:
///
///   * It reads a private Apple interface with no compatibility promise. If a
///     macOS update changes it, `start()` fails, the toggle reports why, and
///     nothing else in the app is affected.
///   * It can only *observe* the gesture, never consume it. Raw contact
///     reading sits below the system's own gesture handling, which is why we
///     can see the swipe at all — but it also means macOS still acts on it.
///     Unless Mission Control's own four-finger gesture is turned off in
///     System Settings, both will open. Settings says so plainly.
@MainActor
final class TrackpadGestureMonitor {
    static let shared = TrackpadGestureMonitor()
    private init() {}

    private(set) var isRunning = false
    private var onSwipeUp: (() -> Void)?
    private var onSwipeDown: (() -> Void)?

    var lastError: String? { MultitouchBridge.lastError }

    @discardableResult
    func start(
        onSwipeUp: @escaping () -> Void,
        onSwipeDown: @escaping () -> Void
    ) -> Bool {
        guard !isRunning else { return true }
        self.onSwipeUp = onSwipeUp
        self.onSwipeDown = onSwipeDown

        SwipeRecognizer.reset()
        SwipeRecognizer.fire = { direction in
            // The contact callback runs off the main actor.
            Task { @MainActor in
                let monitor = TrackpadGestureMonitor.shared
                switch direction {
                case .up: monitor.onSwipeUp?()
                case .down: monitor.onSwipeDown?()
                }
            }
        }

        let started = MultitouchBridge.start(callback: contactCallback)
        if !started { SwipeRecognizer.fire = nil }
        isRunning = started
        return started
    }

    func stop() {
        guard isRunning else { return }
        MultitouchBridge.stop()
        SwipeRecognizer.fire = nil
        onSwipeUp = nil
        onSwipeDown = nil
        isRunning = false
    }
}

/// State for the recogniser. At file scope because the contact callback is a C
/// function pointer and can't capture anything.
enum SwipeRecognizer {
    enum Direction { case up, down }

    /// Thresholds are asymmetric because the measurements were. The guided
    /// probe recorded a four-finger swipe up at about +2.07 mean normalised
    /// velocity but a swipe down at only -0.58 — swiping down is a gentler
    /// motion. A single symmetric threshold set for "up" would simply never
    /// catch a "down".
    static let upVelocity: Float = 0.6
    static let downVelocity: Float = -0.35
    /// Consecutive qualifying frames required, so a stray flick doesn't count.
    static let framesRequired = 3
    /// Contacts must fall away before another swipe can fire, which stops one
    /// long gesture retriggering over and over.
    static let minimumInterval: TimeInterval = 0.5

    nonisolated(unsafe) static var consecutiveFrames = 0
    nonisolated(unsafe) static var currentDirection: Direction?
    nonisolated(unsafe) static var armed = true
    nonisolated(unsafe) static var lastFired = Date.distantPast
    nonisolated(unsafe) static var fire: ((Direction) -> Void)?

    static func reset() {
        consecutiveFrames = 0
        currentDirection = nil
        armed = true
        lastFired = .distantPast
    }

    static func handle(touchCount: Int, meanVelocityY: Float) {
        // Fewer than four fingers ends the gesture and re-arms it.
        guard touchCount >= 4 else {
            consecutiveFrames = 0
            currentDirection = nil
            armed = true
            return
        }

        let direction: Direction?
        if meanVelocityY > upVelocity {
            direction = .up
        } else if meanVelocityY < downVelocity {
            direction = .down
        } else {
            direction = nil
        }

        guard let direction else {
            consecutiveFrames = 0
            return
        }

        // A reversal mid-gesture starts the count again rather than adding to
        // the tally for the other direction.
        if direction != currentDirection {
            currentDirection = direction
            consecutiveFrames = 0
        }

        consecutiveFrames += 1
        guard armed,
              consecutiveFrames >= framesRequired,
              Date().timeIntervalSince(lastFired) > minimumInterval
        else { return }

        armed = false
        lastFired = Date()
        fire?(direction)
    }
}

/// Top-level so it can be used as a C function pointer.
private func contactCallback(
    _ device: MTDeviceRef?,
    _ raw: UnsafeMutableRawPointer?,
    _ count: Int32,
    _ timestamp: Double,
    _ frame: Int32
) -> Int32 {
    let contacts = MultitouchBridge.touches(from: raw, count: count)
    guard !contacts.isEmpty else {
        SwipeRecognizer.handle(touchCount: 0, meanVelocityY: 0)
        return 0
    }
    let meanVelocityY = contacts.reduce(Float(0)) { $0 + $1.normalized.velocity.y }
        / Float(contacts.count)
    SwipeRecognizer.handle(touchCount: contacts.count, meanVelocityY: meanVelocityY)
    return 0
}
