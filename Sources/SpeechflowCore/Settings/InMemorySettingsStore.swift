public final class InMemorySettingsStore: SettingsStoring {
    private var settings: SpeechflowSettings

    public init(initialValue: SpeechflowSettings = .defaultValue) {
        settings = initialValue
    }

    public func load() -> SpeechflowSettings {
        settings
    }

    public func save(_ settings: SpeechflowSettings) {
        self.settings = settings
    }
}
