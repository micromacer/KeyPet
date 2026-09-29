import CoreServices
import Foundation

/// Indexes the user-chosen asset root: each direct subdirectory is one pet
/// (directory name doubles as pet id and menu name), and every file matching
/// `pet-<name>.(png|apng)` (case-insensitive) maps to a normalized lowercase
/// `[a-z0-9]` token. Scanning runs on the serial `keypet.pet-library-scan`
/// queue and is committed on the main actor only while its generation is
/// still current; hot import is a single recursive FSEvents stream on the
/// root tree that funnels into the debounced `requestRescan()`. The library
/// only stats files — it never reads pixels, copies, or rewrites user assets.
@MainActor
final class PetLibrary {
    private static let rootBookmarkKey = "rootBookmark"
    private static let rescanDebounce: Duration = .milliseconds(400)

    private let defaults: UserDefaults
    /// The app's one background serial queue, shared with image decoding.
    private let scanQueue: DispatchQueue

    /// Bumped on every scan start and on stop; stale background results never commit.
    private var generation: UInt64 = 0
    private var rescanTask: Task<Void, Never>?
    private var eventStream: FSEventStreamRef?

    private(set) var rootURL: URL?
    private(set) var pets: [PetDescriptor] = []
    private(set) var issues: [String: [PetIssue]] = [:]
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard, scanQueue: DispatchQueue? = nil) {
        self.defaults = defaults
        self.scanQueue = scanQueue ?? DispatchQueue(label: "keypet.pet-library-scan")
    }

    // MARK: - Root selection

    /// Resolves the saved plain bookmark, verifies the directory is readable,
    /// then restores the root and starts watching + scanning. A stale bookmark
    /// is rebuilt in place. On failure the current root is cleared and `false`
    /// is returned; the stored bookmark is kept since the volume may return.
    @discardableResult
    func restoreRoot() -> Bool {
        guard let data = defaults.data(forKey: Self.rootBookmarkKey) else { return false }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            clearRoot()
            return false
        }
        let path = url.path(percentEncoded: false)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: path) else {
            clearRoot()
            return false
        }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: Self.rootBookmarkKey)
        }
        activate(root: url.standardizedFileURL)
        return true
    }

    /// Persists a plain (non-security-scoped) bookmark for the new root, moves
    /// the FSEvents stream onto its tree and scans immediately.
    func setRoot(_ url: URL) {
        let root = url.standardizedFileURL
        if let data = try? root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: Self.rootBookmarkKey)
        }
        if rootURL?.path(percentEncoded: false) == root.path(percentEncoded: false) {
            requestRescan()
            return
        }
        activate(root: root)
    }

    private func activate(root: URL) {
        rootURL = root
        pets = []
        issues = [:]
        onChange?()
        startWatching(root: root)
        startScan()
    }

    private func clearRoot() {
        rescanTask?.cancel()
        rescanTask = nil
        generation &+= 1
        stopWatching()
        let hadState = rootURL != nil || !pets.isEmpty || !issues.isEmpty
        rootURL = nil
        pets = []
        issues = [:]
        if hadState { onChange?() }
    }

    // MARK: - Scanning

    /// Manual rescan and menu-open recheck entry point. Calls within the
    /// debounce window coalesce into a single scan; there is no periodic timer.
    func requestRescan() {
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(for: Self.rescanDebounce)
            guard !Task.isCancelled else { return }
            self?.startScan()
        }
    }

    private func startScan() {
        guard let root = rootURL else {
            generation &+= 1
            commit(ScanResult(pets: [], issues: [:]))
            return
        }
        generation &+= 1
        let expected = generation
        let queue = scanQueue
        // The scan closure is short-lived and released after one run, so an
        // explicit strong capture here is cycle-free; only the main-actor
        // commit holds `self` weakly to respect `stop()`.
        queue.async { [self] in
            let result = PetLibrary.scan(root: root)
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                self.commit(result)
            }
        }
    }

    private func commit(_ result: ScanResult) {
        guard !Self.petsEqual(pets, result.pets) || !Self.issuesEqual(issues, result.issues) else { return }
        pets = result.pets
        issues = result.issues
        onChange?()
    }

    /// Stops the FSEvents stream and drops any in-flight scan result.
    /// Must be called before the library is released (the stream callback
    /// bridges `self` unretained, so the stream may not outlive the library).
    func stop() {
        rescanTask?.cancel()
        rescanTask = nil
        generation &+= 1
        stopWatching()
    }

    // MARK: - FSEvents

    private func startWatching(root: URL) {
        stopWatching()
        var context = FSEventStreamContext()
        // Unretained bridge: the stream is owned by `self` and is always
        // stopped + invalidated before release (see `stopWatching`), after
        // which no callback is delivered — so `self` outlives every callback.
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let paths = [root.path(percentEncoded: false)] as CFArray
        // FileEvents: recursive per-file events, so changes inside pet
        // subdirectories are reported; UseCFTypes: CFArray payload.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            nil,
            petLibraryFSEventsCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, scanQueue)
        _ = FSEventStreamStart(stream)
        eventStream = stream
    }

    private func stopWatching() {
        guard let stream = eventStream else { return }
        eventStream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    // MARK: - Change detection

    private static func petsEqual(_ lhs: [PetDescriptor], _ rhs: [PetDescriptor]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (l, r) in zip(lhs, rhs) {
            guard l.id == r.id, l.directoryURL == r.directoryURL, l.assets == r.assets else { return false }
        }
        return true
    }

    private static func issuesEqual(_ lhs: [String: [PetIssue]], _ rhs: [String: [PetIssue]]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (key, lIssues) in lhs {
            guard let rIssues = rhs[key], lIssues.count == rIssues.count else { return false }
            for (l, r) in zip(lIssues, rIssues) {
                // PetIssue is not Equatable; the reflection rendering is
                // deterministic for identical payloads and suffices as a
                // change-detection fingerprint.
                guard String(describing: l) == String(describing: r) else { return false }
            }
        }
        return true
    }

    // MARK: - Background scan (nonisolated, runs on `scanQueue`)

    private struct ScanResult: Sendable {
        let pets: [PetDescriptor]
        let issues: [String: [PetIssue]]
    }

    private nonisolated static func scan(root: URL) -> ScanResult {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isReadableKey]
        // A root that is missing or unreadable at scan time scans as empty —
        // an empty root is a normal state, not an error.
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return ScanResult(pets: [], issues: [:])
        }
        var pets: [PetDescriptor] = []
        var issues: [String: [PetIssue]] = [:]
        for directory in children where (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let (descriptor, petIssues) = scanPet(directory: directory, keys: keys, fileManager: fileManager)
            pets.append(descriptor)
            if !petIssues.isEmpty { issues[descriptor.id] = petIssues }
        }
        pets.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        return ScanResult(pets: pets, issues: issues)
    }

    private nonisolated static func scanPet(
        directory: URL,
        keys: [URLResourceKey],
        fileManager: FileManager
    ) -> (PetDescriptor, [PetIssue]) {
        let id = directory.lastPathComponent
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return (PetDescriptor(id: id, directoryURL: directory, assets: [:]), [.unreadableDirectory])
        }
        struct Candidate {
            let name: String
            let url: URL
            let size: UInt64
            let mtime: Date?
            let readable: Bool
        }
        var candidates: [String: [Candidate]] = [:]
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let token = assetToken(forFileName: name) else { continue }
            let size = UInt64(max(0, values.fileSize ?? 0))
            let readable = values.isReadable ?? fileManager.isReadableFile(atPath: file.path(percentEncoded: false))
            candidates[token, default: []].append(
                Candidate(name: name, url: file, size: size, mtime: values.contentModificationDate, readable: readable)
            )
        }
        var assets: [String: PetAsset] = [:]
        var readableTokens = Set<String>()
        var petIssues: [PetIssue] = []
        for token in candidates.keys.sorted() {
            let group = candidates[token] ?? []
            // A normalized-token conflict never silently picks one file by
            // traversal order: the token stays unmapped and both names surface.
            if group.count > 1 {
                petIssues.append(.tokenConflict(token: token, files: group.map(\.name).sorted()))
                continue
            }
            guard let only = group.first else { continue }
            assets[token] = PetAsset(
                token: token,
                fileURL: only.url,
                fileSize: only.size,
                resourceVersion: resourceVersion(path: only.url.path(percentEncoded: false), fileSize: only.size, mtime: only.mtime)
            )
            if only.readable { readableTokens.insert(token) }
        }
        let oversized = candidates.values.flatMap { $0 }
            .filter { $0.size > UInt64(PetResourceLimits.maxFileBytes) }
            .map(\.name)
            .sorted()
        petIssues.append(contentsOf: oversized.map { PetIssue.oversizedFile(name: $0) })
        if assets["idle"] == nil || !readableTokens.contains("idle") {
            petIssues.append(.missingIdle)
        }
        if assets["left"] == nil || assets["right"] == nil {
            petIssues.append(.missingActionImages)
        }
        return (PetDescriptor(id: id, directoryURL: directory, assets: assets), petIssues)
    }

    /// Matches `^pet-(.+)\.(png|apng)$` case-insensitively and normalizes the
    /// capture: lowercased, non-`[a-z0-9]` removed. Returns nil for non-pet
    /// files and for captures that normalize to the empty token.
    private nonisolated static func assetToken(forFileName name: String) -> String? {
        let lower = name.lowercased()
        guard lower.hasPrefix("pet-") else { return nil }
        let extensionLength: Int
        if lower.hasSuffix(".apng") {
            extensionLength = 5
        } else if lower.hasSuffix(".png") {
            extensionLength = 4
        } else {
            return nil
        }
        let core = name.dropFirst(4).dropLast(extensionLength)
        guard !core.isEmpty else { return nil }
        var token = ""
        token.reserveCapacity(core.count)
        for scalar in core.lowercased().unicodeScalars where (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
            token.unicodeScalars.append(scalar)
        }
        return token.isEmpty ? nil : token
    }

    /// FNV-1a over path bytes + file size + mtime (µs): replacing a file
    /// changes size and/or mtime, hence the resource version.
    private nonisolated static func resourceVersion(path: String, fileSize: UInt64, mtime: Date?) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        hash ^= fileSize
        hash &*= 0x100000001b3
        let micros = UInt64(bitPattern: Int64((mtime?.timeIntervalSince1970 ?? 0) * 1_000_000))
        hash ^= micros
        hash &*= 0x100000001b3
        return hash
    }
}

/// FSEvents C callback, delivered on the serial `keypet.pet-library-scan`
/// queue via FSEventStreamSetDispatchQueue. The event payload is never read —
/// any change under the root funnels into the debounced `requestRescan()`.
///
/// Concurrency notes: `info` bridges the owning PetLibrary with
/// `Unmanaged.passUnretained` (the stream is stopped and invalidated before
/// release, so no callback can outlive the library); the hop to the main
/// actor uses a weak capture so a queued task never extends the library's
/// lifetime past `stop()`.
private func petLibraryFSEventsCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let library = Unmanaged<PetLibrary>.fromOpaque(info).takeUnretainedValue()
    Task { @MainActor [weak library] in
        library?.requestRescan()
    }
}
