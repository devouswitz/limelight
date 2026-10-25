import AppKit
import LimelightCore
import Quartz

protocol LimelightActions: AnyObject {
    func run(command url: URL)
}

/// A floating panel that takes keyboard focus without activating Limelight,
/// so the app you were in stays frontmost and gets focus back on close.
final class SearchPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    weak var quickLookSource: (QLPreviewPanelDataSource & QLPreviewPanelDelegate)?

    init() {
        let m = SearchController.shadowMargin
        super.init(contentRect: NSRect(x: 0, y: 0, width: SearchController.width + 2 * m, height: SearchController.headerHeight + 2 * m),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        // The system shadow follows the window's square bounds whenever the panel has keyboard focus,
        // which draws a near-square outline around the rounded glass. ShadowHost draws one instead.
        hasShadow = false
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = quickLookSource
        panel.delegate = quickLookSource
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

final class SearchField: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 22, weight: .regular)
        placeholderString = "Limelight Search"
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        lineBreakMode = .byClipping
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The window's root view: a transparent margin holding the glass and a rounded shadow behind it.
/// Clicking the margin counts as clicking outside the panel.
final class ShadowHost: NSView {
    var onClickOutside: (() -> Void)?
    private let shadowView = NSView()
    private let content: NSView

    init(content: NSView, margin: CGFloat, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        shadowView.wantsLayer = true
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.32
        shadowView.layer?.shadowRadius = 20
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -10)
        for v in [shadowView, content] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
                v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
                v.topAnchor.constraint(equalTo: topAnchor, constant: margin),
                v.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margin),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private let cornerRadius: CGFloat

    override func layout() {
        super.layout()
        shadowView.layer?.shadowPath = CGPath(roundedRect: shadowView.bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !content.frame.contains(point) { onClickOutside?() }
    }
}

/// Dragging any empty part of the panel moves it. Clicks on controls never reach here;
/// clicks on icons, labels and the preview pane pass up the responder chain and do.
final class DragArea: NSView {
    var onDragEnd: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startOrigin = window.frame.origin
        let startPoint = window.convertPoint(toScreen: event.locationInWindow)
        var moved = false
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = window.convertPoint(toScreen: e.locationInWindow)
            if e.type == .leftMouseUp { break }
            moved = true
            window.setFrameOrigin(NSPoint(x: startOrigin.x + p.x - startPoint.x, y: startOrigin.y + p.y - startPoint.y))
        }
        if moved { onDragEnd?() }
    }
}

private enum Row {
    case header(ResultSection)
    case result(SearchResult)

    var result: SearchResult? {
        if case .result(let r) = self { return r }
        return nil
    }
}

final class SearchController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate,
    QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let width: CGFloat = 780
    static let headerHeight: CGFloat = 56
    static let listWidth: CGFloat = 320
    static let rowHeight: CGFloat = 30
    static let sectionHeight: CGFloat = 26
    /// The results area has one size, like Spotlight's, so the panel only ever changes between two shapes.
    static let bodyHeight: CGFloat = 400
    /// Transparent space around the glass for the shadow.
    static let shadowMargin: CGFloat = 44

    let engine: SearchEngine
    weak var actions: LimelightActions?

    private let panel = SearchPanel()
    private let field = SearchField()
    private let completion = NSTextField(labelWithString: "")
    private var completionLeading: NSLayoutConstraint!
    private let modeIcon = NSImageView()
    private let status = NSTextField(labelWithString: "")
    private var modeButtons: [NSButton] = []
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let preview = PreviewPane()
    private let divider = NSBox()
    private let body = NSView()
    private var bodyHeight: NSLayoutConstraint!
    private var contentRoot: NSView!

    private var rows: [Row] = []
    private var mode: SearchMode = .all
    private var shownQuery = ""
    private var generation = 0
    private let queue = DispatchQueue(label: "limelight.search", qos: .userInteractive)
    private var lastHidden = Date.distantPast

    init(engine: SearchEngine) {
        self.engine = engine
        super.init()
        buildViews()
        panel.delegate = self
        panel.quickLookSource = self
        panel.keyHandler = { [weak self] in self?.handleKeyEquivalent($0) ?? false }
    }

    var isVisible: Bool { panel.isVisible }

    private var selectedResult: SearchResult? {
        let i = table.selectedRow
        return i >= 0 && i < rows.count ? rows[i].result : nil
    }

    private var results: [SearchResult] { rows.compactMap(\.result) }

    // MARK: - Views

    private func buildViews() {
        let content = DragArea()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.onDragEnd = { [weak self] in self?.savePosition() }
        contentRoot = content
        // Nothing inside (a selected last row, the scroller) may draw past the rounded glass.
        content.wantsLayer = true
        content.layer?.cornerRadius = 26
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true

        modeIcon.symbolConfiguration = .init(pointSize: 19, weight: .medium)
        modeIcon.translatesAutoresizingMaskIntoConstraints = false

        field.delegate = self
        completion.font = field.font
        completion.textColor = .tertiaryLabelColor
        completion.lineBreakMode = .byTruncatingTail
        completion.translatesAutoresizingMaskIntoConstraints = false
        completion.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        status.font = .systemFont(ofSize: 12)
        status.textColor = .tertiaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        let modes = NSStackView()
        modes.orientation = .horizontal
        modes.spacing = 2
        modes.translatesAutoresizingMaskIntoConstraints = false
        for (i, m) in SearchMode.allCases.dropFirst().enumerated() {
            let b = NSButton(image: NSImage(systemSymbolName: Self.symbol(for: m), accessibilityDescription: Self.title(for: m))!,
                             target: self, action: #selector(modeClicked(_:)))
            b.isBordered = false
            b.tag = m.rawValue
            b.imageScaling = .scaleProportionallyDown
            b.symbolConfiguration = .init(pointSize: 14, weight: .medium)
            b.toolTip = "\(Self.title(for: m))  ⌘\(i + 1)"
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            modes.addArrangedSubview(b)
            modeButtons.append(b)
        }

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.refusesFirstResponder = true
        table.floatsGroupRows = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let split = NSBox()
        split.boxType = .separator
        split.translatesAutoresizingMaskIntoConstraints = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        for v in [scroll, split, preview] as [NSView] { body.addSubview(v) }

        for v in [modeIcon, field, completion, status, modes, divider, body] as [NSView] { content.addSubview(v) }
        completionLeading = completion.leadingAnchor.constraint(equalTo: field.leadingAnchor)
        bodyHeight = body.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            modeIcon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            modeIcon.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.headerHeight / 2),
            modeIcon.widthAnchor.constraint(equalToConstant: 24),
            field.leadingAnchor.constraint(equalTo: modeIcon.trailingAnchor, constant: 10),
            field.centerYAnchor.constraint(equalTo: modeIcon.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: status.leadingAnchor, constant: -8),
            completionLeading,
            completion.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),
            completion.trailingAnchor.constraint(lessThanOrEqualTo: field.trailingAnchor),
            status.trailingAnchor.constraint(equalTo: modes.leadingAnchor, constant: -10),
            status.centerYAnchor.constraint(equalTo: modeIcon.centerYAnchor),
            modes.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            modes.centerYAnchor.constraint(equalTo: modeIcon.centerYAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.headerHeight),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.topAnchor.constraint(equalTo: divider.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bodyHeight,
            scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: body.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            scroll.widthAnchor.constraint(equalToConstant: Self.listWidth),
            split.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
            split.topAnchor.constraint(equalTo: body.topAnchor),
            split.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            split.widthAnchor.constraint(equalToConstant: 1),
            preview.leadingAnchor.constraint(equalTo: split.trailingAnchor),
            preview.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            preview.topAnchor.constraint(equalTo: body.topAnchor),
            preview.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.required, for: .horizontal)

        let background: NSView
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 26
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
        let host = ShadowHost(content: background, margin: Self.shadowMargin, cornerRadius: 26)
        host.onClickOutside = { [weak self] in self?.hide() }
        panel.contentView = host
        applyMode()
    }

    static func symbol(for mode: SearchMode) -> String {
        switch mode {
        case .all: return "magnifyingglass"
        case .applications: return "square.grid.2x2"
        case .files: return "doc"
        case .actions: return "bolt"
        case .clipboard: return "list.clipboard"
        }
    }

    static func title(for mode: SearchMode) -> String {
        switch mode {
        case .all: return "Limelight Search"
        case .applications: return "Applications"
        case .files: return "Files"
        case .actions: return "Actions"
        case .clipboard: return "Clipboard"
        }
    }

    // MARK: - Showing

    func toggle() { panel.isVisible && !isHiding ? hide() : show() }

    func show() {
        // Reopening shortly after closing keeps the last query, selected, like Spotlight.
        if Date().timeIntervalSince(lastHidden) > 60 {
            field.stringValue = ""
            setMode(.all, search: false)
        }
        engine.runningAppPaths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        updateStatus()
        let wasVisible = panel.isVisible
        if !wasVisible { position() }
        // Search before appearing, so the panel opens at its final size instead of growing a moment later.
        searchNow(field.stringValue)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        animateIn(from: wasVisible ? panel.alphaValue : 0)
    }

    func hide(animated: Bool = true) {
        guard panel.isVisible, !isHiding else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        lastHidden = Date()
        isHiding = true
        motionToken += 1
        let token = motionToken
        let finish = { [weak self] in
            guard let self, token == self.motionToken else { return }
            self.isHiding = false
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            // If anything activated Limelight, step aside so the previous app gets focus back.
            if NSApp.isActive, !NSApp.windows.contains(where: { $0 !== self.panel && $0.isVisible && $0.canBecomeKey && !($0 is QLPreviewPanel) }) {
                NSApp.hide(nil)
            }
        }
        guard animated else { finish(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: finish)
    }

    /// Lays the panel out and runs a search while hidden, so the first open after launch is as quick
    /// as every later one (about 50 ms cold versus 10 ms warm).
    func prewarm() {
        guard !panel.isVisible else { return }
        searchNow("")
        panel.contentView?.layoutSubtreeIfNeeded()
        // Ordering in once makes the window server build the window's surface and glass now rather than
        // on the first real open. Fully transparent, off screen and without focus, so nothing shows.
        let frame = panel.frame
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        DispatchQueue.main.async { [self] in
            guard panel.alphaValue == 0 else { return }
            panel.orderOut(nil)
            panel.setFrame(frame, display: false)
            panel.alphaValue = 1
        }
    }

    // MARK: - Motion

    private var motionToken = 0
    private var isHiding = false

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Opening fades in with an ease-out. (A scale-up was tried; nothing that scales a window with
    /// Liquid Glass works without breaking clicks, so the open is a fade only.)
    private func animateIn(from alpha: CGFloat) {
        motionToken += 1
        isHiding = false
        panel.alphaValue = alpha
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.12 : 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func updateStatus() {
        status.stringValue = engine.files.isReady ? "" : "Indexing…"
    }

    // MARK: - Position

    private static let anchorKey = "panelAnchor"

    /// Where the panel's top center sits, as fractions of the screen's visible area, so a position
    /// chosen on one display carries over sensibly to another.
    private var savedAnchor: CGPoint? {
        get { UserDefaults.standard.string(forKey: Self.anchorKey).map(NSPointFromString) }
        set {
            if let newValue { UserDefaults.standard.set(NSStringFromPoint(newValue), forKey: Self.anchorKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.anchorKey) }
        }
    }

    func resetPosition() {
        savedAnchor = nil
        if panel.isVisible { position() }
    }

    private var currentScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// The glass's rectangle on screen; the window extends `shadowMargin` beyond it on every side.
    private var panelFrame: NSRect {
        panel.frame.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
    }

    private func position() {
        guard let area = currentScreen?.visibleFrame else { return }
        let anchor = savedAnchor ?? CGPoint(x: 0.5, y: 0.8)
        let height = panelFrame.height
        var top = area.minY + anchor.y * area.height
        var x = area.minX + anchor.x * area.width - Self.width / 2
        x = min(max(x, area.minX), area.maxX - Self.width)
        top = min(max(top, area.minY + Self.headerHeight), area.maxY)
        setFrame(NSRect(x: x, y: top - height, width: Self.width, height: height))
    }

    /// Places the glass at `frame`, growing the window by the shadow margin.
    private func setFrame(_ frame: NSRect) {
        panel.setFrame(frame.insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin), display: true)
    }

    private func savePosition() {
        guard let area = panel.screen?.visibleFrame else { return }
        let f = panelFrame
        savedAnchor = CGPoint(x: (f.midX - area.minX) / area.width, y: (f.maxY - area.minY) / area.height)
    }

    /// Switches between the bar and the expanded panel. Expanding reveals the results downward;
    /// collapsing folds them back up.
    private func resize(animated: Bool) {
        let expanded = !rows.isEmpty
        var frame = panelFrame
        let top = frame.maxY
        frame.size.height = Self.headerHeight + (expanded ? Self.bodyHeight + 1 : 0)
        frame.origin.y = top - frame.size.height
        if expanded {
            bodyHeight.constant = Self.bodyHeight
            divider.isHidden = false
            body.isHidden = false
        }
        let finish = { [weak self] in
            guard let self, self.rows.isEmpty else { return }
            self.divider.isHidden = true
            self.body.isHidden = true
        }
        guard frame != panelFrame else { finish(); return }
        guard animated, panel.isVisible, !reduceMotion else {
            setFrame(frame)
            finish()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = expanded ? 0.24 : 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame.insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin), display: true)
        }, completionHandler: finish)
    }

    // MARK: - Modes

    @objc private func modeClicked(_ sender: NSButton) {
        let m = SearchMode(rawValue: sender.tag) ?? .all
        setMode(mode == m ? .all : m)
        panel.makeFirstResponder(field)
        field.currentEditor()?.moveToEndOfDocument(nil)
    }

    private func setMode(_ m: SearchMode, search run: Bool = true) {
        mode = m
        applyMode()
        if run { search(field.stringValue) }
    }

    private func applyMode() {
        if let symbol = NSImage(systemSymbolName: Self.symbol(for: mode), accessibilityDescription: nil) {
            if panel.isVisible { modeIcon.setSymbolImage(symbol, contentTransition: .replace) } else { modeIcon.image = symbol }
        }
        modeIcon.contentTintColor = mode == .all ? .secondaryLabelColor : .controlAccentColor
        field.placeholderString = mode == .all ? "Limelight Search" : "Search " + Self.title(for: mode)
        for b in modeButtons {
            b.contentTintColor = b.tag == mode.rawValue ? .controlAccentColor : .tertiaryLabelColor
        }
    }

    // MARK: - Searching

    func controlTextDidChange(_ obj: Notification) {
        search(field.stringValue)
    }

    func search(_ query: String, keepSelection: Bool = false) {
        generation += 1
        let token = generation
        let mode = self.mode
        let previous = keepSelection ? selectedResult?.id : nil
        queue.async { [engine, weak self] in
            let found = engine.search(query, mode: mode, limit: mode == .all ? 40 : 200)
            let groups = engine.grouped(found, mode: mode, query: query)
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.apply(groups, query: query, keepID: previous)
            }
        }
    }

    /// Runs the search on the spot, used when opening so the first frame already has results.
    private func searchNow(_ query: String) {
        generation += 1
        let found = engine.search(query, mode: mode, limit: mode == .all ? 40 : 200)
        apply(engine.grouped(found, mode: mode, query: query), query: query, keepID: nil, animated: false)
    }

    private func apply(_ groups: [ResultGroup], query: String, keepID: String?, animated: Bool = true) {
        var rows: [Row] = []
        for g in groups {
            rows.append(.header(g.section))
            rows += g.results.map { .result($0) }
        }
        self.rows = rows
        shownQuery = query
        table.reloadData()
        // Size the list before selecting, so scrolling to the selection sees the real height.
        resize(animated: animated)
        panel.contentView?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
        let keep = keepID.flatMap { id in rows.firstIndex { $0.result?.id == id } }
        select(keep ?? firstResultRow(), direction: 1)
        updateCompletion()
    }

    /// Re-runs the current query, e.g. after the index finishes building.
    func refreshIfVisible() {
        guard panel.isVisible else { return }
        updateStatus()
        search(field.stringValue, keepSelection: true)
    }

    private func firstResultRow() -> Int {
        rows.firstIndex { $0.result != nil } ?? -1
    }

    private func select(_ row: Int, direction: Int) {
        guard !rows.isEmpty else { preview.show(nil); return }
        var r = max(0, min(rows.count - 1, row))
        while r >= 0, r < rows.count, rows[r].result == nil { r += direction >= 0 ? 1 : -1 }
        if r < 0 || r >= rows.count { r = direction >= 0 ? (rows.lastIndex { $0.result != nil } ?? 0) : firstResultRow() }
        guard r >= 0 else { return }
        table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        // Keep the section header in view when moving to a section's first row.
        if r > 0, rows[r - 1].result == nil { table.scrollRowToVisible(r - 1) }
        table.scrollRowToVisible(r)
    }

    private func jumpSection(_ direction: Int) {
        let headers = rows.indices.filter { rows[$0].result == nil }
        let current = table.selectedRow
        if direction > 0, let next = headers.first(where: { $0 > current }) {
            select(next + 1, direction: 1)
        } else if direction < 0 {
            let starts = headers.filter { $0 < current - 1 }
            select((starts.last ?? 0) + 1, direction: 1)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        preview.show(selectedResult)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    /// Gray text after the cursor finishing the top hit's name, as Spotlight does.
    private func updateCompletion() {
        let typed = field.stringValue
        completion.stringValue = ""
        guard !typed.isEmpty, mode != .clipboard, let top = results.first, top.kind != .web else { return }
        if !promoMode {
            guard let editor = field.currentEditor() as? NSTextView,
                  editor.selectedRange().location == (typed as NSString).length, editor.selectedRange().length == 0
            else { return }
        }
        let width = (typed as NSString).size(withAttributes: [.font: field.font!]).width
        guard width < field.bounds.width - 120 else { return }
        var text: String
        if top.kind != .calculation, Fold.string(String(top.title.prefix(typed.count))) == Fold.string(typed) {
            text = String(top.title.dropFirst(typed.count)) + " — " + Icons.kindLabel(for: top)
        } else {
            text = " — " + top.title
        }
        if typed.hasSuffix(" ") && text.hasPrefix(" ") { text.removeFirst() }
        completion.stringValue = text
        completionLeading.constant = width + 2
    }

    func controlTextDidEndEditing(_ obj: Notification) { completion.stringValue = "" }

    // MARK: - Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            select(table.selectedRow - 1, direction: -1)
        case #selector(NSResponder.moveDown(_:)):
            select(table.selectedRow + 1, direction: 1)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)):
            jumpSection(-1)
        case #selector(NSResponder.moveToEndOfDocument(_:)):
            jumpSection(1)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
            select(table.selectedRow + 10, direction: 1)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            select(table.selectedRow - 10, direction: -1)
        case #selector(NSResponder.insertNewline(_:)):
            activate(selectedResult, reveal: false)
        case #selector(NSResponder.cancelOperation(_:)):
            if !field.stringValue.isEmpty { field.stringValue = ""; search("") }
            else if mode != .all { setMode(.all) }
            else { hide() }
        case #selector(NSResponder.deleteBackward(_:)) where field.stringValue.isEmpty && mode != .all:
            setMode(.all)
        case #selector(NSResponder.insertTab(_:)):
            complete()
        case #selector(NSResponder.moveRight(_:)) where !completion.stringValue.isEmpty:
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
        case 36, 76, 15: // return, R
            activate(selectedResult, reveal: true)
        case 8: // C
            let editor = field.currentEditor() as? NSTextView
            if let editor, editor.selectedRange().length > 0 { return false }
            copySelection()
        case 31: // O
            activate(selectedResult, reveal: false)
        case 16: // Y
            toggleQuickLook()
        case 11: // B
            let q = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty, let url = engine.webSearch.url(for: q) { NSWorkspace.shared.open(url); hide() }
        case 43: // ,
            hide()
            actions?.run(command: URL(string: "limelight:settings")!)
        case 18, 19, 20, 21: // 1–4
            let m = SearchMode(rawValue: [18: 1, 19: 2, 20: 3, 21: 4][Int(event.keyCode)]!)!
            setMode(mode == m ? .all : m)
        default:
            return false
        }
        return true
    }

    /// Tab completes: a folder opens for browsing, anything else fills in its name.
    private func complete() {
        guard let r = selectedResult else { return }
        var text = r.title
        if let path = r.path, r.kind == .folder {
            text = engine.abbreviate(path) + "/"
        } else if let path = r.path, field.stringValue.hasPrefix("/") || field.stringValue.hasPrefix("~") {
            text = engine.abbreviate(path)
        } else if r.kind == .calculation || r.kind == .clipboard || r.kind == .web {
            return
        }
        field.stringValue = text
        field.currentEditor()?.moveToEndOfDocument(nil)
        search(text)
    }

    private func copySelection() {
        guard let r = selectedResult, let text = r.copyText ?? r.path ?? r.url?.absoluteString else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let path = r.path {
            // Paste as a file in Finder and Mail, as the path in text fields.
            pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
        }
        pasteboard.setString(text, forType: .string)
        (table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: false) as? ResultCell)?.showFlash("Copied")
    }

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        activate(rows[row].result, reveal: NSEvent.modifierFlags.contains(.command))
    }

    private func activate(_ result: SearchResult?, reveal: Bool) {
        guard let r = result else { NSSound.beep(); return }
        let workspace = NSWorkspace.shared
        switch r.kind {
        case .calculation, .clipboard, .definition:
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
        case .command, .action:
            hide()
            if let url = r.url { actions?.run(command: url) }
        }
        if ![.web, .calculation, .clipboard, .definition].contains(r.kind) {
            engine.frecency.record(r, query: shownQuery)
        }
        hide()
    }

    // MARK: - Quick Look

    private func toggleQuickLook() {
        guard selectedResult?.path != nil else { NSSound.beep(); return }
        let ql = QLPreviewPanel.shared()!
        if ql.isVisible {
            ql.orderOut(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            ql.makeKeyAndOrderFront(nil)
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedResult?.path == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let path = selectedResult?.path else { return nil }
        return URL(fileURLWithPath: path) as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Arrow keys in Quick Look move through results, as they do in Finder.
        guard event.type == .keyDown else { return false }
        if event.keyCode == 125 { select(table.selectedRow + 1, direction: 1); return true }
        if event.keyCode == 126 { select(table.selectedRow - 1, direction: -1); return true }
        return false
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row].result == nil ? Self.sectionHeight : Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row].result != nil
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ResultRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let section):
            let cell = tableView.makeView(withIdentifier: SectionHeaderCell.identifier, owner: nil) as? SectionHeaderCell
                ?? SectionHeaderCell(frame: .zero)
            cell.configure(section.title)
            return cell
        case .result(let r):
            let cell = tableView.makeView(withIdentifier: ResultCell.identifier, owner: nil) as? ResultCell ?? ResultCell(frame: .zero)
            cell.configure(r, query: shownQuery)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let path = rows[row].result?.path else { return nil }
        return URL(fileURLWithPath: path) as NSURL
    }

    // MARK: - Window

    func windowDidResignKey(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
        hide()
    }

    // MARK: - Promo rendering

    private(set) var promoMode = false

    /// Puts the panel off screen, without taking keyboard focus, for frame-by-frame rendering.
    func promoPrepare() {
        promoMode = true
        panel.appearance = NSAppearance(named: .darkAqua)
        setFrame(NSRect(x: -8000, y: 400, width: Self.width, height: Self.headerHeight))
        panel.orderFront(nil)
        panel.makeFirstResponder(nil)
        preview.useThumbnails = true
    }

    func promoSet(query: String, mode m: SearchMode) {
        if m != mode { setMode(m, search: false) }
        field.stringValue = query
        let found = engine.search(query, mode: m, limit: 40)
        apply(engine.grouped(found, mode: m, query: query), query: query, keepID: nil)
    }

    func promoMove(_ delta: Int) { select(table.selectedRow + delta, direction: delta) }

    /// The panel's contents as an image with a transparent background, plus where the text caret belongs.
    func promoRender() -> (image: NSBitmapImageRep, caret: NSRect)? {
        guard let view = contentRoot, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let f = field.convert(field.bounds, to: view)
        let width = (field.stringValue as NSString).size(withAttributes: [.font: field.font!]).width
        let caret = NSRect(x: f.minX + 2 + width, y: f.midY - 13, width: 2, height: 26)
        return (rep, caret)
    }

    // MARK: - Developer snapshot

    /// Shows the panel with `query` and writes what it draws to `path`. Used by scripts/snapshot.sh
    /// to check layout without screen-recording permission. The glass background is drawn by the
    /// window server, so it does not appear in the image. With `typeKeys`, the query arrives as
    /// posted key events instead, which exercises the real input path; "↓" stands for the down arrow.
    func snapshot(query: String, mode: SearchMode, typeKeys: Bool, to path: String, completion: @escaping () -> Void) {
        if typeKeys {
            show()
        } else {
            // Normally shown without taking keyboard focus, so a test run never captures what someone is typing.
            // LIMELIGHT_FOCUS=1 makes it the key window, which is how it looks in real use.
            position()
            if ProcessInfo.processInfo.environment["LIMELIGHT_FOCUS"] != nil {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
        }
        setMode(mode, search: false)
        if typeKeys {
            for (n, ch) in query.enumerated() {
                if ch == "↓" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(n) * 0.05) { [self] in postKey(ch) }
                } else {
                    postKey(ch)
                }
            }
        } else {
            field.stringValue = query
            search(query)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
            print("panelIsKey=\(panel.isKeyWindow) field=\"\(field.stringValue)\" selectedRow=\(table.selectedRow) rows=\(rows.count) completion=\"\(self.completion.stringValue)\"")
            if let real = windowServerImage() {
                let url = URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-window.png"))
                try? NSBitmapImageRep(cgImage: real).representation(using: .png, properties: [:])?.write(to: url)
                print("window image \(real.width)x\(real.height)")
            } else {
                print("window image unavailable")
            }
            var inner = panel.contentView
            if #available(macOS 26.0, *), let glass = inner as? NSGlassEffectView { inner = glass.contentView }
            guard let view = inner, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { completion(); return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(white: 0.16, alpha: 1).setFill()
            view.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            completion()
        }
    }

    /// Drags the panel by its search icon with posted mouse events, then reports where it went.
    func testDrag(by delta: CGPoint, completion: @escaping () -> Void) {
        show()
        // Drag once the panel has finished appearing, as a person would; a fully transparent window takes no clicks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            panel.contentView?.layoutSubtreeIfNeeded()
            let before = panel.frame.origin
            let start = NSPoint(x: Self.shadowMargin + 30, y: panel.frame.height - Self.shadowMargin - Self.headerHeight / 2)
            func mouse(_ type: NSEvent.EventType, _ p: NSPoint) {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            // Real drag events are reported relative to wherever the window is when they arrive.
            let screenStart = panel.convertPoint(toScreen: start)
            func at(_ fraction: CGFloat) -> NSPoint {
                panel.convertPoint(fromScreen: NSPoint(x: screenStart.x + delta.x * fraction, y: screenStart.y + delta.y * fraction))
            }
            mouse(.leftMouseDown, start)
            for i in 1...10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(i)) { mouse(.leftMouseDragged, at(CGFloat(i) / 10)) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { mouse(.leftMouseUp, at(1)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                print("before=\(before) after=\(panel.frame.origin) saved=\(String(describing: savedAnchor))")
                hide(animated: false)
                show()
                print("reopened at \(panel.frame.origin)")
                completion()
            }
        }
    }

    /// The window as the window server composites it, shadow included. Diagnostic only.
    /// CGWindowListCreateImage is gone from the SDK but still answers at runtime for an app's own windows.
    func windowServerImage() -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(sym, to: Capture.self)
        // kCGWindowListOptionIncludingWindow = 8; image option 0 keeps the shadow framing.
        return capture(.null, 8, UInt32(panel.windowNumber), 0)?.takeRetainedValue()
    }

    /// Logs window opacity every 20 ms through an open and a close, and how long opening takes. Diagnostic only.
    func traceMotion(completion: @escaping () -> Void) {
        let start = Date()
        let timer = Timer(timeInterval: 0.02, repeats: true) { [self] _ in
            print(String(format: "%.3f alpha %.2f visible %d", Date().timeIntervalSince(start), panel.alphaValue, panel.isVisible ? 1 : 0))
        }
        RunLoop.main.add(timer, forMode: .common)
        var t0 = CACurrentMediaTime()
        show()
        print(String(format: "show() took %.1f ms (cold)", (CACurrentMediaTime() - t0) * 1000))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in hide() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [self] in
            timer.invalidate()
            t0 = CACurrentMediaTime()
            show()
            print(String(format: "show() took %.1f ms (warm)", (CACurrentMediaTime() - t0) * 1000))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in hide(animated: false); completion() }
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
}
