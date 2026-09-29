import AppKit

@MainActor
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(setAccessibilityFrame(_:)) { return false }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    /// Window managers must not change this overlay's geometry through AX.
    /// The app's own drag, size and screen recovery paths use NSWindow directly.
    override func setAccessibilityFrame(_ accessibilityFrame: NSRect) {}

    // NSWindow still exposes AXPosition through the legacy attribute path,
    // independently of setAccessibilityFrame. Keep both geometry attributes
    // read-only there as well; other accessibility attributes retain AppKit's
    // default behavior. These public compatibility methods are deprecated,
    // but the modern selector guard alone does not protect NSPanel geometry.
    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        if attribute == .position || attribute == .size { return false }
        return super.accessibilityIsAttributeSettable(attribute)
    }

    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        if attribute == .position || attribute == .size { return }
        super.accessibilitySetValue(value, forAttribute: attribute)
    }
}

@MainActor
final class PetView: NSView {
    /// Drag starts only when pressed on a visible pixel of the current frame.
    var hitTest: ((NSPoint) -> Bool)?
    var onDragEnded: (() -> Void)?
    private var downPoint: NSPoint?
    private var downOrigin = NSPoint.zero
    private(set) var dragging = false
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("KeyPet")
        setAccessibilityHelp(L10n.petAccessibilityHelp.text)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard hitTest?(point) == true, let window else { return }
        downPoint = window.convertPoint(toScreen: event.locationInWindow)
        downOrigin = window.frame.origin; dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, let window else { return }
        let mouse = window.convertPoint(toScreen: event.locationInWindow)
        let delta = NSPoint(x: mouse.x - start.x, y: mouse.y - start.y)
        if hypot(delta.x, delta.y) > 4 { dragging = true }
        if dragging { window.setFrameOrigin(NSPoint(x: downOrigin.x + delta.x, y: downOrigin.y + delta.y)) }
    }
    override func mouseUp(with event: NSEvent) {
        guard downPoint != nil else { return }
        if dragging { onDragEnded?() }
        downPoint = nil; dragging = false
    }
}

@MainActor
final class PetWindowController: NSWindowController, NSWindowDelegate {
    let renderer: PetRenderer
    let petView: PetView
    let preferences: PreferencesStore
    private(set) var currentWidth: Double
    private var sizeNeedsSaving = false
    private var placementNeedsSaving = false
    private var hasPetGeometry = false
    /// Sub-point residue of AppKit's whole-point frame rounding, applied to
    /// the draw rect so anchored placements stay pixel-exact.
    private var layoutCompensation = CGPoint.zero
    private var screenObserver: NSObjectProtocol?
    var onVisibilityChanged: (() -> Void)?
    /// Fired whenever layout recomputes the draw rect or backing scale, so the
    /// playback controller can retarget its decode size.
    var onLayoutChanged: (() -> Void)?
    /// Decode target in physical pixels for the current draw rect.
    var drawPixelSize: CGSize {
        let scale = window?.backingScaleFactor ?? 2
        let rect = renderer.drawRect
        return CGSize(width: rect.width * scale, height: rect.height * scale)
    }
    var isActuallyVisible: Bool {
        window?.isVisible == true && (window?.alphaValue ?? 0) > 0 && window?.occlusionState.contains(.visible) == true
    }

    init(renderer: PetRenderer, preferences: PreferencesStore) {
        self.renderer = renderer
        self.preferences = preferences
        currentWidth = preferences.width
        petView = PetView()
        let size = renderer.windowSize(characterWidth: preferences.width)
        let panel = PetPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "KeyPet"
        // Expose the desktop companion as a group containing the accessible
        // character image, rather than an AXWindow that a tiling client can
        // select. Keep the panel and its children in the accessibility tree.
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.group)
        panel.setAccessibilitySubrole(nil)
        panel.setAccessibilityLabel("KeyPet")
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone]
        panel.level = preferences.alwaysOnTop ? .floating : .normal
        panel.alphaValue = preferences.opacity
        panel.ignoresMouseEvents = preferences.clickThrough
        panel.contentView = petView
        petView.layer?.addSublayer(renderer.root)
        super.init(window: panel)
        panel.delegate = self
        petView.hitTest = { [weak renderer] point in renderer?.hitTest(point) ?? false }
        petView.onDragEnded = { [weak self] in self?.constrainAndSave() }
        // The real canvas is still unknown; do not restore or save placement
        // using this temporary square geometry.
        moveToDefaultPosition()
        updateLayout()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.constrainAndSave(); self?.updateLayout() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func cleanup() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }
    func updateLayout() {
        guard let view = window?.contentView else { return }
        renderer.layout(viewSize: view.bounds.size, characterWidth: currentWidth, backingScale: window?.backingScaleFactor ?? 2,
                        compensation: layoutCompensation)
        onLayoutChanged?()
    }
    /// A pet switch keeps the character's bottom-center position and only then
    /// re-clamps to the screen, so the new aspect ratio grows upward/inward.
    func applyPetGeometry() {
        guard let window else { return }
        let size = renderer.windowSize(characterWidth: currentWidth)
        if hasPetGeometry {
            let anchor = CGPoint(x: window.frame.minX + renderer.drawRect.midX,
                                 y: window.frame.minY + renderer.drawRect.minY)
            placeWindow(charAnchor: anchor, size: size)
        } else {
            hasPetGeometry = true
            layoutCompensation = .zero
            if let restored = preferences.restoredFrame(size: size, screens: NSScreen.screens) {
                window.setFrame(restored, display: true)
                updateLayout()
            } else {
                window.setContentSize(size)
                updateLayout()
                moveToDefaultPosition()
            }
        }
        constrainAndSave()
    }
    func setOpacity(_ value: Double) {
        guard let window, value.isFinite else { return }
        window.alphaValue = min(1, max(PreferencesStore.minimumOpacity, value))
        updateMouseInteraction()
        onVisibilityChanged?()
    }
    func saveOpacity() {
        if let window { preferences.opacity = window.alphaValue }
    }
    func updateMouseInteraction() {
        window?.ignoresMouseEvents = preferences.clickThrough || window?.alphaValue == 0
    }
    /// Slider previews use the same geometry as persistence, without writing
    /// defaults per event; the value is saved when the menu closes.
    func previewWidth(_ width: Double) {
        guard let window, width.isFinite else { return }
        // The old window-midX/minY rule, expressed on the character: its
        // horizontal center and floor do not move while resizing.
        let anchor = CGPoint(x: window.frame.minX + renderer.drawRect.midX,
                             y: window.frame.minY + renderer.drawRect.minY)
        currentWidth = PreferencesStore.clampedWidth(width)
        sizeNeedsSaving = true
        placeWindow(charAnchor: anchor, size: renderer.windowSize(characterWidth: currentWidth))
        constrainToScreen()
    }
    func saveGeometry() {
        if sizeNeedsSaving {
            preferences.width = currentWidth
            sizeNeedsSaving = false
        }
        if placementNeedsSaving { constrainAndSave() }
    }
    /// Shadow changes grow or shrink only the window's transparent margins;
    /// the character's on-screen draw rect is kept exactly stationary, and its
    /// pixel size is untouched so no re-decode is triggered.
    func applyShadow(enabled: Bool, radius: Double, opacity: Double) {
        guard let window else { return }
        let anchor = CGPoint(x: window.frame.minX + renderer.drawRect.midX,
                             y: window.frame.minY + renderer.drawRect.minY)
        let previousPadding = renderer.shadowPadding
        renderer.setShadow(enabled: enabled, radius: radius, opacity: opacity)
        guard renderer.shadowPadding != previousPadding else { return }
        placeWindow(charAnchor: anchor, size: renderer.windowSize(characterWidth: currentWidth))
        constrainToScreen()
    }
    /// Requests `size` keeping the character's draw-rect center-x and floor on
    /// `charAnchor` (screen coordinates). AppKit floors the window frame to
    /// whole points; deriving anchors back from the rounded frame would feed a
    /// sub-point loss into every slider event and visibly ratchet the
    /// character across the screen, so the residue goes into
    /// `layoutCompensation` instead.
    private func placeWindow(charAnchor: CGPoint, size: NSSize) {
        guard let window else { return }
        let padding = renderer.shadowPadding
        window.setFrame(NSRect(x: charAnchor.x - size.width / 2,
                               y: charAnchor.y - padding,
                               width: size.width, height: size.height), display: true)
        let actual = window.frame
        layoutCompensation = CGPoint(
            x: charAnchor.x - actual.midX,
            y: charAnchor.y - actual.minY - padding)
        placementNeedsSaving = true
        updateLayout()
    }
    func resetPosition() {
        moveToDefaultPosition()
        savePlacement()
    }
    private func moveToDefaultPosition() {
        guard let window, let screen = NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        let draw = renderer.drawRect
        // Anchor the character (not the window): its floor stays 16 pt above
        // the Dock no matter how much transparent shadow padding the window
        // carries.
        window.setFrameOrigin(NSPoint(x: area.maxX - 16 - draw.maxX, y: area.minY + 16 - draw.minY))
    }
    func constrainAndSave() {
        constrainToScreen()
        savePlacement()
    }
    /// Constraints apply to the character's draw rect, never to the window:
    /// the transparent shadow padding may overhang the screen edge (the halo
    /// simply continues beneath the Dock or off-screen), so enabling a shadow
    /// can never push the character away from the screen border.
    private func constrainToScreen() {
        guard let window, let main = NSScreen.screens.first else { return }
        let draw = renderer.drawRect
        let character = NSRect(x: window.frame.minX + draw.minX, y: window.frame.minY + draw.minY,
                               width: draw.width, height: draw.height)
        let screen = NSScreen.screens.max(by: {
            let a = $0.visibleFrame.intersection(character), b = $1.visibleFrame.intersection(character)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }) ?? main
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(character) }) { moveToDefaultPosition(); return }
        let area = screen.visibleFrame
        var dx: CGFloat = 0, dy: CGFloat = 0
        if character.minX < area.minX { dx = area.minX - character.minX }
        else if character.maxX > area.maxX { dx = area.maxX - character.maxX }
        if character.minY < area.minY { dy = area.minY - character.minY }
        else if character.maxY > area.maxY { dy = area.maxY - character.maxY }
        if dx != 0 || dy != 0 { window.setFrameOrigin(NSPoint(x: window.frame.minX + dx, y: window.frame.minY + dy)) }
    }
    private func savePlacement() {
        guard hasPetGeometry, let window, let screen = window.screen else { return }
        preferences.save(frame: window.frame, screen: screen)
        placementNeedsSaving = false
    }
    func windowDidChangeBackingProperties(_ notification: Notification) { updateLayout() }
    func windowDidChangeScreen(_ notification: Notification) { updateLayout() }
    func windowDidChangeOcclusionState(_ notification: Notification) { onVisibilityChanged?() }
}
