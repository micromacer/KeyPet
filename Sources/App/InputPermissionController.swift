import AppKit
import CoreGraphics

/// A temporary setup window. Permission is checked on return from Settings or
/// explicit continuation, so normal operation needs no permission polling.
@MainActor
final class InputPermissionController: NSObject, NSWindowDelegate {
    private let alert = NSAlert()
    private var activationObserver: NSObjectProtocol?
    private var onGranted: (() -> Void)?

    override init() {
        super.init()
        alert.icon = Bundle.main.image(forResource: "KeyPet")
        alert.messageText = L10n.permissionTitle.text
        alert.informativeText = L10n.permissionMessage.text
        for (title, action) in [
            (L10n.permissionAllow.text, #selector(requestAccess)),
            (L10n.permissionContinue.text, #selector(checkAccess)),
            (L10n.permissionLater.text, #selector(dismiss)),
        ] {
            let button = alert.addButton(withTitle: title)
            button.target = self
            button.action = action
        }
        alert.layout()
        alert.window.isReleasedWhenClosed = false
        alert.window.delegate = self
    }

    func show(onGranted: @escaping () -> Void) {
        self.onGranted = onGranted
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.continueIfGranted() }
            }
        }
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        continueIfGranted()
    }

    @objc private func requestAccess() {
        _ = CGRequestListenEventAccess()
        if KeyboardMonitor.permissionGranted {
            continueIfGranted()
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }

    @objc private func checkAccess() {
        if KeyboardMonitor.permissionGranted {
            continueIfGranted()
        } else {
            alert.informativeText = L10n.permissionMissing.text
            alert.layout()
        }
    }

    private func continueIfGranted() {
        guard KeyboardMonitor.permissionGranted, let completion = onGranted else { return }
        dismiss()
        // Let the activation notification/window close finish before opening
        // the directory picker, which may run its own modal event loop.
        DispatchQueue.main.async { completion() }
    }

    @objc func dismiss() {
        stopObserving()
        alert.window.close()
    }

    func windowWillClose(_ notification: Notification) { stopObserving() }

    private func stopObserving() {
        onGranted = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }
}
