import Foundation

public final class UserDefaultsSettingsStore: SettingsStoring {
    private let defaults: UserDefaults
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "Speechflow.Settings"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func load() -> SpeechflowSettings {
        guard let data = defaults.data(forKey: storageKey) else {
            return .defaultValue
        }

        return (try? decoder.decode(SpeechflowSettings.self, from: data)) ?? .defaultValue
    }

    public func save(_ settings: SpeechflowSettings) {
        guard let data = try? encoder.encode(settings) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }
}
