import Foundation

/// Remembers what you open and what you typed to get there, so the next search ranks it higher.
/// Weights halve every two weeks, so old habits fade.
public final class Frecency: @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        public var key: String
        public var kind: SearchResult.Kind
        public var title: String
        public var path: String?
        public var url: String?
        var weight: Double
        var last: TimeInterval
        var queries: [String: Double]
    }

    static let halfLife: TimeInterval = 14 * 86_400
    static let maxEntries = 400
    static let maxQueriesPerEntry = 12

    private var entries: [String: Entry] = [:]
    private let file: URL?
    private let lock = NSLock()
    private var saveScheduled = false

    public init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([Entry].self, from: data) {
            for e in list { entries[e.key] = e }
        }
    }

    public func record(_ result: SearchResult, query: String, now: Date = Date()) {
        let q = Fold.string(query.trimmingCharacters(in: .whitespaces))
        let t = now.timeIntervalSince1970
        lock.withLock {
            var e = entries[result.id] ?? Entry(
                key: result.id, kind: result.kind, title: result.title, path: result.path,
                url: result.url?.absoluteString, weight: 0, last: t, queries: [:]
            )
            e.weight = Self.decayed(e.weight, since: e.last, now: t) + 1
            e.last = t
            e.title = result.title
            if !q.isEmpty {
                e.queries[q, default: 0] += 1
                if e.queries.count > Self.maxQueriesPerEntry,
                   let weakest = e.queries.min(by: { $0.value < $1.value })?.key {
                    e.queries[weakest] = nil
                }
            }
            entries[result.id] = e
            if entries.count > Self.maxEntries {
                let doomed = entries.values
                    .sorted { Self.decayed($0.weight, since: $0.last, now: t) < Self.decayed($1.weight, since: $1.last, now: t) }
                    .prefix(entries.count - Self.maxEntries)
                for d in doomed { entries[d.key] = nil }
            }
        }
        scheduleSave()
    }

    public func forget(_ key: String) {
        lock.withLock { entries[key] = nil }
        scheduleSave()
    }

    /// Extra score for `key`: a general bonus for things you use, plus a larger one when you
    /// picked it after typing something that overlaps the current query.
    public func boost(for key: String, foldedQuery q: String, now: Date = Date()) -> Int {
        guard let e = lock.withLock({ entries[key] }) else { return 0 }
        let w = Self.decayed(e.weight, since: e.last, now: now.timeIntervalSince1970)
        var bonus = min(150, Int(50 * log2(1 + w)))
        if !q.isEmpty {
            var best = 0.0
            for (past, count) in e.queries where past.hasPrefix(q) || q.hasPrefix(past) {
                let overlap = Double(min(past.count, q.count)) / Double(max(past.count, q.count))
                best = max(best, count * overlap)
            }
            bonus += min(450, Int(220 * best))
        }
        return bonus
    }

    public func recent(limit: Int, now: Date = Date()) -> [Entry] {
        let t = now.timeIntervalSince1970
        return lock.withLock { Array(entries.values) }
            .sorted { Self.decayed($0.weight, since: $0.last, now: t) > Self.decayed($1.weight, since: $1.last, now: t) }
            .prefix(limit)
            .map { $0 }
    }

    static func decayed(_ weight: Double, since last: TimeInterval, now: TimeInterval) -> Double {
        weight * pow(0.5, max(0, now - last) / halfLife)
    }

    private func scheduleSave() {
        guard file != nil else { return }
        let shouldSchedule: Bool = lock.withLock {
            if saveScheduled { return false }
            saveScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in save() }
    }

    public func save() {
        guard let file else { return }
        let list: [Entry] = lock.withLock {
            saveScheduled = false
            return Array(entries.values)
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: file, options: .atomic) }
    }
}
