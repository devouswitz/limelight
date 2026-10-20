import Foundation
import LimelightCore

// Developer tool: builds the same index the app uses and runs queries against it.
// usage: limelight-cli [query ...]    (no query: interactive)

let started = Date()
let index = FileIndex(config: .standard())
let engine = SearchEngine(files: index, frecency: Frecency(file: nil))
engine.catalog = AppCatalog.scanApplications() + AppCatalog.settingsPanes()
let catalogTime = Date().timeIntervalSince(started)
let crawlStart = Date()
index.rebuild()
index.waitUntilIdle()
print(String(format: "catalog %d items in %.0f ms; indexed %d files in %.2f s",
             engine.catalog.count, catalogTime * 1000, index.itemCount, Date().timeIntervalSince(crawlStart)))

func run(_ q: String) {
    let t = Date()
    let results = engine.search(q, limit: 12)
    let ms = Date().timeIntervalSince(t) * 1000
    print(String(format: "\n“%@”  (%.1f ms)", q, ms))
    for r in results {
        print(String(format: "  %6d  %-11@ %@  —  %@", r.score, r.kind.rawValue as NSString, r.title, r.subtitle))
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty {
    while let line = readLine() { run(line) }
} else {
    for q in args { run(q) }
}
