import Foundation

/// The case- and accent-insensitive byte form every match runs on.
public enum Fold {
    public static func bytes(_ s: String) -> [UInt8] {
        var out = Array(s.utf8)
        if out.contains(where: { $0 >= 0x80 }) {
            let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            out = Array(folded.precomposedStringWithCanonicalMapping.utf8)
        }
        for i in out.indices where out[i] &- 65 < 26 { out[i] &+= 32 }
        return out
    }

    public static func string(_ s: String) -> String {
        String(decoding: bytes(s), as: UTF8.self)
    }

    /// Splits a query into folded tokens on whitespace.
    public static func tokens(_ s: String) -> [[UInt8]] {
        s.split(whereSeparator: { $0.isWhitespace }).map { bytes(String($0)) }.filter { !$0.isEmpty }
    }
}
