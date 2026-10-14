import AppKit
import CoreAudio
import Foundation
import QuartzCore

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(description: message) }
}

@main
struct RhythmChecks {
    @MainActor
    static func main() {
        Task { @MainActor in
            do {
                try await run()
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        #if APP_CHECKS
        if CommandLine.arguments.contains("--app") || CommandLine.arguments.contains("--performance") {
            NSApplication.shared.run()
        }
        #endif
        dispatchMain()
    }

    @MainActor
    private static func run() async throws {
        if let index = CommandLine.arguments.firstIndex(of: "--pcm") {
            try compareRecording(path: CommandLine.arguments[index + 1])
            return
        }
        try checkDetector()
        try checkLockedOnsetResponse()
        try checkPCMWindows()
        try await checkActions()
        try checkPreferences()
        print("PASS: onset/tempo tracking, PCM windows, rhythm actions, keyboard regression, preferences")
        #if APP_CHECKS
        if CommandLine.arguments.contains("--app") || CommandLine.arguments.contains("--performance") {
            try await checkAppCoordination()
        }
        #endif
        if CommandLine.arguments.contains("--capture") {
            try await checkCapture(cycles: 1)
        } else if CommandLine.arguments.contains("--stress") {
            try await checkCapture(cycles: 100)
        }
    }

    private static func checkDetector() throws {
        let silence = RhythmDetector()
        for index in 0..<500 {
            try expect(silence.consume(onsetStrength: 1, energy: index.isMultiple(of: 2) ? 0 : 0.5e-6,
                                      timestamp: Double(index) * 0.01, sensitivity: .high) == nil,
                       "Silence/noise emitted a pulse")
        }
        let steady = RhythmDetector()
        var pulses = 0
        for index in 0..<500 {
            if steady.consume(onsetStrength: 0, energy: 0.05,
                              timestamp: Double(index) * 0.01, sensitivity: .standard) != nil {
                pulses += 1
            }
        }
        try expect(pulses == 0, "Steady sound repeatedly triggered")
        let cooldown = RhythmDetector()
        var times: [Double] = []
        for index in 0..<100 {
            let strength: Float = [2, 8, 15, 40].contains(index) ? 1 : 0
            if let pulse = cooldown.consume(onsetStrength: strength, energy: 0.01,
                                            timestamp: Double(index) * 0.01, sensitivity: .standard) {
                times.append(pulse)
            }
        }
        try expect(times == [0.02, 0.4], "Cooldown ignored or replayed a past rise: \(times)")

        let tracker = RhythmDetector()
        var lockTime: Double?
        var missing: [Double] = []
        for index in 0..<1_200 {
            let time = Double(index) * 0.01
            let strength: Float = index.isMultiple(of: 50) && index < 800 ? 1 : 0
            let pulse = tracker.consume(onsetStrength: strength, energy: 0.01,
                                        timestamp: time, sensitivity: time < 6 ? .standard : .high)
            if tracker.lockedPeriod != nil && lockTime == nil { lockTime = time }
            if let pulse, pulse >= 7.8 { missing.append(pulse) }
            if time > 6 && time < 8 {
                try expect(abs(tracker.lockedPeriod! - 0.5) < 0.015, "Sensitivity changed tempo")
            }
        }
        try expect(lockTime != nil && lockTime! <= 6, "Stable features did not lock in six seconds")
        try expect(missing.count == 2 && tracker.lockedPeriod == nil,
                   "Missing rhythm was not limited to two predicted beats: \(missing)")

        let stopped = RhythmDetector()
        var silencePulses = 0
        for index in 0..<900 {
            let silent = index >= 800
            if stopped.consume(onsetStrength: !silent && index.isMultiple(of: 50) ? 1 : 0,
                               energy: silent ? 0 : 0.01, timestamp: Double(index) * 0.01,
                               sensitivity: .standard) != nil && silent { silencePulses += 1 }
        }
        try expect(silencePulses == 0 && stopped.lockedPeriod == nil, "Silence did not stop prediction")

        let changing = RhythmDetector()
        var changedPulses: [Double] = []
        var periods: [Double] = []
        for index in 0..<2_200 {
            let strong = index < 1_000 ? index.isMultiple(of: 50) : (index - 1_000).isMultiple(of: 75)
            if let pulse = changing.consume(onsetStrength: strong ? 1 : 0, energy: 0.01,
                                            timestamp: Double(index) * 0.01, sensitivity: .standard) {
                changedPulses.append(pulse)
            }
            if index > 1_800, let period = changing.lockedPeriod { periods.append(period) }
        }
        try expect(zip(changedPulses.dropFirst(), changedPulses).allSatisfy { $0 - $1 >= 0.2 - 1e-9 },
                   "Reacquisition bypassed output throttle")
        try expect(!periods.isEmpty && periods.allSatisfy { abs($0 - 0.75) < 0.0225 },
                   "Clear tempo change was not reacquired")
    }

    private static func checkLockedOnsetResponse() throws {
        let detector = RhythmDetector()
        let interval = 60.0 / 160
        var pulses: [Double] = []
        var onsets: [Double] = []
        var firstLock: Double?
        for frame in 0..<1_400 {
            let time = Double(frame) * 0.01
            let beat = Int(((time - 0.5) / interval).rounded())
            let isOnset = beat >= 0 && frame == Int(((0.5 + Double(beat) * interval) / 0.01).rounded())
            if isOnset { onsets.append(time) }
            if let pulse = detector.consume(onsetStrength: isOnset ? 1 : 0, energy: 0.01,
                                            timestamp: time, sensitivity: .standard) {
                pulses.append(pulse)
            }
            if firstLock == nil && detector.lockedPeriod != nil { firstLock = time }
        }
        try expect(firstLock != nil && firstLock! <= 6, "Onset response regression did not reach lock")
        for onset in onsets where onset >= 6 {
            try expect(pulses.contains { abs($0 - onset) <= 0.04 },
                       "Lock swallowed a confirmed onset at \(onset)s (period \(detector.lockedPeriod!))")
        }
        try expect(zip(pulses.dropFirst(), pulses).allSatisfy { $0 - $1 >= 0.2 - 1e-9 },
                   "Onset/grid merge duplicated an action")
        func medianInterval(from start: Double, to end: Double) -> Double {
            let selected = pulses.filter { $0 >= start && $0 < end }
            let intervals = zip(selected.dropFirst(), selected).map(-).sorted()
            return intervals[intervals.count / 2]
        }
        let before = medianInterval(from: 1, to: 4)
        let after = medianInterval(from: 6, to: 13)
        try expect(abs(after / before - 1) < 0.05, "Lock reduced the rate of steady confirmed onsets")
        print(String(format: "LOCK HANDOFF: lock %.2fs, model period %.3fs; output before %.3fs, after %.3fs",
                     firstLock!, detector.lockedPeriod!, before, after))
    }

    private struct Analysis {
        var pulses: [Double] = []
        var periods: [(time: Double, period: Double?)] = []
        var bytes = 0
    }

    private static func analyze(_ samples: [Float], sampleRate: Double, buffers: [Int]) -> Analysis {
        let analyzer = RhythmAnalyzer(sampleRate: sampleRate)
        var analysis = Analysis(bytes: analyzer.workingStorageBytes)
        var window = 0
        samples.withUnsafeBufferPointer { buffer in
            var offset = 0
            var block = 0
            while offset < buffer.count {
                let count = min(buffers[block % buffers.count], buffer.count - offset)
                analyzer.consume(samples: buffer.baseAddress!.advanced(by: offset), count: count,
                                 timestamp: Double(offset) / sampleRate, sensitivity: .standard) { _, pulse in
                    if let pulse { analysis.pulses.append(pulse) }
                    let time = Double(analyzer.windowFrames / 2 + window * analyzer.hopFrames) / sampleRate
                    analysis.periods.append((time, analyzer.lockedPeriod))
                    window += 1
                }
                offset += count
                block += 1
            }
        }
        return analysis
    }

    private static func checkPCMWindows() throws {
        for sampleRate in [44_100.0, 48_000.0] {
            for bpm in [90.0, 120.0, 160.0] {
                let interval = 60 / bpm
                let samples = (0..<Int(14 * sampleRate)).map { frame -> Float in
                    let time = Double(frame) / sampleRate
                    let phase = (time - 0.5).truncatingRemainder(dividingBy: interval)
                    let bed = 0.015 * sin(2 * .pi * 375 * time)
                    let drum = time >= 0.5 && phase < 0.09
                        ? 0.6 * exp(-phase * 45) * (sin(2 * .pi * 110 * phase) + 0.3 * sin(2 * .pi * 2_400 * phase)) : 0
                    return Float(bed + drum)
                }
                let reference = analyze(samples, sampleRate: sampleRate, buffers: [960])
                guard let firstLock = reference.periods.first(where: { $0.period != nil }) else {
                    throw CheckFailure(description: "No lock at \(bpm) BPM / \(sampleRate) Hz")
                }
                try expect(firstLock.time <= 6, "Slow lock at \(bpm) BPM / \(sampleRate) Hz: \(firstLock.time)")
                let layer = [interval / 2, interval, interval * 2].min(by: {
                    abs($0 - firstLock.period!) < abs($1 - firstLock.period!)
                })!
                try expect(reference.periods.filter { $0.time >= 6 }.allSatisfy {
                    $0.period != nil && abs($0.period! / layer - 1) <= 0.03
                }, "Tempo layer drifted at \(bpm) BPM / \(sampleRate) Hz")
                for pulse in reference.pulses where pulse >= 6 {
                    let nearest = 0.5 + ((pulse - 0.5) / interval).rounded() * interval
                    try expect(abs(pulse - nearest) <= 0.04, "Beat phase error at \(bpm) BPM: \(pulse - nearest)")
                }
                try expect(reference.bytes < 128 * 1024, "DSP storage exceeded 128 KiB")
                for buffers in [[128], [512], [1001], [17, 255, 1024, 64]] {
                    let actual = analyze(samples, sampleRate: sampleRate, buffers: buffers)
                    try expect(actual.pulses.count == reference.pulses.count, "Buffer size changed pulse count")
                    try expect(zip(actual.pulses, reference.pulses).allSatisfy { abs($0 - $1) < 1e-8 },
                               "Buffer size changed pulse timing")
                }
                try expect(zip(reference.pulses.dropFirst(), reference.pulses).allSatisfy { $0 - $1 >= 0.2 - 1e-9 },
                           "Pulse rate exceeded five per second")
                print(String(format: "SYNTH %.0f BPM / %.0f Hz: lock %.3fs, period %.5fs, DSP %d bytes",
                             bpm, sampleRate, firstLock.time, firstLock.period!, reference.bytes))
            }
        }
        let steady = (0..<240_000).map { Float(0.1 * sin(2 * .pi * 375 * Double($0) / 48_000)) }
        let steadyAnalysis = analyze(steady, sampleRate: 48_000, buffers: [512])
        try expect(steadyAnalysis.pulses.filter { $0 > 0.2 }.isEmpty, "Steady PCM kept triggering")
        print("PASS: 90/120/160 BPM at 44.1/48 kHz, five buffer layouts")
    }

    /// Raw mono Float32 at 48 kHz is decoded externally, never included in the repository.
    private static func compareRecording(path: String) throws {
        let bytes = path == "-" ? FileHandle.standardInput.readDataToEndOfFile()
            : try Data(contentsOf: URL(fileURLWithPath: path))
        let samples = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let clips: [(Double, Double)]
        if let index = CommandLine.arguments.firstIndex(of: "--clip") {
            clips = [(Double(CommandLine.arguments[index + 1])!, Double(CommandLine.arguments[index + 2])!)]
        } else { clips = [(30, 45), (90, 105), (150, 180)] }
        for (start, end) in clips {
            let warmup = start - 6
            let clip = Array(samples[Int(warmup * 48_000)..<Int(end * 48_000)])
            let analysis = analyze(clip, sampleRate: 48_000, buffers: [512])
            let pulses = analysis.pulses.filter { $0 >= 6 }.map { $0 + warmup }
            var old: [Double] = []
            var baseline: Float = 0
            var armed = true
            var lastPulse = -Double.infinity
            for frame in stride(from: 0, through: clip.count - 960, by: 960) {
                var energy: Float = 0
                for sample in clip[frame..<(frame + 960)] { energy += sample * sample }
                energy /= 960
                let time = Double(frame + 960) / 48_000
                if energy <= max(1e-6, baseline * 1.1) { armed = true }
                if armed && energy > max(1e-6, baseline * 1.7) {
                    armed = false
                    if time - lastPulse >= 0.2 {
                        lastPulse = time
                        if time >= 6 { old.append(time + warmup) }
                    }
                }
                baseline += Float(1 - exp(-0.02 / 0.3)) * (energy - baseline)
            }
            let locked = analysis.periods.filter { $0.time >= 6 && $0.period != nil }
            let intervals = zip(pulses.dropFirst(), pulses).map(-).sorted()
            print(String(format: "CLIP %.0f–%.0fs: old %d, new %d; locked %.1f%%, median interval %.3fs",
                         start, end, old.count, pulses.count,
                         Double(locked.count) / Double(analysis.periods.filter { $0.time >= 6 }.count) * 100,
                         intervals.isEmpty ? 0 : intervals[intervals.count / 2]))
            print("NEW PULSES: \(pulses.map { String(format: "%.3f", $0) }.joined(separator: ", "))")
            print("OLD PULSES: \(old.map { String(format: "%.3f", $0) }.joined(separator: ", "))")
        }
    }

    @MainActor
    private static func checkActions() async throws {
        let state = PetInputStateMachine()
        var selections: [PlaybackSelection] = []
        var bounceCount = 0
        state.tokenAvailable = { ["idle", "left", "right", "a"].contains($0) }
        state.onSelection = { selections.append($0) }
        state.onBounce = { bounceCount += 1 }
        state.handleRhythmPulse()
        state.handleRhythmPulse()
        try expect(selections.map(\.token) == ["left", "right"], "Paws did not alternate")
        try expect(bounceCount == 2 && state.heldKeyCount == 0, "Music created held keys or missed bounce")
        state.reset()
        state.swapSides = true
        state.handleRhythmPulse()
        try expect(selections.last?.token == "right", "Paw swap ignored")
        state.reset()
        state.swapSides = false
        state.tokenAvailable = { ["idle", "right"].contains($0) }
        state.handleRhythmPulse()
        state.handleRhythmPulse()
        try expect(selections.suffix(2).map(\.token) == ["idle", "right"], "Missing paw fallback changed")
        state.reset()
        state.tokenAvailable = { $0 == "idle" }
        state.handleRhythmPulse()
        let firstSerial = selections.last!.restartSerial
        state.handleRhythmPulse()
        try expect(selections.last!.restartSerial > firstSerial, "Same-token playback was not restarted")

        state.reset()
        state.resetDelay = 0.15
        state.tokenAvailable = { ["idle", "left", "right", "a"].contains($0) }
        state.handleRhythmPulse()
        try await Task.sleep(for: .milliseconds(80))
        state.handleRhythmPulse()
        try await Task.sleep(for: .milliseconds(90))
        try expect(selections.last?.token == "right", "Old idle deadline interrupted a new pulse")
        try await Task.sleep(for: .milliseconds(100))
        try expect(selections.last?.token == "idle", "Last pulse did not return to idle")
        state.resetDelay = 0.04
        state.handleRhythmPulse()
        state.reset()
        let count = selections.count
        try await Task.sleep(for: .milliseconds(80))
        try expect(selections.count == count, "Reset left a stale idle callback")

        let beforeKeys = bounceCount
        func key(_ code: UInt16, _ phase: KeyEventPhase) {
            state.handle(NormalizedKeyEvent(keyCode: code, phase: phase, isRepeat: false,
                                            timestamp: CACurrentMediaTime()))
        }
        key(0, .down)
        state.handle(NormalizedKeyEvent(keyCode: 0, phase: .down, isRepeat: true, timestamp: CACurrentMediaTime()))
        try expect(selections.last?.token == "a" && bounceCount == beforeKeys + 1,
                   "Dedicated key/repeat behavior changed")
        key(36, .down)
        try expect(state.heldKeyCount == 2 && selections.last?.token == "left", "Multi-key press changed")
        key(36, .up)
        try expect(selections.last?.token == "a", "Release did not restore held key")
        key(0, .up)
        try await Task.sleep(for: .milliseconds(80))
        try expect(state.heldKeyCount == 0 && selections.last?.token == "idle", "Keyboard reset failed")
    }

    @MainActor
    private static func checkPreferences() throws {
        let name = "local.kenny.KeyPet.RhythmChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PreferencesStore(defaults: defaults)
        try expect(preferences.rhythmSensitivity == .standard, "Wrong default sensitivity")
        preferences.rhythmSensitivity = .high
        try expect(PreferencesStore(defaults: defaults).rhythmSensitivity == .high, "Sensitivity not persisted")
        preferences.restoreDefaults()
        try expect(preferences.rhythmSensitivity == .standard, "Defaults did not restore sensitivity")
        defaults.set(99, forKey: "experimentalMusicSensitivity")
        try expect(preferences.rhythmSensitivity == .standard, "Invalid stored sensitivity was not normalized")
    }

    #if APP_CHECKS
    @MainActor
    private static func waitFor(_ message: String, until condition: () throws -> Bool) async throws {
        for _ in 0..<200 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CheckFailure(description: message)
    }

    private static func keyboardTapCount() throws -> Int {
        var count: UInt32 = 0
        try expect(CGGetEventTapList(0, nil, &count) == .success, "Unable to enumerate keyboard taps")
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        let status = taps.withUnsafeMutableBufferPointer { CGGetEventTapList(count, $0.baseAddress, &count) }
        try expect(status == .success, "Unable to read keyboard taps")
        return taps.filter { $0.tappingProcess == getpid() && $0.enabled }.count
    }

    private static func processResources() throws -> (cpu: Double, footprint: UInt64) {
        var usage = rusage()
        try expect(getrusage(RUSAGE_SELF, &usage) == 0, "Unable to read process CPU time")
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        var memory = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: memory) / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &memory) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        try expect(status == KERN_SUCCESS, "Unable to read process physical footprint")
        return (cpu, memory.phys_footprint)
    }

    @MainActor
    private static func measureMusicPerformance(baselineFootprint: UInt64, idleCPU: Double) async throws {
        let before = try processResources()
        let started = CACurrentMediaTime()
        print("PERFORMANCE: measuring 30-second music-mode sample; 150 pt PNG, 60 FPS, standard sensitivity")
        fflush(stdout)
        try await Task.sleep(for: .seconds(30))
        let after = try processResources()
        let musicCPU = (after.cpu - before.cpu) / (CACurrentMediaTime() - started) * 100
        let footprintDelta = (Double(after.footprint) - Double(baselineFootprint)) / 1_048_576
        print(String(format: "PERFORMANCE: off CPU %.2f%%; on CPU %.2f%%; added %.2f%% of one core; footprint delta %.2f MiB",
                     idleCPU, musicCPU, musicCPU - idleCPU, footprintDelta))
        try expect(musicCPU - idleCPU <= 3, "Short sample exceeded additional single-core CPU budget")
        try expect(footprintDelta <= 10, "Short sample exceeded additional physical-memory budget")
    }

    /// Exercises the real menu targets with isolated preferences and tiny PNGs;
    /// workspace notifications below are simulated, not actual system sleep.
    @MainActor
    private static func checkAppCoordination() async throws {
        try expect(KeyboardMonitor.permissionGranted, "App checks require existing Input Monitoring permission")
        _ = NSApplication.shared
        let name = "local.kenny.KeyPet.AppChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 64, bitsPerPixel: 32)!
        let color = NSColor(deviceRed: 0.1, green: 0.4, blue: 0.9, alpha: 1)
        for x in 0..<16 { for y in 0..<16 { bitmap.setColor(color, atX: x, y: y) } }
        let png = bitmap.representation(using: .png, properties: [:])!
        for pet in ["first", "second"] {
            let directory = fixtures.appendingPathComponent(pet)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for token in ["idle", "left", "right"] {
                try png.write(to: directory.appendingPathComponent("pet-\(token).png"))
            }
        }
        defaults.set(try fixtures.bookmarkData(options: []), forKey: "rootBookmark")
        var controller: AppController? = AppController(defaults: defaults)
        let termination = Notification(name: NSApplication.willTerminateNotification)
        defer {
            controller?.applicationWillTerminate(termination)
            for window in NSApp.windows where window is PetPanel { window.orderOut(nil) }
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: fixtures)
        }
        func launch(_ app: AppController) throws -> NSMenu {
            app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            guard let menu = NSApp.windows.compactMap({ $0.contentView?.menu }).first(where: {
                $0.item(withTitle: L10n.experimentalFeatures.text)?.submenu?
                    .item(withTitle: L10n.musicRhythm.text)?.target === app
            }) else { throw CheckFailure(description: "Experimental menu was not created") }
            return menu
        }
        func invoke(_ item: NSMenuItem) throws {
            try expect(NSApp.sendAction(item.action!, to: item.target, from: item), "Menu action was not handled")
        }
        let tapsBefore = try audioObjects(kAudioHardwarePropertyTapList)
        let root = try launch(controller!)
        let experimental = root.item(withTitle: L10n.experimentalFeatures.text)!.submenu!
        let music = experimental.item(withTitle: L10n.musicRhythm.text)!
        let status = experimental.items.first { $0.action == nil && $0.submenu == nil && !$0.isSeparatorItem }!
        let sensitivity = experimental.item(withTitle: L10n.musicSensitivity.text)!.submenu!
        let performance = CommandLine.arguments.contains("--performance")
        let player = Process()
        if performance {
            guard let index = CommandLine.arguments.firstIndex(of: "--audio") else {
                throw CheckFailure(description: "Performance sample requires --audio followed by an existing music file")
            }
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["-v", "0.03", CommandLine.arguments[index + 1]]
            try player.run()
        }
        defer { if player.isRunning { player.terminate() } }
        try expect(root.indexOfItem(withTitle: L10n.experimentalFeatures.text)
                   == root.indexOfItem(withTitle: L10n.frameRate.text) + 1, "Experimental menu order changed")
        try expect(!music.isEnabled && music.state == .off, "Music enabled before pet startup")
        try await waitFor("Pet startup did not finish") { music.isEnabled }
        try expect(status.title == L10n.musicStatus.format(L10n.musicOff.text), "Initial music status changed")
        try await waitFor("Initial keyboard listener missing") { try keyboardTapCount() == 1 }
        try invoke(sensitivity.item(withTitle: L10n.sensitivityHigh.text)!)
        try expect(PreferencesStore(defaults: defaults).rhythmSensitivity == .high, "Sensitivity action not persisted")
        var baselineFootprint: UInt64?
        var idleCPU = 0.0
        if performance {
            try invoke(sensitivity.item(withTitle: L10n.sensitivityStandard.text)!)
            let before = try processResources()
            let time = CACurrentMediaTime()
            print("PERFORMANCE: measuring 30-second keyboard-mode baseline")
            fflush(stdout)
            try await Task.sleep(for: .seconds(30))
            let after = try processResources()
            idleCPU = (after.cpu - before.cpu) / (CACurrentMediaTime() - time) * 100
            baselineFootprint = after.footprint
        }
        try invoke(music)
        try await waitFor("Music did not start") {
            status.title == L10n.musicStatus.format(L10n.musicWaiting.text)
                || status.title == L10n.musicStatus.format(L10n.musicResponding.text)
        }
        try expect(music.state == .on && (try keyboardTapCount()) == 0, "Music did not stop keyboard input")
        let ownedTaps = try audioObjects(kAudioHardwarePropertyTapList).subtracting(tapsBefore)
        try expect(ownedTaps.count == 1, "Music tap missing")
        if let baselineFootprint {
            try await measureMusicPerformance(baselineFootprint: baselineFootprint, idleCPU: idleCPU)
            try invoke(sensitivity.item(withTitle: L10n.sensitivityHigh.text)!)
        }
        let pets = root.item(withTitle: L10n.petMenu.text)!.submenu!
        try invoke(pets.item(withTitle: "second")!)
        try await waitFor("Pet switch did not commit") { PreferencesStore(defaults: defaults).currentPetID == "second" }
        try expect(try audioObjects(kAudioHardwarePropertyTapList).subtracting(tapsBefore) == ownedTaps,
                   "Pet switch rebuilt capture")
        let pause = root.item(withTitle: L10n.pause.text)!
        try invoke(pause)
        try expect(music.state == .on && status.title == L10n.musicStatus.format(L10n.musicPausedByUser.text),
                   "Pause lost music mode/status")
        try await waitFor("Pause retained audio tap") { try audioObjects(kAudioHardwarePropertyTapList) == tapsBefore }
        try invoke(pause)
        try await waitFor("Resume did not restart audio") { try audioObjects(kAudioHardwarePropertyTapList).count > tapsBefore.count }
        if !performance {
            let visibility = root.item(withTitle: L10n.hidePet.text)!
            try invoke(visibility)
            try expect(status.title == L10n.musicStatus.format(L10n.musicHidden.text), "Hide status missing")
            try await waitFor("Hide retained audio tap") { try audioObjects(kAudioHardwarePropertyTapList) == tapsBefore }
            try invoke(visibility)
            try await waitFor("Show did not restart audio") { try audioObjects(kAudioHardwarePropertyTapList).count > tapsBefore.count }
            for (stop, resume, reason) in [
                (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, L10n.musicSleeping),
                (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, L10n.musicScreenSleeping),
                (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, L10n.musicSessionInactive),
            ] {
                NSWorkspace.shared.notificationCenter.post(name: stop, object: nil)
                try expect(status.title == L10n.musicStatus.format(reason.text), "Lifecycle pause status missing")
                try await waitFor("Lifecycle pause retained tap") { try audioObjects(kAudioHardwarePropertyTapList) == tapsBefore }
                NSWorkspace.shared.notificationCenter.post(name: resume, object: nil)
                try await waitFor("Lifecycle resume did not restart tap") { try audioObjects(kAudioHardwarePropertyTapList).count > tapsBefore.count }
            }
        }
        try invoke(music)
        try await waitFor("Music off retained tap") { try audioObjects(kAudioHardwarePropertyTapList) == tapsBefore }
        try expect(music.state == .off && (try keyboardTapCount()) == 1, "Music off did not restore keyboard")
        try invoke(music)
        try await waitFor("Music restart missing") { try audioObjects(kAudioHardwarePropertyTapList).count > tapsBefore.count }
        controller!.applicationWillTerminate(termination)
        controller = AppController(defaults: defaults)
        let restartedRoot = try launch(controller!)
        let restartedExperimental = restartedRoot.item(withTitle: L10n.experimentalFeatures.text)!.submenu!
        try expect(restartedExperimental.item(withTitle: L10n.musicRhythm.text)!.state == .off,
                   "Music was restored after restart")
        let restartedSensitivity = restartedExperimental.item(withTitle: L10n.musicSensitivity.text)!.submenu!
        try expect(restartedSensitivity.item(withTitle: L10n.sensitivityHigh.text)!.state == .on,
                   "Sensitivity was lost after restart")
        print(performance ? "PASS: app menu, exclusive inputs, pet switch, pause/resume, termination, restart preferences"
              : "PASS: app menu, exclusive inputs, pet switch, pause/hide, simulated lifecycle, restart preferences")
    }
    #endif

    private static func audioObjects(_ selector: AudioObjectPropertySelector) throws -> Set<AudioObjectID> {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        try expect(status == noErr, "Unable to enumerate audio objects: \(status)")
        if size == 0 { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        status = objects.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        try expect(status == noErr, "Unable to read audio objects: \(status)")
        return Set(objects)
    }

    /// Opt-in only: starts system-audio capture from the signed check bundle.
    @MainActor
    private static func checkCapture(cycles: Int) async throws {
        let monitor = SystemAudioMonitor()
        defer { monitor.shutdown() }
        var pulseCount = 0
        monitor.onPulse = { _ in pulseCount += 1 }
        for cycle in 0..<cycles {
            let tapsBefore = try audioObjects(kAudioHardwarePropertyTapList)
            let devicesBefore = try audioObjects(kAudioHardwarePropertyDevices)
            monitor.start(sensitivity: .standard)
            for _ in 0..<600 where monitor.status == .starting {
                try await Task.sleep(for: .milliseconds(100))
            }
            if case .failed(let failure) = monitor.status {
                monitor.shutdown()
                throw CheckFailure(description: "Core Audio start failed: \(failure)")
            }
            try expect(monitor.status == .waiting || monitor.status == .responding,
                       "Capture did not finish starting; check the system permission prompt")
            let ownedTaps = try audioObjects(kAudioHardwarePropertyTapList).subtracting(tapsBefore)
            let ownedDevices = try audioObjects(kAudioHardwarePropertyDevices).subtracting(devicesBefore)
            try expect(ownedTaps.count == 1 && ownedDevices.count == 1, "Expected one tap and one aggregate")
            try await Task.sleep(for: .milliseconds(cycles == 1 ? 10_000 : 50))
            monitor.shutdown()
            var tapsAfter = try audioObjects(kAudioHardwarePropertyTapList)
            var devicesAfter = try audioObjects(kAudioHardwarePropertyDevices)
            // HAL documents aggregate destruction as asynchronous. Wait only
            // in verification for its object lists to reflect completed teardown.
            for _ in 0..<20 {
                if ownedTaps.isDisjoint(with: tapsAfter), ownedDevices.isDisjoint(with: devicesAfter) { break }
                try await Task.sleep(for: .milliseconds(50))
                tapsAfter = try audioObjects(kAudioHardwarePropertyTapList)
                devicesAfter = try audioObjects(kAudioHardwarePropertyDevices)
            }
            try expect(ownedTaps.isDisjoint(with: tapsAfter), "Tap leaked")
            try expect(ownedDevices.isDisjoint(with: devicesAfter), "Aggregate leaked")
            if (cycle + 1).isMultiple(of: 10) { print("Capture cycle \(cycle + 1)/\(cycles)") }
        }
        if cycles == 1 {
            try expect(pulseCount > 0, "No pulses captured. Play audio and check the check app's audio permission.")
        }
        print("PASS: \(cycles) capture cycles, \(pulseCount) pulses; no retained tap/aggregate")
    }
}
