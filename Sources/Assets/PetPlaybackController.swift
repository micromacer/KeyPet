import AppKit
import QuartzCore

/// Drives the displayed image: APNG timeline, frame prefetch, the key-press
/// bounce trajectory and the display clock. The clock runs only while an
/// animated asset is playing or a bounce is in flight; a static PNG with no
/// bounce leaves it paused.
@MainActor
final class PetPlaybackController {
    private let cache: PetFrameCache
    private weak var hostView: NSView?
    private let decodeQueue: DispatchQueue
    private var displayLink: CADisplayLink?
    private var pet: PetDescriptor?
    private var metadataByAsset: [PetAsset: AnimationMetadata] = [:]
    private var asset: PetAsset?
    private var metadata: AnimationMetadata?
    private var lastSelection: PlaybackSelection?
    private var presentedIndex = -1
    private var wantedIndex = 0
    private var timelineStart = CACurrentMediaTime()
    /// Incremented on every show/pet change; stale background decodes compare
    /// against it and never write back into a newer selection.
    private var generation: UInt64 = 0
    // The serial queue runs one decode; asset/wantedIndex always describe the
    // latest request to service next, including while a stale decode finishes.
    private var decoding = false
    private var bounceStart: Double?
    private var bounceRestored = true
    private var active = true
    private var idleSerial: UInt64 = 0

    var onPresent: ((CGImage, AlphaMask) -> Void)?
    var onBounceTransform: ((_ scaleX: Double, _ scaleY: Double) -> Void)?
    var onDecodeFailure: ((PetDecodeError) -> Void)?

    var bounceEnabled = true {
        didSet {
            // Turning the bounce off restores the neutral pose immediately;
            // key-triggered image changes keep working.
            if !bounceEnabled { stopBounce() }
        }
    }
    var frameRate = 60 {
        didSet { displayLink?.preferredFrameRateRange = Self.rateRange(frameRate) }
    }
    /// Display-pixel target for decoding (draw points × backing scale).
    /// Zero means "not laid out yet": decode at native size.
    private var targetPixels = CGSize.zero

    init(cache: PetFrameCache, hostView: NSView, decodeQueue: DispatchQueue) {
        self.cache = cache
        self.hostView = hostView
        self.decodeQueue = decodeQueue
    }

    // MARK: - Selection

    func setPet(_ pet: PetDescriptor?, seeding metadata: [String: AnimationMetadata]) {
        self.pet = pet
        metadataByAsset = [:]
        for (token, meta) in metadata {
            if let asset = pet?.assets[token] { metadataByAsset[asset] = meta }
        }
        generation &+= 1
        asset = nil
        self.metadata = nil
        presentedIndex = -1
        stopBounce()
        updateDisplayLinkState()
    }

    func show(_ selection: PlaybackSelection) {
        lastSelection = selection
        guard active, let pet else { return }
        // A rescan can drop a token between the state machine's resolution and
        // arrival here; idle is guaranteed by the library's validation.
        guard let resolved = pet.assets[selection.token] ?? pet.assets["idle"] else { return }
        asset = resolved
        metadata = metadataByAsset[resolved]
        timelineStart = CACurrentMediaTime()
        presentedIndex = -1
        wantedIndex = 0
        generation &+= 1
        prepareCurrentFrame()
        updateDisplayLinkState()
    }

    /// Explicit reset of both pose and bounce after input resets, pet switches
    /// and activity resumption. Ordinary key release keeps its bounce tail.
    func showIdle() {
        stopBounce()
        idleSerial &+= 1
        show(PlaybackSelection(token: "idle", restartSerial: idleSerial))
    }

    // MARK: - Bounce

    /// Bounce trajectory: one shared 380 ms curve, restarted by
    /// each effective key press, never stacked.
    func triggerBounce() {
        guard bounceEnabled, active else { return }
        bounceStart = CACurrentMediaTime()
        bounceRestored = false
        updateDisplayLinkState()
    }

    private func stopBounce() {
        bounceStart = nil
        if !bounceRestored { onBounceTransform?(1, 1) }
        bounceRestored = true
    }

    // MARK: - Target size

    func updateTarget(pixels: CGSize) {
        guard pixels.width > 0, pixels.height > 0, pixels != targetPixels else { return }
        let previousTarget = targetOrNil
        targetPixels = pixels
        guard asset != nil else { return }
        if let metadata,
           PetAssetDecoder.pixelLimit(canvas: metadata.canvasPixels, target: previousTarget)
            == PetAssetDecoder.pixelLimit(canvas: metadata.canvasPixels, target: pixels) { return }
        generation &+= 1
        presentedIndex = -1
        prepareCurrentFrame()
    }

    // MARK: - Activity

    func setActive(_ newValue: Bool) {
        guard newValue != active else { return }
        active = newValue
        if active {
            // Resume from idle on a fresh time base; frames elapsed while
            // suspended are not replayed.
            if lastSelection != nil { showIdle() }
        } else {
            generation &+= 1
            stopBounce()
        }
        updateDisplayLinkState()
    }

    func stopAll() {
        active = false
        generation &+= 1
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Display link

    private func ensureDisplayLink() {
        guard displayLink == nil, let hostView else { return }
        let link = hostView.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = Self.rateRange(frameRate)
        // Menu tracking must not stall animation timing.
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        displayLink = link
    }

    private static func rateRange(_ fps: Int) -> CAFrameRateRange {
        CAFrameRateRange(minimum: Float(fps / 2), maximum: Float(fps), preferred: Float(fps))
    }

    private func updateDisplayLinkState() {
        ensureDisplayLink()
        let playing = active && metadata?.isAnimated == true
        let needClock = active && (playing || !bounceRestored)
        displayLink?.isPaused = !needClock
    }

    @objc private func tick(_ sender: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let metadata, metadata.isAnimated, active {
            let index = frameIndex(at: now, metadata: metadata)
            wantedIndex = index
            prepareCurrentFrame()
        }

        if let bounceStart {
            let t = min(1, (now - bounceStart) / 0.38)
            if t >= 1 {
                stopBounce()
            } else {
                let a = 0.11 * (1 - t)
                let s = sin(3.2 * Double.pi * t)
                onBounceTransform?(1 - 0.6 * s * a, 1 + s * a)
            }
        }
        updateDisplayLinkState()
    }

    /// Loops forever while the action is displayed, ignoring any finite loop
    /// count the APNG declares.
    private func frameIndex(at now: Double, metadata: AnimationMetadata) -> Int {
        let durations = metadata.frameDurations
        let total = durations.reduce(0, +)
        guard total > 0, metadata.frameCount > 1 else { return 0 }
        var t = (now - timelineStart).truncatingRemainder(dividingBy: total)
        for (index, duration) in durations.enumerated() {
            if t < duration { return min(index, metadata.frameCount - 1) }
            t -= duration
        }
        return metadata.frameCount - 1
    }

    // MARK: - Decoding

    private var targetOrNil: CGSize? { targetPixels.width > 0 ? targetPixels : nil }

    /// Demand has priority over prefetch. Completion always revisits the latest
    /// selection, so a busy decoder cannot swallow a static frame or a resize.
    private func prepareCurrentFrame() {
        guard active, let asset else { return }
        guard let metadata else {
            requestDecode(asset: asset, index: wantedIndex)
            return
        }
        let limit = PetAssetDecoder.pixelLimit(canvas: metadata.canvasPixels, target: targetOrNil)
        if wantedIndex != presentedIndex {
            guard let frame = cache.frame(asset: asset, index: wantedIndex, pixelLimit: limit) else {
                requestDecode(asset: asset, index: wantedIndex)
                return
            }
            present(frame: frame, index: wantedIndex)
        }
        if metadata.isAnimated {
            let next = (wantedIndex + 1) % metadata.frameCount
            if cache.frame(asset: asset, index: next, pixelLimit: limit) == nil {
                requestDecode(asset: asset, index: next)
            }
        }
    }

    private func requestDecode(asset: PetAsset, index: Int) {
        guard !decoding else { return }
        decoding = true
        let gen = generation
        let target = targetOrNil
        let knownMetadata = metadata
        decodeQueue.async { [weak self] in
            let decoded = Result {
                let meta = try knownMetadata ?? PetAssetDecoder.metadata(asset: asset)
                let frame = try PetAssetDecoder.prepareFrame(asset: asset, index: index, targetPixelSize: target)
                return (meta, frame)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.decoding = false
                guard self.active, gen == self.generation, self.asset == asset else {
                    self.prepareCurrentFrame()
                    return
                }
                switch decoded {
                case .success(let (meta, frame)):
                    self.metadataByAsset[asset] = meta
                    self.metadata = meta
                    let limit = PetAssetDecoder.pixelLimit(canvas: meta.canvasPixels, target: target)
                    self.cache.store(frame, asset: asset, index: index, pixelLimit: limit)
                    if index == self.wantedIndex, index != self.presentedIndex {
                        self.present(frame: frame, index: index)
                    }
                    self.updateDisplayLinkState()
                    self.prepareCurrentFrame()
                case .failure(let error):
                    self.report(error)
                }
            }
        }
    }

    private func present(frame: DecodedPetFrame, index: Int) {
        presentedIndex = index
        onPresent?(frame.image, frame.alphaMask)
    }

    private func report(_ error: Error) {
        onDecodeFailure?((error as? PetDecodeError) ?? .corruptImage)
    }
}
