import AppKit
import CoreGraphics
import Foundation
import IOKit.hidsystem
import QuartzCore

/// Read-only session event tap plus a narrowly filtered Fn/Globe HID observer.
///
/// Privacy contract: the tap is `.listenOnly`, the mask covers only
/// keyDown / keyUp / flagsChanged / systemDefined. Only supported media-key
/// packets are decoded from systemDefined. Only bounded, in-memory Fn timing
/// is retained for cross-channel deduplication; no text is read or recorded.
@MainActor
final class KeyboardMonitor {

    enum Status: Sendable, Equatable {
        case unauthorized
        case listening
        case failed
    }

    private(set) var status: Status = .unauthorized {
        didSet {
            guard status != oldValue else { return }
            onStatusChange?(status)
        }
    }

    /// Delivered on the main thread, in tap order.
    var onEvent: ((NormalizedKeyEvent) -> Void)?
    /// Fired when the listen chain (re)starts, so consumers drop stale held keys.
    var onReset: (() -> Void)?
    var onStatusChange: ((Status) -> Void)?

    /// `nonisolated`: preflight is a thread-safe C query, handy outside MainActor.
    nonisolated static var permissionGranted: Bool { CGPreflightListenEventAccess() }

    // MARK: - Key codes

    /// Left/right shift, control, option, command. Per-side tracking is what
    /// keeps releasing one side from clearing the other side's held state.
    private static let sidedModifiers: [UInt16: (group: CGEventFlags, side: UInt64, pair: UInt64)] = [
        56: (.maskShift, UInt64(NX_DEVICELSHIFTKEYMASK), UInt64(NX_DEVICERSHIFTKEYMASK)),
        60: (.maskShift, UInt64(NX_DEVICERSHIFTKEYMASK), UInt64(NX_DEVICELSHIFTKEYMASK)),
        59: (.maskControl, UInt64(NX_DEVICELCTLKEYMASK), UInt64(NX_DEVICERCTLKEYMASK)),
        62: (.maskControl, UInt64(NX_DEVICERCTLKEYMASK), UInt64(NX_DEVICELCTLKEYMASK)),
        58: (.maskAlternate, UInt64(NX_DEVICELALTKEYMASK), UInt64(NX_DEVICERALTKEYMASK)),
        61: (.maskAlternate, UInt64(NX_DEVICERALTKEYMASK), UInt64(NX_DEVICELALTKEYMASK)),
        55: (.maskCommand, UInt64(NX_DEVICELCMDKEYMASK), UInt64(NX_DEVICERCMDKEYMASK)),
        54: (.maskCommand, UInt64(NX_DEVICERCMDKEYMASK), UInt64(NX_DEVICELCMDKEYMASK))
    ]
    private static let capsLockKeyCode: UInt16 = 57
    private static let functionKeyCode: UInt16 = 63
    private static let lostReleaseInterval: TimeInterval = 6

    // MARK: - Tracked state

    /// Per-key pressed snapshot for sided modifiers and Fn; missing entry == up.
    private var modifierDown: [UInt16: Bool] = [:]
    /// Caps Lock latch state as seen through `.maskAlphaShift`.
    private var capsLockOn = false
    /// Key codes for which a `down` was delivered without a matching `up`.
    private var reportedDown: Set<UInt16> = []
    /// Media keys have no CGEventSource.keyState entry. Repeats refresh their
    /// activity deadline so a dropped release cannot leave a permanent pose.
    private var mediaLastActivity: [UInt16: Double] = [:]
    private let functionKeyMonitor = FunctionKeyMonitor()
    private var hidFunctionDown: Bool?
    private var functionPresses = FunctionKeyPressTracker()

    // MARK: - Lost-release reconciliation

    private var reconcilePending = false
    /// Bumped on every (re)schedule and cancel so a stale asyncAfter can tell
    /// it has been superseded without a persistent timer.
    private var reconcileGeneration: UInt64 = 0

    // MARK: - Tap resources

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init() {
        functionKeyMonitor.onStateChange = { [weak self] down, timestamp in
            self?.handleHIDFunctionState(down, timestamp: timestamp)
        }
    }

    isolated deinit {
        // Safety net: the lifecycle calls stop() first, but the C callback
        // bridges an unretained `self`, so the port must never outlive us.
        teardownTap()
    }

    /// Creates and enables the tap when permission is granted. Idempotent while
    /// listening; from `.unauthorized` / `.failed` it makes a fresh attempt.
    func start() {
        if status == .listening, eventTap != nil { return }
        guard Self.permissionGranted else {
            status = .unauthorized
            return
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            clearTrackedKeys()
            status = .listening
            onReset?()
            functionKeyMonitor.start()
            handleHIDFunctionState(functionKeyMonitor.currentState)
            return
        }

        // unsafe: `userInfo` bridges an unretained `self` into the C callback.
        // The monitor is owned by the app for the whole session, and the tap is
        // invalidated in stop()/deinit before release, so the pointer cannot
        // dangle; retaining from the callback would create a cycle instead.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: ExtractedKeyEvent.eventMask,
            callback: keyboardEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Creation fails for reasons other than permission too (port limits,
            // session changes); the menu exposes retry via a later start().
            status = .failed
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            status = .failed
            return
        }

        // Common modes keep events flowing while menus are tracked.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source

        clearTrackedKeys()
        cancelReconcile()
        status = .listening
        // A fresh listen chain invalidates any key state the consumer held.
        onReset?()
        functionKeyMonitor.start()
    }

    /// Pause / hide / sleep / quit path: tears down the tap, drops held-key
    /// tracking and cancels the pending release check.
    func stop() {
        cancelReconcile()
        teardownTap()
        functionKeyMonitor.stop()
        clearTrackedKeys()
        // stop() is a deliberate lifecycle action, not a health change; the
        // only correction worth publishing is a permission revocation.
        if !Self.permissionGranted { status = .unauthorized }
    }

    // MARK: - Event handling (main thread)

    /// The C tap callback reaches the monitor through this single entry point.
    func handleExtractedEvent(_ payload: ExtractedKeyEvent) {
        switch payload.kind {
        case .keyDown:
            if payload.keyCode == Self.functionKeyCode {
                handleQuartzFunctionState(true, timestamp: payload.timestamp)
                return
            }
            emit(NormalizedKeyEvent(keyCode: payload.keyCode, phase: .down,
                                    isRepeat: payload.isAutorepeat, timestamp: payload.timestamp))
        case .keyUp:
            if payload.keyCode == Self.functionKeyCode {
                handleQuartzFunctionState(false, timestamp: payload.timestamp)
                return
            }
            emit(NormalizedKeyEvent(keyCode: payload.keyCode, phase: .up,
                                    isRepeat: payload.isAutorepeat, timestamp: payload.timestamp))
        case .flagsChanged:
            handleFlagsChanged(keyCode: payload.keyCode, flags: CGEventFlags(rawValue: payload.flagsRaw),
                               timestamp: payload.timestamp)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            recoverFromDisabledTap()
        }
    }

    private func handleFlagsChanged(keyCode: UInt16, flags: CGEventFlags, timestamp: Double) {
        // Caps Lock latches: the off→on edge is one trigger, emitted as an
        // atomic down+up pair so the lock state never reads as a held key.
        let capsOn = flags.contains(.maskAlphaShift)
        if keyCode == Self.capsLockKeyCode, capsOn != capsLockOn {
            capsLockOn = capsOn
            if capsOn {
                emit(NormalizedKeyEvent(keyCode: Self.capsLockKeyCode, phase: .down,
                                        isRepeat: false, timestamp: timestamp))
                emit(NormalizedKeyEvent(keyCode: Self.capsLockKeyCode, phase: .up,
                                        isRepeat: false, timestamp: timestamp))
            }
        }

        // Navigation keys also carry maskSecondaryFn, so only an actual Fn
        // event updates this source. An idle HID device must not mask remaps
        // or another keyboard that reports Fn only through Quartz.
        if keyCode == Self.functionKeyCode {
            handleQuartzFunctionState(flags.contains(.maskSecondaryFn), timestamp: timestamp)
        }

        // Use the event-time flags, including the device-dependent side bits.
        // Querying live keyState after this event was queued can lose edges or
        // retain a stale modifier press, preventing the pet from returning idle.
        for key in Self.sidedModifiers.keys.sorted() {
            let wasDown = modifierDown[key] ?? false
            // Without side bits, only the named key changed. A cleared group
            // bit still releases both sides, including any missed release.
            let down = Self.sidedModifierState(key, flags: flags)
                ?? (key == keyCode ? !wasDown : wasDown)
            guard down != wasDown else { continue }
            modifierDown[key] = down
            emit(NormalizedKeyEvent(keyCode: key, phase: down ? .down : .up,
                                    isRepeat: false, timestamp: timestamp))
        }
    }

    func handleHIDFunctionState(_ down: Bool?, timestamp: Double? = nil) {
        hidFunctionDown = down
        let held = functionPresses.update(.hid, down: down == true, timestamp: timestamp)
        setFunctionDown(held, timestamp: timestamp ?? CACurrentMediaTime())
    }

    private func handleQuartzFunctionState(_ down: Bool, timestamp: Double) {
        let held = functionPresses.update(.quartz, down: down, timestamp: timestamp)
        setFunctionDown(held, timestamp: timestamp)
    }

    private func setFunctionDown(_ down: Bool, timestamp: Double) {
        guard down != (modifierDown[Self.functionKeyCode] ?? false) else { return }
        modifierDown[Self.functionKeyCode] = down
        emit(NormalizedKeyEvent(keyCode: Self.functionKeyCode, phase: down ? .down : .up,
                                isRepeat: false, timestamp: timestamp))
    }

    /// nil means the group is held but the producer supplied no side bits.
    private static func sidedModifierState(_ keyCode: UInt16, flags: CGEventFlags) -> Bool? {
        guard let modifier = sidedModifiers[keyCode] else { return nil }
        guard flags.contains(modifier.group) else { return false }
        guard flags.rawValue & (modifier.side | modifier.pair) != 0 else { return nil }
        return flags.rawValue & modifier.side != 0
    }

    /// The system disabled the tap (timeout or user input). Re-enable it and
    /// reset: events from the disabled window are gone for good, so every held
    /// key must be dropped to avoid a stuck paw.
    private func recoverFromDisabledTap() {
        guard Self.permissionGranted else {
            // Permission was revoked under us; stop() publishes .unauthorized.
            stop()
            return
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        clearTrackedKeys()
        cancelReconcile()
        onReset?()
        functionKeyMonitor.refresh()
        handleHIDFunctionState(functionKeyMonitor.currentState)
    }

    // MARK: - Emission and held-key bookkeeping

    private func emit(_ event: NormalizedKeyEvent) {
        switch event.phase {
        case .down:
            if PetMediaKey(rawValue: event.keyCode) != nil {
                mediaLastActivity[event.keyCode] = event.timestamp
            }
            // Caps Lock is never tracked: its down+up pair is atomic, and its
            // latched HID state would keep the reconcile loop alive forever.
            if event.keyCode != Self.capsLockKeyCode {
                reportedDown.insert(event.keyCode)
                scheduleReconcileIfNeeded()
            }
        case .up:
            reportedDown.remove(event.keyCode)
            mediaLastActivity.removeValue(forKey: event.keyCode)
        }
        onEvent?(event)
    }

    // MARK: - Lost-release protection

    /// One-shot 6 s check, queued only while keys are believed held. No idle
    /// polling: an empty set schedules nothing.
    private func scheduleReconcileIfNeeded() {
        guard !reconcilePending, !reportedDown.isEmpty else { return }
        reconcilePending = true
        reconcileGeneration &+= 1
        let generation = reconcileGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lostReleaseInterval) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.reconcilePending, self.reconcileGeneration == generation else { return }
                self.reconcilePending = false
                if self.reportedDown.contains(Self.functionKeyCode), self.hidFunctionDown != nil {
                    self.functionKeyMonitor.refresh()
                }
                self.reconcileHeldKeys(modifierFlags: CGEventSource.flagsState(.combinedSessionState))
            }
        }
    }

    private func cancelReconcile() {
        reconcilePending = false
        reconcileGeneration &+= 1
    }

    /// Modifier flags and ordinary key state repair missed releases without
    /// imposing a timeout on genuinely held keys.
    func reconcileHeldKeys(modifierFlags: CGEventFlags, timestamp: Double = CACurrentMediaTime()) {
        guard !reportedDown.isEmpty else { return }
        for keyCode in reportedDown.sorted() {
            let down: Bool
            if let lastActivity = mediaLastActivity[keyCode] {
                down = timestamp - lastActivity < Self.lostReleaseInterval
            } else if Self.sidedModifiers[keyCode] != nil {
                // A group-only snapshot cannot identify which side is held.
                down = Self.sidedModifierState(keyCode, flags: modifierFlags) ?? true
            } else if keyCode == Self.functionKeyCode {
                let quartzDown = functionPresses.isPressed(on: .quartz) && modifierFlags.contains(.maskSecondaryFn)
                down = functionPresses.update(.quartz, down: quartzDown, timestamp: nil)
            } else {
                down = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
            }
            guard !down else { continue }
            if modifierDown[keyCode] == true { modifierDown[keyCode] = false }
            emit(NormalizedKeyEvent(keyCode: keyCode, phase: .up,
                                    isRepeat: false, timestamp: timestamp))
        }
        // Still-held keys get another one-shot check.
        scheduleReconcileIfNeeded()
    }

    // MARK: - Teardown

    private func teardownTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Invalidate also unschedules the port from every run loop, so no
            // callback can fire after this point.
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    private func clearTrackedKeys() {
        modifierDown.removeAll()
        capsLockOn = false
        reportedDown.removeAll()
        mediaLastActivity.removeAll()
        hidFunctionDown = nil
        functionPresses = FunctionKeyPressTracker()
    }
}

/// Value-type snapshot extracted inside the C callback. The callback runs in
/// the event-tap hot path. NSEvent exposes media packet fields; only scalar
/// values cross to the main queue, where tracked state and rendering live.
struct ExtractedKeyEvent: Sendable {
    enum Kind: Sendable {
        case keyDown, keyUp, flagsChanged
        case tapDisabledByTimeout, tapDisabledByUserInput
    }
    let kind: Kind
    let keyCode: UInt16
    let isAutorepeat: Bool
    let flagsRaw: UInt64
    /// Seconds on the monotonic boot clock (the CACurrentMediaTime domain).
    let timestamp: Double

    static let eventMask: CGEventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
        | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        | (CGEventMask(1) << NX_SYSDEFINED)

    static func extract(type: CGEventType, event: CGEvent) -> ExtractedKeyEvent? {
        if type.rawValue == UInt32(NX_SYSDEFINED) {
            guard let mediaEvent = NSEvent(cgEvent: event), mediaEvent.type == .systemDefined,
                  mediaEvent.subtype.rawValue == Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
                  let mediaKey = PetMediaKey(systemKeyType: (mediaEvent.data1 >> 16) & 0xFFFF)
            else { return nil }
            // NX auxiliary-control data1: key type in bits 16–31, phase in
            // bits 8–15, repeat in bit 0. Do not read keyboardEventKeycode here.
            let kind: Kind
            switch (mediaEvent.data1 >> 8) & 0xFF {
            case Int(NX_KEYDOWN): kind = .keyDown
            case Int(NX_KEYUP): kind = .keyUp
            default: return nil
            }
            return ExtractedKeyEvent(kind: kind, keyCode: mediaKey.rawValue,
                                     isAutorepeat: mediaEvent.data1 & 1 != 0,
                                     flagsRaw: event.flags.rawValue,
                                     timestamp: Double(event.timestamp) / 1_000_000_000)
        }
        let kind: ExtractedKeyEvent.Kind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        case .tapDisabledByTimeout: kind = .tapDisabledByTimeout
        case .tapDisabledByUserInput: kind = .tapDisabledByUserInput
        default: return nil
        }

        return ExtractedKeyEvent(
            kind: kind,
            keyCode: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)),
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            flagsRaw: event.flags.rawValue,
            // CGEventTypes.h: "Event timestamp; roughly, nanoseconds since startup."
            // NormalizedKeyEvent wants seconds in the CACurrentMediaTime domain.
            timestamp: Double(event.timestamp) / 1_000_000_000
        )
    }
}

private func keyboardEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Listen-only tap: always hand back the untouched original event.
    guard let refcon else { return Unmanaged.passUnretained(event) }

    guard let payload = ExtractedKeyEvent.extract(type: type, event: event) else {
        return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        // DispatchQueue.main executes on the main thread; the monitor's state
        // is only ever touched here, on the main thread.
        MainActor.assumeIsolated {
            monitor.handleExtractedEvent(payload)
        }
    }
    return Unmanaged.passUnretained(event)
}
