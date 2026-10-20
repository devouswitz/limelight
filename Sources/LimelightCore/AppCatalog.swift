import Foundation

/// Something launchable that isn't a plain file: an app, a System Settings pane, or a Limelight command.
public struct CatalogItem: Sendable, Hashable {
    public enum Kind: String, Sendable, Codable { case app, setting, command, action }

    public let kind: Kind
    public let name: String
    public let key: String
    public let path: String?
    public let url: URL?
    public let keywords: [String]
    /// For actions: what runs it, e.g. "Shortcut".
    public var subtitle: String?
    /// When the app last ran, from files apps rewrite on every launch. Nil when unknown.
    public var lastUsed: Date?
    /// When the bundle was installed, updated or built.
    public var updated: Date?
    let foldedName: [UInt8]
    let originalName: [UInt8]
    let foldedKeywords: [[UInt8]]

    public init(kind: Kind, name: String, key: String, path: String? = nil, url: URL? = nil, keywords: [String] = []) {
        self.kind = kind
        self.name = name
        self.key = key
        self.path = path
        self.url = url
        self.keywords = keywords
        foldedName = Fold.bytes(name)
        originalName = Array(name.utf8)
        foldedKeywords = keywords.map(Fold.bytes)
    }
}

public enum AppCatalog {
    public static func applicationFolders(home: String = NSHomeDirectory()) -> [String] {
        [
            "/Applications",
            "/System/Applications",
            "/System/Library/CoreServices/Applications",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
            home + "/Applications",
        ]
    }

    /// Reads the app folders directly, so nothing depends on Spotlight's metadata store.
    /// Descends into ordinary folders (Utilities, "Chrome Apps", vendor folders) up to four levels.
    public static func scanApplications(folders: [String] = applicationFolders()) -> [CatalogItem] {
        let fm = FileManager.default
        var seenPaths = Set<String>()
        var items: [CatalogItem] = []

        func visit(_ dir: String, depth: Int) {
            guard depth <= 4, let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = dir + "/" + name
                if name.hasSuffix(".app") {
                    let resolved = (path as NSString).resolvingSymlinksInPath
                    guard seenPaths.insert(resolved).inserted else { continue }
                    let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
                    let bundleID = info?["CFBundleIdentifier"] as? String
                    var display = fm.displayName(atPath: path)
                    if display.hasSuffix(".app") { display.removeLast(4) }
                    var keywords = aliases[bundleID ?? ""] ?? []
                    let stem = String(name.dropLast(4))
                    if stem != display { keywords.append(stem) }
                    if let bundleName = info?["CFBundleName"] as? String, bundleName != display, bundleName != stem {
                        keywords.append(bundleName)
                    }
                    var item = CatalogItem(kind: .app, name: display, key: path, path: path, keywords: keywords)
                    item.lastUsed = bundleID.flatMap(lastUsed)
                    item.updated = modificationDate(path)
                    items.append(item)
                    continue
                }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                let ext = (name as NSString).pathExtension.lowercased()
                if !ext.isEmpty && ext != "localized" && IndexConfig.packageExtensions.contains(ext) { continue }
                visit(path, depth: depth + 1)
            }
        }

        for folder in folders { visit(folder, depth: 0) }
        if fm.fileExists(atPath: "/System/Library/CoreServices/Finder.app"),
           seenPaths.insert("/System/Library/CoreServices/Finder.app").inserted {
            items.append(CatalogItem(kind: .app, name: "Finder", key: "/System/Library/CoreServices/Finder.app",
                                     path: "/System/Library/CoreServices/Finder.app", keywords: ["files", "explorer"]))
        }
        return items
    }

    /// Apps rewrite their preferences and saved window state when they run, so the newest of those
    /// files is a good "last opened" date that doesn't depend on Spotlight's metadata store.
    public static func lastUsed(bundleID: String) -> Date? {
        let lib = NSHomeDirectory() + "/Library"
        return [
            "\(lib)/Preferences/\(bundleID).plist",
            "\(lib)/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist",
            "\(lib)/Saved Application State/\(bundleID).savedState",
        ].compactMap(modificationDate).max()
    }

    static func modificationDate(_ path: String) -> Date? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    /// Names people type for apps whose real name they don't remember.
    static let aliases: [String: [String]] = [
        "com.apple.systempreferences": ["settings", "preferences", "system preferences", "control panel"],
        "com.apple.ActivityMonitor": ["task manager", "processes", "cpu"],
        "com.apple.Terminal": ["shell", "command line", "console"],
        "com.apple.finder": ["files", "explorer"],
        "com.apple.AppStore": ["store"],
        "com.apple.DiskUtility": ["format", "partition"],
        "com.apple.screenshot.launcher": ["screen capture", "screen recording"],
        "com.apple.QuickTimePlayerX": ["video player", "movie"],
        "com.apple.Preview": ["pdf", "image viewer"],
        "com.apple.TextEdit": ["notepad", "text editor"],
        "com.apple.calculator": ["calc"],
        "com.apple.iCal": ["calendar"],
        "com.apple.AddressBook": ["contacts", "address book"],
        "com.apple.MobileSMS": ["imessage", "sms", "texts"],
        "com.apple.Passwords": ["keychain", "passwords"],
        "com.apple.Console": ["logs"],
    ]

    /// System Settings panes that exist on this Mac, opened by their extension identifier.
    public static func settingsPanes(extensionsFolder: String = "/System/Library/ExtensionKit/Extensions") -> [CatalogItem] {
        var installed = Set<String>()
        if let names = try? FileManager.default.contentsOfDirectory(atPath: extensionsFolder) {
            for name in names where name.hasSuffix(".appex") {
                if let info = NSDictionary(contentsOfFile: extensionsFolder + "/" + name + "/Contents/Info.plist"),
                   let id = info["CFBundleIdentifier"] as? String {
                    installed.insert(id)
                }
            }
        }
        return settingsTable.compactMap { name, id, keywords in
            guard installed.contains(id), let url = URL(string: "x-apple.systempreferences:" + id) else { return nil }
            return CatalogItem(kind: .setting, name: name, key: "setting:" + id, url: url, keywords: keywords)
        }
    }

    static let settingsTable: [(String, String, [String])] = [
        ("Wi-Fi", "com.apple.wifi-settings-extension", ["wifi", "wireless", "internet"]),
        ("Bluetooth", "com.apple.BluetoothSettings", ["airpods", "pairing"]),
        ("Network", "com.apple.Network-Settings.extension", ["ethernet", "proxy", "dns", "firewall", "ip address"]),
        ("VPN", "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension", []),
        ("Notifications", "com.apple.Notifications-Settings.extension", ["alerts", "badges"]),
        ("Sound", "com.apple.Sound-Settings.extension", ["volume", "audio", "output", "input", "microphone", "speakers"]),
        ("Focus", "com.apple.Focus-Settings.extension", ["do not disturb", "dnd"]),
        ("Screen Time", "com.apple.Screen-Time-Settings.extension", ["parental controls", "app limits"]),
        ("About This Mac", "com.apple.SystemProfiler.AboutExtension", ["about", "serial number", "macos version", "specs"]),
        ("Software Update", "com.apple.Software-Update-Settings.extension", ["update", "upgrade", "macos"]),
        ("Storage", "com.apple.settings.Storage", ["disk space", "free space"]),
        ("AirDrop & Handoff", "com.apple.AirDrop-Handoff-Settings.extension", ["airplay receiver", "continuity"]),
        ("Login Items & Extensions", "com.apple.LoginItems-Settings.extension", ["startup items", "open at login", "background items"]),
        ("Language & Region", "com.apple.Localization-Settings.extension", ["locale", "date format", "units"]),
        ("Date & Time", "com.apple.Date-Time-Settings.extension", ["clock", "time zone", "24-hour"]),
        ("Sharing", "com.apple.Sharing-Settings.extension", ["file sharing", "screen sharing", "remote login", "ssh", "computer name", "hostname"]),
        ("Time Machine", "com.apple.Time-Machine-Settings.extension", ["backup"]),
        ("Transfer or Reset", "com.apple.Transfer-Reset-Settings.extension", ["erase", "factory reset", "migration"]),
        ("Startup Disk", "com.apple.Startup-Disk-Settings.extension", ["boot"]),
        ("Appearance", "com.apple.Appearance-Settings.extension", ["dark mode", "light mode", "accent color", "theme", "scroll bars"]),
        ("Accessibility", "com.apple.Accessibility-Settings.extension", ["voiceover", "zoom", "reduce motion", "contrast"]),
        ("Control Center", "com.apple.ControlCenter-Settings.extension", ["menu bar", "menu bar icons"]),
        ("Siri", "com.apple.Siri-Settings.extension", ["apple intelligence", "voice"]),
        ("Spotlight", "com.apple.Spotlight-Settings.extension", ["search results"]),
        ("Privacy & Security", "com.apple.settings.PrivacySecurity.extension", ["permissions", "full disk access", "camera access", "location services", "filevault", "accessibility access"]),
        ("Desktop & Dock", "com.apple.Desktop-Settings.extension", ["dock", "stage manager", "hot corners", "mission control", "widgets"]),
        ("Displays", "com.apple.Displays-Settings.extension", ["monitor", "resolution", "night shift", "brightness", "refresh rate"]),
        ("Wallpaper", "com.apple.Wallpaper-Settings.extension", ["background", "desktop picture"]),
        ("Battery", "com.apple.Battery-Settings.extension", ["power", "energy", "low power mode"]),
        ("Lock Screen", "com.apple.Lock-Screen-Settings.extension", ["screen saver", "require password"]),
        ("Touch ID & Password", "com.apple.Touch-ID-Settings.extension", ["fingerprint", "login password"]),
        ("Users & Groups", "com.apple.Users-Groups-Settings.extension", ["accounts", "guest user"]),
        ("Internet Accounts", "com.apple.Internet-Accounts-Settings.extension", ["email accounts", "mail accounts", "google account"]),
        ("Game Center", "com.apple.Game-Center-Settings.extension", []),
        ("Game Controllers", "com.apple.Game-Controller-Settings.extension", ["gamepad", "controller"]),
        ("Wallet & Apple Pay", "com.apple.WalletSettingsExtension", ["cards"]),
        ("Keyboard", "com.apple.Keyboard-Settings.extension", ["keyboard shortcuts", "dictation", "input sources", "key repeat"]),
        ("Mouse", "com.apple.Mouse-Settings.extension", ["tracking speed", "scroll direction"]),
        ("Trackpad", "com.apple.Trackpad-Settings.extension", ["gestures", "tap to click", "natural scrolling"]),
        ("Printers & Scanners", "com.apple.Print-Scan-Settings.extension", ["printer", "scanner"]),
        ("Apple Account", "com.apple.systempreferences.AppleIDSettings", ["icloud", "apple id"]),
        ("Family", "com.apple.Family-Settings.extension", ["family sharing"]),
    ]
}
