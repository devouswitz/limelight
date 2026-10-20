import Foundation
import LimelightCore

/// Settings persisted in UserDefaults.
final class Preferences {
    private let defaults = UserDefaults.standard

    var hotKey: KeyCombo? {
        get { decode(KeyCombo.self, "hotKey") }
        set { encode(newValue, "hotKey") }
    }

    var indexConfig: IndexConfig {
        get { decode(IndexConfig.self, "indexConfig") ?? .standard() }
        set { encode(newValue, "indexConfig") }
    }

    var webSearch: WebSearchProvider {
        get {
            let name = defaults.string(forKey: "webSearch")
            return WebSearchProvider.all.first { $0.name == name } ?? WebSearchProvider.all[0]
        }
        set { defaults.set(newValue.name, forKey: "webSearch") }
    }

    var clipboardHistory: Bool {
        get { defaults.object(forKey: "clipboardHistory") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "clipboardHistory") }
    }

    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: "hasLaunchedBefore") }
        set { defaults.set(newValue, forKey: "hasLaunchedBefore") }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
