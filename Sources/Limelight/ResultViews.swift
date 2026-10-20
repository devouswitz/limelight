import AppKit
import LimelightCore
import UniformTypeIdentifiers

enum Icons {
    private static let cache = NSCache<NSString, NSImage>()

    /// SF Symbols for built-in actions, keyed by result id.
    static var symbols: [String: String] = [:]

    static func image(for r: SearchResult, size: CGFloat = 32) -> NSImage {
        if let symbol = symbols[r.id] {
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.6, weight: .medium)
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
            return image
        }
        let key: String
        switch r.kind {
        case .app, .file, .folder: key = r.path ?? ""
        case .setting: key = "/System/Applications/System Settings.app"
        case .calculation: key = "/System/Applications/Calculator.app"
        case .definition: key = "/System/Applications/Dictionary.app"
        case .web, .url: key = browserPath ?? "/Applications/Safari.app"
        case .action: key = r.id.hasPrefix("shortcut:") ? "/System/Applications/Shortcuts.app" : ""
        case .clipboard:
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.55, weight: .regular)
            return NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
        case .command: return NSApp.applicationIconImage
        }
        let cacheKey = "\(key)#\(Int(size))" as NSString
        if let hit = cache.object(forKey: cacheKey) { return hit }
        // Resolve symlinks (Safari lives in a cryptex, linked into /Applications) so icons carry no alias badge.
        let image = NSWorkspace.shared.icon(forFile: (key as NSString).resolvingSymlinksInPath)
        image.size = NSSize(width: size, height: size)
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    private static let browserPath: String? = {
        guard let probe = URL(string: "https://example.com") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)?.path
    }()

    static func kindLabel(for r: SearchResult) -> String {
        switch r.kind {
        case .app: return "Application"
        case .setting: return "System Settings"
        case .command: return "Limelight"
        case .action: return r.subtitle
        case .folder: return "Folder"
        case .calculation: return "Calculator"
        case .definition: return "Dictionary"
        case .clipboard: return "Clipboard"
        case .web: return "Web Search"
        case .url: return "Website"
        case .file:
            let ext = ((r.path ?? r.title) as NSString).pathExtension
            if !ext.isEmpty, let type = UTType(filenameExtension: ext), let name = type.localizedDescription {
                return name.prefix(1).uppercased() + name.dropFirst()
            }
            return "Document"
        }
    }

    /// The dim text after a row's name: the containing folder for files, the time for clipboard entries.
    static func hint(for r: SearchResult) -> String? {
        switch r.kind {
        case .file, .folder:
            guard let path = r.path else { return nil }
            let parent = (path as NSString).deletingLastPathComponent
            return parent == NSHomeDirectory() ? "Home" : (parent as NSString).lastPathComponent
        case .clipboard: return r.subtitle
        case .calculation: return r.subtitle
        default: return nil
        }
    }
}

final class ResultRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 0), xRadius: 7, yRadius: 7).fill()
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

final class SectionHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SectionHeader")
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ title: String) { label.stringValue = title }
}

final class ResultCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ResultCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let flashLabel = NSTextField(labelWithString: "")
    private var result: SearchResult?
    private var query = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.usesSingleLineMode = true
        title.cell?.wraps = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        flashLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        flashLabel.isHidden = true
        for v in [icon, title, flashLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: flashLabel.leadingAnchor, constant: -6),
            flashLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            flashLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    func configure(_ r: SearchResult, query: String) {
        result = r
        self.query = query
        flashLabel.isHidden = true
        icon.image = Icons.image(for: r, size: 20)
        icon.contentTintColor = nil
        render()
    }

    func showFlash(_ text: String) {
        flashLabel.stringValue = text
        flashLabel.isHidden = false
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.flashLabel.isHidden = true
        }
    }

    private func render() {
        guard let r = result else { return }
        let selected = backgroundStyle == .emphasized
        let primary: NSColor = selected ? .white : .labelColor
        let dim: NSColor = selected ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor
        icon.contentTintColor = selected ? .white : .secondaryLabelColor
        flashLabel.textColor = dim

        let font = NSFont.systemFont(ofSize: 13.5)
        let oneLine = NSMutableParagraphStyle()
        oneLine.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: r.title, attributes: [.font: font, .foregroundColor: primary, .paragraphStyle: oneLine])
        if [.app, .file, .folder, .setting, .action, .command].contains(r.kind) {
            for range in Matcher.highlights(for: query, in: r.title) {
                text.addAttribute(.font, value: NSFont.systemFont(ofSize: 13.5, weight: .semibold), range: NSRange(range, in: r.title))
            }
        }
        if let hint = Icons.hint(for: r), !hint.isEmpty {
            text.append(NSAttributedString(string: "  —  " + hint, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: dim, .paragraphStyle: oneLine]))
        }
        title.attributedStringValue = text
    }
}
