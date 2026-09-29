import Foundation
import IOKit.hid

/// Tracks Fn elements separately so releasing or unplugging one keyboard cannot
/// release a Fn key still held on another keyboard.
struct FunctionKeyState {
    struct Source: Hashable {
        let deviceID: UInt64
        let elementCookie: UInt32
    }

    private var values: [Source: Bool] = [:]
    var isDown: Bool? { values.isEmpty ? nil : values.values.contains(true) }

    static func matches(usagePage: UInt32, usage: UInt32) -> Bool {
        // Apple vendor Top Case / Keyboard Fn, and USB Consumer Globe.
        ((usagePage == 0x00FF || usagePage == 0xFF01) && usage == 0x0003)
            || (usagePage == 0x000C && usage == 0x029D)
    }

    mutating func update(_ source: Source, value: Int) {
        values[source] = value != 0
    }

    mutating func remove(deviceID: UInt64) {
        values = values.filter { $0.key.deviceID != deviceID }
    }
}

/// Supplemental, non-exclusive HID observation for Fn/Globe. Some keyboards do
/// not generate an independent Quartz flagsChanged event for this key.
@MainActor
final class FunctionKeyMonitor {
    var onStateChange: ((Bool?, Double?) -> Void)?
    private var manager: IOHIDManager?
    private var elements: [FunctionKeyState.Source: IOHIDElement] = [:]
    private var state = FunctionKeyState()
    var currentState: Bool? { state.isDown }

    private static let secondsPerMachTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    isolated deinit { teardown() }

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        // Consumer-control interfaces can expose Globe without a keyboard
        // collection; match both, while filtering input to Fn/Globe only.
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6],
            [kIOHIDDeviceUsagePageKey: 12, kIOHIDDeviceUsageKey: 1]
        ] as CFArray)
        IOHIDManagerSetInputValueMatchingMultiple(manager, [
            [kIOHIDElementUsagePageKey: 0x00FF, kIOHIDElementUsageKey: 0x0003],
            [kIOHIDElementUsagePageKey: 0xFF01, kIOHIDElementUsageKey: 0x0003],
            [kIOHIDElementUsagePageKey: 0x000C, kIOHIDElementUsageKey: 0x029D]
        ] as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, functionDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, functionDeviceRemoved, context)
        IOHIDManagerRegisterInputValueCallback(manager, functionValueChanged, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        // Never seize a keyboard: macOS keeps its normal Fn/Globe behavior.
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            stop()
            return
        }
    }

    func stop() {
        teardown()
        elements.removeAll()
        state = FunctionKeyState()
    }

    /// Only called for lost-release reconciliation, never polled while idle.
    func refresh() {
        let previous = state.isDown
        for (source, element) in elements {
            if let value = Self.readValue(element) {
                state.update(source, value: value)
            }
        }
        if state.isDown != previous { onStateChange?(state.isDown, nil) }
    }

    fileprivate func add(_ device: IOHIDDevice) {
        let candidates = (IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]) ?? []
        for element in candidates where Self.isFunctionInput(element) {
            let source = Self.source(for: element)
            elements[source] = element
            if let value = Self.readValue(element) {
                state.update(source, value: value)
            }
        }
        onStateChange?(state.isDown, nil)
    }

    fileprivate func remove(_ device: IOHIDDevice) {
        let deviceID = Self.deviceID(device)
        elements = elements.filter { $0.key.deviceID != deviceID }
        state.remove(deviceID: deviceID)
        onStateChange?(state.isDown, nil)
    }

    fileprivate func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard Self.isFunctionInput(element) else { return }
        let source = Self.source(for: element)
        elements[source] = element
        let previous = state.isDown
        state.update(source, value: IOHIDValueGetIntegerValue(value))
        if state.isDown != previous {
            // IOHIDValue uses Mach ticks; Quartz timestamps use nanoseconds.
            // Preserve the input time even if the main run loop was busy.
            let timestamp = Double(IOHIDValueGetTimeStamp(value)) * Self.secondsPerMachTick
            onStateChange?(state.isDown, timestamp)
        }
    }

    private static func isFunctionInput(_ element: IOHIDElement) -> Bool {
        let type = IOHIDElementGetType(element)
        return (type == kIOHIDElementTypeInput_Misc || type == kIOHIDElementTypeInput_Button || type == kIOHIDElementTypeInput_ScanCodes)
            && FunctionKeyState.matches(usagePage: IOHIDElementGetUsagePage(element), usage: IOHIDElementGetUsage(element))
    }

    private static func readValue(_ element: IOHIDElement) -> Int? {
        let value = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard IOHIDDeviceGetValue(IOHIDElementGetDevice(element), element, value) == kIOReturnSuccess else { return nil }
        return IOHIDValueGetIntegerValue(value.pointee.takeUnretainedValue())
    }

    private static func source(for element: IOHIDElement) -> FunctionKeyState.Source {
        FunctionKeyState.Source(deviceID: deviceID(IOHIDElementGetDevice(element)),
                                elementCookie: IOHIDElementGetCookie(element))
    }

    private static func deviceID(_ device: IOHIDDevice) -> UInt64 {
        // A removed device's registry entry may already be gone. Its callback
        // object remains valid, so pointer identity also works during removal.
        UInt64(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque()))
    }

    private func teardown() {
        guard let manager else { return }
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }
}

// All callbacks run on the main run loop. They finish synchronously, so no
// queued value can outlive stop(), device removal, or the unretained context.
private func functionDeviceMatched(_ context: UnsafeMutableRawPointer?, _ result: IOReturn,
                                   _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice) {
    guard result == kIOReturnSuccess, let context else { return }
    let monitor = Unmanaged<FunctionKeyMonitor>.fromOpaque(context).takeUnretainedValue()
    nonisolated(unsafe) let callbackDevice = device
    MainActor.assumeIsolated { monitor.add(callbackDevice) }
}

private func functionDeviceRemoved(_ context: UnsafeMutableRawPointer?, _ result: IOReturn,
                                   _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice) {
    guard let context else { return }
    let monitor = Unmanaged<FunctionKeyMonitor>.fromOpaque(context).takeUnretainedValue()
    nonisolated(unsafe) let callbackDevice = device
    MainActor.assumeIsolated { monitor.remove(callbackDevice) }
}

private func functionValueChanged(_ context: UnsafeMutableRawPointer?, _ result: IOReturn,
                                  _ sender: UnsafeMutableRawPointer?, _ value: IOHIDValue) {
    guard result == kIOReturnSuccess, let context else { return }
    let monitor = Unmanaged<FunctionKeyMonitor>.fromOpaque(context).takeUnretainedValue()
    nonisolated(unsafe) let callbackValue = value
    MainActor.assumeIsolated { monitor.handle(callbackValue) }
}
