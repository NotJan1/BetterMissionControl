import Foundation

// MARK: - Private framework layout
//
// Declared at file scope rather than nested, because a C function pointer's
// parameter types have to be C-representable and nested Swift types are not.

struct MTPoint {
    var x: Float = 0
    var y: Float = 0
}

struct MTVector {
    var position = MTPoint()
    var velocity = MTPoint()
}

/// Mirrors MultitouchSupport's contact struct.
///
/// Only `identifier`, `state` and `normalized` are read; the trailing fields
/// exist purely so the struct has the right stride when the framework strides
/// through an array of them.
struct MTTouch {
    var frame: Int32 = 0
    var timestamp: Double = 0
    var identifier: Int32 = 0
    var state: Int32 = 0
    var fingerID: Int32 = 0
    var handID: Int32 = 0
    var normalized = MTVector()
    var zTotal: Float = 0
    var field9: Int32 = 0
    var angle: Float = 0
    var majorAxis: Float = 0
    var minorAxis: Float = 0
    var absoluteVector = MTVector()
    var field14: Int32 = 0
    var field15: Int32 = 0
    var zDensity: Float = 0
}

typealias MTDeviceRef = UnsafeMutableRawPointer

/// The contact array arrives as a raw pointer because a C function pointer's
/// parameters must be C-representable, and `UnsafeMutablePointer<MTTouch>`
/// isn't. Use `MultitouchBridge.touches(from:count:)` to read it.
typealias MTContactCallback = @convention(c) (
    MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Int32

/// The one and only place this project touches a private Apple framework.
///
/// Reading raw trackpad contacts is the only way to see a four-finger swipe:
/// macOS reserves those gestures for itself and never delivers them to a
/// background app through any public API. BetterTouchTool and Swish take the
/// same route.
///
/// The PRD rules private frameworks out precisely because they break on OS
/// updates, so everything here is built to fail safe rather than to be relied
/// on:
///
///   * Symbols are resolved at runtime with `dlopen`/`dlsym`, never linked. A
///     renamed or removed symbol makes `start()` return false — it can't stop
///     the app launching and can't crash it.
///   * Nothing outside this file knows these types exist. If it ever has to be
///     deleted, the gesture goes with it and nothing else notices.
///
/// If this stops working after a macOS update, the fix is to turn the feature
/// off — not to chase Apple's internals.
enum MultitouchBridge {
    private typealias CreateList = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias RegisterCallback = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    private typealias UnregisterCallback = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    private typealias DeviceStart = @convention(c) (MTDeviceRef, Int32) -> Void
    private typealias DeviceStop = @convention(c) (MTDeviceRef) -> Void

    private nonisolated(unsafe) static var handle: UnsafeMutableRawPointer?
    private nonisolated(unsafe) static var devices: [MTDeviceRef] = []
    private nonisolated(unsafe) static var unregister: UnregisterCallback?
    private nonisolated(unsafe) static var stopDevice: DeviceStop?
    private nonisolated(unsafe) static var activeCallback: MTContactCallback?

    static var isRunning: Bool { !devices.isEmpty }

    /// Reads the raw contact array handed to a callback.
    static func touches(from raw: UnsafeMutableRawPointer?, count: Int32) -> [MTTouch] {
        guard let raw, count > 0 else { return [] }
        let pointer = raw.bindMemory(to: MTTouch.self, capacity: Int(count))
        return Array(UnsafeBufferPointer(start: pointer, count: Int(count)))
    }

    /// Why the last `start()` failed, so Settings can say so rather than
    /// leaving a toggle that silently does nothing.
    private(set) nonisolated(unsafe) static var lastError: String?
    /// How many devices the framework reported, for diagnostics.
    private(set) nonisolated(unsafe) static var deviceCount = 0

    /// Returns false if the framework isn't there or has changed shape.
    @discardableResult
    static func start(callback: MTContactCallback) -> Bool {
        guard !isRunning else { return true }
        lastError = nil

        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            lastError = "MultitouchSupport isn't available on this system"
            return false
        }
        self.handle = handle

        guard let createSym = dlsym(handle, "MTDeviceCreateList"),
              let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let unregisterSym = dlsym(handle, "MTUnregisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart"),
              let stopSym = dlsym(handle, "MTDeviceStop")
        else {
            lastError = "MultitouchSupport has changed in this version of macOS"
            dlclose(handle)
            self.handle = nil
            return false
        }

        let createList = unsafeBitCast(createSym, to: CreateList.self)
        let register = unsafeBitCast(registerSym, to: RegisterCallback.self)
        unregister = unsafeBitCast(unregisterSym, to: UnregisterCallback.self)
        let deviceStart = unsafeBitCast(startSym, to: DeviceStart.self)
        stopDevice = unsafeBitCast(stopSym, to: DeviceStop.self)

        guard let list = createList()?.takeRetainedValue() else {
            lastError = "MTDeviceCreateList returned nothing"
            return false
        }

        // Read the CFArray through the CoreFoundation API rather than bridging
        // it to a Swift array: it holds opaque device pointers, not objects,
        // and `as? [UnsafeMutableRawPointer]` silently fails on them — which
        // looked exactly like "no trackpad found".
        let count = CFArrayGetCount(list)
        deviceCount = count
        guard count > 0 else {
            lastError = "No multitouch trackpad reported by the system"
            return false
        }

        activeCallback = callback
        for index in 0 ..< count {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            register(device, callback)
            deviceStart(device, 0)
            devices.append(device)
        }

        guard !devices.isEmpty else {
            lastError = "Multitouch devices could not be opened"
            return false
        }
        return true
    }

    static func stop() {
        if let unregister, let activeCallback {
            for device in devices { unregister(device, activeCallback) }
        }
        if let stopDevice {
            for device in devices { stopDevice(device) }
        }
        devices.removeAll()
        activeCallback = nil
    }
}
