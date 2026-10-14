import CoreAudio
import Foundation
import QuartzCore
import Synchronization

enum AudioCaptureFailure: Error, Equatable, Sendable {
    case system(OSStatus)
    case unsupportedFormat
}

/// Main-actor ownership and UI callbacks; HAL work runs on its own serial queue.
@MainActor
final class SystemAudioMonitor {
    enum Status: Equatable, Sendable {
        case stopped, starting, waiting, responding
        case failed(AudioCaptureFailure)
    }

    private(set) var status: Status = .stopped {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    var onPulse: ((_ timestamp: Double) -> Void)?
    var onStatusChange: ((Status) -> Void)?
    private let capture = AudioTapCapture()
    private var sensitivity = RhythmSensitivity.standard
    private var signals: AudioTapSignals?
    private var generation: UInt64 = 0

    func start(sensitivity: RhythmSensitivity) {
        setSensitivity(sensitivity)
        guard signals == nil else { return }
        beginCapture()
    }

    func setSensitivity(_ sensitivity: RhythmSensitivity) {
        self.sensitivity = sensitivity
        signals?.sensitivity.store(sensitivity.rawValue, ordering: .relaxed)
    }

    func stop() {
        guard signals != nil || status != .stopped else { return }
        generation &+= 1
        signals?.source.cancel()
        signals = nil
        capture.stop()
        status = .stopped
    }

    /// Termination waits for queued teardown instead of leaving it to process exit.
    func shutdown() {
        stop()
        capture.finishStopping()
    }

    private func beginCapture() {
        generation &+= 1
        let gen = generation
        signals?.source.cancel()
        let source = DispatchSource.makeUserDataOrSource(queue: .main)
        let signals = AudioTapSignals(source: source, sensitivity: sensitivity)
        self.signals = signals
        source.setEventHandler { [weak self, weak signals] in
            MainActor.assumeIsolated {
                guard let self, let signals, self.generation == gen else { return }
                let events = signals.source.data
                self.status = signals.audible.load(ordering: .acquiring) ? .responding : .waiting
                if events & AudioTapSignals.pulseEvent != 0 {
                    let timestamp = signals.pulseTime.load(ordering: .acquiring)
                    // A busy main thread presents only a recent pulse, never a backlog.
                    if CACurrentMediaTime() - timestamp <= RhythmDetector.minimumPulseInterval {
                        self.onPulse?(timestamp)
                    }
                }
            }
        }
        source.resume()
        status = .starting
        capture.start(signals: signals, onStarted: { [weak self, weak signals] outcome in
            DispatchQueue.main.async { [weak self, weak signals] in
                guard let self, let signals, self.generation == gen else { return }
                switch outcome {
                case .success:
                    self.status = signals.audible.load(ordering: .acquiring) ? .responding : .waiting
                case .failure(let failure):
                    signals.source.cancel()
                    self.signals = nil
                    self.status = .failed(failure)
                }
            }
        }, onConfigurationChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == gen, self.signals != nil else { return }
                self.beginCapture()
            }
        })
    }
}

/// Only atomics and libdispatch cross the I/O/control/main-thread boundary.
private final class AudioTapSignals: @unchecked Sendable {
    static let activityEvent: UInt = 1
    static let pulseEvent: UInt = 2
    let source: any DispatchSourceUserDataOr
    let sensitivity: Atomic<Int>
    let audible = Atomic<Bool>(false)
    let pulseTime = Atomic<Double>(0)

    init(source: any DispatchSourceUserDataOr, sensitivity: RhythmSensitivity) {
        self.source = source
        self.sensitivity = Atomic(sensitivity.rawValue)
    }
}

/// The HAL invokes one I/O block serially. Its analyzer is never accessed by
/// control or main-thread code, and the block retains this context until teardown.
private final class AudioTapContext: @unchecked Sendable {
    private let analyzer: RhythmAnalyzer
    private let signals: AudioTapSignals

    init(sampleRate: Double, signals: AudioTapSignals) {
        analyzer = RhythmAnalyzer(sampleRate: sampleRate)
        self.signals = signals
    }

    func consume(_ input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>) {
        guard input.pointee.mNumberBuffers > 0, let data = input.pointee.mBuffers.mData else { return }
        let count = Int(input.pointee.mBuffers.mDataByteSize) / MemoryLayout<Float>.stride
        let timestamp = Double(AudioConvertHostTimeToNanos(time.pointee.mHostTime)) / 1e9
        let sensitivity = RhythmSensitivity(rawValue: signals.sensitivity.load(ordering: .relaxed))!
        analyzer.consume(samples: data.assumingMemoryBound(to: Float.self), count: count,
                         timestamp: timestamp, sensitivity: sensitivity) { energy, pulse in
            let audible = energy > RhythmDetector.silenceEnergy
            var events: UInt = 0
            if signals.audible.exchange(audible, ordering: .acquiringAndReleasing) != audible {
                events |= AudioTapSignals.activityEvent
            }
            if let pulse {
                signals.pulseTime.store(pulse, ordering: .releasing)
                events |= AudioTapSignals.pulseEvent
            }
            if events != 0 { signals.source.or(data: events) }
        }
    }
}

/// Session ownership is confined to `queue`; start/stop and property listeners
/// share that queue. The I/O block touches only its separate AudioTapContext.
private final class AudioTapCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "keypet.audio.control")
    private var session: AudioTapSession?

    func start(signals: AudioTapSignals,
               onStarted: @escaping @Sendable (Result<Void, AudioCaptureFailure>) -> Void,
               onConfigurationChange: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            self.session?.close()
            self.session = nil
            do {
                let session = try AudioTapSession(signals: signals)
                self.session = session
                try session.observeConfiguration(on: self.queue) { [weak self, weak session] in
                    guard let self, let session, self.session === session else { return }
                    onConfigurationChange()
                }
                try session.start()
                onStarted(.success(()))
            } catch {
                self.session?.close()
                self.session = nil
                onStarted(.failure(error as? AudioCaptureFailure ?? .unsupportedFormat))
            }
        }
    }

    func stop() {
        queue.async {
            self.session?.close()
            self.session = nil
        }
    }

    func finishStopping() { queue.sync {} }
}

/// HAL handles and listener closures stay on the control queue. Only the retained
/// context enters the I/O thread, so destroying the I/O block precedes releasing it.
private final class AudioTapSession: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var started = false
    private var format = AudioStreamBasicDescription()
    private var defaultOutput = AudioObjectID(kAudioObjectUnknown)
    private var context: AudioTapContext?
    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock
    }
    private var listeners: [Listener] = []

    init(signals: AudioTapSignals) throws {
        do {
            let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
            description.name = "KeyPet Rhythm"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try Self.check(AudioHardwareCreateProcessTap(description, &tapID))
            format = try readTapFormat()
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  format.mChannelsPerFrame == 1, format.mBitsPerChannel == 32,
                  format.mBytesPerFrame == 4, format.mSampleRate * 0.02 >= 1 else {
                throw AudioCaptureFailure.unsupportedFormat
            }
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "KeyPet Rhythm",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: 1,
                kAudioAggregateDeviceTapAutoStartKey: 1,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
            ]
            try Self.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &deviceID))
            let context = AudioTapContext(sampleRate: format.mSampleRate, signals: signals)
            self.context = context
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, nil) { _, input, time, _, _ in
                context.consume(input, time: time)
            })
        } catch {
            close()
            throw error
        }
    }

    func start() throws {
        try Self.check(AudioDeviceStart(deviceID, ioProc))
        started = true
    }

    func observeConfiguration(on queue: DispatchQueue,
                              changed: @escaping @Sendable () -> Void) throws {
        defaultOutput = try readDefaultOutput()
        try addListener(object: AudioObjectID(kAudioObjectSystemObject),
                        selector: kAudioHardwarePropertyDefaultOutputDevice, queue: queue) { [weak self] _, _ in
            guard let self else { return }
            if let output = try? self.readDefaultOutput(), output == self.defaultOutput { return }
            changed()
        }
        try addListener(object: tapID, selector: kAudioTapPropertyFormat, queue: queue) { [weak self] _, _ in
            guard let self else { return }
            if let updated = try? self.readTapFormat(),
               updated.mSampleRate == self.format.mSampleRate,
               updated.mFormatID == self.format.mFormatID,
               updated.mFormatFlags == self.format.mFormatFlags,
               updated.mBytesPerFrame == self.format.mBytesPerFrame,
               updated.mChannelsPerFrame == self.format.mChannelsPerFrame,
               updated.mBitsPerChannel == self.format.mBitsPerChannel { return }
            changed()
        }
    }

    func close() {
        if let ioProc {
            if started { _ = AudioDeviceStop(deviceID, ioProc) }
            _ = AudioDeviceDestroyIOProcID(deviceID, ioProc)
        }
        ioProc = nil
        started = false
        for var listener in listeners {
            _ = AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address,
                                                      listener.queue, listener.block)
        }
        listeners.removeAll()
        if deviceID != kAudioObjectUnknown { _ = AudioHardwareDestroyAggregateDevice(deviceID) }
        if tapID != kAudioObjectUnknown { _ = AudioHardwareDestroyProcessTap(tapID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        context = nil
    }

    private func addListener(object: AudioObjectID, selector: AudioObjectPropertySelector,
                             queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) throws {
        var address = Self.address(selector)
        try Self.check(AudioObjectAddPropertyListenerBlock(object, &address, queue, block))
        listeners.append(Listener(object: object, address: address, queue: queue, block: block))
    }

    private func readTapFormat() throws -> AudioStreamBasicDescription {
        var address = Self.address(kAudioTapPropertyFormat)
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: value))
        try Self.check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &value))
        return value
    }

    private func readDefaultOutput() throws -> AudioObjectID {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: value))
        try Self.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                 &address, 0, nil, &size, &value))
        return value
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw AudioCaptureFailure.system(status) }
    }
}
