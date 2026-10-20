import XCTest
@testable import LimelightCore

final class IndexTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("limelight-\(UUID().uuidString)")
        try make("Documents/Taxes 2024/return.pdf")
        try make("Documents/Projects/Lifting/Models.swift")
        try make("Documents/Projects/Lifting/node_modules/leftpad/index.js")
        try make("Documents/Projects/Lifting/build/Models.swift")
        try make("Documents/Projects/Lifting/.git/config")
        try make("Documents/Old.noindex/secret.txt")
        try make("Documents/Résumé.pages/Index.xml")
        try make("Desktop/notes.txt")
        try make("Library/Preferences/com.example.plist")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func make(_ rel: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    func makeIndex() -> FileIndex {
        var cfg = IndexConfig.standard(home: root.path)
        cfg.roots = [root.path]
        let index = FileIndex(config: cfg, home: root.path)
        index.rebuild()
        index.waitUntilIdle()
        return index
    }

    func names(_ index: FileIndex, _ q: String) -> [String] {
        index.search(Fold.tokens(q)).map(\.name)
    }

    func testCrawlRespectsExclusionsAndPackages() {
        let index = makeIndex()
        XCTAssertEqual(names(index, "return"), ["return.pdf"])
        XCTAssertEqual(names(index, "index"), [], "package contents, node_modules and .noindex are skipped")
        XCTAssertEqual(names(index, "config"), [], "hidden folders are skipped")
        XCTAssertEqual(names(index, "com.example"), [], "~/Library is skipped")
        XCTAssertEqual(names(index, "resume"), ["Résumé.pages"])
        XCTAssertEqual(index.search(Fold.tokens("resume")).first?.isPackage, true)
    }

    func testBuildFoldersRankBelowSources() {
        let index = makeIndex()
        let hits = index.search(Fold.tokens("models"))
        XCTAssertEqual(hits.count, 2)
        XCTAssertFalse(hits[0].path.contains("/build/"))
    }

    func testPathTokens() {
        let index = makeIndex()
        XCTAssertEqual(names(index, "taxes return"), ["return.pdf"])
        XCTAssertEqual(names(index, "lifting models"), ["Models.swift", "Models.swift"])
        XCTAssertEqual(names(index, "taxes"), ["Taxes 2024"], "a path-only match does not list the folder's contents")
    }

    func testIncrementalRefresh() throws {
        let index = makeIndex()
        try make("Desktop/fresh idea.md")
        try make("Desktop/New Folder/inside.txt")
        index.refresh([root.appendingPathComponent("Desktop/fresh idea.md").path, root.appendingPathComponent("Desktop/New Folder").path])
        index.waitUntilIdle()
        XCTAssertEqual(names(index, "fresh"), ["fresh idea.md"])
        XCTAssertEqual(names(index, "inside"), ["inside.txt"])

        try FileManager.default.removeItem(at: root.appendingPathComponent("Desktop/New Folder"))
        index.refresh([root.appendingPathComponent("Desktop/New Folder").path])
        index.waitUntilIdle()
        XCTAssertEqual(names(index, "inside"), [])
        XCTAssertEqual(names(index, "new folder"), [])
    }

    func testWatcherPicksUpChanges() throws {
        let index = makeIndex()
        let seen = expectation(description: "watcher saw the new file")
        let watcher = FileWatcher(paths: [root.path], latency: 0.1) { changes in
            index.refresh(changes.map(\.path))
            index.waitUntilIdle()
            if index.search(Fold.tokens("watched")).contains(where: { $0.path.hasSuffix("/watched.txt") }) {
                seen.fulfill()
            }
        }
        XCTAssertNotNil(watcher)
        try make("Desktop/watched.txt")
        wait(for: [seen], timeout: 10)
        watcher?.stop()
    }
}

final class EngineTests: XCTestCase {
    func testAppsRankAboveFilesAndLearningReordersThem() {
        let index = FileIndex(config: IndexConfig(roots: [], excludedPaths: [], excludedNames: [], includeHidden: false))
        let engine = SearchEngine(files: index, frecency: Frecency(file: nil))
        engine.catalog = [
            CatalogItem(kind: .app, name: "Clock", key: "/A/Clock.app", path: "/A/Clock.app"),
            CatalogItem(kind: .app, name: "Claude", key: "/A/Claude.app", path: "/A/Claude.app"),
            CatalogItem(kind: .setting, name: "Wi-Fi", key: "setting:wifi", url: URL(string: "x-apple.systempreferences:wifi"), keywords: ["wireless"]),
        ]
        let first = engine.search("cl").map(\.title)
        XCTAssertEqual(first.prefix(2).sorted(), ["Claude", "Clock"])
        let claude = engine.search("cl").first { $0.title == "Claude" }!
        engine.frecency.record(claude, query: "cl")
        XCTAssertEqual(engine.search("cl").first?.title, "Claude")
        XCTAssertEqual(engine.search("c").first?.title, "Claude", "a shorter prefix of a learned query also benefits")
        XCTAssertEqual(engine.search("wireless").first?.title, "Wi-Fi")
        XCTAssertEqual(engine.search("").first?.title, "Claude", "empty query shows what you open most")
    }

    func testSpecialQueries() {
        let index = FileIndex(config: IndexConfig(roots: [], excludedPaths: [], excludedNames: [], includeHidden: false))
        let engine = SearchEngine(files: index, frecency: Frecency(file: nil))
        XCTAssertEqual(engine.search("12*12").first?.title, "144")
        XCTAssertEqual(engine.search("github.com").first?.kind, .url)
        XCTAssertEqual(engine.search("notes.md").first?.kind, .web, "file names are not mistaken for URLs")
        XCTAssertEqual(engine.search("anything").last?.kind, .web)
        let browse = engine.search("/System/")
        XCTAssertTrue(browse.contains { $0.title == "Library" })
        XCTAssertEqual(engine.search("/Syst").first?.title, "System")
    }
}
