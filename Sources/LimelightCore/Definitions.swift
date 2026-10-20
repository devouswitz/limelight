import CoreServices
import Foundation

/// Word definitions from the Dictionary app's local dictionaries.
public enum Definitions {
    static let wordPattern = try! NSRegularExpression(pattern: #"^[\p{L}][\p{L}'\- ]{2,30}$"#)

    public static func lookup(_ query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.split(separator: " ").count <= 2,
              wordPattern.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)) != nil else { return nil }
        let range = CFRange(location: 0, length: (q as NSString).length)
        guard let raw = DCSCopyTextDefinition(nil, q as CFString, range)?.takeRetainedValue() else { return nil }
        return (raw as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The definition proper, without the headword and pronunciation ("word | wɜːd | noun …").
    public static func summary(_ text: String) -> String {
        let parts = text.components(separatedBy: "|")
        let body = parts.count >= 3 ? parts[2...].joined(separator: "|") : text
        return body.components(separatedBy: " ORIGIN").first!.trimmingCharacters(in: .whitespaces)
    }

    /// Breaks the dictionary's single run-on line at its section markers for reading.
    public static func formatted(_ text: String) -> String {
        var t = text
        for marker in [" ORIGIN ", " PHRASES ", " DERIVATIVES ", " PHRASAL VERBS "] {
            t = t.replacingOccurrences(of: marker, with: "\n\n" + marker.trimmingCharacters(in: .whitespaces) + "\n")
        }
        return t
    }
}
