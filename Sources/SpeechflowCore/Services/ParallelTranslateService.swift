import Foundation

public final class ParallelTranslateService: TranslateServicing {
    private let translationProvider: TranslateServicing
    private let assistantProvider: TranslateServicing

    public init(
        translationProvider: TranslateServicing,
        assistantProvider: TranslateServicing
    ) {
        self.translationProvider = translationProvider
        self.assistantProvider = assistantProvider
    }

    public func start(eventSink: @escaping (SpeechflowEvent) -> Void) {
        translationProvider.start(eventSink: eventSink)
        assistantProvider.start(eventSink: eventSink)
    }

    public func updateLanguagePair(_ pair: LanguagePair) {
        translationProvider.updateLanguagePair(pair)
        assistantProvider.updateLanguagePair(pair)
    }

    public func updatePolicy(_ policy: TranslationPolicy) {
        translationProvider.updatePolicy(policy)
        assistantProvider.updatePolicy(policy)
    }

    public func updateNetworkQuality(_ quality: NetworkQuality) {
        translationProvider.updateNetworkQuality(quality)
        assistantProvider.updateNetworkQuality(quality)
    }

    public func updateBackendPreference(_ backendPreference: TranslationBackendPreference) {
        translationProvider.updateBackendPreference(backendPreference)
        assistantProvider.updateBackendPreference(backendPreference)
    }

    public func updateOpenRouterAPIKey(_ apiKey: String) {
        translationProvider.updateOpenRouterAPIKey(apiKey)
        assistantProvider.updateOpenRouterAPIKey(apiKey)
    }

    public func enqueue(_ segment: TranscriptSegment) {
        translationProvider.enqueue(segment)
        assistantProvider.enqueue(segment)
    }

    public func cancelAll() {
        translationProvider.cancelAll()
        assistantProvider.cancelAll()
    }
}
