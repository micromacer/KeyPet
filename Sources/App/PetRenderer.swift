import AppKit
import QuartzCore

/// Layer tree: root -> flip (horizontal mirror) -> bounce (bottom-pivot scale)
/// -> image. Mirroring and bounce live on separate layers so neither
/// overwrites the other's transform. All state images map into one fixed draw
/// rect derived from the idle canvas aspect, keeping transparent margins and
/// avoiding position jumps when the displayed asset changes.
@MainActor
final class PetRenderer {
    /// Action headroom: ~9% of window width on each side, ~26% of window
    /// height on top, so the bounce scale never clips. The bottom stays on
    /// the window floor; shadow clearance comes from `shadowPadding` instead.
    static let sideMarginFraction = 0.09
    static let topMarginFraction = 0.26
    /// The offset-zero halo stays visually significant well past 1× its blur
    /// radius, so the window grows transparent padding of twice the radius on
    /// every side while the shadow is on. Zero when off: the character then
    /// sits on the window floor with no lift.
    static let shadowPaddingScale = 2.0
    private(set) var shadowPadding = 0.0

    let root = CALayer()
    private let flipLayer = CALayer()
    private let bounceLayer = CALayer()
    private let imageLayer = CALayer()
    /// y-up window coordinates; bottom edge stays on the window floor plus
    /// `shadowPadding`.
    private(set) var drawRect = CGRect.zero
    private(set) var idleCanvas = CGSize(width: 1, height: 1)
    private var currentMask: AlphaMask?
    private(set) var currentImage: CGImage?

    var mirrored = false {
        didSet {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            flipLayer.sublayerTransform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
            CATransaction.commit()
        }
    }

    init() {
        flipLayer.addSublayer(bounceLayer)
        bounceLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        bounceLayer.addSublayer(imageLayer)
        root.addSublayer(flipLayer)
    }

    func windowSize(characterWidth: Double) -> NSSize {
        let size = characterSize(width: characterWidth)
        return NSSize(width: size.width / (1 - 2 * Self.sideMarginFraction) + 2 * shadowPadding,
                      height: size.height / (1 - Self.topMarginFraction) + 2 * shadowPadding)
    }

    private func characterSize(width: Double) -> CGSize {
        CGSize(width: width, height: width * idleCanvas.height / idleCanvas.width)
    }

    func setIdleCanvas(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        idleCanvas = size
    }

    func layout(viewSize: NSSize, characterWidth: Double, backingScale: CGFloat, compensation: CGPoint = .zero) {
        // Window rounding changes only the margins, never the artwork or its
        // decode target. Compensation preserves the screen-space anchor.
        let size = characterSize(width: characterWidth)
        drawRect = CGRect(origin: CGPoint(x: (viewSize.width - size.width) / 2 + compensation.x,
                                          y: shadowPadding + compensation.y), size: size)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: viewSize)
        // Mirror around the artwork center, including its rounding residue.
        flipLayer.frame = drawRect
        bounceLayer.bounds = CGRect(origin: .zero, size: drawRect.size)
        // Bottom-center pivot: the base stays fixed while the head moves with
        // the vertical squash/stretch.
        bounceLayer.position = CGPoint(x: drawRect.width / 2, y: 0)
        imageLayer.frame = bounceLayer.bounds
        imageLayer.contentsScale = backingScale
        CATransaction.commit()
    }

    func display(_ image: CGImage, mask: AlphaMask) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
        currentImage = image
        currentMask = mask
    }

    /// Surrounding halo pinned to the artwork's alpha silhouette (offset zero,
    /// fixed black). A pure layer property: it inherits mirror/bounce transforms
    /// and never touches hit testing, which uses the separate AlphaMask. Also
    /// updates `shadowPadding`; callers must re-layout and re-frame the window
    /// afterwards so the halo is never clipped by the window edge.
    func setShadow(enabled: Bool, radius: Double, opacity: Double) {
        shadowPadding = enabled ? radius * Self.shadowPaddingScale : 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.shadowColor = NSColor.black.cgColor
        imageLayer.shadowOffset = .zero
        imageLayer.shadowRadius = radius
        imageLayer.shadowOpacity = enabled ? Float(opacity) : 0
        CATransaction.commit()
    }

    /// Restoring must land exactly on the identity transform after the 380 ms
    /// trajectory, so callers pass literal 1.0 rather than a faded remainder.
    func setBounce(scaleX: Double, scaleY: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bounceLayer.setAffineTransform(CGAffineTransform(scaleX: scaleX, y: scaleY))
        CATransaction.commit()
    }

    /// `point` is in the y-up view coordinate space.
    func hitTest(_ point: NSPoint) -> Bool {
        guard let mask = currentMask, drawRect.contains(point), drawRect.width > 0, drawRect.height > 0 else { return false }
        let u = (point.x - drawRect.minX) / drawRect.width
        let vFromBottom = (point.y - drawRect.minY) / drawRect.height
        return mask.contains(u: mirrored ? 1 - u : u, v: 1 - vFromBottom)
    }
}
