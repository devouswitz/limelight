import Foundation
import Darwin

public struct IndexConfig: Sendable, Equatable, Codable {
    public var roots: [String]
    public var excludedPaths: [String]
    public var excludedNames: [String]
    public var includeHidden: Bool

    public init(roots: [String], excludedPaths: [String], excludedNames: [String], includeHidden: Bool) {
        self.roots = roots
        self.excludedPaths = excludedPaths
        self.excludedNames = excludedNames
        self.includeHidden = includeHidden
    }

    /// Home folder and iCloud Drive, minus ~/Library and build/dependency folders that bury real results.
    public static func standard(home: String = NSHomeDirectory()) -> IndexConfig {
        var roots = [home]
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: iCloud) { roots.append(iCloud) }
        return IndexConfig(
            roots: roots,
            excludedPaths: [home + "/Library"],
            excludedNames: [
                "node_modules", "bower_components", "__pycache__", "site-packages", "DerivedData",
                "Pods", "venv", "Carthage", "$RECYCLE.BIN",
            ],
            includeHidden: false
        )
    }

    /// Bundles that Finder shows as single files. They are indexed but not descended into.
    public static let packageExtensions: Set<String> = [
        "app", "appex", "band", "bundle", "docarchive", "dsym", "fcpbundle", "framework", "imovielibrary",
        "kext", "key", "logicx", "mdimporter", "musiclibrary", "numbers", "pages", "photoslibrary",
        "playground", "plugin", "prefpane", "qlgenerator", "rtfd", "saver", "scptd", "sparsebundle",
        "swiftpm", "textbundle", "tvlibrary", "xcarchive", "xcassets", "xcframework", "xcodeproj",
        "xcresult", "xcworkspace",
    ]
}

/// One directory's children, stored as packed byte buffers to keep a million entries small.
final class DirNode: @unchecked Sendable {
    static let isDirectory: UInt8 = 1
    static let isPackage: UInt8 = 2

    let path: String
    let foldedPath: [UInt8]
    let depth: Int
    let names: [UInt8]
    let nameStarts: [UInt32]
    let folded: [UInt8]
    let foldedStarts: [UInt32]
    let flags: [UInt8]
    let mtimes: [UInt32]
    /// Inside a build, cache or vendored-dependency folder. Still searchable, just ranked lower.
    let isNoisy: Bool

    var count: Int { flags.count }

    static let noiseMarkers: [[UInt8]] = [
        "/build/", "/.build/", "build-cache/", "/deriveddata/", "/intermediates", "/products/", "/cache/",
        "/caches/", "/index/store/", "/datastore/", "/dist/", "/target/", "/vendor/", "/deps/", "/out/",
        "/obj/", "/.git/", "/tmp/", "/temp/", "/logs/",
    ].map { Array($0.utf8) }

    init(builder b: NodeBuilder, home: String) {
        path = b.path
        var rel = b.path
        if rel == home { rel = "~" } else if rel.hasPrefix(home + "/") { rel = "~" + rel.dropFirst(home.count) }
        foldedPath = Fold.bytes(rel)
        depth = rel.utf8.reduce(0) { $1 == 47 ? $0 + 1 : $0 }
        names = b.names
        nameStarts = b.nameStarts
        folded = b.folded
        foldedStarts = b.foldedStarts
        flags = b.flags
        mtimes = b.mtimes
        let probe = foldedPath + [47]
        isNoisy = DirNode.noiseMarkers.contains { FileIndex.contains(probe, $0) }
    }

    func name(at i: Int) -> String {
        String(decoding: names[Int(nameStarts[i])..<Int(nameStarts[i + 1])], as: UTF8.self)
    }

    var childDirectoryPaths: Set<String> {
        var out = Set<String>()
        for i in 0..<count where flags[i] & DirNode.isDirectory != 0 { out.insert(path + "/" + name(at: i)) }
        return out
    }
}

struct NodeBuilder {
    let path: String
    let level: Int
    var names: [UInt8] = []
    var nameStarts: [UInt32] = [0]
    var folded: [UInt8] = []
    var foldedStarts: [UInt32] = [0]
    var flags: [UInt8] = []
    var mtimes: [UInt32] = []

    init(path: String, level: Int) {
        self.path = path
        self.level = level
    }

    mutating func add(_ name: UnsafeBufferPointer<UInt8>, flags f: UInt8, mtime: Int) {
        names.append(contentsOf: name)
        nameStarts.append(UInt32(names.count))
        if name.contains(where: { $0 >= 0x80 }) {
            folded.append(contentsOf: Fold.bytes(String(decoding: name, as: UTF8.self)))
        } else {
            for b in name { folded.append(b &- 65 < 26 ? b &+ 32 : b) }
        }
        foldedStarts.append(UInt32(folded.count))
        flags.append(f)
        mtimes.append(UInt32(clamping: max(0, mtime)))
    }
}

/// An in-memory index of file and folder names, kept current by `FileWatcher`.
public final class FileIndex: @unchecked Sendable {
    public struct Hit: Sendable, Equatable {
        public let path: String
        public let name: String
        public let isDirectory: Bool
        public let isPackage: Bool
        public let score: Int
        public let modified: Date
    }

    public let home: String
    private let lock = NSLock()
    private var nodes: [String: DirNode] = [:]
    private var ordered: [DirNode] = []
    private var orderedIsStale = false
    private var _config: IndexConfig
    private var _itemCount = 0
    private var _isReady = false
    private var _lastBuilt: Date?
    private var crawling = false
    private var deferred: [(path: String, deep: Bool)] = []
    private let work = DispatchQueue(label: "limelight.index", qos: .utility)

    /// Called on the index queue after the contents change.
    public var onChange: (() -> Void)?

    public init(config: IndexConfig, home: String = NSHomeDirectory()) {
        _config = config
        self.home = home
    }

    public var config: IndexConfig { lock.withLock { _config } }
    public var itemCount: Int { lock.withLock { _itemCount } }
    public var isReady: Bool { lock.withLock { _isReady } }
    public var lastBuilt: Date? { lock.withLock { _lastBuilt } }
    public var isCrawling: Bool { lock.withLock { crawling } }

    // MARK: - Building

    public func rebuild(config newConfig: IndexConfig? = nil, completion: (() -> Void)? = nil) {
        lock.withLock {
            if let newConfig { _config = newConfig }
            crawling = true
        }
        work.async { [self] in
            let cfg = config
            var fresh: [String: DirNode] = [:]
            for node in Self.parallelCrawl(cfg.roots.map(Self.standardize), config: cfg, home: home) { fresh[node.path] = node }
            let total = fresh.values.reduce(0) { $0 + $1.count }
            let pending: [(path: String, deep: Bool)] = lock.withLock {
                nodes = fresh
                orderedIsStale = true
                _itemCount = total
                _isReady = true
                _lastBuilt = Date()
                crawling = false
                defer { deferred.removeAll() }
                return deferred
            }
            if !pending.isEmpty { apply(pending) }
            onChange?()
            completion?()
        }
    }

    /// Re-reads directories after file system events. `deep` re-crawls the whole subtree.
    public func refresh(_ paths: [String], deep: Bool = false) {
        let entries = paths.map { (path: $0, deep: deep) }
        let queued: Bool = lock.withLock {
            if crawling { deferred.append(contentsOf: entries); return true }
            return false
        }
        if queued { return }
        work.async { [self] in
            apply(entries)
            onChange?()
        }
    }

    /// Blocks until queued index work has finished. For tests and the CLI.
    public func waitUntilIdle() { work.sync {} }

    private func apply(_ entries: [(path: String, deep: Bool)]) {
        let cfg = config
        var targets: [String: Bool] = [:]
        for (path, deep) in entries {
            let p = Self.standardize(path)
            let parent = (p as NSString).deletingLastPathComponent
            let known = lock.withLock { (nodes[p] != nil, nodes[parent] != nil) }
            if known.0 { targets[p] = (targets[p] ?? false) || deep }
            if known.1 { targets[parent] = targets[parent] ?? false }
        }
        for (dir, deep) in targets.sorted(by: { $0.key < $1.key }) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
                removeSubtree(dir, includingSelf: true)
                continue
            }
            if deep {
                removeSubtree(dir, includingSelf: true)
                var added: [DirNode] = []
                Self.crawl(dir, maxDepth: nil, config: cfg, home: home) { added.append($0) }
                insert(added)
                continue
            }
            var shallow: [DirNode] = []
            Self.crawl(dir, maxDepth: 1, config: cfg, home: home) { shallow.append($0) }
            guard let node = shallow.first(where: { $0.path == dir }) else { continue }
            let old = lock.withLock { nodes[dir] }
            let before = old?.childDirectoryPaths ?? []
            let after = node.childDirectoryPaths
            insert([node])
            for gone in before.subtracting(after) { removeSubtree(gone, includingSelf: true) }
            for new in after.subtracting(before) {
                var added: [DirNode] = []
                Self.crawl(new, maxDepth: nil, config: cfg, home: home) { added.append($0) }
                insert(added)
            }
        }
    }

    private func insert(_ list: [DirNode]) {
        lock.withLock {
            for n in list {
                _itemCount += n.count - (nodes[n.path]?.count ?? 0)
                nodes[n.path] = n
            }
            orderedIsStale = true
        }
    }

    private func removeSubtree(_ dir: String, includingSelf: Bool) {
        let prefix = dir + "/"
        lock.withLock {
            let doomed = nodes.keys.filter { ($0 == dir && includingSelf) || $0.hasPrefix(prefix) }
            for key in doomed {
                _itemCount -= nodes[key]?.count ?? 0
                nodes[key] = nil
            }
            if !doomed.isEmpty { orderedIsStale = true }
        }
    }

    private func snapshot() -> [DirNode] {
        lock.withLock {
            if orderedIsStale {
                ordered = Array(nodes.values)
                orderedIsStale = false
            }
            return ordered
        }
    }

    public static func realPath(_ path: String) -> String { standardize(path) }

    /// Resolves symlinks the way FSEvents reports paths (/var → /private/var), even for paths that no longer exist.
    static func standardize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        if let real = realpath(p, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        let parent = (p as NSString).deletingLastPathComponent
        guard parent != p, parent != "/" else { return p }
        return (standardize(parent) as NSString).appendingPathComponent((p as NSString).lastPathComponent)
    }

    /// Reads the top two levels one folder at a time, then crawls everything below them in parallel.
    static func parallelCrawl(_ roots: [String], config: IndexConfig, home: String) -> [DirNode] {
        var all: [DirNode] = []
        var frontier = roots
        for _ in 0..<2 {
            var next: [String] = []
            for dir in frontier {
                crawl(dir, maxDepth: 1, config: config, home: home) { node in
                    all.append(node)
                    next.append(contentsOf: node.childDirectoryPaths)
                }
            }
            frontier = next
        }
        var parts = [[DirNode]](repeating: [], count: frontier.count)
        parts.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: frontier.count) { i in
                var local: [DirNode] = []
                crawl(frontier[i], maxDepth: nil, config: config, home: home) { local.append($0) }
                out[i] = local
            }
        }
        for p in parts { all.append(contentsOf: p) }
        return all
    }

    /// Walks `root` with fts(3), emitting one node per directory.
    static func crawl(_ root: String, maxDepth: Int?, config: IndexConfig, home: String, emit: (DirNode) -> Void) {
        let excludedNames = Set(config.excludedNames)
        let excludedPaths = Set(config.excludedPaths.map(standardize))
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(root), nil]
        defer { free(argv[0]) }
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(fts) }

        var stack: [NodeBuilder] = []
        while let ent = fts_read(fts) {
            let e = ent.pointee
            let level = Int(e.fts_level)
            let info = Int32(e.fts_info)
            let namePtr = UnsafeRawPointer(e.fts_path + (Int(e.fts_pathlen) - Int(e.fts_namelen)))
                .assumingMemoryBound(to: UInt8.self)
            let name = UnsafeBufferPointer(start: namePtr, count: Int(e.fts_namelen))
            let mtime = e.fts_statp.map { Int($0.pointee.st_mtimespec.tv_sec) } ?? 0

            if info == FTS_DP {
                if let top = stack.last, top.level == level {
                    emit(DirNode(builder: top, home: home))
                    stack.removeLast()
                }
                continue
            }
            if level == 0 {
                if info == FTS_D { stack.append(NodeBuilder(path: String(cString: e.fts_path), level: 0)) }
                continue
            }
            let hidden = name.first == 46
            if hidden && !config.includeHidden {
                if info == FTS_D { fts_set(fts, ent, FTS_SKIP) }
                continue
            }
            switch info {
            case FTS_D:
                let nameString = String(decoding: name, as: UTF8.self)
                let path = String(cString: e.fts_path)
                if excludedNames.contains(nameString) || excludedPaths.contains(path) || nameString.hasSuffix(".noindex") {
                    fts_set(fts, ent, FTS_SKIP)
                    continue
                }
                let ext = (nameString as NSString).pathExtension.lowercased()
                let isPackage = !ext.isEmpty && IndexConfig.packageExtensions.contains(ext)
                stack[stack.count - 1].add(name, flags: isPackage ? DirNode.isPackage : DirNode.isDirectory, mtime: mtime)
                if isPackage || (maxDepth.map { level >= $0 } ?? false) {
                    fts_set(fts, ent, FTS_SKIP)
                } else {
                    stack.append(NodeBuilder(path: path, level: level))
                }
            case FTS_DNR:
                stack[stack.count - 1].add(name, flags: DirNode.isDirectory, mtime: mtime)
            case FTS_DC:
                continue
            default:
                if name.count == 5, String(decoding: name, as: UTF8.self) == "Icon\r" { continue }
                stack[stack.count - 1].add(name, flags: 0, mtime: mtime)
            }
        }
    }

    // MARK: - Searching

    /// Every token must hit the file name or one of its parent folders, and at least one must hit the name.
    public func search(_ tokens: [[UInt8]], limit: Int = 60, now: Date = Date()) -> [Hit] {
        guard !tokens.isEmpty else { return [] }
        let nodes = snapshot()
        guard !nodes.isEmpty else { return [] }
        let nowSeconds = Int(now.timeIntervalSince1970)
        let shortQuery = tokens.count == 1 && tokens[0].count < 3
        let chunks = min(nodes.count, ProcessInfo.processInfo.activeProcessorCount * 4)
        var partials = [[Candidate]](repeating: [], count: chunks)

        partials.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                var top = TopK(limit: limit)
                var pathHits = [Bool](repeating: false, count: tokens.count)
                var ni = chunk
                while ni < nodes.count {
                    let node = nodes[ni]
                    if tokens.count > 1 {
                        for k in tokens.indices { pathHits[k] = Self.contains(node.foldedPath, tokens[k]) }
                    }
                    Self.scan(node, nodeIndex: ni, tokens: tokens, pathHits: pathHits, shortQuery: shortQuery, now: nowSeconds, into: &top)
                    ni += chunks
                }
                out[chunk] = top.sorted()
            }
        }

        var merged = TopK(limit: limit)
        for list in partials { for c in list { merged.push(c) } }
        return merged.sorted().map { c in
            let node = nodes[c.node]
            let name = node.name(at: c.entry)
            let f = node.flags[c.entry]
            return Hit(
                path: node.path + "/" + name,
                name: name,
                isDirectory: f & DirNode.isDirectory != 0,
                isPackage: f & DirNode.isPackage != 0,
                score: c.score,
                modified: Date(timeIntervalSince1970: TimeInterval(node.mtimes[c.entry]))
            )
        }
    }

    /// The most recently modified files, outside build and cache folders.
    public func recent(limit: Int) -> [Hit] {
        let nodes = snapshot()
        var top = TopK(limit: limit)
        for (ni, node) in nodes.enumerated() where !node.isNoisy {
            for e in 0..<node.count where node.flags[e] & DirNode.isDirectory == 0 {
                top.push(Candidate(score: Int(node.mtimes[e]), node: ni, entry: e))
            }
        }
        return top.sorted().map { c in
            let node = nodes[c.node]
            let name = node.name(at: c.entry)
            return Hit(path: node.path + "/" + name, name: name, isDirectory: false,
                       isPackage: node.flags[c.entry] & DirNode.isPackage != 0, score: 0,
                       modified: Date(timeIntervalSince1970: TimeInterval(node.mtimes[c.entry])))
        }
    }

    private static func scan(_ node: DirNode, nodeIndex: Int, tokens: [[UInt8]], pathHits: [Bool], shortQuery: Bool, now: Int, into top: inout TopK) {
        node.folded.withUnsafeBufferPointer { folded in
            node.names.withUnsafeBufferPointer { names in
                for e in 0..<node.count {
                    let fs = Int(node.foldedStarts[e]), fe = Int(node.foldedStarts[e + 1])
                    let ns = Int(node.nameStarts[e]), ne = Int(node.nameStarts[e + 1])
                    let n = UnsafeBufferPointer(rebasing: folded[fs..<fe])
                    let o: UnsafeBufferPointer<UInt8>? = (fe - fs == ne - ns) ? UnsafeBufferPointer(rebasing: names[ns..<ne]) : nil
                    var stem: Int?
                    if let dot = n.lastIndex(of: 46), dot > 0 { stem = dot }

                    var total = 0
                    var nameHit = false
                    var failed = false
                    for k in tokens.indices {
                        let s = tokens[k].withUnsafeBufferPointer { Matcher.score($0, in: n, original: o, stem: stem) }
                        if s > 0 {
                            total += s
                            nameHit = true
                        } else if pathHits[k] {
                            total += 150
                        } else {
                            failed = true
                            break
                        }
                    }
                    if failed || !nameHit { continue }
                    total /= tokens.count
                    if shortQuery && total < Matcher.wordPrefix { continue }

                    let flags = node.flags[e]
                    if flags & DirNode.isDirectory != 0 { total += 15 }
                    // Smooth: 70 for today, about 40 for last week, 0 after six months.
                    let days = Double(max(0, now - Int(node.mtimes[e]))) / 86_400
                    total += max(0, Int(70 * (1 - log2(1 + days) / log2(181.0))))
                    total -= min(node.depth, 10) * 5
                    if node.isNoisy { total -= 200 }
                    top.push(Candidate(score: total, node: nodeIndex, entry: e))
                }
            }
        }
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        return haystack.withUnsafeBufferPointer { h in
            needle.withUnsafeBufferPointer { t in
                for i in 0...(h.count - t.count) where h[i] == t[0] && memcmp(h.baseAddress! + i, t.baseAddress!, t.count) == 0 {
                    return true
                }
                return false
            }
        }
    }
}

struct Candidate {
    let score: Int
    let node: Int
    let entry: Int
}

/// Keeps roughly the best `limit` candidates without sorting everything.
struct TopK {
    let limit: Int
    private var items: [Candidate] = []
    private var floor = Int.min

    init(limit: Int) { self.limit = limit }

    mutating func push(_ c: Candidate) {
        if items.count >= limit && c.score <= floor { return }
        items.append(c)
        if items.count >= limit * 4 { compact() }
    }

    private mutating func compact() {
        items.sort { $0.score > $1.score }
        items.removeLast(items.count - limit)
        floor = items[items.count - 1].score
    }

    func sorted() -> [Candidate] {
        Array(items.sorted { $0.score > $1.score }.prefix(limit))
    }
}
