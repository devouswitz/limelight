import AppKit
import LimelightCore
import SwiftUI

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
        installMainMenu()

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Limelight", isDirectory: true)
        index = FileIndex(config: prefs.indexConfig)
        engine = SearchEngine(files: index, frecency: Frecency(file: support.appendingPathComponent("history.json")))
        engine.webSearch = prefs.webSearch
        index.onChange = { [weak self] in
            DispatchQueue.main.async {
                self?.search.refreshIfVisible()
                self?.syncSettings()
            }
        }

        search = SearchController(engine: engine)
        search.actions = self
        HotKeyCenter.shared.onPress = { [weak self] in self?.search.toggle() }

        reloadCatalog()
        index.rebuild()
        startWatchers()
        installStatusItem()
        installHotKey()
        wireSettings()

        let env = ProcessInfo.processInfo.environment
        if let path = env["LIMELIGHT_SNAPSHOT"] {
            snapshotWhenIndexed(query: env["LIMELIGHT_QUERY"] ?? "", path: path)
            return
        }

        if !prefs.hasLaunchedBefore {
            prefs.hasLaunchedBefore = true
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.frecency.save()
    }

    /// Opening Limelight from Finder or the Dock while it is already running shows the search panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        search.show()
        return false
    }

    private func snapshotWhenIndexed(query: String, path: String) {
        guard index.isReady, !engine.catalog.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.snapshotWhenIndexed(query: query, path: path) }
            return
        }
        let typeKeys = ProcessInfo.processInfo.environment["LIMELIGHT_TYPE"] != nil
        search.snapshot(query: query, typeKeys: typeKeys, to: path) { NSApp.terminate(nil) }
    }

    // MARK: - Catalog and index

    private func reloadCatalog() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = AppCatalog.scanApplications() + AppCatalog.settingsPanes() + Self.commands
            DispatchQueue.main.async { self?.engine.catalog = items }
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

    private func installHotKey() {
        if let saved = prefs.hotKey {
            settings.hotKey = saved
            settings.hotKeyWorks = HotKeyCenter.shared.register(saved)
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
        settings.hotKeyWorks = HotKeyCenter.shared.register(combo)
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
            } else if let combo = self.prefs.hotKey {
                self.settings.hotKeyWorks = HotKeyCenter.shared.register(combo)
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
        default: break
        }
    }
}
