import AppKit
import LimelightCore

protocol LimelightActions: AnyObject {
    func run(command url: URL)
}

/// A floating panel that takes keyboard focus without activating Limelight,
/// so the app you were in stays frontmost and gets focus back on close.
final class SearchPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: SearchController.width, height: SearchController.headerHeight),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class SearchField: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 24, weight: .regular)
        placeholderString = "Limelight Search"
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        lineBreakMode = .byClipping
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class SearchController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let width: CGFloat = 720
    static let headerHeight: CGFloat = 60
    static let rowHeight: CGFloat = 46
    static let maxVisibleRows = 8

    let engine: SearchEngine
    weak var actions: LimelightActions?

    private let panel = SearchPanel()
    private let field = SearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let divider = NSBox()
    private let status = NSTextField(labelWithString: "")
    private var listHeight: NSLayoutConstraint!

    private var results: [SearchResult] = []
    private var shownQuery = ""
    private var generation = 0
    private let queue = DispatchQueue(label: "limelight.search", qos: .userInteractive)
    private var lastHidden = Date.distantPast

    init(engine: SearchEngine) {
        self.engine = engine
        super.init()
        buildViews()
        panel.delegate = self
        panel.keyHandler = { [weak self] in self?.handleKeyEquivalent($0) ?? false }
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Views

    private func buildViews() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        glass.symbolConfiguration = .init(pointSize: 20, weight: .medium)
        glass.contentTintColor = .secondaryLabelColor
        glass.translatesAutoresizingMaskIntoConstraints = false

        field.delegate = self
        status.font = .systemFont(ofSize: 12)
        status.textColor = .tertiaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        status.setContentHuggingPriority(.required, for: .horizontal)

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.refusesFirstResponder = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for v in [glass, field, status, divider, scroll] as [NSView] { content.addSubview(v) }
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            glass.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.headerHeight / 2),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 12),
            field.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: status.leadingAnchor, constant: -10),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            status.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.headerHeight),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            listHeight,
        ])

        let background: NSView
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 24
            g.contentView = content
            background = g
        } else {
            let fx = NSVisualEffectView()
            fx.material = .popover
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 18
            fx.layer?.masksToBounds = true
            fx.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                content.topAnchor.constraint(equalTo: fx.topAnchor),
                content.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            ])
            background = fx
        }
        panel.contentView = background
    }

    // MARK: - Showing

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        // Reopening shortly after closing keeps the last query, selected, like Spotlight.
        if Date().timeIntervalSince(lastHidden) > 60 { field.stringValue = "" }
        updateStatus()
        position()
        search(field.stringValue)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastHidden = Date()
        // If anything activated Limelight, step aside so the previous app gets focus back.
        if NSApp.isActive, !NSApp.windows.contains(where: { $0 !== panel && $0.isVisible && $0.canBecomeKey }) {
            NSApp.hide(nil)
        }
    }

    func updateStatus() {
        let files = engine.files
        status.stringValue = files.isReady ? "" : "Indexing files…"
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let height = panel.frame.height
        let top = area.maxY - area.height * 0.2
        panel.setFrame(NSRect(x: area.midX - Self.width / 2, y: top - height, width: Self.width, height: height), display: false)
    }

    private func resize() {
        let rows = min(results.count, Self.maxVisibleRows)
        let list: CGFloat = rows == 0 ? 0 : CGFloat(rows) * (Self.rowHeight + 2) + 12
        listHeight.constant = list
        divider.isHidden = rows == 0
        let height = Self.headerHeight + (rows == 0 ? 0 : list + 1)
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    // MARK: - Searching

    func controlTextDidChange(_ obj: Notification) {
        search(field.stringValue)
    }

    func search(_ query: String) {
        generation += 1
        let token = generation
        queue.async { [engine, weak self] in
            let found = engine.search(query)
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.results = found
                self.shownQuery = query
                self.table.reloadData()
                if !found.isEmpty { self.select(0) }
                self.resize()
            }
        }
    }

    /// Re-runs the current query, e.g. after the index finishes building.
    func refreshIfVisible() {
        guard panel.isVisible else { return }
        updateStatus()
        let selected = table.selectedRow >= 0 && table.selectedRow < results.count ? results[table.selectedRow].id : nil
        generation += 1
        let token = generation
        let query = field.stringValue
        queue.async { [engine, weak self] in
            let found = engine.search(query)
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.results = found
                self.table.reloadData()
                let keep = found.firstIndex { $0.id == selected } ?? 0
                if !found.isEmpty { self.select(keep) }
                self.resize()
            }
        }
    }

    private func select(_ row: Int) {
        guard !results.isEmpty else { return }
        let r = max(0, min(results.count - 1, row))
        table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    // MARK: - Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            select(table.selectedRow - 1)
        case #selector(NSResponder.moveDown(_:)):
            select(table.selectedRow + 1)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
            select(table.selectedRow + Self.maxVisibleRows)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            select(table.selectedRow - Self.maxVisibleRows)
        case #selector(NSResponder.insertNewline(_:)):
            activate(row: table.selectedRow, reveal: false)
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { hide() } else { field.stringValue = ""; search("") }
        case #selector(NSResponder.insertTab(_:)):
            complete()
        default:
            return false
        }
        return true
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags == .command else { return false }
        switch Int(event.keyCode) {
        case 36, 76: // return
            activate(row: table.selectedRow, reveal: true)
            return true
        case 8: // c
            let editor = field.currentEditor() as? NSTextView
            if let editor, editor.selectedRange().length > 0 { return false }
            copySelection()
            return true
        case 31: // o
            activate(row: table.selectedRow, reveal: false)
            return true
        case 43: // ,
            hide()
            actions?.run(command: URL(string: "limelight:settings")!)
            return true
        default:
            let digits: [Int: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
            if let n = digits[Int(event.keyCode)], n < results.count {
                activate(row: n, reveal: false)
                return true
            }
            return false
        }
    }

    /// Tab completes: a folder opens for browsing, anything else fills in its name.
    private func complete() {
        guard table.selectedRow >= 0, table.selectedRow < results.count else { return }
        let r = results[table.selectedRow]
        var text = r.title
        if let path = r.path, r.kind == .folder {
            text = engine.abbreviate(path) + "/"
        } else if let path = r.path, field.stringValue.hasPrefix("/") || field.stringValue.hasPrefix("~") {
            text = engine.abbreviate(path)
        }
        field.stringValue = text
        field.currentEditor()?.moveToEndOfDocument(nil)
        search(text)
    }

    private func copySelection() {
        guard table.selectedRow >= 0, table.selectedRow < results.count else { return }
        let r = results[table.selectedRow]
        guard let text = r.copyText ?? r.path ?? r.url?.absoluteString else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let path = r.path {
            // Paste as a file in Finder and Mail, as the path in text fields.
            pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
        }
        pasteboard.setString(text, forType: .string)
        (table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: false) as? ResultCell)?.showFlash("Copied")
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0 else { return }
        activate(row: row, reveal: NSEvent.modifierFlags.contains(.command))
    }

    private func activate(row: Int, reveal: Bool) {
        guard row >= 0, row < results.count else { NSSound.beep(); return }
        let r = results[row]
        let workspace = NSWorkspace.shared
        switch r.kind {
        case .calculation:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(r.copyText ?? r.title, forType: .string)
        case .app, .file, .folder:
            guard let path = r.path else { return }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                NSSound.beep()
                engine.files.refresh([(path as NSString).deletingLastPathComponent])
                return
            }
            if reveal {
                workspace.activateFileViewerSelecting([url])
            } else if r.kind == .app {
                workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                workspace.open(url)
            }
        case .setting, .url, .web:
            if let url = r.url { workspace.open(url) }
        case .command:
            hide()
            if let url = r.url { actions?.run(command: url) }
        }
        if r.kind != .web && r.kind != .calculation {
            engine.frecency.record(r, query: shownQuery)
        }
        hide()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ResultRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ResultCell.identifier, owner: nil) as? ResultCell ?? ResultCell(frame: .zero)
        cell.configure(results[row], query: shownQuery)
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let path = results[row].path else { return nil }
        return URL(fileURLWithPath: path) as NSURL
    }

    // MARK: - Developer snapshot

    /// Shows the panel with `query` and writes what it draws to `path`. Used by scripts/snapshot.sh
    /// to check layout without screen-recording permission. The glass background is drawn by the
    /// window server, so it does not appear in the image.
    /// With `typeKeys`, the query arrives as posted key events instead, which exercises the real input path;
    /// "↓" stands for the down arrow.
    func snapshot(query: String, typeKeys: Bool, to path: String, completion: @escaping () -> Void) {
        show()
        if typeKeys {
            for (n, ch) in query.enumerated() {
                // Arrow keys wait for results, as a person would.
                if ch == "↓" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(n) * 0.05) { [self] in postKey(ch) }
                    continue
                }
                postKey(ch)
            }
        } else {
            field.stringValue = query
            search(query)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            print("panelIsKey=\(panel.isKeyWindow) appIsActive=\(NSApp.isActive) field=\"\(field.stringValue)\" selectedRow=\(table.selectedRow) rows=\(results.count)")
            var inner = panel.contentView
            if #available(macOS 26.0, *), let glass = inner as? NSGlassEffectView { inner = glass.contentView }
            guard let view = inner,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { completion(); return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            completion()
        }
    }

    private func postKey(_ ch: Character) {
        let down = ch == "↓"
        let chars = down ? String(UnicodeScalar(NSDownArrowFunctionKey)!) : String(ch)
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: down ? [.numericPad, .function] : [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                    context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                    isARepeat: false, keyCode: down ? 125 : 0) {
            NSApp.postEvent(e, atStart: false)
        }
    }

    // MARK: - Window

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
