import CoreGraphics
import Foundation
import ImageIO

enum PetDecodeError: Error, Sendable {
    case unreadableFile
    case notPNG
    /// Larger than PetResourceLimits.maxFileBytes.
    case fileTooLarge
    /// Either canvas side larger than PetResourceLimits.maxCanvasDimension.
    case canvasTooLarge
    /// More frames than PetResourceLimits.maxFrames.
    case tooManyFrames
    case corruptImage
}

/// Stateless PNG/APNG decoding; every method is safe to call from the
/// caller's background serial queue.
///
/// `CGImageSourceCreateImageAtIndex`
/// returns fully composited full-canvas frames (region offsets, blend and
/// dispose ops already applied per the PNG spec), so no client-side
/// compositing state machine is needed. `CGImageSourceCreateThumbnailAtIndex`
/// preserves that compositing while downsampling, which makes it the
/// downscale path. APNG timing and canvas size live in the {PNG} property
/// dictionary; the SDK exposes no {APNG} dictionary key.
enum PetAssetDecoder {
    /// Header-only pass: file size, canvas, frame count and per-frame delays,
    /// with limit checks ordered so oversize assets are rejected before any
    /// pixel decode (file size, then canvas, then frame count).
    static func metadata(asset: PetAsset) throws -> AnimationMetadata {
        let header = try openSource(asset: asset)
        let animated = header.frameCount > 1
        var durations = [Double]()
        durations.reserveCapacity(header.frameCount)
        for index in 0..<header.frameCount {
            durations.append(frameDelay(source: header.source, index: index))
        }
        if !animated {
            // A single frame has no timeline; the placeholder only keeps the
            // one-entry-per-frame shape without implying motion.
            durations = [0.1]
        }
        return AnimationMetadata(canvasPixels: header.canvasPixels,
                                 frameCount: header.frameCount,
                                 frameDurations: durations,
                                 isAnimated: animated)
    }

    /// Returns the composited full-canvas frame. When `targetPixelSize` is
    /// non-nil and the canvas exceeds it, decoding downsamples to fit that
    /// display-pixel box (aspect preserved); smaller sources are never
    /// upscaled. The index wraps modulo the frame count, which also maps any
    /// index to 0 for single-frame assets.
    static func decodeFrame(asset: PetAsset, index: Int, targetPixelSize: CGSize?) throws -> CGImage {
        let header = try openSource(asset: asset)
        let frame = ((index % header.frameCount) + header.frameCount) % header.frameCount
        let maxPixel = pixelLimit(canvas: header.canvasPixels, target: targetPixelSize)
        if maxPixel < Int(max(header.canvasPixels.width, header.canvasPixels.height)) {
            let options: [CFString: Any] = [
                // Without "always", PNG sources may yield no thumbnail at all.
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCache: false,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(header.source, frame, options as CFDictionary) else {
                throw PetDecodeError.corruptImage
            }
            return image
        }
        guard let image = CGImageSourceCreateImageAtIndex(header.source, frame, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            throw PetDecodeError.corruptImage
        }
        // Native ImageIO images can defer decompression until the first draw.
        // Materialize a bitmap here so presenting it never invokes a PNG decoder.
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: max(8, image.bitsPerComponent), bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PetDecodeError.corruptImage
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let bitmap = context.makeImage() else { throw PetDecodeError.corruptImage }
        return bitmap
    }

    static func prepareFrame(asset: PetAsset, index: Int, targetPixelSize: CGSize?) throws -> DecodedPetFrame {
        let image = try decodeFrame(asset: asset, index: index, targetPixelSize: targetPixelSize)
        return DecodedPetFrame(image: image, alphaMask: makeAlphaMask(image: image))
    }

    /// Downscales to a ≤64px (long side) alpha-only mask for drag hit-testing.
    static func makeAlphaMask(image: CGImage) -> AlphaMask {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return AlphaMask(width: 0, height: 0, bytes: []) }
        let longSide = max(width, height)
        let scale = longSide > 64 ? 64.0 / Double(longSide) : 1.0
        let w = max(1, Int((Double(width) * scale).rounded(.down)))
        let h = max(1, Int((Double(height) * scale).rounded(.down)))
        guard let context = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buffer = context.data else {
            return AlphaMask(width: 0, height: 0, bytes: [])
        }
        context.interpolationQuality = .high
        // Bitmap memory is row-major starting at the image's top-left row,
        // matching the y-down view coordinates the mask is queried in.
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var bytes = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            bytes[i] = pixels[i * 4 + 3]
        }
        return AlphaMask(width: w, height: h, bytes: bytes)
    }

    private struct SourceHeader {
        let source: CGImageSource
        let canvasPixels: CGSize
        let frameCount: Int
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private static func openSource(asset: PetAsset) throws -> SourceHeader {
        let path = asset.fileURL.path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            throw PetDecodeError.unreadableFile
        }
        if size > UInt64(PetResourceLimits.maxFileBytes) { throw PetDecodeError.fileTooLarge }

        guard let handle = try? FileHandle(forReadingFrom: asset.fileURL) else {
            throw PetDecodeError.unreadableFile
        }
        defer { try? handle.close() }
        // The signature is the PNG/A(PNG) discriminator; ImageIO sniffs
        // content rather than the extension, so .png and .apng share a path.
        let signature: Data
        do {
            signature = try handle.read(upToCount: 8) ?? Data()
        } catch {
            throw PetDecodeError.unreadableFile
        }
        guard Array(signature) == pngSignature else { throw PetDecodeError.notPNG }

        // ShouldCache=false keeps ImageIO's own decoded-frame cache from
        // stacking on top of PetFrameCache's budgeted one.
        guard let source = CGImageSourceCreateWithURL(asset.fileURL as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            throw PetDecodeError.unreadableFile
        }
        guard let canvas = canvasSize(source: source) else { throw PetDecodeError.corruptImage }
        if canvas.width > CGFloat(PetResourceLimits.maxCanvasDimension)
            || canvas.height > CGFloat(PetResourceLimits.maxCanvasDimension) {
            throw PetDecodeError.canvasTooLarge
        }
        let frameCount = CGImageSourceGetCount(source)
        if frameCount < 1 { throw PetDecodeError.corruptImage }
        if frameCount > PetResourceLimits.maxFrames { throw PetDecodeError.tooManyFrames }
        return SourceHeader(source: source, canvasPixels: canvas, frameCount: frameCount)
    }

    private static func canvasSize(source: CGImageSource) -> CGSize? {
        // For APNG the canvas comes from the source-level {PNG} dictionary;
        // source-level PixelWidth/Height are absent there. Static PNGs parse
        // lazily and only expose dimensions on frame 0's properties.
        if let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
           let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            let w = (png[kCGImagePropertyAPNGCanvasPixelWidth] as? NSNumber)?.intValue
            let h = (png[kCGImagePropertyAPNGCanvasPixelHeight] as? NSNumber)?.intValue
            if let w, let h, w > 0, h > 0 { return CGSize(width: w, height: h) }
        }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
            let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
            if let w, let h, w > 0, h > 0 { return CGSize(width: w, height: h) }
        }
        return nil
    }

    private static func frameDelay(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] else {
            return 0.1
        }
        // Per contract: the (system-clamped) DelayTime first, then the raw
        // UnclampedDelayTime, then a 0.1 s default.
        if let delay = (png[kCGImagePropertyAPNGDelayTime] as? NSNumber)?.doubleValue {
            return delay
        }
        if let delay = (png[kCGImagePropertyAPNGUnclampedDelayTime] as? NSNumber)?.doubleValue {
            return delay
        }
        return 0.1
    }

    /// One identity for every target that produces the same ImageIO decode.
    /// In particular, enlarging a small source always reuses its native frame.
    static func pixelLimit(canvas: CGSize, target: CGSize?) -> Int {
        let longSide = max(canvas.width, canvas.height)
        guard let target, target.width > 0, target.height > 0 else { return Int(longSide) }
        let scale = min(1, min(target.width / canvas.width, target.height / canvas.height))
        return max(1, Int((longSide * scale).rounded(.up)))
    }
}

/// Cost-based LRU for decoded images and their alpha masks, including both
/// allocations in the budget. Main-thread hits and background switch preparation share
/// a short lock; synchronous hits avoid a queue hop on every key press.
final class PetFrameCache: @unchecked Sendable {
    private struct Key: Hashable {
        let path: String
        let resourceVersion: UInt64
        let index: Int
        let pixelLimit: Int
    }

    private struct Entry {
        let frame: DecodedPetFrame
        let cost: Int
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    /// Front is least recently used.
    private var recency: [Key] = []
    private var budget: Int
    private var bytes = 0

    init(byteBudget: Int = PetResourceLimits.imageCacheByteBudget) {
        budget = byteBudget
    }

    var byteBudget: Int {
        get { locked { budget } }
        set { locked { budget = newValue; evictWithinBudget() } }
    }

    var currentBytes: Int { locked { bytes } }

    func frame(asset: PetAsset, index: Int, pixelLimit: Int) -> DecodedPetFrame? {
        locked {
            let key = Self.key(asset: asset, index: index, pixelLimit: pixelLimit)
            guard let entry = entries[key] else { return nil }
            markRecent(key)
            return entry.frame
        }
    }

    func store(_ frame: DecodedPetFrame, asset: PetAsset, index: Int, pixelLimit: Int) {
        locked {
            let key = Self.key(asset: asset, index: index, pixelLimit: pixelLimit)
            let cost = frame.byteCost
            if let old = entries.removeValue(forKey: key) {
                bytes -= old.cost
                recency.removeAll { $0 == key }
            }
            // A frame that alone exceeds the budget can never be retained.
            guard cost <= budget else { return }
            entries[key] = Entry(frame: frame, cost: cost)
            recency.append(key)
            bytes += cost
            evictWithinBudget()
        }
    }

    /// Called once a pet switch commits, so no entries of the old pet survive.
    func removeAll() {
        locked {
            entries.removeAll()
            recency.removeAll()
            bytes = 0
        }
    }

    /// Hot-switch variant: entries belonging to the committed pet survive
    /// (its first frames were warmed during prepare); everything else — the
    /// previous pet and stale versions — is released.
    func removeAll(except kept: Set<PetAsset>) {
        locked {
            let keptKeys = Set(kept.flatMap { asset in
                entries.keys.filter { $0.path == asset.fileURL.standardizedFileURL.path(percentEncoded: false)
                    && $0.resourceVersion == asset.resourceVersion }
            })
            let doomed = recency.filter { !keptKeys.contains($0) }
            for key in doomed {
                if let evicted = entries.removeValue(forKey: key) { bytes -= evicted.cost }
            }
            recency.removeAll { !keptKeys.contains($0) }
        }
    }

    private static func key(asset: PetAsset, index: Int, pixelLimit: Int) -> Key {
        Key(path: asset.fileURL.standardizedFileURL.path(percentEncoded: false),
            resourceVersion: asset.resourceVersion,
            index: index,
            pixelLimit: pixelLimit)
    }

    private func markRecent(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func evictWithinBudget() {
        while bytes > budget, !recency.isEmpty {
            let victim = recency.removeFirst()
            if let evicted = entries.removeValue(forKey: victim) {
                bytes -= evicted.cost
            }
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
