import AppKit
import LimelightCore
import Quartz

/// The right-hand pane: a Quick Look preview or large icon, then the details Spotlight shows.
final class PreviewPane: NSView {
    private let stack = NSStackView()
    private lazy var quickLook: QLPreviewView = {
        let v = QLPreviewView(frame: .zero, style: .compact)!
        v.shouldCloseWithWindow = false
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()
    private var shownID: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ result: SearchResult?) {
        guard result?.id != shownID || result?.kind == .calculation else { return }
        shownID = result?.id
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        guard let r = result else { return }

        switch r.kind {
        case .calculation:
            stack.addArrangedSubview(spacer(28))
            stack.addArrangedSubview(label(r.subtitle, size: 15, color: .secondaryLabelColor, lines: 3))
            stack.addArrangedSubview(label("= " + r.title, size: 34, weight: .semibold, lines: 2))
        case .definition, .clipboard:
            stack.addArrangedSubview(spacer(4))
            stack.addArrangedSubview(header(r, iconSize: 44))
            stack.addArrangedSubview(divider())
            stack.addArrangedSubview(textBox(r.detail ?? r.title))
        case .file, .folder, .app:
            showFile(r)
        default:
            stack.addArrangedSubview(spacer(24))
            stack.addArrangedSubview(header(r, iconSize: 96))
        }
    }

    private func showFile(_ r: SearchResult) {
        guard let path = r.path else { return }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let isPackage = IndexConfig.packageExtensions.contains(ext)
        if r.kind == .file && !isPackage {
            quickLook.previewItem = url as NSURL
            stack.addArrangedSubview(quickLook)
            NSLayoutConstraint.activate([
                quickLook.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
                quickLook.heightAnchor.constraint(equalToConstant: 190),
            ])
            stack.addArrangedSubview(label(r.title, size: 15, weight: .semibold, lines: 2))
            stack.addArrangedSubview(label(Icons.kindLabel(for: r), size: 12, color: .secondaryLabelColor))
        } else {
            stack.addArrangedSubview(spacer(10))
            stack.addArrangedSubview(header(r, iconSize: 112))
        }
        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(details(for: r, path: path))
    }

    private func details(for r: SearchResult, path: String) -> NSView {
        let fm = FileManager.default
        let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
        var rows: [(String, String)] = []
        if r.kind == .app {
            let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
            if let v = info?["CFBundleShortVersionString"] as? String { rows.append(("Version", v)) }
            if let id = info?["CFBundleIdentifier"] as? String, let used = AppCatalog.lastUsed(bundleID: id) {
                rows.append(("Last opened", Self.date(used)))
            }
        } else if r.kind == .folder {
            let count = (try? fm.contentsOfDirectory(atPath: path).filter { !$0.hasPrefix(".") }.count) ?? 0
            rows.append(("Contains", count == 1 ? "1 item" : "\(count.formatted()) items"))
        } else if let size = attrs[.size] as? NSNumber, !IndexConfig.packageExtensions.contains((path as NSString).pathExtension.lowercased()) {
            rows.append(("Size", ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)))
        }
        if let created = attrs[.creationDate] as? Date { rows.append(("Created", Self.date(created))) }
        if let modified = attrs[.modificationDate] as? Date { rows.append(("Modified", Self.date(modified))) }
        rows.append(("Where", r.subtitle))

        let grid = NSGridView(views: rows.map { key, value in
            [label(key, size: 11.5, color: .secondaryLabelColor, align: .right),
             label(value, size: 11.5, align: .left, lines: 2, truncateMiddle: key == "Where")]
        })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 5
        grid.columnSpacing = 8
        grid.column(at: 0).width = 80
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        return grid
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: d)
    }

    // MARK: - Pieces

    private func header(_ r: SearchResult, iconSize: CGFloat) -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .centerX
        v.spacing = 6
        let icon = NSImageView(image: Icons.image(for: r, size: iconSize))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: iconSize).isActive = true
        icon.heightAnchor.constraint(equalToConstant: iconSize).isActive = true
        v.addArrangedSubview(icon)
        v.addArrangedSubview(label(r.title, size: 15, weight: .semibold, lines: 2))
        let sub = [.app, .folder, .file, .definition, .clipboard].contains(r.kind) ? Icons.kindLabel(for: r) : r.subtitle
        v.addArrangedSubview(label(sub, size: 12, color: .secondaryLabelColor, lines: 2))
        for view in v.arrangedSubviews { view.setContentCompressionResistancePriority(.required, for: .vertical) }
        v.setContentCompressionResistancePriority(.required, for: .vertical)
        return v
    }

    private func textBox(_ text: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.drawsBackground = false
            tv.font = .systemFont(ofSize: 13)
            tv.textColor = .labelColor
            tv.string = text
            tv.textContainerInset = NSSize(width: 2, height: 4)
        }
        // Takes whatever height is left after the header, never squeezing it.
        let preferred = scroll.heightAnchor.constraint(equalToConstant: 260)
        preferred.priority = .defaultLow
        preferred.isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        scroll.setContentCompressionResistancePriority(.init(1), for: .vertical)
        scroll.widthAnchor.constraint(equalToConstant: 380).isActive = true
        return scroll
    }

    private func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 380).isActive = true
        return line
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
                       align: NSTextAlignment = .center, lines: Int = 1, truncateMiddle: Bool = false) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = align
        l.maximumNumberOfLines = lines
        l.lineBreakMode = truncateMiddle ? .byTruncatingMiddle : .byTruncatingTail
        l.cell?.truncatesLastVisibleLine = true
        l.preferredMaxLayoutWidth = align == .center ? 380 : 290
        l.isSelectable = false
        return l
    }
}
