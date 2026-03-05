import Foundation

public struct ColorComponents: Equatable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct LanguagePair: Equatable, Codable, Sendable {
    public var sourceCode: String
    public var targetCode: String

    public init(sourceCode: String = "en-US", targetCode: String = "zh-Hans") {
        self.sourceCode = sourceCode
        self.targetCode = targetCode
    }
}

public struct RecognitionTuning: Equatable, Codable, Sendable {
    public var inputGain: Double
    public var voiceProcessingEnabled: Bool
    public var automaticGainControlEnabled: Bool
    public var pauseCommitDelay: Double

    public init(
        inputGain: Double = 1.0,
        // NOTE: voiceProcessingEnabled defaults to FALSE.
        // Enabling it changes the inputNode's hardware format at startCapture() time,
        // before the audio tap is installed. The format mismatch causes
        // SFSpeechAudioBufferRecognitionRequest to silently produce no results.
        // Users can enable this in Settings once the tap is re-created afterwards.
        voiceProcessingEnabled: Bool = false,
        automaticGainControlEnabled: Bool = true,
        pauseCommitDelay: Double = 1.25
    ) {
        self.inputGain = inputGain
        self.voiceProcessingEnabled = voiceProcessingEnabled
        self.automaticGainControlEnabled = automaticGainControlEnabled
        self.pauseCommitDelay = pauseCommitDelay
    }

    public static let defaultValue = RecognitionTuning()
}

public enum OverlayScreenMode: String, Codable, Sendable {
    case followPrimary
    case pinCurrent
}

public struct OverlayFrame: Equatable, Codable, Sendable {
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var height: Double

    public init(originX: Double, originY: Double, width: Double, height: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }
}

public struct SpeechflowSettings: Equatable, Codable, Sendable {
    public var fontSize: Double
    public var opacity: Double
    public var maxVisibleLines: Int
    public var languagePair: LanguagePair
    public var recognitionTuning: RecognitionTuning
    public var translationPolicy: TranslationPolicy
    public var translationBackendPreference: TranslationBackendPreference
    public var overlayVisibleByDefault: Bool
    public var translationEnabledByDefault: Bool
    public var overlayScreenMode: OverlayScreenMode
    public var overlayFrame: OverlayFrame?
    public var sourceBackgroundColor: ColorComponents
    public var targetBackgroundColor: ColorComponents
    public var sourceTextColor: ColorComponents
    public var targetTextColor: ColorComponents
    public var openRouterAPIKey: String

    public init(
        fontSize: Double = 18,
        opacity: Double = 0.88,
        maxVisibleLines: Int = 6,
        languagePair: LanguagePair = LanguagePair(),
        recognitionTuning: RecognitionTuning = .defaultValue,
        translationPolicy: TranslationPolicy = .defaultValue,
        translationBackendPreference: TranslationBackendPreference = .localOllama,
        overlayVisibleByDefault: Bool = true,
        translationEnabledByDefault: Bool = true,
        overlayScreenMode: OverlayScreenMode = .followPrimary,
        overlayFrame: OverlayFrame? = nil,
        sourceBackgroundColor: ColorComponents = ColorComponents(red: 0, green: 0, blue: 0, alpha: 0.4),
        targetBackgroundColor: ColorComponents = ColorComponents(red: 0, green: 0, blue: 0, alpha: 0.4),
        sourceTextColor: ColorComponents = ColorComponents(red: 1, green: 1, blue: 1),
        targetTextColor: ColorComponents = ColorComponents(red: 1, green: 1, blue: 0),
        openRouterAPIKey: String = ""
    ) {
        self.fontSize = fontSize
        self.opacity = opacity
        self.maxVisibleLines = maxVisibleLines
        self.languagePair = languagePair
        self.recognitionTuning = recognitionTuning
        self.translationPolicy = translationPolicy
        self.translationBackendPreference = translationBackendPreference
        self.overlayVisibleByDefault = overlayVisibleByDefault
        self.translationEnabledByDefault = translationEnabledByDefault
        self.overlayScreenMode = overlayScreenMode
        self.overlayFrame = overlayFrame
        self.sourceBackgroundColor = sourceBackgroundColor
        self.targetBackgroundColor = targetBackgroundColor
        self.sourceTextColor = sourceTextColor
        self.targetTextColor = targetTextColor
        self.openRouterAPIKey = openRouterAPIKey
    }

    public static let defaultValue = SpeechflowSettings()
}
