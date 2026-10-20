import Foundation

public struct SearchResult: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case app, setting, command, action, folder, file, calculation, definition, clipboard, web, url
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String
    public let path: String?
    public let url: URL?
    public let copyText: String?
    /// Longer text for the preview pane: a definition, a clipboard entry.
    public let detail: String?
    /// Last used or modified; breaks ties so the newer of two equal matches comes first.
    public let date: Date?
    public var score: Int

    public init(id: String, kind: Kind, title: String, subtitle: String, path: String? = nil, url: URL? = nil,
                copyText: String? = nil, detail: String? = nil, date: Date? = nil, score: Int) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.path = path
        self.url = url
        self.copyText = copyText
        self.detail = detail
        self.date = date
        self.score = score
    }
}

/// Browsing scopes, matching Spotlight's ⌘1–⌘4.
public enum SearchMode: Int, Sendable, CaseIterable {
    case all, applications, files, actions, clipboard
}

public enum ResultSection: Int, Sendable, CaseIterable {
    case recents, topHit, calculator, applications, settings, actions, folders, documents, definition, clipboard, web

    public var title: String {
        switch self {
        case .recents: return "Recents"
        case .topHit: return "Top Hit"
        case .calculator: return "Calculator"
        case .applications: return "Applications"
        case .settings: return "System Settings"
        case .actions: return "Actions"
        case .folders: return "Folders"
        case .documents: return "Documents"
        case .definition: return "Definition"
        case .clipboard: return "Clipboard"
        case .web: return "Web"
        }
    }

    public static func of(_ kind: SearchResult.Kind) -> ResultSection {
        switch kind {
        case .app: return .applications
        case .setting: return .settings
        case .command, .action: return .actions
        case .folder: return .folders
        case .file: return .documents
        case .calculation: return .calculator
        case .definition: return .definition
        case .clipboard: return .clipboard
        case .web, .url: return .web
        }
    }

    /// How many rows a section gets in the mixed view before it is cut off. Modes show everything.
    var mixedLimit: Int {
        switch self {
        case .applications: return 6
        case .settings, .actions: return 4
        case .folders: return 5
        case .documents: return 10
        default: return 3
        }
    }
}

public struct ResultGroup: Sendable, Equatable {
    public let section: ResultSection
    public let results: [SearchResult]
}

public enum Grouping {
    /// Spotlight-style layout: the best result alone as Top Hit, then sections in the order of
    /// their best result, with web search last.
    public static func group(_ results: [SearchResult], mode: SearchMode, query: String) -> [ResultGroup] {
        guard !results.isEmpty else { return [] }
        if query.trimmingCharacters(in: .whitespaces).isEmpty && mode == .all {
            return [ResultGroup(section: .recents, results: results)]
        }
        if mode != .all {
            return [ResultGroup(section: ResultSection.of(results[0].kind), results: results)]
        }
        var rest = results
        var groups: [ResultGroup] = []
        if let first = rest.first, first.kind != .web, first.kind != .calculation {
            groups.append(ResultGroup(section: .topHit, results: [first]))
            rest.removeFirst()
        }
        var order: [ResultSection] = []
        var buckets: [ResultSection: [SearchResult]] = [:]
        for r in rest {
            let s = ResultSection.of(r.kind)
            if buckets[s] == nil { order.append(s) }
            if buckets[s, default: []].count < s.mixedLimit { buckets[s, default: []].append(r) }
        }
        order.removeAll { $0 == .web }
        if buckets[.web] != nil { order.append(.web) }
        for s in order { groups.append(ResultGroup(section: s, results: buckets[s]!)) }
        return groups
    }
}

public enum Recency {
    /// A smooth bonus that is `max` for something touched just now and falls to zero at `horizonDays`.
    /// Smooth rather than stepped, so two otherwise equal results still order newest first.
    public static func bonus(_ date: Date?, now: Date = Date(), max: Double, horizonDays: Double) -> Int {
        guard let date else { return 0 }
        let days = Swift.max(0, now.timeIntervalSince(date) / 86_400)
        let f = 1 - log2(1 + days) / log2(1 + horizonDays)
        return f > 0 ? Int(max * f) : 0
    }
}
