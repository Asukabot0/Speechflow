import Foundation
import Testing
@testable import SpeechflowCore

@Suite("UserDefaultsSettingsStore Tests")
struct UserDefaultsSettingsStoreTests {
    @Test("旧持久化 sourceCode=zh-Hans 应迁移为 zh-CN 并写回")
    func testLegacyChineseSourceLocaleMigration() throws {
        let suiteName = "SpeechflowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsSettingsStore(
            defaults: defaults,
            storageKey: "Speechflow.Settings.Tests"
        )

        let encoder = JSONEncoder()
        var legacySettings = SpeechflowSettings.defaultValue
        legacySettings.languagePair.sourceCode = "zh-Hans"
        let encoded = try encoder.encode(legacySettings)
        defaults.set(encoded, forKey: "Speechflow.Settings.Tests")

        let migratedSettings = store.load()

        #expect(migratedSettings.languagePair.sourceCode == "zh-CN")

        let persistedData = defaults.data(forKey: "Speechflow.Settings.Tests")
        let persistedSettings = try JSONDecoder().decode(SpeechflowSettings.self, from: try #require(persistedData))
        #expect(persistedSettings.languagePair.sourceCode == "zh-CN")
    }
}
