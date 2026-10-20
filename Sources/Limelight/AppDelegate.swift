import AppKit
import os
import LimelightCore
import SwiftUI

private let log = Logger(subsystem: "com.spencermccauley.Limelight", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, LimelightActions {
    private let prefs = Preferences()
    private var index: FileIndex!
    private var engine: SearchEngine!
    private var search: SearchController!
    private var statusItem: NSStatusItem!
    private var openItem: NSMenuItem!
    private var countItem: NSMenuItem!
    private var fileWatchers: [FileWatcher] = []
    private var appWatcher: FileWatcher?
    private var settingsWindow: NSWindow?
    private let settings = SettingsModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        // Developer runs (snapshots, the promo, the drag test) are short-lived second copies. They must not
        // take the shortcut, add a menu bar icon, watch files or write history, or they disturb the real one.
        let devRun = ["LIMELIGHT_PROMO", "LIMELIGHT_DRAG", "LIMELIGHT_SNAPSHOT"].contains { env[$0] != nil }
        if !devRun, NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            log.notice("another copy is already running; exiting")
            NSApp.terminate(nil)
            return
        }
        installMainMenu()

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Limelight", isDirectory: true)
        index = FileIndex(config: prefs.indexConfig)
        engine = SearchEngine(files: index, frecency: Frecency(file: devRun ? nil : support.appendingPathComponent("history.json")))
        engine.webSearch = prefs.webSearch
        index.onChange = { [weak self] in
            DispatchQueue.main.async {
                self?.search.refreshIfVisible()
                self?.syncSettings()
            }
        }

        search = SearchController(engine: engine)
        search.actions = self
        for (item, symbol) in Self.systemActions { Icons.symbols[item.key] = symbol }
        reloadCatalog()
        index.rebuild()

        if let promo = env["LIMELIGHT_PROMO"] {
            recordPromoWhenReady(to: URL(fileURLWithPath: promo))
            return
        }
        if let drag = env["LIMELIGHT_DRAG"] {
            let parts = drag.split(separator: ",").compactMap { Double($0) }
            search.testDrag(by: CGPoint(x: parts.first ?? 0, y: parts.last ?? 0)) { NSApp.terminate(nil) }
            return
        }
        if let path = env["LIMELIGHT_SNAPSHOT"] {
            snapshotWhenIndexed(query: env["LIMELIGHT_QUERY"] ?? "", path: path)
            return
        }

        HotKeyCenter.shared.onPress = { [weak self] in self?.search.toggle() }
        setClipboardHistory(prefs.clipboardHistory)
        startWatchers()
        installStatusItem()
        installHotKey()
        wireSettings()

        if !prefs.hasLaunchedBefore {
            prefs.hasLaunchedBefore = true
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.frecency.save()
    }

    /// Opening Limelight from Finder or the Dock while it is already running shows the search panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        search?.show()
        return false
    }

    private func recordPromoWhenReady(to url: URL) {
        guard !engine.catalog.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.recordPromoWhenReady(to: url) }
            return
        }
        // Personal shortcuts stay out of a video meant for posting.
        let catalog = engine.catalog.filter { !$0.key.hasPrefix("shortcut:") }
        // Run from the run loop rather than a dispatch block: the recorder spins nested run loops,
        // and those can only deliver main-queue callbacks (Quick Look thumbnails) from outside one.
        RunLoop.main.perform {
            do {
                try PromoRecorder(output: url, catalog: catalog).run()
                print("wrote \(url.path)")
            } catch {
                print("promo failed: \(error)")
            }
            NSApp.terminate(nil)
        }
    }

    private func snapshotWhenIndexed(query: String, path: String) {
        guard index.isReady, !engine.catalog.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.snapshotWhenIndexed(query: query, path: path) }
            return
        }
        let typeKeys = ProcessInfo.processInfo.environment["LIMELIGHT_TYPE"] != nil
        let mode = SearchMode(rawValue: Int(ProcessInfo.processInfo.environment["LIMELIGHT_MODE"] ?? "") ?? 0) ?? .all
        search.snapshot(query: query, mode: mode, typeKeys: typeKeys, to: path) { NSApp.terminate(nil) }
    }

    // MARK: - Catalog and index

    private func reloadCatalog() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = AppCatalog.scanApplications() + AppCatalog.settingsPanes() + Self.commands
                + Self.systemActions.map(\.item) + Self.loadShortcuts()
            DispatchQueue.main.async { self?.engine.catalog = items }
        }
    }

    /// Built-in actions. Restart, Shut Down and Log Out go through loginwindow, which asks for confirmation.
    private static let systemActions: [(item: CatalogItem, symbol: String)] = [
        ("Lock Screen", "lock", "lock.fill", ["lock"]),
        ("Sleep", "sleep", "moon.fill", ["sleep"]),
        ("Turn Off Display", "displaysleep", "display", ["screen off", "display sleep"]),
        ("Start Screen Saver", "screensaver", "sparkles.tv", ["screensaver"]),
        ("Toggle Dark Mode", "darkmode", "circle.lefthalf.filled", ["dark mode", "light mode", "appearance"]),
        ("Show Trash", "trash", "trash", ["bin", "recycle"]),
        ("Restart…", "restart", "restart", ["reboot"]),
        ("Shut Down…", "shutdown", "power", ["power off", "turn off"]),
        ("Log Out…", "logout", "rectangle.portrait.and.arrow.right", ["sign out"]),
    ].map { name, id, symbol, keywords in
        var item = CatalogItem(kind: .action, name: name, key: "action:" + id, url: URL(string: "limelight:action/" + id), keywords: keywords)
        item.subtitle = "Action"
        return (item, symbol)
    }

    /// The user's Shortcuts, read from the shortcuts command-line tool.
    private static func loadShortcuts() -> [CatalogItem] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            let name = String(line).trimmingCharacters(in: .whitespaces)
            var c = URLComponents()
            c.scheme = "limelight"
            c.path = "shortcut"
            c.queryItems = [URLQueryItem(name: "name", value: name)]
            guard !name.isEmpty, let url = c.url else { return nil }
            var item = CatalogItem(kind: .action, name: name, key: "shortcut:" + name, url: url)
            item.subtitle = "Shortcut"
            return item
        }
    }

    private static let commands: [CatalogItem] = [
        CatalogItem(kind: .command, name: "Limelight Settings", key: "cmd:settings",
                    url: URL(string: "limelight:settings"), keywords: ["preferences"]),
        CatalogItem(kind: .command, name: "Rebuild Limelight Index", key: "cmd:reindex",
                    url: URL(string: "limelight:reindex"), keywords: ["reindex"]),
        CatalogItem(kind: .command, name: "Quit Limelight", key: "cmd:quit", url: URL(string: "limelight:quit")),
    ]

    private func startWatchers() {
        fileWatchers.forEach { $0.stop() }
        fileWatchers = []
        let cfg = index.config
        for root in cfg.roots {
            // Skip noisy subtrees at the FSEvents level, but never a folder that contains this root.
            let excluded = cfg.excludedPaths.filter { $0.hasPrefix(root + "/") }
            let watcher = FileWatcher(paths: [root], excluding: excluded) { [weak self] changes in
                guard let index = self?.index else { return }
                let deep = changes.filter(\.mustRescanSubtree).map(\.path)
                let shallow = changes.filter { !$0.mustRescanSubtree }.map(\.path)
                if !shallow.isEmpty { index.refresh(shallow) }
                if !deep.isEmpty { index.refresh(deep, deep: true) }
            }
            if let watcher { fileWatchers.append(watcher) }
        }
        let appFolders = AppCatalog.applicationFolders().filter { FileManager.default.fileExists(atPath: $0) }
        appWatcher = FileWatcher(paths: appFolders, latency: 2) { [weak self] _ in
            DispatchQueue.main.async { self?.reloadCatalog() }
        }
    }

    // MARK: - Hotkey

    private var hotKeyRetry: Timer?

    /// Registers the saved shortcut. If something else briefly holds it, keeps trying every few seconds
    /// instead of leaving Limelight without a shortcut until the next launch.
    private func registerSavedHotKey() {
        guard let combo = prefs.hotKey else { return }
        let ok = HotKeyCenter.shared.register(combo)
        settings.hotKeyWorks = ok
        log.notice("shortcut \(combo.display, privacy: .public) registered: \(ok, privacy: .public)")
        hotKeyRetry?.invalidate()
        hotKeyRetry = nil
        if !ok {
            hotKeyRetry = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.registerSavedHotKey() }
        }
    }

    private func installHotKey() {
        if let saved = prefs.hotKey {
            settings.hotKey = saved
            registerSavedHotKey()
            updateOpenItem()
            return
        }
        // First launch: take ⌘Space if Spotlight has let it go, otherwise the first free fallback.
        var candidates: [KeyCombo] = [.optionSpace, .controlSpace, .optionCommandSpace]
        if !HotKeyCenter.spotlightOwnsCommandSpace { candidates.insert(.commandSpace, at: 0) }
        let chosen = candidates.first { HotKeyCenter.shared.register($0) } ?? .optionSpace
        prefs.hotKey = chosen
        settings.hotKey = chosen
        settings.hotKeyWorks = HotKeyCenter.shared.register(chosen)
        updateOpenItem()
    }

    private func setHotKey(_ combo: KeyCombo) {
        prefs.hotKey = combo
        settings.hotKey = combo
        registerSavedHotKey()
        settings.refreshSystemState()
        updateOpenItem()
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Limelight")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        openItem = NSMenuItem(title: "Open Limelight", action: #selector(openSearch), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        countItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        countItem.isEnabled = false
        menu.addItem(countItem)
        let rebuild = NSMenuItem(title: "Rebuild Index", action: #selector(rebuildIndex), keyEquivalent: "")
        rebuild.target = self
        menu.addItem(rebuild)
        let reset = NSMenuItem(title: "Reset Panel Position", action: #selector(resetPanelPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        let prefsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Limelight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        countItem.title = index.isReady && !index.isCrawling
            ? "\(index.itemCount.formatted()) files and folders indexed"
            : "Indexing…"
        updateOpenItem()
    }

    private func updateOpenItem() {
        guard let openItem, let combo = prefs.hotKey else { return }
        openItem.keyEquivalent = combo.menuKeyEquivalent
        openItem.keyEquivalentModifierMask = combo.cocoaModifiers
    }

    @objc private func openSearch() { search.show() }
    @objc private func rebuildIndex() { index.rebuild(); syncSettings() }
    @objc private func openSettings() { showSettings() }
    @objc private func resetPanelPosition() { search.resetPosition() }

    /// Standard Edit menu so ⌘C, ⌘V, ⌘A and undo work in text fields of an app with no menu bar.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Limelight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: - Settings

    private func wireSettings() {
        settings.webSearch = prefs.webSearch.name
        settings.config = index.config
        settings.setHotKey = { [weak self] in self?.setHotKey($0) }
        settings.pauseHotKey = { [weak self] recording in
            guard let self else { return }
            if recording {
                HotKeyCenter.shared.unregister()
            } else {
                self.registerSavedHotKey()
            }
        }
        settings.setWebSearch = { [weak self] name in
            guard let self, let provider = WebSearchProvider.all.first(where: { $0.name == name }) else { return }
            self.prefs.webSearch = provider
            self.engine.webSearch = provider
        }
        settings.setConfig = { [weak self] cfg in
            guard let self else { return }
            self.prefs.indexConfig = cfg
            self.index.rebuild(config: cfg)
            self.startWatchers()
            self.syncSettings()
        }
        settings.rebuild = { [weak self] in self?.rebuildIndex() }
        settings.clipboardHistory = prefs.clipboardHistory
        settings.setClipboardHistory = { [weak self] on in
            self?.prefs.clipboardHistory = on
            self?.setClipboardHistory(on)
        }
        settings.resetPosition = { [weak self] in self?.search.resetPosition() }
        syncSettings()
    }

    private func syncSettings() {
        settings.itemCount = index.itemCount
        settings.indexing = index.isCrawling || !index.isReady
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: settings)))
            window.title = "Limelight Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        syncSettings()
        settings.refreshSystemState()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func run(command url: URL) {
        switch url.absoluteString {
        case "limelight:settings": showSettings()
        case "limelight:reindex": rebuildIndex()
        case "limelight:quit": NSApp.terminate(nil)
        case "limelight:action/lock": Self.lockScreen()
        case "limelight:action/sleep": Self.run("/usr/bin/pmset", ["sleepnow"])
        case "limelight:action/displaysleep": Self.run("/usr/bin/pmset", ["displaysleepnow"])
        case "limelight:action/screensaver":
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
        case "limelight:action/darkmode":
            Self.appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        case "limelight:action/trash":
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
        case "limelight:action/restart": Self.appleScript("tell application \"loginwindow\" to «event aevtrrst»")
        case "limelight:action/shutdown": Self.appleScript("tell application \"loginwindow\" to «event aevtrsdn»")
        case "limelight:action/logout": Self.appleScript("tell application \"loginwindow\" to «event aevtlogo»")
        default:
            if url.path == "shortcut", let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "name" })?.value {
                Self.run("/usr/bin/shortcuts", ["run", name])
            }
        }
    }

    private static func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try? p.run()
    }

    private static func appleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    /// The same call the Lock Screen menu item makes.
    private static func lockScreen() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
              let sym = dlsym(handle, "SACLockScreenImmediate") else { return }
        typealias Lock = @convention(c) () -> Int32
        _ = unsafeBitCast(sym, to: Lock.self)()
    }

    // MARK: - Clipboard

    private var clipboardTimer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    /// Polls the pasteboard, which has no change notification. Skips anything a password manager
    /// marks as concealed or transient.
    func setClipboardHistory(_ on: Bool) {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        if !on { engine.clipboard.clear(); return }
        let skip: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            let pb = NSPasteboard.general
            guard pb.changeCount != self.lastChangeCount else { return }
            self.lastChangeCount = pb.changeCount
            let types = Set((pb.types ?? []).map(\.rawValue))
            guard types.isDisjoint(with: skip) else { return }
            let source = NSWorkspace.shared.frontmostApplication?.localizedName
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                self.engine.clipboard.add(urls.map(\.path).joined(separator: "\n"), source: source)
            } else if let text = pb.string(forType: .string) {
                self.engine.clipboard.add(text, source: source)
            }
        }
    }
}
