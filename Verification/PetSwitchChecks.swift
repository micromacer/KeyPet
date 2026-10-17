import AppKit
import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

/// Holds only the test's background queue; the main actor remains runnable.
private struct QueueGate {
    private let entered = DispatchGroup()
    private let released = DispatchSemaphore(value: 0)

    init(on queue: DispatchQueue) {
        entered.enter()
        let entered = self.entered, released = self.released
        queue.async {
            entered.leave()
            guard released.wait(timeout: .now() + 10) == .success else {
                print("FAIL: Background queue gate timed out")
                exit(EXIT_FAILURE)
            }
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            entered.notify(queue: .main) { continuation.resume() }
        }
    }

    func open() { released.signal() }
}

@MainActor
private final class AppFixture {
    let cache = PetFrameCache()
    let queue = DispatchQueue(label: "keypet.pet-switch-checks")
    let defaults: UserDefaults
    let app: AppController
    let menu: NSMenu
    private let suite = "local.kenny.KeyPet.PetSwitchChecks.\(UUID().uuidString)"

    init(root: URL, preferred: String?) throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(try root.bookmarkData(options: []), forKey: "rootBookmark")
        defaults.set(preferred, forKey: "currentPetID")
        defaults.set(40.0, forKey: "petWidth")
        app = AppController(defaults: defaults, cache: cache, backgroundQueue: queue)
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let controller = app
        guard let rootMenu = NSApp.windows.compactMap({ $0.contentView?.menu }).first(where: {
            ($0.item(withTitle: L10n.pause.text)?.target as? AppController) === controller
        }) else { throw CheckFailure(description: "Pet menu was not created") }
        menu = rootMenu
        // Selection and warmup still run while paused, without listening to keys.
        try invoke(menu.item(withTitle: L10n.pause.text)!)
    }

    var pets: NSMenu { menu.item(withTitle: L10n.petMenu.text)!.submenu! }
    var selectedID: String? {
        pets.items.first { $0.state == .on }?.representedObject as? String
    }

    func select(_ id: String) throws {
        guard let item = pets.items.first(where: { ($0.representedObject as? String) == id }) else {
            throw CheckFailure(description: "Pet missing from menu: \(id)")
        }
        try invoke(item)
    }

    private func invoke(_ item: NSMenuItem) throws {
        try expect(NSApp.sendAction(item.action!, to: item.target, from: item), "Menu action failed")
    }

    func waitForSelection(_ id: String) async throws {
        try await PetSwitchChecks.waitFor("Pet did not commit: \(id)") {
            self.selectedID == id && self.cache.byteBudget == PetResourceLimits.imageCacheByteBudget
        }
        try expect(defaults.string(forKey: "currentPetID") == id, "Committed selection was not saved")
        try expect(cache.currentBytes > 0, "Committed pet has no warm frames")
    }

    func drainQueue() async {
        await withCheckedContinuation { continuation in
            queue.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func close() {
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        for window in NSApp.windows where window.contentView?.menu === menu { window.close() }
        defaults.removePersistentDomain(forName: suite)
    }
}

@main
@MainActor
struct PetSwitchChecks {
    static func main() {
        Task { @MainActor in
            do {
                try expect(KeyboardMonitor.permissionGranted,
                           "Pet switch checks require existing Input Monitoring permission")
                try await run()
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        NSApplication.shared.run()
    }

    static func waitFor(_ message: String, until condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CheckFailure(description: message)
    }

    private static func makePet(at directory: URL, png: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for token in ["idle", "left", "right"] {
            try png.write(to: directory.appendingPathComponent("pet-\(token).png"))
        }
    }

    private static func run() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyPet-switch-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 64, bitsPerPixel: 32)!
        let color = NSColor(deviceRed: 0.1, green: 0.4, blue: 0.9, alpha: 1)
        for x in 0..<16 { for y in 0..<16 { bitmap.setColor(color, atX: x, y: y) } }
        let png = bitmap.representation(using: .png, properties: [:])!
        let root = temporary.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A-empty"),
                                                withIntermediateDirectories: true)
        for id in ["B", "C", "D"] { try makePet(at: root.appendingPathComponent(id), png: png) }

        for (preferred, expected) in [(nil, "B"), ("A-empty", "B"), ("D", "D"), ("missing", "B")] as [(String?, String)] {
            let fixture = try AppFixture(root: root, preferred: preferred)
            defer { fixture.close() }
            try await fixture.waitForSelection(expected)
            try expect(fixture.pets.items.contains { ($0.representedObject as? String) == "A-empty" },
                       "Blocked directory disappeared from the menu")
        }
        print("PASS: initial selection skips blocked pets and restores usable preferences")

        let blockedRoot = temporary.appendingPathComponent("blocked")
        let repaired = blockedRoot.appendingPathComponent("A")
        try FileManager.default.createDirectory(at: repaired, withIntermediateDirectories: true)
        do {
            let fixture = try AppFixture(root: blockedRoot, preferred: "A")
            defer { fixture.close() }
            try await waitFor("Blocked pet was not indexed") {
                fixture.pets.items.contains { ($0.representedObject as? String) == "A" }
            }
            await fixture.drainQueue()
            try expect(fixture.selectedID == nil && fixture.cache.currentBytes == 0,
                       "All-blocked library started a pet")
            try expect(fixture.cache.byteBudget == PetResourceLimits.imageCacheByteBudget,
                       "All-blocked library raised the cache budget")
            try expect(fixture.defaults.string(forKey: "currentPetID") == "A", "Unavailable preference was overwritten")
            try makePet(at: repaired, png: png)
            fixture.app.setLibraryRoot(blockedRoot)
            try await fixture.waitForSelection("A")
        }
        print("PASS: all-blocked library stays idle and recovers after repair")

        do {
            let fixture = try AppFixture(root: root, preferred: "B")
            defer { fixture.close() }
            try await fixture.waitForSelection("B")
            let bytes = fixture.cache.currentBytes
            try makePet(at: root.appendingPathComponent("0-new"), png: png)
            fixture.app.setLibraryRoot(root)
            try await waitFor("Same-root rescan did not finish") {
                fixture.pets.items.contains { ($0.representedObject as? String) == "0-new" }
            }
            try expect(fixture.selectedID == "B" && fixture.cache.currentBytes == bytes,
                       "Same-root rescan changed the selected pet or cleared its cache")
        }
        print("PASS: same-root rescan preserves the current pet and cache")

        let emptyRoot = temporary.appendingPathComponent("empty")
        let newRoot = temporary.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        try makePet(at: newRoot.appendingPathComponent("new-pet"), png: png)
        for destination in [emptyRoot, newRoot] {
            let fixture = try AppFixture(root: root, preferred: "B")
            defer { fixture.close() }
            try await fixture.waitForSelection("B")
            let gate = QueueGate(on: fixture.queue)
            defer { gate.open() }
            await gate.waitUntilEntered()
            try fixture.select("C")
            try expect(fixture.cache.byteBudget == PetResourceLimits.transientCacheByteBudget,
                       "Switch did not enter its transient budget")
            fixture.app.setLibraryRoot(destination)
            try expect(fixture.cache.byteBudget == PetResourceLimits.imageCacheByteBudget,
                       "Root replacement did not immediately restore the cache budget")
            gate.open()
            await fixture.drainQueue()
            if destination == emptyRoot {
                try expect(fixture.cache.currentBytes == 0 && fixture.selectedID == nil,
                           "Stale warmup survived replacement with an empty root")
                try expect(fixture.defaults.string(forKey: "currentPetID") == "B",
                           "Stale switch overwrote the previous preference")
            } else {
                try await fixture.waitForSelection("new-pet")
            }
        }
        print("PASS: in-flight warmups cannot survive root replacement or erase a new pet")

        do {
            let fixture = try AppFixture(root: root, preferred: "B")
            defer { fixture.close() }
            try await fixture.waitForSelection("B")
            let first = QueueGate(on: fixture.queue)
            defer { first.open() }
            await first.waitUntilEntered()
            try fixture.select("C")
            let second = QueueGate(on: fixture.queue)
            defer { second.open() }
            try fixture.select("D")
            first.open()
            await second.waitUntilEntered()
            try expect(fixture.selectedID == "B", "Superseded switch committed")
            try expect(fixture.cache.byteBudget == PetResourceLimits.transientCacheByteBudget,
                       "Stale completion reduced the newer switch's budget")
            second.open()
            try await fixture.waitForSelection("D")
        }
        print("PASS: superseded switch preserves the newest request and transient budget")
    }
}
