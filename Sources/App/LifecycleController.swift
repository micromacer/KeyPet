import AppKit

/// Unified activity gate: hidden, paused, system/display sleep and session
/// switch-out all stop the keyboard tap and the display clock. Ordinary app
/// focus changes do not pause anything.
@MainActor
final class LifecycleController {
    var onChange: (() -> Void)?
    var hidden = false { didSet { if oldValue != hidden { onChange?() } } }
    var paused = false { didSet { if oldValue != paused { onChange?() } } }
    private(set) var sleeping = false
    private(set) var screensSleeping = false
    private(set) var sessionInactive = false
    private var observers: [NSObjectProtocol] = []
    var allowsActivity: Bool { !hidden && !paused && !sleeping && !screensSleeping && !sessionInactive }

    init() {
        observe(NSWorkspace.willSleepNotification) { $0.sleeping = true }
        observe(NSWorkspace.didWakeNotification) { $0.sleeping = false }
        observe(NSWorkspace.screensDidSleepNotification) { $0.screensSleeping = true }
        observe(NSWorkspace.screensDidWakeNotification) { $0.screensSleeping = false }
        observe(NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
    }
    private func observe(_ name: Notification.Name, change: @escaping @MainActor (LifecycleController) -> Void) {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self); self.onChange?()
            }
        })
    }
    func cleanup() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll(); onChange = nil
    }
}
