import CoreGraphics
import Foundation

/// Which paw a key falls back to when it has no dedicated key image.
enum PawSide: String, Sendable {
    case left
    case right
    var swapped: PawSide { self == .left ? .right : .left }
}

enum KeyEventPhase: Sendable { case down, up }

/// A keyboard event after layout-independent normalization. Never carries text.
struct NormalizedKeyEvent: Sendable {
    /// A macOS virtual key code or a distinct PetMediaKey identifier.
    let keyCode: UInt16
    let phase: KeyEventPhase
    let isRepeat: Bool
    /// Monotonic seconds in the CACurrentMediaTime domain.
    let timestamp: Double
}

/// A request to (re)start displaying one asset token. A fresh `restartSerial`
/// restarts playback even when `token` is unchanged (re-press, auto-repeat).
struct PlaybackSelection: Sendable {
    let token: String
    let restartSerial: UInt64
}

/// One image file inside a pet directory.
struct PetAsset: Sendable, Hashable {
    /// Normalized token: "idle", "left", "right", "1", "enter", ...
    let token: String
    let fileURL: URL
    let fileSize: UInt64
    /// Content identity (path + size + mtime) for cache invalidation on hot replace.
    let resourceVersion: UInt64
}

/// A pet directory under the user-chosen root. `id` doubles as the menu name.
struct PetDescriptor: Sendable {
    let id: String
    let directoryURL: URL
    let assets: [String: PetAsset]
    func asset(for token: String) -> PetAsset? { assets[token] }
}

/// Problems found while indexing a pet directory, surfaced in the menu.
enum PetIssue: Sendable {
    case unreadableDirectory
    case missingIdle
    /// Left/right action images absent; those keys fall back to idle.
    case missingActionImages
    /// Two files normalize to the same token; neither is used for it.
    case tokenConflict(token: String, files: [String])
    case oversizedFile(name: String)
    case oversizedCanvas(name: String)
    case tooManyFrames(name: String)
}

/// Header-level description of a PNG/APNG, obtained without full decode.
struct AnimationMetadata: Sendable {
    let canvasPixels: CGSize
    let frameCount: Int
    /// One entry per frame, seconds, using each frame's own delay.
    let frameDurations: [Double]
    let isAnimated: Bool
}

/// Downscaled alpha coverage of the currently displayed frame, used only for
/// drag hit-testing. Row-major from the top-left, matching the y-down view.
struct AlphaMask: Sendable {
    let width: Int
    let height: Int
    let bytes: [UInt8]
    func contains(u: Double, v: Double) -> Bool {
        guard width > 0, height > 0, !bytes.isEmpty else { return false }
        let x = min(width - 1, max(0, Int(u * Double(width))))
        let y = min(height - 1, max(0, Int(v * Double(height))))
        return bytes[y * width + x] > 0x30
    }
}

/// Prepared together off the main thread and retained/evicted as one cache entry.
struct DecodedPetFrame: Sendable {
    let image: CGImage
    let alphaMask: AlphaMask
    var byteCost: Int { image.bytesPerRow * image.height + alphaMask.bytes.count }
}

/// First-version resource and cache ceilings from the development plan.
enum PetResourceLimits {
    static let maxCanvasDimension = 2048
    static let maxFileBytes = 64 * 1024 * 1024
    static let maxFrames = 2000
    /// Decoded-image cache held by the app, steady state.
    static let imageCacheByteBudget = 16 * 1024 * 1024
    /// Raised ceiling while a pet switch is preparing; drops back after commit.
    static let transientCacheByteBudget = 32 * 1024 * 1024
}
