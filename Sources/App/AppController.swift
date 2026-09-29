import AppKit
import QuartzCore

/// Single coordination point: menu, preferences, pet switching, keyboard
/// wiring and the unified activity lifecycle.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let preferences: PreferencesStore
    private let permissionController = InputPermissionController()
    private var startupCompleted = false
    private let lifecycle = LifecycleController()
    private let monitor = KeyboardMonitor()
    private let stateMachine = PetInputStateMachine()
    private let cache = PetFrameCache()
    private let renderer = PetRenderer()
    /// File scanning and image decoding share one background serial queue.
    private let backgroundQueue = DispatchQueue(label: "keypet.background")
    private let library: PetLibrary
    private var windowController: PetWindowController!
    private var playback: PetPlaybackController!
    private var statusItem: NSStatusItem?
    private var menuItems: [String: NSMenuItem] = [:]
    private var petSubmenu: NSMenu?
    private var frameRateItems: [NSMenuItem] = []
    private var languageItems: [NSMenuItem] = []
    /// Languages shipped in the bundle; menu labels stay in their own language.
    private static let supportedLanguages = ["en", "ja", "zh-Hant", "zh-Hans"]
    private static let languageNames = ["en": "English", "ja": "日本語", "zh-Hant": "繁體中文", "zh-Hans": "简体中文"]
    private var sizeView: MenuSliderView?
    private var opacityView: MenuSliderView?
    private var resetDelayView: MenuSliderView?
    private var pendingResetDelayMs: Int = 0
    private var shadowRadiusView: MenuSliderView?
    private var shadowOpacityView: MenuSliderView?
    private var pendingShadowRadius = PreferencesStore.defaultShadowRadius
    private var pendingShadowOpacity = PreferencesStore.defaultShadowOpacity
    private var currentPet: PetDescriptor?
    private var switchGeneration: UInt64 = 0
    /// The current pet's files went missing or unreadable: keep the last valid
    /// frame on screen, stop reacting, and say so in the menu.
    private var degraded = false
    private var statusText: String?
    private var active = false

    init(defaults: UserDefaults = .standard) {
        preferences = PreferencesStore(defaults: defaults)
        library = PetLibrary(defaults: defaults, scanQueue: backgroundQueue)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        renderer.mirrored = preferences.flipHorizontal
        windowController = PetWindowController(renderer: renderer, preferences: preferences)
        playback = PetPlaybackController(cache: cache, hostView: windowController.petView, decodeQueue: backgroundQueue)
        playback.bounceEnabled = preferences.bounceEnabled
        playback.frameRate = preferences.frameRate
        playback.onPresent = { [weak renderer] image, mask in renderer?.display(image, mask: mask) }
        playback.onBounceTransform = { [weak renderer] x, y in renderer?.setBounce(scaleX: x, scaleY: y) }
        playback.onDecodeFailure = { [weak self] _ in self?.enterDegraded(reason: L10n.currentAssetUnreadable.text) }
        windowController.onLayoutChanged = { [weak self] in self?.updateDecodeTarget() }
        windowController.onVisibilityChanged = { [weak self] in self?.updateActivity() }
        stateMachine.resetDelay = Double(preferences.resetDelayMs) / 1000
        stateMachine.swapSides = preferences.swapSides
        stateMachine.tokenAvailable = { $0 == "idle" }
        stateMachine.onSelection = { [weak self] selection in self?.playback.show(selection) }
        stateMachine.onBounce = { [weak self] in self?.playback.triggerBounce() }
        monitor.onEvent = { [weak self] event in
            guard let self, self.active else { return }
            self.stateMachine.handle(event)
        }
        monitor.onReset = { [weak self] in
            self?.stateMachine.reset()
            self?.playback.showIdle()
        }
        monitor.onStatusChange = { [weak self] _ in self?.refreshMenu() }
        lifecycle.onChange = { [weak self] in self?.updateActivity() }
        library.onChange = { [weak self] in self?.libraryChanged() }
        buildMenu()
        applyShadow()
        windowController.window?.orderFrontRegardless()
        windowController.petView.menu = statusItem?.menu
        playback.setActive(false)
        continueStartup()
    }

    // MARK: - Activity lifecycle

    private func updateActivity() {
        let shouldBeActive = lifecycle.allowsActivity && windowController.isActuallyVisible
            && currentPet != nil && !degraded
        guard shouldBeActive != active else { return }
        active = shouldBeActive
        if active {
            monitor.start()
            playback.setActive(true)
        } else {
            monitor.stop()
            stateMachine.reset()
            playback.setActive(false)
        }
    }

    private func updateDecodeTarget() {
        playback.updateTarget(pixels: windowController.drawPixelSize)
    }

    /// Sliders preview live through the pending values; persistence waits for
    /// the menu to close, same as the size/opacity sliders.
    private func applyShadow() {
        windowController.applyShadow(enabled: preferences.shadowEnabled,
                                     radius: pendingShadowRadius, opacity: pendingShadowOpacity)
    }

    // MARK: - Pet library and switching

    private func libraryChanged() {
        rebuildPetSubmenu()
        guard library.rootURL != nil else { currentPet = nil; refreshMenu(); return }
        if let current = currentPet {
            if let updated = library.pets.first(where: { $0.id == current.id }), !isBlocking(id: current.id) {
                if degraded || updated.assets != current.assets {
                    switchPet(to: current.id)
                }
            } else {
                enterDegraded(reason: L10n.petUnavailable.format(current.id))
            }
        } else if !library.pets.isEmpty {
            // First valid selection: restore the last choice, else the first
            // pet in sorted order.
            let restored = preferences.currentPetID.flatMap { id in library.pets.first(where: { $0.id == id }) }
            switchPet(to: (restored ?? library.pets[0]).id)
        }
        refreshMenu()
    }

    private func isBlocking(id: String) -> Bool {
        (library.issues[id] ?? []).contains {
            if case .missingIdle = $0 { return true }
            if case .unreadableDirectory = $0 { return true }
            return false
        }
    }

    private func switchPet(to id: String, onFailure: (@MainActor @Sendable (String) -> Void)? = nil) {
        guard let pet = library.pets.first(where: { $0.id == id }) else { return }
        if isBlocking(id: id) {
            handleSwitchFailure(name: id, reason: L10n.missingReadableIdle.text)
            onFailure?(L10n.missingReadableIdle.text)
            return
        }
        switchGeneration &+= 1
        let gen = switchGeneration
        let previousAssets = Set(currentPet.map { Array($0.assets.values) } ?? [])
        let pixelWidth = windowController.currentWidth * (windowController.window?.backingScaleFactor ?? 2)
        cache.byteBudget = PetResourceLimits.transientCacheByteBudget
        backgroundQueue.async { [weak self] in
            // Validate every file's header against the resource budget, then
            // warm the common first frames, before anything is committed.
            var metas: [String: AnimationMetadata] = [:]
            var failure: String?
            for asset in pet.assets.values {
                do {
                    metas[asset.token] = try PetAssetDecoder.metadata(asset: asset)
                } catch let error as PetDecodeError {
                    failure = L10n.fileError.format(asset.fileURL.lastPathComponent, Self.describe(error))
                    break
                } catch {
                    failure = L10n.fileError.format(asset.fileURL.lastPathComponent, L10n.unreadableFile.text)
                    break
                }
            }
            if failure == nil, let idle = metas["idle"] {
                let target = CGSize(width: pixelWidth, height: pixelWidth * idle.canvasPixels.height / idle.canvasPixels.width)
                for token in ["idle", "left", "right"] {
                    guard let asset = pet.assets[token], let meta = metas[token] else { continue }
                    do {
                        let frame = try PetAssetDecoder.prepareFrame(asset: asset, index: 0, targetPixelSize: target)
                        let limit = PetAssetDecoder.pixelLimit(canvas: meta.canvasPixels, target: target)
                        self?.cache.store(frame, asset: asset, index: 0, pixelLimit: limit)
                    } catch {
                        failure = L10n.fileError.format(asset.fileURL.lastPathComponent, Self.describe((error as? PetDecodeError) ?? .corruptImage))
                        break
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.switchGeneration else { return }
                self.cache.byteBudget = PetResourceLimits.imageCacheByteBudget
                guard self.library.pets.contains(where: { $0.directoryURL == pet.directoryURL && $0.assets == pet.assets }) else {
                    self.cache.removeAll(except: previousAssets)
                    return
                }
                if let failure {
                    // The old pet stays on screen; its frames stay cached.
                    self.cache.removeAll(except: previousAssets)
                    self.handleSwitchFailure(name: pet.id, reason: failure)
                    onFailure?(failure)
                    return
                }
                self.commitSwitch(pet: pet, metas: metas)
            }
        }
    }

    private func commitSwitch(pet: PetDescriptor, metas: [String: AnimationMetadata]) {
        currentPet = pet
        degraded = false
        statusText = nil
        preferences.currentPetID = pet.id
        stateMachine.reset()
        stateMachine.tokenAvailable = { token in pet.assets[token] != nil || token == "idle" }
        playback.setPet(pet, seeding: metas)
        if let idle = metas["idle"] { renderer.setIdleCanvas(idle.canvasPixels) }
        windowController.applyPetGeometry()
        updateDecodeTarget()
        cache.removeAll(except: Set(pet.assets.values))
        playback.showIdle()
        updateActivity()
        refreshMenu()
    }

    private func handleSwitchFailure(name: String, reason: String) {
        statusText = L10n.switchFailureStatus.format(name, reason)
        refreshMenu()
    }

    private func presentSwitchFailure(name: String, reason: String) {
        let alert = NSAlert()
        alert.icon = Bundle.main.image(forResource: "KeyPet")
        alert.messageText = L10n.switchFailureTitle.format(name)
        alert.informativeText = L10n.switchFailureMessage.format(reason)
        alert.addButton(withTitle: L10n.ok.text)
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func enterDegraded(reason: String) {
        degraded = true
        statusText = L10n.pausedStatus.format(reason)
        stateMachine.reset()
        updateActivity()
        refreshMenu()
        library.requestRescan()
    }

    /// Pure rendering of an error for display; `nonisolated` because switch
    /// validation reports from the background queue.
    private nonisolated static func describe(_ error: PetDecodeError) -> String {
        switch error {
        case .fileTooLarge: return L10n.fileTooLarge.text
        case .canvasTooLarge: return L10n.canvasTooLarge.text
        case .tooManyFrames: return L10n.tooManyFrames.text
        case .notPNG: return L10n.notPNG.text
        case .unreadableFile: return L10n.unreadableFile.text
        case .corruptImage: return L10n.corruptImage.text
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(named: "StatusBarIcon")?.copy() as? NSImage {
            image.size = NSSize(width: 22, height: 18)
            image.isTemplate = true
            image.accessibilityDescription = "KeyPet"
            item.button?.image = image
        } else {
            item.button?.title = "KeyPet"
        }
        item.button?.setAccessibilityLabel("KeyPet")
        item.button?.toolTip = "KeyPet"
        let menu = NSMenu(); menu.delegate = self
        let title = NSMenuItem(title: "KeyPet", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title); menu.addItem(.separator())
        let petItem = NSMenuItem(title: L10n.petMenu.text, action: nil, keyEquivalent: "")
        let petMenu = NSMenu()
        petItem.submenu = petMenu
        petSubmenu = petMenu
        menu.addItem(petItem)
        add("visibility", L10n.hidePet.text, #selector(toggleVisibility), to: menu)
        add("pause", L10n.pause.text, #selector(togglePause), to: menu)
        menu.addItem(.separator())
        let sizeControl = MenuSliderView(title: L10n.size.text, value: preferences.width,
                                         range: PreferencesStore.minimumWidth...PreferencesStore.maximumWidth,
                                         format: { L10n.points.format(Int($0.rounded())) })
        sizeControl.onChange = { [weak self] width in
            self?.windowController.previewWidth(width)
        }
        let sizeItem = NSMenuItem(); sizeItem.view = sizeControl; menu.addItem(sizeItem)
        sizeView = sizeControl
        let opacityControl = MenuSliderView(title: L10n.opacity.text, value: preferences.opacity,
                                            range: PreferencesStore.minimumOpacity...1,
                                            format: { L10n.percentage.format(Int(($0 * 100).rounded())) })
        opacityControl.onChange = { [weak self] in self?.windowController.setOpacity($0) }
        let opacityItem = NSMenuItem(); opacityItem.view = opacityControl; menu.addItem(opacityItem)
        opacityView = opacityControl
        pendingShadowRadius = preferences.shadowRadius
        pendingShadowOpacity = preferences.shadowOpacity
        pendingResetDelayMs = preferences.resetDelayMs
        let resetControl = MenuSliderView(title: L10n.resetDelay.text, value: Double(pendingResetDelayMs),
                                          range: Double(PreferencesStore.minimumResetDelayMs)...Double(PreferencesStore.maximumResetDelayMs),
                                          format: { L10n.milliseconds.format(Int($0.rounded())) })
        resetControl.onChange = { [weak self] value in
            let ms = Int(value.rounded())
            self?.pendingResetDelayMs = ms
            self?.stateMachine.resetDelay = Double(ms) / 1000
        }
        let resetItem = NSMenuItem(); resetItem.view = resetControl; menu.addItem(resetItem)
        resetDelayView = resetControl
        menu.addItem(.separator())
        // Shadow options live in their own separated section: the toggle
        // followed by its two sliders.
        add("shadow", L10n.shadow.text, #selector(toggleShadow), to: menu)
        let shadowRadiusControl = MenuSliderView(title: L10n.shadowBlur.text, value: pendingShadowRadius,
                                                 range: 0...PreferencesStore.maximumShadowRadius,
                                                 format: { L10n.points.format(Int($0.rounded())) })
        shadowRadiusControl.onChange = { [weak self] value in
            self?.pendingShadowRadius = value
            self?.applyShadow()
        }
        let shadowRadiusItem = NSMenuItem(); shadowRadiusItem.view = shadowRadiusControl; menu.addItem(shadowRadiusItem)
        shadowRadiusView = shadowRadiusControl
        let shadowOpacityControl = MenuSliderView(title: L10n.shadowOpacity.text, value: pendingShadowOpacity,
                                                  range: PreferencesStore.minimumShadowOpacity...1,
                                                  format: { L10n.percentage.format(Int(($0 * 100).rounded())) })
        shadowOpacityControl.onChange = { [weak self] value in
            self?.pendingShadowOpacity = value
            self?.applyShadow()
        }
        let shadowOpacityItem = NSMenuItem(); shadowOpacityItem.view = shadowOpacityControl; menu.addItem(shadowOpacityItem)
        shadowOpacityView = shadowOpacityControl
        menu.addItem(.separator())
        add("flip", L10n.flip.text, #selector(toggleFlip), to: menu)
        add("swap", L10n.swap.text, #selector(toggleSwap), to: menu)
        add("bounce", L10n.bounce.text, #selector(toggleBounce), to: menu)
        let rateItem = NSMenuItem(title: L10n.frameRate.text, action: nil, keyEquivalent: "")
        let rateMenu = NSMenu()
        for fps in [60, 30] {
            let choice = NSMenuItem(title: L10n.framesPerSecond.format(fps), action: #selector(changeFrameRate(_:)), keyEquivalent: "")
            choice.target = self; choice.tag = fps; rateMenu.addItem(choice); frameRateItems.append(choice)
        }
        rateItem.submenu = rateMenu; menu.addItem(rateItem)
        menu.addItem(.separator())
        add("top", L10n.alwaysOnTop.text, #selector(toggleTop), to: menu)
        add("through", L10n.clickThrough.text, #selector(toggleThrough), to: menu)
        add("reset", L10n.resetPosition.text, #selector(resetPosition), to: menu)
        add("defaults", L10n.restoreDefaultsMenu.text, #selector(restoreDefaults), to: menu)
        menu.addItem(.separator())
        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        status.isEnabled = false; status.isHidden = true; menuItems["status"] = status; menu.addItem(status)
        // The keyboard entry surfaces only when something is wrong (not
        // authorized or tap failed); a working listener needs no menu row.
        add("keyboardAction", L10n.allowKeyboard.text, #selector(keyboardAccess), to: menu)
        menu.addItem(.separator())
        let languageItem = NSMenuItem(title: L10n.languageMenu.text, action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        let followSystem = NSMenuItem(title: L10n.followSystem.text, action: #selector(selectLanguage(_:)), keyEquivalent: "")
        followSystem.target = self
        languageMenu.addItem(followSystem); languageItems.append(followSystem)
        languageMenu.addItem(.separator())
        for code in Self.supportedLanguages {
            let choice = NSMenuItem(title: Self.languageNames[code] ?? code, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = code
            languageMenu.addItem(choice); languageItems.append(choice)
        }
        languageItem.submenu = languageMenu; menu.addItem(languageItem)
        add("about", L10n.aboutMenu.text, #selector(about), to: menu)
        add("quit", L10n.quit.text, #selector(quit), to: menu)
        item.menu = menu; statusItem = item
        rebuildPetSubmenu()
        refreshMenu()
    }

    private func add(_ key: String, _ title: String, _ action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menuItems[key] = item; menu.addItem(item)
    }

    private func rebuildPetSubmenu() {
        guard let petSubmenu else { return }
        petSubmenu.removeAllItems()
        if library.pets.isEmpty {
            let empty = NSMenuItem(title: L10n.noPets.text, action: nil, keyEquivalent: "")
            empty.isEnabled = false; petSubmenu.addItem(empty)
        } else {
            for pet in library.pets {
                let item = NSMenuItem(title: pet.id, action: #selector(selectPet(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = pet.id
                item.state = pet.id == currentPet?.id ? .on : .off
                petSubmenu.addItem(item)
                for issue in library.issues[pet.id] ?? [] {
                    let note = NSMenuItem(title: Self.describe(issue), action: nil, keyEquivalent: "")
                    note.isEnabled = false
                    note.indentationLevel = 1
                    petSubmenu.addItem(note)
                }
            }
        }
        petSubmenu.addItem(.separator())
        let choose = NSMenuItem(title: L10n.chooseRoot.text, action: #selector(chooseRoot), keyEquivalent: "")
        choose.target = self; petSubmenu.addItem(choose)
        let reveal = NSMenuItem(title: L10n.revealRoot.text, action: #selector(openRootInFinder), keyEquivalent: "")
        reveal.target = self; reveal.isEnabled = library.rootURL != nil; petSubmenu.addItem(reveal)
        let rescan = NSMenuItem(title: L10n.rescan.text, action: #selector(rescan), keyEquivalent: "")
        rescan.target = self; rescan.isEnabled = library.rootURL != nil; petSubmenu.addItem(rescan)
    }

    private static func describe(_ issue: PetIssue) -> String {
        switch issue {
        case .unreadableDirectory: return L10n.unreadableDirectory.text
        case .missingIdle: return L10n.missingIdle.text
        case .missingActionImages: return L10n.missingActions.text
        case .tokenConflict(let token, let files): return L10n.tokenConflict.format(token, files.joined(separator: L10n.listSeparator.text))
        case .oversizedFile(let name): return L10n.oversizedFile.format(name)
        case .oversizedCanvas(let name): return L10n.oversizedCanvas.format(name)
        case .tooManyFrames(let name): return L10n.excessiveFrames.format(name)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
        // FSEvents can lag on external or network volumes; opening the menu is
        // a natural moment to double-check.
        library.requestRescan()
    }
    func menuDidClose(_ menu: NSMenu) {
        windowController.saveOpacity()
        windowController.saveGeometry()
        preferences.resetDelayMs = pendingResetDelayMs
        preferences.shadowRadius = pendingShadowRadius
        preferences.shadowOpacity = pendingShadowOpacity
    }

    private func refreshMenu() {
        menuItems["visibility"]?.title = lifecycle.hidden ? L10n.showPet.text : L10n.hidePet.text
        menuItems["pause"]?.title = lifecycle.paused ? L10n.resume.text : L10n.pause.text
        menuItems["flip"]?.state = preferences.flipHorizontal ? .on : .off
        menuItems["swap"]?.state = preferences.swapSides ? .on : .off
        menuItems["bounce"]?.state = preferences.bounceEnabled ? .on : .off
        menuItems["shadow"]?.state = preferences.shadowEnabled ? .on : .off
        menuItems["top"]?.state = preferences.alwaysOnTop ? .on : .off
        menuItems["through"]?.state = preferences.clickThrough ? .on : .off
        for item in frameRateItems { item.state = item.tag == preferences.frameRate ? .on : .off }
        let pendingLanguage = storedLanguageCode()
        for item in languageItems { item.state = (item.representedObject as? String) == pendingLanguage ? .on : .off }
        sizeView?.update(value: windowController?.currentWidth ?? preferences.width)
        opacityView?.update(value: Double(windowController?.window?.alphaValue ?? 1))
        resetDelayView?.update(value: Double(pendingResetDelayMs))
        shadowRadiusView?.update(value: pendingShadowRadius)
        shadowOpacityView?.update(value: pendingShadowOpacity)
        if let statusText {
            menuItems["status"]?.title = statusText
            menuItems["status"]?.isHidden = false
        } else {
            menuItems["status"]?.isHidden = true
        }
        let granted = KeyboardMonitor.permissionGranted
        switch monitor.status {
        case .listening:
            menuItems["keyboardAction"]?.isHidden = true
        case .failed:
            menuItems["keyboardAction"]?.isHidden = false
            menuItems["keyboardAction"]?.title = L10n.retryKeyboard.text
        case .unauthorized:
            menuItems["keyboardAction"]?.isHidden = false
            menuItems["keyboardAction"]?.title = granted ? L10n.enableKeyboard.text : L10n.allowKeyboard.text
        }
        rebuildPetSubmenuCheckmarks()
    }

    private func rebuildPetSubmenuCheckmarks() {
        for item in petSubmenu?.items ?? [] {
            guard let id = item.representedObject as? String else { continue }
            item.state = id == currentPet?.id ? .on : .off
        }
    }

    // MARK: - Menu actions

    @objc private func toggleVisibility() {
        if lifecycle.hidden {
            lifecycle.hidden = false
            windowController.window?.orderFrontRegardless()
            updateActivity()
        } else {
            lifecycle.hidden = true
            windowController.window?.orderOut(nil)
        }
    }
    @objc private func togglePause() { lifecycle.paused.toggle() }
    @objc private func toggleFlip() {
        preferences.flipHorizontal.toggle()
        renderer.mirrored = preferences.flipHorizontal
        refreshMenu()
    }
    @objc private func toggleSwap() {
        preferences.swapSides.toggle()
        stateMachine.swapSides = preferences.swapSides
        // Held keys keep their press-time resolution, so a mid-hold toggle
        // would be ambiguous; clear them instead.
        stateMachine.reset()
        playback.showIdle()
        refreshMenu()
    }
    @objc private func toggleBounce() {
        preferences.bounceEnabled.toggle()
        playback.bounceEnabled = preferences.bounceEnabled
        refreshMenu()
    }
    @objc private func toggleShadow() {
        preferences.shadowEnabled.toggle()
        applyShadow()
        // Menu actions may run after menuDidClose; commit toggle geometry here.
        windowController.saveGeometry()
        refreshMenu()
    }
    @objc private func changeFrameRate(_ sender: NSMenuItem) {
        preferences.frameRate = sender.tag
        playback.frameRate = sender.tag
        refreshMenu()
    }
    /// The pending selection lives in AppleLanguages, the same per-app
    /// override System Settings writes. It is read from the application
    /// domain only, so a launch-time -AppleLanguages argument does not
    /// masquerade as a stored selection.
    private func storedLanguageCode() -> String? {
        guard let domain = Bundle.main.bundleIdentifier,
              let stored = (UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String])?.first
        else { return nil }
        return Bundle.preferredLocalizations(from: Self.supportedLanguages, forPreferences: [stored]).first
    }
    /// Stores the choice and reports whether it differs from the language
    /// this process is running in, i.e. whether a restart would change the UI.
    @discardableResult
    private func applyLanguageSelection(_ code: String?) -> Bool {
        guard code != storedLanguageCode() else { return false }
        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        let running = Bundle.main.preferredLocalizations.first ?? "en"
        let next = code ?? Bundle.preferredLocalizations(from: Self.supportedLanguages,
                                                         forPreferences: Locale.preferredLanguages).first ?? "en"
        refreshMenu()
        return next != running
    }
    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard applyLanguageSelection(sender.representedObject as? String) else { return }
        let alert = NSAlert()
        alert.icon = Bundle.main.image(forResource: "KeyPet")
        alert.messageText = L10n.restartTitle.text
        alert.informativeText = L10n.restartMessage.text
        alert.addButton(withTitle: L10n.restartNow.text)
        alert.addButton(withTitle: L10n.restartLater.text)
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        relaunch()
    }
    /// open(1) reactivates a running instance instead of launching a new one,
    /// so the helper waits for this process to exit before reopening the app.
    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "for _ in $(seq 1 100); do kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || break; sleep 0.1; done; open \"\(Bundle.main.bundlePath)\""]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }
    @objc private func toggleTop() {
        preferences.alwaysOnTop.toggle()
        windowController.window?.level = preferences.alwaysOnTop ? .floating : .normal
        refreshMenu()
    }
    @objc private func toggleThrough() {
        preferences.clickThrough.toggle()
        windowController.updateMouseInteraction()
        refreshMenu()
    }
    @objc private func resetPosition() { windowController.resetPosition() }
    @objc private func selectPet(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != currentPet?.id else { return }
        switchPet(to: id) { [weak self] reason in
            self?.presentSwitchFailure(name: id, reason: reason)
        }
    }
    @objc private func chooseRoot() {
        guard startupCompleted else { continueStartup(); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.choose.text
        panel.message = L10n.chooseRootMessage.text
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        statusText = nil
        if library.rootURL != url.standardizedFileURL {
            switchGeneration &+= 1
            currentPet = nil
            updateActivity()
        }
        library.setRoot(url)
    }
    @objc private func openRootInFinder() {
        if let root = library.rootURL { NSWorkspace.shared.open(root) }
    }
    @objc private func rescan() { library.requestRescan() }
    @objc private func keyboardAccess() {
        if !startupCompleted {
            continueStartup()
        } else if KeyboardMonitor.permissionGranted {
            if active { monitor.start() }
        } else {
            permissionController.show { [weak self] in
                guard let self else { return }
                if self.active { self.monitor.start() }
                self.refreshMenu()
            }
        }
        refreshMenu()
    }
    @objc private func about() {
        let alert = NSAlert()
        alert.icon = Bundle.main.image(forResource: "KeyPet")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        alert.messageText = "KeyPet \(version)"
        alert.informativeText = L10n.aboutMessage.text
        alert.addButton(withTitle: L10n.ok.text)
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func continueStartup() {
        guard !startupCompleted else { return }
        guard KeyboardMonitor.permissionGranted else {
            permissionController.show { [weak self] in self?.continueStartup() }
            return
        }
        startupCompleted = true
        if !library.restoreRoot() { chooseRoot() }
        updateActivity()
        refreshMenu()
    }

    @objc private func restoreDefaults() {
        let alert = NSAlert()
        alert.icon = Bundle.main.image(forResource: "KeyPet")
        alert.alertStyle = .warning
        alert.messageText = L10n.restoreTitle.text
        alert.informativeText = L10n.restoreMessage.text
        alert.addButton(withTitle: L10n.cancel.text)
        alert.addButton(withTitle: L10n.restoreConfirm.text)
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        applyDefaultOptions()
    }

    private func applyDefaultOptions() {
        preferences.restoreDefaults()
        stateMachine.reset()
        stateMachine.swapSides = preferences.swapSides
        pendingResetDelayMs = preferences.resetDelayMs
        stateMachine.resetDelay = Double(pendingResetDelayMs) / 1000
        renderer.mirrored = preferences.flipHorizontal
        pendingShadowRadius = preferences.shadowRadius
        pendingShadowOpacity = preferences.shadowOpacity
        applyShadow()
        playback.setActive(false)
        playback.bounceEnabled = preferences.bounceEnabled
        playback.frameRate = preferences.frameRate
        windowController.previewWidth(preferences.width)
        windowController.saveGeometry()
        windowController.setOpacity(preferences.opacity)
        windowController.window?.level = preferences.alwaysOnTop ? .floating : .normal
        windowController.updateMouseInteraction()
        windowController.resetPosition()
        lifecycle.hidden = false
        lifecycle.paused = false
        windowController.window?.orderFrontRegardless()
        updateActivity()
        playback.setActive(active)
        refreshMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        windowController.saveOpacity()
        windowController.saveGeometry()
        preferences.resetDelayMs = pendingResetDelayMs
        preferences.shadowRadius = pendingShadowRadius
        preferences.shadowOpacity = pendingShadowOpacity
        permissionController.dismiss()
        monitor.stop()
        playback.stopAll()
        library.stop()
        lifecycle.cleanup()
        windowController.cleanup()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}
