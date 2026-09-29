import AppKit

@MainActor
final class PreferencesStore {
    static let minimumOpacity = 0.1
    static let minimumWidth = 40.0
    static let maximumWidth = 500.0
    static let defaultWidth = 150.0
    static let minimumResetDelayMs = 30
    static let maximumResetDelayMs = 1000
    static let defaultResetDelayMs = 150
    static let maximumShadowRadius = 30.0
    static let defaultShadowRadius = 10.0
    static let minimumShadowOpacity = 0.1
    static let defaultShadowOpacity = 0.4
    private static let optionDefaults: [String: Any] = [
        "petWidth": defaultWidth, "petOpacity": 1.0, "flipHorizontal": false,
        "swapSides": false, "alwaysOnTop": true, "resetDelayMs": defaultResetDelayMs,
        "bounceEnabled": true, "frameRate": 60, "clickThrough": false,
        "shadowEnabled": false, "shadowRadius": defaultShadowRadius, "shadowOpacity": defaultShadowOpacity,
    ]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Self.optionDefaults)
    }

    /// Removing only option overrides preserves the chosen library and pet.
    func restoreDefaults() {
        for key in Self.optionDefaults.keys { defaults.removeObject(forKey: key) }
        defaults.removeObject(forKey: "placement")
    }

    var width: Double {
        get { Self.clampedWidth(defaults.double(forKey: "petWidth")) }
        set { defaults.set(Self.clampedWidth(newValue), forKey: "petWidth") }
    }
    static func clampedWidth(_ value: Double) -> Double {
        value.isFinite ? min(maximumWidth, max(minimumWidth, value)) : defaultWidth
    }
    var opacity: Double {
        get {
            let value = defaults.double(forKey: "petOpacity")
            return value.isFinite ? min(1, max(Self.minimumOpacity, value)) : 1
        }
        set { defaults.set(newValue.isFinite ? min(1, max(Self.minimumOpacity, newValue)) : 1, forKey: "petOpacity") }
    }
    var flipHorizontal: Bool { get { defaults.bool(forKey: "flipHorizontal") } set { defaults.set(newValue, forKey: "flipHorizontal") } }
    var swapSides: Bool { get { defaults.bool(forKey: "swapSides") } set { defaults.set(newValue, forKey: "swapSides") } }
    var alwaysOnTop: Bool { get { defaults.bool(forKey: "alwaysOnTop") } set { defaults.set(newValue, forKey: "alwaysOnTop") } }
    var bounceEnabled: Bool { get { defaults.bool(forKey: "bounceEnabled") } set { defaults.set(newValue, forKey: "bounceEnabled") } }
    var clickThrough: Bool { get { defaults.bool(forKey: "clickThrough") } set { defaults.set(newValue, forKey: "clickThrough") } }
    var resetDelayMs: Int {
        get {
            let value = defaults.integer(forKey: "resetDelayMs")
            return min(Self.maximumResetDelayMs, max(Self.minimumResetDelayMs, value))
        }
        set { defaults.set(min(Self.maximumResetDelayMs, max(Self.minimumResetDelayMs, newValue)), forKey: "resetDelayMs") }
    }
    /// Only 60 or 30; anything stored outside the two choices falls back to 60.
    var frameRate: Int {
        get { defaults.integer(forKey: "frameRate") == 30 ? 30 : 60 }
        set { defaults.set(newValue == 30 ? 30 : 60, forKey: "frameRate") }
    }
    var shadowEnabled: Bool { get { defaults.bool(forKey: "shadowEnabled") } set { defaults.set(newValue, forKey: "shadowEnabled") } }
    var shadowRadius: Double {
        get {
            let value = defaults.double(forKey: "shadowRadius")
            return value.isFinite ? min(Self.maximumShadowRadius, max(0, value)) : Self.defaultShadowRadius
        }
        set { defaults.set(newValue.isFinite ? min(Self.maximumShadowRadius, max(0, newValue)) : Self.defaultShadowRadius, forKey: "shadowRadius") }
    }
    var shadowOpacity: Double {
        get {
            let value = defaults.double(forKey: "shadowOpacity")
            return value.isFinite ? min(1, max(Self.minimumShadowOpacity, value)) : Self.defaultShadowOpacity
        }
        set { defaults.set(newValue.isFinite ? min(1, max(Self.minimumShadowOpacity, newValue)) : Self.defaultShadowOpacity, forKey: "shadowOpacity") }
    }
    /// Last selected pet directory name; hidden/paused states are not persisted.
    var currentPetID: String? {
        get { defaults.string(forKey: "currentPetID") }
        set { defaults.set(newValue, forKey: "currentPetID") }
    }

    /// Position survives monitor rearrangement: screen identity plus
    /// visible-frame-relative center coordinates.
    func save(frame: NSRect, screen: NSScreen) {
        let area = screen.visibleFrame
        defaults.set(["screen": screen.stableID,
                      "x": (frame.midX - area.minX) / area.width,
                      "y": (frame.midY - area.minY) / area.height], forKey: "placement")
    }
    func restoredFrame(size: NSSize, screens: [NSScreen]) -> NSRect? {
        guard let placement = defaults.dictionary(forKey: "placement"),
              let id = placement["screen"] as? String,
              let screen = screens.first(where: { $0.stableID == id }),
              let x = placement["x"] as? Double, let y = placement["y"] as? Double,
              x.isFinite, y.isFinite else { return nil }
        return NSRect(x: screen.visibleFrame.minX + x * screen.visibleFrame.width - size.width / 2,
                      y: screen.visibleFrame.minY + y * screen.visibleFrame.height - size.height / 2,
                      width: size.width, height: size.height)
    }
}

extension NSScreen {
    var stableID: String { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "main" }
}
