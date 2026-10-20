import Foundation

public struct SearchResult: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable { case app, setting, command, folder, file, calculation, web, url }

    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String
    public let path: String?
    public let url: URL?
    public let copyText: String?
    public var score: Int

    public init(id: String, kind: Kind, title: String, subtitle: String, path: String? = nil, url: URL? = nil, copyText: String? = nil, score: Int) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.path = path
        self.url = url
        self.copyText = copyText
        self.score = score
    }
}

public struct WebSearchProvider: Sendable, Hashable, Codable {
    public let name: String
    public let template: String

    public static let all: [WebSearchProvider] = [
        .init(name: "Google", template: "https://www.google.com/search?q=%s"),
        .init(name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s"),
        .init(name: "Bing", template: "https://www.bing.com/search?q=%s"),
        .init(name: "Kagi", template: "https://kagi.com/search?q=%s"),
        .init(name: "Brave Search", template: "https://search.brave.com/search?q=%s"),
    ]

    public func url(for query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }
}

/// Merges apps, settings, files, math and URLs into one ranked list.
public final class SearchEngine: @unchecked Sendable {
    public let files: FileIndex
    public let frecency: Frecency
    public let home: String
    private let lock = NSLock()
    private var _catalog: [CatalogItem] = []
    private var catalogPaths = Set<String>()
    private var _web = WebSearchProvider.all[0]

    public init(files: FileIndex, frecency: Frecency, home: String = NSHomeDirectory()) {
        self.files = files
        self.frecency = frecency
        self.home = home
    }

    public var catalog: [CatalogItem] {
        get { lock.withLock { _catalog } }
        set {
            lock.withLock {
                _catalog = newValue
                catalogPaths = Set(newValue.compactMap(\.path))
            }
        }
    }

    public var webSearch: WebSearchProvider {
        get { lock.withLock { _web } }
        set { lock.withLock { _web = newValue } }
    }

    public func search(_ raw: String, limit: Int = 40) -> [SearchResult] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return recents(limit: 8) }
        if query.hasPrefix("/") || query.hasPrefix("~") { return browse(query, limit: limit) }

        var results: [SearchResult] = []
        if let answer = Calculator.evaluate(query) {
            results.append(SearchResult(
                id: "calc", kind: .calculation, title: answer.display, subtitle: query,
                copyText: answer.copyText, score: 100_000
            ))
        }
        if let url = Self.urlCandidate(query) {
            results.append(SearchResult(
                id: "url:" + url.absoluteString, kind: .url, title: "Open " + query, subtitle: url.absoluteString,
                url: url, score: 700
            ))
        }

        let folded = Fold.string(query)
        let whole = Fold.bytes(query)
        let tokens = Fold.tokens(query)
        let (items, appPaths) = lock.withLock { (_catalog, catalogPaths) }

        var catalogHits: [(item: CatalogItem, raw: Int)] = []
        for item in items {
            var s = Matcher.score(whole, in: item.foldedName, original: item.originalName, fuzzy: true)
            if s == 0, tokens.count > 1 {
                let parts = tokens.map { Matcher.score($0, in: item.foldedName, original: item.originalName) }
                if !parts.contains(0) { s = parts.reduce(0, +) / parts.count - 30 }
            }
            for keyword in item.foldedKeywords {
                let k = Matcher.score(whole, in: keyword)
                if k >= Matcher.wordPrefix { s = max(s, k * 85 / 100) }
            }
            if whole.count == 1 && s < Matcher.wordPrefix { continue }
            if item.kind == .command && s < Matcher.prefix { continue }
            if s > 0 { catalogHits.append((item, s)) }
        }
        // Typo and fuzzy matches are a fallback; once something matches properly they are just noise.
        let hasRealMatch = catalogHits.contains { $0.raw >= Matcher.substring }
        for (item, raw) in catalogHits where !hasRealMatch || raw >= Matcher.substring {
            var s = raw
            switch item.kind {
            case .app: s += 250
            case .setting: s += 120
            case .command: break
            }
            s += frecency.boost(for: item.key, foldedQuery: folded)
            results.append(result(for: item, score: s))
        }

        if whole.count >= 2 {
            let hasAnswer = results.contains { $0.kind == .calculation }
            for hit in files.search(tokens, limit: 60) {
                if hit.isPackage, appPaths.contains(hit.path) { continue }
                if hasAnswer && hit.score < 700 { continue }
                let kind: SearchResult.Kind = hit.isDirectory ? .folder : .file
                let id = hit.path
                results.append(SearchResult(
                    id: id, kind: kind, title: hit.name, subtitle: abbreviate((hit.path as NSString).deletingLastPathComponent),
                    path: hit.path, score: hit.score + frecency.boost(for: id, foldedQuery: folded)
                ))
            }
        }

        var seen = Set<String>()
        results = results
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.title.count < $1.title.count }
            .filter { seen.insert($0.id).inserted }
        results = Array(results.prefix(limit))

        let web = webSearch
        if let url = web.url(for: query) {
            results.append(SearchResult(
                id: "web", kind: .web, title: "Search \(web.name) for “\(query)”", subtitle: url.host ?? "",
                url: url, score: -1
            ))
        }
        return results
    }

    func result(for item: CatalogItem, score: Int) -> SearchResult {
        let subtitle: String
        switch item.kind {
        case .app: subtitle = abbreviate(item.path ?? "")
        case .setting: subtitle = "System Settings"
        case .command: subtitle = "Limelight"
        }
        return SearchResult(id: item.key, kind: SearchResult.Kind(rawValue: item.kind.rawValue)!, title: item.name,
                            subtitle: subtitle, path: item.path, url: item.url, score: score)
    }

    /// What you opened most, shown before you type anything.
    func recents(limit: Int) -> [SearchResult] {
        let fm = FileManager.default
        let items = lock.withLock { _catalog }
        var out: [SearchResult] = []
        for e in frecency.recent(limit: limit * 2) where out.count < limit {
            if let item = items.first(where: { $0.key == e.key }) {
                out.append(result(for: item, score: 0))
            } else if let path = e.path, fm.fileExists(atPath: path) {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: path, isDirectory: &isDir)
                out.append(SearchResult(
                    id: e.key, kind: isDir.boolValue && !path.hasSuffix(".app") ? .folder : .file, title: e.title,
                    subtitle: abbreviate((path as NSString).deletingLastPathComponent), path: path, score: 0
                ))
            }
        }
        return out
    }

    /// Typing a path lists that folder live, like a shell with tab completion.
    func browse(_ query: String, limit: Int) -> [SearchResult] {
        let expanded = (query as NSString).expandingTildeInPath
        let fm = FileManager.default
        let dir: String
        let filter: String
        if query.hasSuffix("/") {
            dir = expanded
            filter = ""
        } else {
            dir = (expanded as NSString).deletingLastPathComponent
            filter = (expanded as NSString).lastPathComponent
        }
        var results: [SearchResult] = []
        var isDir: ObjCBool = false
        if !query.hasSuffix("/"), query != "~", fm.fileExists(atPath: expanded, isDirectory: &isDir) {
            results.append(fileResult(expanded, isDirectory: isDir.boolValue, score: 10_000))
        }
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return results }
        let f = Fold.bytes(filter)
        var scored: [(String, Int)] = []
        for name in names {
            if name.hasPrefix(".") && !filter.hasPrefix(".") { continue }
            if f.isEmpty {
                // Folders first, then files, each alphabetical.
                let isFolder = fm.fileExists(atPath: (dir as NSString).appendingPathComponent(name), isDirectory: &isDir)
                    && isDir.boolValue && !IndexConfig.packageExtensions.contains((name as NSString).pathExtension.lowercased())
                scored.append((name, isFolder ? 1 : 0))
                continue
            }
            let s = Matcher.score(f, in: Fold.bytes(name), original: Array(name.utf8), fuzzy: true)
            if s > 0 { scored.append((name, s)) }
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        for (name, s) in scored.prefix(limit) {
            let path = (dir as NSString).appendingPathComponent(name)
            if path == expanded { continue }
            fm.fileExists(atPath: path, isDirectory: &isDir)
            results.append(fileResult(path, isDirectory: isDir.boolValue, score: s))
        }
        return results
    }

    func fileResult(_ path: String, isDirectory: Bool, score: Int) -> SearchResult {
        let isFolder = isDirectory && !IndexConfig.packageExtensions.contains((path as NSString).pathExtension.lowercased())
        return SearchResult(
            id: path, kind: isFolder ? .folder : .file, title: displayName(path),
            subtitle: abbreviate((path as NSString).deletingLastPathComponent), path: path, score: score
        )
    }

    private func displayName(_ path: String) -> String {
        path == "/" ? "Macintosh HD" : (path as NSString).lastPathComponent
    }

    public func abbreviate(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static let urlPattern = try! NSRegularExpression(
        pattern: #"^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+(?:com|org|net|io|dev|ai|co|edu|gov|me|us|uk|de|fr|ca|au|jp|xyz|gg|tv|ly|fm|eu|nl|ch)(?::\d+)?(?:/\S*)?$"#,
        options: [.caseInsensitive]
    )

    static func urlCandidate(_ q: String) -> URL? {
        guard !q.contains(" ") else { return nil }
        let lower = q.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: q), url.host != nil else { return nil }
            return url
        }
        if lower.hasPrefix("localhost:") { return URL(string: "http://" + q) }
        let range = NSRange(q.startIndex..., in: q)
        guard urlPattern.firstMatch(in: q, range: range) != nil else { return nil }
        return URL(string: "https://" + q)
    }
}
