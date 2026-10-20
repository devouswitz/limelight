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

final class LayoutAndSignalTests: XCTestCase {
    func engine(_ items: [CatalogItem]) -> SearchEngine {
        let index = FileIndex(config: IndexConfig(roots: [], excludedPaths: [], excludedNames: [], includeHidden: false))
        let e = SearchEngine(files: index, frecency: Frecency(file: nil))
        e.catalog = items
        return e
    }

    func app(_ name: String, updated: Date? = nil, used: Date? = nil) -> CatalogItem {
        var item = CatalogItem(kind: .app, name: name, key: "/A/\(name).app", path: "/A/\(name).app")
        item.updated = updated
        item.lastUsed = used
        return item
    }

    func testEqualMatchesGoNewestFirst() {
        let now = Date()
        let e = engine([
            app("Game 7.2 Beta 6", updated: now.addingTimeInterval(-7 * 86_400)),
            app("Game 7.3 Beta 9", updated: now.addingTimeInterval(-86_400)),
            app("Game 7.3 Beta 10", updated: now.addingTimeInterval(-3600)),
        ])
        XCTAssertEqual(e.search("game").prefix(3).map(\.title), ["Game 7.3 Beta 10", "Game 7.3 Beta 9", "Game 7.2 Beta 6"])
    }

    func testRecentUseBeatsInstallDate() {
        let now = Date()
        let e = engine([app("Clock", updated: now), app("Claude", used: now.addingTimeInterval(-600))])
        XCTAssertEqual(e.search("cl").first?.title, "Claude")
    }

    func testGroupingPutsTopHitFirstAndWebLast() {
        let e = engine([app("Safari"), app("Safari Technology Preview")])
        let groups = e.grouped(e.search("saf"), mode: .all, query: "saf")
        XCTAssertEqual(groups.first?.section, .topHit)
        XCTAssertEqual(groups.first?.results.map(\.title), ["Safari"])
        XCTAssertEqual(groups.last?.section, .web)
        XCTAssertEqual(groups.map(\.section), [.topHit, .applications, .web])
    }

    func testModes() {
        var lock = CatalogItem(kind: .action, name: "Lock Screen", key: "action:lock", url: URL(string: "limelight:action/lock"))
        lock.subtitle = "Action"
        let e = engine([app("Safari"), lock])
        XCTAssertEqual(e.search("", mode: .applications).map(\.title), ["Safari"])
        XCTAssertEqual(e.search("lo", mode: .actions).map(\.title), ["Lock Screen"])
        XCTAssertEqual(e.search("lock").first?.title, "Lock Screen")
        XCTAssertFalse(e.search("l").contains { $0.kind == .action }, "actions need a deliberate prefix in the mixed view")
        e.clipboard.add("meeting moved to 3pm", source: "Messages")
        e.clipboard.add("https://example.com", source: nil)
        XCTAssertEqual(e.search("", mode: .clipboard).map(\.title), ["https://example.com", "meeting moved to 3pm"])
        XCTAssertEqual(e.search("3pm", mode: .clipboard).count, 1)
        e.clipboard.add("meeting moved to 3pm", source: "Messages")
        XCTAssertEqual(e.search("", mode: .clipboard).first?.title, "meeting moved to 3pm", "copying again moves it to the top")
    }

    func testClipboardExpires() {
        let h = ClipboardHistory()
        h.add("old", source: nil, date: Date().addingTimeInterval(-9 * 3600))
        h.add("new", source: nil)
        XCTAssertEqual(h.search("").map(\.title), ["new"])
    }

    func testRecencyIsSmoothAndBounded() {
        let now = Date()
        let today = Recency.bonus(now, now: now, max: 60, horizonDays: 90)
        let week = Recency.bonus(now.addingTimeInterval(-7 * 86_400), now: now, max: 60, horizonDays: 90)
        let old = Recency.bonus(now.addingTimeInterval(-200 * 86_400), now: now, max: 60, horizonDays: 90)
        XCTAssertEqual(today, 60)
        XCTAssertTrue(week > 0 && week < today)
        XCTAssertEqual(old, 0)
    }

    func testDefinitions() throws {
        let text = try XCTUnwrap(Definitions.lookup("serendipity"))
        XCTAssertTrue(Definitions.summary(text).hasPrefix("noun"))
        XCTAssertNil(Definitions.lookup("12*3"))
    }
}
