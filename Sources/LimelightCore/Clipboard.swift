import Foundation

/// Text you copied recently, kept in memory only and dropped after eight hours.
public final class ClipboardHistory: @unchecked Sendable {
    public struct Entry: Sendable, Equatable {
        public let id: UUID
        public let text: String
        public let date: Date
        public let source: String?
        let folded: [UInt8]
    }

    public static let retention: TimeInterval = 8 * 3600
    static let maxEntries = 200
    private var entries: [Entry] = []
    private let lock = NSLock()

    public init() {}

    public func add(_ text: String, source: String?, date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = Entry(id: UUID(), text: text, date: date, source: source, folded: Fold.bytes(String(text.prefix(4000))))
        lock.withLock {
            entries.removeAll { $0.text == text }
            entries.insert(entry, at: 0)
            if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        }
    }

    public func clear() { lock.withLock { entries.removeAll() } }

    public var count: Int { lock.withLock { entries.count } }

    public func search(_ query: String, now: Date = Date()) -> [SearchResult] {
        let live: [Entry] = lock.withLock {
            entries.removeAll { now.timeIntervalSince($0.date) > Self.retention }
            return entries
        }
        let tokens = Fold.tokens(query)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return live.compactMap { e in
            guard tokens.allSatisfy({ FileIndex.contains(e.folded, $0) }) else { return nil }
            let firstLine = e.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? e.text
            var when = formatter.localizedString(for: e.date, relativeTo: now)
            if let source = e.source { when += " · " + source }
            return SearchResult(
                id: "clip:" + e.id.uuidString, kind: .clipboard,
                title: String(firstLine.trimmingCharacters(in: .whitespaces).prefix(200)), subtitle: when,
                copyText: e.text, detail: e.text, date: e.date, score: 0
            )
        }
    }
}
