import Accelerate
import Foundation

private enum RhythmTuning {
    static let windowDuration = 0.02
    static let hopDuration = 0.01
    static let historyDuration = 6.0
    static let minimumHistoryDuration = 4.0
    static let statisticsDuration = 0.5
    static let estimateInterval = 0.5
    static let silenceDuration = 0.1
    static let minimumBPM = 60.0
    static let maximumBPM = 200.0
    static let preferredBPM = 110.0
    static let minimumCorrelation: Float = 0.30
    static let consistentPeriodTolerance = 0.04
    static let nearbyPeriodTolerance = 0.1
    static let periodCorrection = 0.2
    static let phaseCorrection = 0.25
    static let maximumMatchDelay = 0.08
    static let matchPeriodFraction = 0.12
    static let unsupportedBeatLimit = 2
    static let changedEstimateLimit = 3
    static let changedScoreRatio: Float = 1.2
    static let lowestFrequency = 40.0
    static let highestFrequency = 10_000.0
    static let logarithmGain: Float = 100
    // Ignore FFT roundoff in an otherwise unchanging spectrum. This is far
    // below a useful onset, but prevents adaptive statistics amplifying it.
    static let minimumOnsetStrength: Float = 1e-6
}

enum RhythmSensitivity: Int, CaseIterable, Sendable {
    case low, standard, high

    var peakDeviation: Float {
        switch self {
        case .low: 2
        case .standard: 1.5
        case .high: 1
        }
    }
}

/// Owns scalar history only. Confirmed onsets drive motion in both states;
/// a locked grid can bridge two weak beats, never a third.
final class RhythmDetector {
    static let silenceEnergy: Float = 1e-6
    static let minimumPulseInterval = 0.2
    private enum Tracking { case searching, locked }
    private struct Estimate {
        let period: Double
        let correlation: Float
        let score: Float
    }

    let frameDuration: Double
    private let statisticsWeight: Float
    private let capacity: Int
    private let minimumLag: Int
    private let maximumLag: Int
    private var strengths: [Float]
    private var candidates: [Bool]
    private var centered: [Float]
    private var squaredPrefix: [Double]
    private var correlations: [Float]
    private var writeIndex = 0
    private var count = 0
    private var mean: Float = 0
    private var deviation: Float = 0
    private var previousStrength: Float = 0
    private var precedingStrength: Float = 0
    private var previousThreshold: Float = 0
    private var previousAudible = false
    private var previousTime = 0.0
    private var peakFrames = 0
    private var silenceStarted: Double?
    private var nextEstimate = 0.0
    private var lastEstimate: Estimate?
    private var tracking = Tracking.searching
    private(set) var lockedPeriod: Double?
    private var nextBeat = 0.0
    private var nextSupported = false
    private var nextCorrection = 0.0
    private var pendingBeat: Double?
    private var pendingSupported = false
    private var pendingCorrection = 0.0
    private var unsupportedBeats = 0
    private var changedEstimate: Estimate?
    private var changedEstimateCount = 0
    private var lastPulse = -Double.infinity

    init(frameDuration: Double = RhythmTuning.hopDuration) {
        self.frameDuration = frameDuration
        statisticsWeight = Float(1 - exp(-frameDuration / RhythmTuning.statisticsDuration))
        capacity = Int((RhythmTuning.historyDuration / frameDuration).rounded())
        minimumLag = Int(ceil(60 / RhythmTuning.maximumBPM / frameDuration))
        maximumLag = Int(floor(60 / RhythmTuning.minimumBPM / frameDuration))
        strengths = .init(repeating: 0, count: capacity)
        candidates = .init(repeating: false, count: capacity)
        centered = .init(repeating: 0, count: capacity)
        squaredPrefix = .init(repeating: 0, count: capacity + 1)
        correlations = .init(repeating: 0, count: maximumLag * 2 + 2)
    }

    var workingStorageBytes: Int {
        (strengths.count + centered.count + correlations.count) * MemoryLayout<Float>.stride
            + candidates.count * MemoryLayout<Bool>.stride
            + squaredPrefix.count * MemoryLayout<Double>.stride
    }

    func consume(onsetStrength: Float, energy: Float, timestamp: Double,
                 sensitivity: RhythmSensitivity) -> Double? {
        let audible = energy > Self.silenceEnergy
        if !audible {
            if silenceStarted == nil { silenceStarted = timestamp }
            if timestamp - silenceStarted! >= RhythmTuning.silenceDuration {
                clearHistory()
                return nil
            }
        } else {
            silenceStarted = nil
        }

        let threshold = mean + sensitivity.peakDeviation * deviation
        strengths[writeIndex] = onsetStrength
        candidates[writeIndex] = false
        writeIndex = (writeIndex + 1) % capacity
        count = min(count + 1, capacity)
        var onset: Double?
        if peakFrames >= 2, previousAudible,
           previousStrength > precedingStrength, previousStrength >= onsetStrength,
           previousStrength > max(previousThreshold, RhythmTuning.minimumOnsetStrength) {
            candidates[(writeIndex + capacity - 2) % capacity] = true
            onset = previousTime
        }
        let distance = abs(onsetStrength - mean)
        mean += statisticsWeight * (onsetStrength - mean)
        deviation += statisticsWeight * (distance - deviation)
        precedingStrength = previousStrength
        previousStrength = onsetStrength
        previousThreshold = threshold
        previousAudible = audible
        previousTime = timestamp
        peakFrames = min(peakFrames + 1, 2)

        var pulse: Double?
        if let onset {
            switch tracking {
            case .searching: pulse = emit(onset)
            case .locked:
                supportBeat(at: onset)
                // The grid may represent a slower metrical level. Locking must
                // not discard real onsets between its beats. The shared output
                // limit merges an onset with a nearby predicted action.
                pulse = emit(onset)
            }
        }
        if Double(count) * frameDuration >= RhythmTuning.minimumHistoryDuration, timestamp >= nextEstimate {
            nextEstimate = timestamp + RhythmTuning.estimateInterval
            updateTempo(at: timestamp)
        }
        if tracking == .locked {
            let period = lockedPeriod!
            let tolerance = matchTolerance(period)
            if let beat = pendingBeat, timestamp > beat + tolerance + frameDuration {
                unsupportedBeats = pendingSupported ? 0 : unsupportedBeats + 1
                pendingBeat = nil
            }
            if timestamp >= nextBeat {
                if unsupportedBeats >= RhythmTuning.unsupportedBeatLimit && !nextSupported {
                    clearHistory()
                } else {
                    let beat = nextBeat
                    pendingBeat = beat
                    pendingSupported = nextSupported
                    pendingCorrection = nextCorrection
                    nextBeat = beat + period + nextCorrection
                    nextSupported = false
                    nextCorrection = 0
                    if audible, let predicted = emit(beat) { pulse = predicted }
                }
            }
        }
        return pulse
    }

    private func emit(_ timestamp: Double) -> Double? {
        guard timestamp - lastPulse >= Self.minimumPulseInterval - 1e-9 else { return nil }
        lastPulse = timestamp
        return timestamp
    }

    private func matchTolerance(_ period: Double) -> Double {
        min(RhythmTuning.maximumMatchDelay, period * RhythmTuning.matchPeriodFraction)
    }

    private func supportBeat(at onset: Double) {
        let tolerance = matchTolerance(lockedPeriod!)
        if let beat = pendingBeat, abs(onset - beat) <= tolerance {
            let correction = (onset - beat) * RhythmTuning.phaseCorrection
            if !pendingSupported || abs(correction) < abs(pendingCorrection) {
                nextBeat += correction - pendingCorrection
                pendingCorrection = correction
            }
            pendingSupported = true
        } else if abs(onset - nextBeat) <= tolerance {
            let correction = (onset - nextBeat) * RhythmTuning.phaseCorrection
            if !nextSupported || abs(correction) < abs(nextCorrection) { nextCorrection = correction }
            nextSupported = true
        }
    }

    private func clearHistory() {
        tracking = .searching
        lockedPeriod = nil
        count = 0
        writeIndex = 0
        mean = 0
        deviation = 0
        peakFrames = 0
        pendingBeat = nil
        nextSupported = false
        nextCorrection = 0
        unsupportedBeats = 0
        lastEstimate = nil
        changedEstimate = nil
        changedEstimateCount = 0
        // lastPulse survives loss of lock and silence: neither can bypass the
        // output limit. Session recreation alone resets this clock.
    }

    private func historyIndex(_ frame: Int) -> Int { (writeIndex + capacity - count + frame) % capacity }

    private func prepareCorrelations() -> Bool {
        var average: Float = 0
        for frame in 0..<count { average += strengths[historyIndex(frame)] }
        average /= Float(count)
        squaredPrefix[0] = 0
        for frame in 0..<count {
            let value = strengths[historyIndex(frame)] - average
            centered[frame] = value
            squaredPrefix[frame + 1] = squaredPrefix[frame] + Double(value) * Double(value)
        }
        guard squaredPrefix[count] > 1e-12 else { return false }
        centered.withUnsafeBufferPointer { buffer in
            for lag in (minimumLag / 2 - 1)...(maximumLag * 2 + 1) {
                let length = count - lag
                var dot: Float = 0
                vDSP_dotpr(buffer.baseAddress!, 1, buffer.baseAddress!.advanced(by: lag), 1,
                           &dot, vDSP_Length(length))
                let norm = sqrt(squaredPrefix[length] * (squaredPrefix[count] - squaredPrefix[lag]))
                correlations[lag] = norm > 1e-12 ? max(0, Float(Double(dot) / norm)) : 0
            }
        }
        return true
    }

    private func correlation(at lag: Double) -> Float {
        let lower = Int(lag)
        let fraction = Float(lag - Double(lower))
        return correlations[lower] + fraction * (correlations[lower + 1] - correlations[lower])
    }

    private func score(at lag: Double) -> Float {
        let bpm = 60 / (lag * frameDuration)
        let octave = log2(bpm / RhythmTuning.preferredBPM)
        return (correlation(at: lag) + 0.5 * correlation(at: lag * 2)
                + 0.25 * correlation(at: lag / 2)) * Float(exp(-0.5 * octave * octave))
    }

    private func estimateTempo() -> Estimate? {
        guard prepareCorrelations() else { return nil }
        var best: Estimate?
        for lag in minimumLag...maximumLag {
            let middle = correlations[lag]
            guard middle > 0, middle >= correlations[lag - 1], middle >= correlations[lag + 1] else { continue }
            let denominator = correlations[lag - 1] - 2 * middle + correlations[lag + 1]
            let offset = denominator < 0
                ? max(-0.5, min(0.5, 0.5 * (correlations[lag - 1] - correlations[lag + 1]) / denominator)) : 0
            let refinedLag = max(Double(minimumLag), min(Double(maximumLag), Double(lag) + Double(offset)))
            let estimate = Estimate(period: refinedLag * frameDuration,
                                    correlation: correlation(at: refinedLag), score: score(at: refinedLag))
            if best == nil || estimate.score > best!.score { best = estimate }
        }
        return best
    }

    private func updateTempo(at timestamp: Double) {
        guard let estimate = estimateTempo() else { lastEstimate = nil; return }
        switch tracking {
        case .searching:
            if let previous = lastEstimate,
               abs(estimate.period / previous.period - 1) <= RhythmTuning.consistentPeriodTolerance,
               estimate.correlation >= RhythmTuning.minimumCorrelation,
               let phase = supportedPhase(period: estimate.period, timestamp: timestamp) {
                tracking = .locked
                lockedPeriod = estimate.period
                nextBeat = phase + (floor((timestamp - phase) / estimate.period) + 1) * estimate.period
                nextSupported = false
                nextCorrection = 0
                pendingBeat = nil
                unsupportedBeats = 0
            }
            lastEstimate = estimate
        case .locked:
            let period = lockedPeriod!
            if abs(estimate.period / period - 1) <= RhythmTuning.nearbyPeriodTolerance {
                lockedPeriod = period + RhythmTuning.periodCorrection * (estimate.period - period)
                changedEstimate = nil
                changedEstimateCount = 0
            } else if estimate.correlation >= RhythmTuning.minimumCorrelation,
                      estimate.score > score(at: period / frameDuration) * RhythmTuning.changedScoreRatio {
                if let previous = changedEstimate,
                   abs(estimate.period / previous.period - 1) <= RhythmTuning.consistentPeriodTolerance {
                    changedEstimateCount += 1
                } else { changedEstimateCount = 1 }
                changedEstimate = estimate
                if changedEstimateCount >= RhythmTuning.changedEstimateLimit { clearHistory() }
            } else {
                changedEstimate = nil
                changedEstimateCount = 0
            }
        }
    }

    private func supportedPhase(period: Double, timestamp: Double) -> Double? {
        let oldestTime = timestamp - Double(count - 1) * frameDuration
        var bestPhase = 0.0
        var bestScore: Float = -1
        for offset in 0..<Int(ceil(period / frameDuration)) {
            let phase = timestamp - Double(offset) * frameDuration
            var sum: Float = 0
            for beat in 0..<4 {
                let frame = Int(((phase - Double(beat) * period - oldestTime) / frameDuration).rounded())
                for neighbor in max(0, frame - 1)...min(count - 1, frame + 1) {
                    sum += strengths[historyIndex(neighbor)]
                }
            }
            if sum > bestScore { bestScore = sum; bestPhase = phase }
        }
        let tolerance = matchTolerance(period)
        var supported = 0
        for beat in 0..<4 {
            let time = bestPhase - Double(beat) * period
            let first = max(0, Int(ceil((time - tolerance - oldestTime) / frameDuration)))
            let last = min(count - 1, Int(floor((time + tolerance - oldestTime) / frameDuration)))
            if first <= last {
                for frame in first...last where candidates[historyIndex(frame)] {
                    supported += 1
                    break
                }
            }
        }
        return supported >= 3 ? bestPhase : nil
    }
}

/// FFT storage is created on the capture control queue and destroyed after I/O
/// stops. The callback advances a short overlapping PCM ring without allocating.
final class RhythmAnalyzer {
    let sampleRate: Double
    let windowFrames: Int
    let hopFrames: Int
    private let fft: FFTSetup
    private let log2Length: vDSP_Length
    private let pcm: UnsafeMutablePointer<Float>
    private let window: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imaginary: UnsafeMutablePointer<Float>
    private let previousSpectrum: UnsafeMutablePointer<Float>
    private let spectrumCount: Int
    private let firstBin: Int
    private let lastBin: Int
    private let amplitudeScale: Float
    private let detector: RhythmDetector
    private var writeIndex = 0
    private var framesUntilAnalysis: Int
    private var spectrumInitialized = false
    private var streamStarted: Double?
    private var consumedFrames: Int64 = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let exponent = Int(ceil(log2(sampleRate * RhythmTuning.windowDuration)))
        windowFrames = 1 << exponent
        log2Length = vDSP_Length(exponent)
        hopFrames = Int((sampleRate * RhythmTuning.hopDuration).rounded())
        framesUntilAnalysis = windowFrames
        spectrumCount = windowFrames / 2 + 1
        firstBin = Int(ceil(RhythmTuning.lowestFrequency * Double(windowFrames) / sampleRate))
        lastBin = min(windowFrames / 2, Int(floor(RhythmTuning.highestFrequency * Double(windowFrames) / sampleRate)))
        fft = vDSP_create_fftsetup(log2Length, FFTRadix(kFFTRadix2))!
        pcm = .allocate(capacity: windowFrames)
        window = .allocate(capacity: windowFrames)
        real = .allocate(capacity: windowFrames)
        imaginary = .allocate(capacity: windowFrames)
        previousSpectrum = .allocate(capacity: spectrumCount)
        vDSP_hann_window(window, vDSP_Length(windowFrames), Int32(vDSP_HANN_NORM))
        var windowSum: Float = 0
        vDSP_sve(window, 1, &windowSum, vDSP_Length(windowFrames))
        amplitudeScale = 2 / windowSum
        detector = RhythmDetector(frameDuration: Double(hopFrames) / sampleRate)
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
        pcm.deallocate()
        window.deallocate()
        real.deallocate()
        imaginary.deallocate()
        previousSpectrum.deallocate()
    }

    var lockedPeriod: Double? { detector.lockedPeriod }
    var workingStorageBytes: Int {
        (windowFrames * 4 + spectrumCount) * MemoryLayout<Float>.stride + detector.workingStorageBytes
    }

    func consume(samples: UnsafePointer<Float>, count: Int, timestamp: Double,
                 sensitivity: RhythmSensitivity, onWindow: (_ energy: Float, _ pulse: Double?) -> Void) {
        if streamStarted == nil { streamStarted = timestamp }
        var offset = 0
        while offset < count {
            let length = min(count - offset, min(windowFrames - writeIndex, framesUntilAnalysis))
            pcm.advanced(by: writeIndex).update(from: samples.advanced(by: offset), count: length)
            writeIndex = (writeIndex + length) % windowFrames
            framesUntilAnalysis -= length
            consumedFrames += Int64(length)
            offset += length
            if framesUntilAnalysis == 0 {
                // Buffer timestamps describe its first sample; all features use
                // the FFT window center, independent of callback chunk sizes.
                let time = streamStarted! + (Double(consumedFrames) - Double(windowFrames) / 2) / sampleRate
                analyze(timestamp: time, sensitivity: sensitivity, onWindow: onWindow)
                framesUntilAnalysis = hopFrames
            }
        }
    }

    private func analyze(timestamp: Double, sensitivity: RhythmSensitivity,
                         onWindow: (_ energy: Float, _ pulse: Double?) -> Void) {
        let tail = windowFrames - writeIndex
        real.update(from: pcm.advanced(by: writeIndex), count: tail)
        real.advanced(by: tail).update(from: pcm, count: writeIndex)
        var energy: Float = 0
        vDSP_svesq(real, 1, &energy, vDSP_Length(windowFrames))
        energy /= Float(windowFrames)
        vDSP_vmul(real, 1, window, 1, real, 1, vDSP_Length(windowFrames))
        vDSP_vclr(imaginary, 1, vDSP_Length(windowFrames))
        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        vDSP_fft_zip(fft, &split, 1, log2Length, FFTDirection(FFT_FORWARD))
        var strength: Float = 0
        for bin in firstBin...lastBin {
            let amplitude = sqrt(real[bin] * real[bin] + imaginary[bin] * imaginary[bin]) * amplitudeScale
            let value = log1p(RhythmTuning.logarithmGain * amplitude)
            if spectrumInitialized { strength += max(0, value - previousSpectrum[bin]) }
            previousSpectrum[bin] = value
        }
        strength /= Float(lastBin - firstBin + 1)
        spectrumInitialized = true
        let pulse = detector.consume(onsetStrength: strength, energy: energy, timestamp: timestamp,
                                     sensitivity: sensitivity)
        onWindow(energy, pulse)
    }
}
