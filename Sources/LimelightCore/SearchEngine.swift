import Foundation

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
    private var _runningAppPaths = Set<String>()
    public let clipboard = ClipboardHistory()

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

    /// Paths of apps currently running; set by the app before each search session.
    public var runningAppPaths: Set<String> {
        get { lock.withLock { _runningAppPaths } }
        set { lock.withLock { _runningAppPaths = newValue } }
    }

    public var webSearch: WebSearchProvider {
        get { lock.withLock { _web } }
        set { lock.withLock { _web = newValue } }
    }

    /// Results ranked best first. `grouped` lays them out in sections for display.
    public func search(_ raw: String, mode: SearchMode = .all, limit: Int = 40) -> [SearchResult] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .clipboard:
            return clipboard.search(query)
        case .applications:
            return query.isEmpty ? allApps() : catalogResults(query, kinds: [.app])
        case .actions:
            return query.isEmpty ? allActions() : catalogResults(query, kinds: [.action, .command])
        case .files:
            if query.hasPrefix("/") || query.hasPrefix("~") { return browse(query, limit: 200) }
            if query.isEmpty { return recentFiles(limit: 60) }
            return ranked(fileResults(query, limit: 150), limit: 150)
        case .all:
            break
        }
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

        results += catalogResults(query, kinds: [.app, .setting, .command, .action])
        if Fold.bytes(query).count >= 2 {
            let hasAnswer = results.contains { $0.kind == .calculation }
            results += fileResults(query, limit: 60).filter { !hasAnswer || $0.score >= 700 }
        }
        if let text = Definitions.lookup(query) {
            results.append(SearchResult(
                id: "define:" + query.lowercased(), kind: .definition, title: query, subtitle: Definitions.summary(text),
                copyText: text, detail: Definitions.formatted(text), score: 300
            ))
        }
        results = ranked(results, limit: limit)

        let web = webSearch
        if let url = web.url(for: query) {
            results.append(SearchResult(
                id: "web", kind: .web, title: "Search \(web.name) for “\(query)”", subtitle: url.host ?? "",
                url: url, score: -1
            ))
        }
        return results
    }

    public func grouped(_ results: [SearchResult], mode: SearchMode, query: String) -> [ResultGroup] {
        Grouping.group(results, mode: mode, query: query)
    }

    /// Best score first; equal scores go to the more recently used or changed item, then the shorter name.
    func ranked(_ results: [SearchResult], limit: Int) -> [SearchResult] {
        var seen = Set<String>()
        return Array(results.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let da = a.date ?? .distantPast, db = b.date ?? .distantPast
            if da != db { return da > db }
            return a.title.count < b.title.count
        }
        .filter { seen.insert($0.id).inserted }
        .prefix(limit))
    }

    func catalogResults(_ query: String, kinds: Set<CatalogItem.Kind>) -> [SearchResult] {
        let folded = Fold.string(query)
        let whole = Fold.bytes(query)
        let tokens = Fold.tokens(query)
        let (items, running) = lock.withLock { (_catalog, _runningAppPaths) }
        let now = Date()

        var hits: [(item: CatalogItem, raw: Int)] = []
        for item in items where kinds.contains(item.kind) {
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
            // Commands only answer to a deliberate prefix, so they don't crowd ordinary searches.
            if kinds.count > 2 && (item.kind == .command || item.kind == .action) && (s < Matcher.wordPrefix || whole.count < 2) { continue }
            if s > 0 { hits.append((item, s)) }
        }
        // Typo and fuzzy matches are a fallback; once something matches properly they are just noise.
        let hasRealMatch = hits.contains { $0.raw >= Matcher.substring }
        return hits.filter { !hasRealMatch || $0.raw >= Matcher.substring }.map { item, raw in
            var s = raw
            switch item.kind {
            case .app:
                // Apps you use, apps just built or updated, and apps already running come first among equals.
                s += 250
                s += Recency.bonus(item.lastUsed, now: now, max: 60, horizonDays: 90)
                s += Recency.bonus(item.updated, now: now, max: 25, horizonDays: 60)
                if let p = item.path, running.contains(p) { s += 30 }
            case .setting: s += 120
            case .action: s += 60
            case .command: break
            }
            s += frecency.boost(for: item.key, foldedQuery: folded)
            return result(for: item, score: s)
        }
    }

    func fileResults(_ query: String, limit: Int) -> [SearchResult] {
        let folded = Fold.string(query)
        let appPaths = lock.withLock { catalogPaths }
        return files.search(Fold.tokens(query), limit: limit).compactMap { hit in
            if hit.isPackage, appPaths.contains(hit.path) { return nil }
            return SearchResult(
                id: hit.path, kind: hit.isDirectory ? .folder : .file, title: hit.name,
                subtitle: abbreviate((hit.path as NSString).deletingLastPathComponent), path: hit.path,
                date: hit.modified, score: hit.score + frecency.boost(for: hit.path, foldedQuery: folded)
            )
        }
    }

    func allApps() -> [SearchResult] {
        lock.withLock { _catalog }.filter { $0.kind == .app }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { result(for: $0, score: 0) }
    }

    func allActions() -> [SearchResult] {
        lock.withLock { _catalog }.filter { $0.kind == .action || $0.kind == .command }
            .map { result(for: $0, score: 0) }
    }

    func recentFiles(limit: Int) -> [SearchResult] {
        files.recent(limit: limit).map { hit in
            SearchResult(
                id: hit.path, kind: hit.isDirectory ? .folder : .file, title: hit.name,
                subtitle: abbreviate((hit.path as NSString).deletingLastPathComponent), path: hit.path,
                date: hit.modified, score: 0
            )
        }
    }

    func result(for item: CatalogItem, score: Int) -> SearchResult {
        let subtitle: String
        switch item.kind {
        case .app: subtitle = abbreviate(item.path ?? "")
        case .setting: subtitle = "System Settings"
        case .command: subtitle = "Limelight"
        case .action: subtitle = item.subtitle ?? "Action"
        }
        return SearchResult(id: item.key, kind: SearchResult.Kind(rawValue: item.kind.rawValue)!, title: item.name,
                            subtitle: subtitle, path: item.path, url: item.url,
                            date: [item.lastUsed, item.updated].compactMap { $0 }.max(), score: score)
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
