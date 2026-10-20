import AppKit
import LimelightCore
import UniformTypeIdentifiers

enum Icons {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for r: SearchResult) -> NSImage {
        let key: String
        switch r.kind {
        case .app, .file, .folder: key = r.path ?? ""
        case .setting: key = "/System/Applications/System Settings.app"
        case .calculation: key = "/System/Applications/Calculator.app"
        case .web, .url: key = browserPath ?? "/Applications/Safari.app"
        case .command: return NSApp.applicationIconImage
        }
        if let hit = cache.object(forKey: key as NSString) { return hit }
        // Resolve symlinks (Safari lives in a cryptex, linked into /Applications) so icons carry no alias badge.
        let image = NSWorkspace.shared.icon(forFile: (key as NSString).resolvingSymlinksInPath)
        image.size = NSSize(width: 32, height: 32)
        cache.setObject(image, forKey: key as NSString)
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
        case .command: return "Command"
        case .folder: return "Folder"
        case .calculation: return "Calculator"
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
}

final class ResultRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 8, dy: 1)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

final class ResultCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ResultCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let accessory = NSTextField(labelWithString: "")
    private var result: SearchResult?
    private var query = ""
    private var flash: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        for label in [title, subtitle, accessory] {
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        subtitle.lineBreakMode = .byTruncatingMiddle
        accessory.alignment = .right
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.translatesAutoresizingMaskIntoConstraints = false
        for v in [icon, title, subtitle, accessory] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            title.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -12),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 0),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -12),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    func configure(_ r: SearchResult, query: String) {
        result = r
        self.query = query
        flash = nil
        icon.image = Icons.image(for: r)
        render()
    }

    func showFlash(_ text: String) {
        flash = text
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.flash == text else { return }
            self.flash = nil
            self.render()
        }
    }

    private func render() {
        guard let r = result else { return }
        let selected = backgroundStyle == .emphasized
        let primary: NSColor = selected ? .white : .labelColor
        let secondary: NSColor = selected ? NSColor.white.withAlphaComponent(0.78) : .secondaryLabelColor
        let tertiary: NSColor = selected ? NSColor.white.withAlphaComponent(0.85) : .tertiaryLabelColor

        let titleSize: CGFloat = r.kind == .calculation ? 17 : 14
        let text = NSMutableAttributedString(string: r.title, attributes: [
            .font: NSFont.systemFont(ofSize: titleSize, weight: r.kind == .calculation ? .semibold : .regular),
            .foregroundColor: primary,
        ])
        if r.kind != .calculation && r.kind != .web && r.kind != .url {
            for range in Matcher.highlights(for: query, in: r.title) {
                text.addAttribute(.font, value: NSFont.systemFont(ofSize: titleSize, weight: .bold), range: NSRange(range, in: r.title))
            }
        }
        title.attributedStringValue = text
        subtitle.attributedStringValue = NSAttributedString(string: r.subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: secondary,
        ])
        accessory.attributedStringValue = NSAttributedString(string: flash ?? Icons.kindLabel(for: r), attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: flash == nil ? .regular : .semibold), .foregroundColor: tertiary,
        ])
    }
}
