import AVFoundation
import Foundation
import Speech

public enum LocalRecognitionError: LocalizedError {
    case missingSpeechRecognizer(localeIdentifier: String)
    case speechAuthorizationDenied
    case recognizerUnavailable(localeIdentifier: String)
    case recognizerAlreadyRunning

    public var errorDescription: String? {
        switch self {
        case .missingSpeechRecognizer(let localeIdentifier):
            return "No speech recognizer is available for locale \(localeIdentifier)."
        case .speechAuthorizationDenied:
            return "Speech recognition permission is not granted."
        case .recognizerUnavailable(let localeIdentifier):
            return "The local speech recognizer is currently unavailable for locale \(localeIdentifier)."
        case .recognizerAlreadyRunning:
            return "A local speech recognition task is already running."
        }
    }
}

public final class SystemAudioEngineService: AudioEngineServicing {
    private let audioEngine: AVAudioEngine
    private let tapBus: AVAudioNodeBus
    private let bufferSize: AVAudioFrameCount

    private var isTapInstalled = false
    private var bufferHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var recognitionTuning: RecognitionTuning
    private let stateLock = NSLock()

    public init(
        audioEngine: AVAudioEngine = AVAudioEngine(),
        tapBus: AVAudioNodeBus = 0,
        bufferSize: AVAudioFrameCount = 512,
        recognitionTuning: RecognitionTuning = .defaultValue
    ) {
        self.audioEngine = audioEngine
        self.tapBus = tapBus
        self.bufferSize = bufferSize
        self.recognitionTuning = recognitionTuning
    }

    public func setBufferHandler(_ handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        stateLock.lock()
        bufferHandler = handler
        stateLock.unlock()
    }

    public func clearBufferHandler() {
        stateLock.lock()
        bufferHandler = nil
        stateLock.unlock()
    }

    public func updateRecognitionTuning(_ tuning: RecognitionTuning) {
        stateLock.lock()
        recognitionTuning = tuning
        stateLock.unlock()
    }

    public func updateInputSource(_ inputSource: AudioInputSource) {
        _ = inputSource
    }

    public func startCapture() throws {
        let tuning = currentRecognitionTuning
        configureInputNodeForSpeechCapture(using: tuning)
        installTapIfNeeded()

        guard !audioEngine.isRunning else {
            return
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    public func pauseCapture() {
        guard audioEngine.isRunning else {
            return
        }

        audioEngine.pause()
    }

    public func stopCapture() {
        audioEngine.stop()
        removeTapIfNeeded()
        clearBufferHandler()
    }

    private func installTapIfNeeded() {
        guard !isTapInstalled else {
            return
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: tapBus)

        inputNode.installTap(
            onBus: tapBus,
            bufferSize: bufferSize,
            format: format
        ) { [weak self] buffer, time in
            self?.forwardBuffer(buffer, at: time)
        }

        isTapInstalled = true
    }

    private func configureInputNodeForSpeechCapture(using tuning: RecognitionTuning) {
        _ = tuning
        // Avoid toggling the system voice-processing I/O unit on macOS.
        // On some devices it breaks the capture graph and ASR stops receiving audio.
    }

    private func removeTapIfNeeded() {
        guard isTapInstalled else {
            return
        }

        audioEngine.inputNode.removeTap(onBus: tapBus)
        isTapInstalled = false
    }

    private func forwardBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        stateLock.lock()
        let currentHandler = bufferHandler
        let currentTuning = recognitionTuning
        stateLock.unlock()
        processInputBuffer(buffer, with: currentTuning)
        currentHandler?(buffer, time)
    }

    private var currentRecognitionTuning: RecognitionTuning {
        stateLock.lock()
        let tuning = recognitionTuning
        stateLock.unlock()
        return tuning
    }

    private func processInputBuffer(
        _ buffer: AVAudioPCMBuffer,
        with tuning: RecognitionTuning
    ) {
        if tuning.voiceProcessingEnabled {
            applyNoiseGateIfNeeded(to: buffer)
        }

        let effectiveGain = effectiveSoftwareGain(for: buffer, tuning: tuning)
        applySoftwareGainIfNeeded(to: buffer, gain: effectiveGain)
    }

    private func effectiveSoftwareGain(
        for buffer: AVAudioPCMBuffer,
        tuning: RecognitionTuning
    ) -> Double {
        let baseGain = max(0.25, min(tuning.inputGain, 4.0))
        guard tuning.automaticGainControlEnabled,
              let peakAmplitude = measuredPeakAmplitude(in: buffer),
              peakAmplitude > 0 else {
            return baseGain
        }

        let targetPeak = 0.2
        let adaptiveGain = min(2.0, max(0.8, targetPeak / peakAmplitude))
        return max(0.25, min(baseGain * adaptiveGain, 4.0))
    }

    private func measuredPeakAmplitude(in buffer: AVAudioPCMBuffer) -> Double? {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var peak = 0.0

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            for audioBuffer in audioBuffers {
                guard let data = audioBuffer.mData else {
                    continue
                }

                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
                for index in 0..<sampleCount {
                    peak = max(peak, Double(abs(samples[index])))
                }
            }
        case .pcmFormatInt16:
            let scale = Double(Int16.max)
            for audioBuffer in audioBuffers {
                guard let data = audioBuffer.mData else {
                    continue
                }

                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                let samples = data.bindMemory(to: Int16.self, capacity: sampleCount)
                for index in 0..<sampleCount {
                    peak = max(peak, Double(abs(Int(samples[index]))) / scale)
                }
            }
        case .pcmFormatInt32:
            let scale = Double(Int32.max)
            for audioBuffer in audioBuffers {
                guard let data = audioBuffer.mData else {
                    continue
                }

                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
                let samples = data.bindMemory(to: Int32.self, capacity: sampleCount)
                for index in 0..<sampleCount {
                    peak = max(peak, Double(abs(samples[index])) / scale)
                }
            }
        default:
            return nil
        }

        return peak
    }

    private func applySoftwareGainIfNeeded(
        to buffer: AVAudioPCMBuffer,
        gain: Double
    ) {
        let appliedGain = Float(max(0.25, min(gain, 4.0)))
        guard abs(appliedGain - 1.0) > 0.001 else {
            return
        }

        AudioBufferProcessing.applyGain(to: buffer, boostFactor: appliedGain)
    }

    private func applyNoiseGateIfNeeded(to buffer: AVAudioPCMBuffer) {
        let threshold = 0.006
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            let limit = Float(threshold)
            for audioBuffer in audioBuffers {
                guard let data = audioBuffer.mData else {
                    continue
                }

                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
                for index in 0..<sampleCount where abs(samples[index]) < limit {
                    samples[index] = 0
                }
            }
        case .pcmFormatInt16:
            let limit = Int(Double(Int16.max) * threshold)
            for audioBuffer in audioBuffers {
                guard let data = audioBuffer.mData else {
                    continue
                }

                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                let samples = data.bindMemory(to: Int16.self, capacity: sampleCount)
                for index in 0..<sampleCount where abs(Int(samples[index])) < limit {
                    samples[index] = 0
                }
            }
        case .pcmFormatInt32:
            let limit = Int64(Double(Int32.max) * threshold)
            for audioBuffer in audioBuffers {
                guard let data = audioBuffer.mData else {
                    continue
                }

                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
                let samples = data.bindMemory(to: Int32.self, capacity: sampleCount)
                for index in 0..<sampleCount where abs(Int64(samples[index])) < limit {
                    samples[index] = 0
                }
            }
        default:
            return
        }
    }
}

public final class SpeechFrameworkASRService: LocalASRServicing {
    private let audioService: AudioEngineServicing
    private let taskHint: SFSpeechRecognitionTaskHint
    private let prefersOnDeviceRecognition: Bool

    private var localeIdentifier: String
    private var eventSink: ((SpeechflowEvent) -> Void)?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechRecognizer: SFSpeechRecognizer?
    private var activeRequiresOnDeviceRecognition = false
    private var hasReceivedRecognitionResult = false
    private var lastDeliveredPartialText = ""

    public init(
        audioService: AudioEngineServicing,
        localeIdentifier: String = Locale.current.identifier,
        taskHint: SFSpeechRecognitionTaskHint = .dictation,
        prefersOnDeviceRecognition: Bool = true
    ) {
        self.audioService = audioService
        self.localeIdentifier = localeIdentifier
        self.taskHint = taskHint
        self.prefersOnDeviceRecognition = prefersOnDeviceRecognition
    }

    public func updateLocaleIdentifier(_ localeIdentifier: String) {
        guard self.localeIdentifier != localeIdentifier else {
            return
        }

        self.localeIdentifier = localeIdentifier
        if recognitionTask == nil {
            speechRecognizer = nil
        }
    }

    public func startStreaming(eventSink: @escaping (SpeechflowEvent) -> Void) throws {
        try beginStreaming(eventSink: eventSink, forcingServerFallback: false)
    }

    private func beginStreaming(
        eventSink: @escaping (SpeechflowEvent) -> Void,
        forcingServerFallback: Bool
    ) throws {
        guard recognitionTask == nil else {
            throw LocalRecognitionError.recognizerAlreadyRunning
        }

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw LocalRecognitionError.speechAuthorizationDenied
        }

        let recognizer = try makeRecognizer()
        guard recognizer.isAvailable else {
            throw LocalRecognitionError.recognizerUnavailable(localeIdentifier: localeIdentifier)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = taskHint
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        // Prefer on-device recognition for lower latency, but transparently
        // fall back to server recognition when local assets are unavailable.
        let requiresOnDeviceRecognition = prefersOnDeviceRecognition &&
            !forcingServerFallback &&
            recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition

        self.eventSink = eventSink
        self.recognitionRequest = request
        self.speechRecognizer = recognizer
        self.activeRequiresOnDeviceRecognition = requiresOnDeviceRecognition
        self.hasReceivedRecognitionResult = false
        self.lastDeliveredPartialText = ""

        audioService.setBufferHandler { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleRecognitionCallback(result: result, error: error)
        }
    }

    public func stopStreaming() {
        audioService.clearBufferHandler()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        activeRequiresOnDeviceRecognition = false
        hasReceivedRecognitionResult = false
        lastDeliveredPartialText = ""
        eventSink = nil
    }

    private func makeRecognizer() throws -> SFSpeechRecognizer {
        if let existingRecognizer = speechRecognizer,
           existingRecognizer.locale.identifier == localeIdentifier {
            return existingRecognizer
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            throw LocalRecognitionError.missingSpeechRecognizer(localeIdentifier: localeIdentifier)
        }

        speechRecognizer = recognizer
        return recognizer
    }

    private func handleRecognitionCallback(
        result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        if let result {
            hasReceivedRecognitionResult = true

            if result.isFinal {
                let finalText = trimmedTranscriptText(from: result.bestTranscription.formattedString)
                let textToCommit = finalText.isEmpty ? lastDeliveredPartialText : finalText
                lastDeliveredPartialText = ""

                if !textToCommit.isEmpty {
                    eventSink?(.asrFinalReceived(textToCommit))
                }
            } else if let partialText = nextStablePartial(from: result.bestTranscription.formattedString) {
                eventSink?(.asrPartialReceived(partialText))
            }
        }

        if let error {
            let message = error.localizedDescription
            let sink = eventSink
            let shouldRetryWithoutOnDeviceAssets = shouldRetryWithoutOnDeviceAssets(for: message)
            stopStreaming()

            if shouldRetryWithoutOnDeviceAssets, let sink {
                do {
                    try beginStreaming(eventSink: sink, forcingServerFallback: true)
                    return
                } catch {
                    sink(.localASRFailed(message: error.localizedDescription))
                    return
                }
            }

            sink?(.localASRFailed(message: message))
        }
    }

    private func shouldRetryWithoutOnDeviceAssets(for message: String) -> Bool {
        guard activeRequiresOnDeviceRecognition, !hasReceivedRecognitionResult else {
            return false
        }

        let normalizedMessage = message.lowercased()
        return normalizedMessage.contains("asset") || normalizedMessage.contains("on-device")
    }

    private func nextStablePartial(from candidate: String) -> String? {
        let trimmedCandidate = trimmedTranscriptText(from: candidate)
        guard !trimmedCandidate.isEmpty else {
            return nil
        }

        guard !lastDeliveredPartialText.isEmpty else {
            lastDeliveredPartialText = trimmedCandidate
            return trimmedCandidate
        }

        let previous = lastDeliveredPartialText
        let normalizedCandidate = Self.normalizeComparisonText(trimmedCandidate)
        let normalizedPrevious = Self.normalizeComparisonText(previous)

        guard normalizedCandidate != normalizedPrevious else {
            return nil
        }

        if shouldIgnoreMinorRollback(candidate: normalizedCandidate, previous: normalizedPrevious) {
            return nil
        }

        lastDeliveredPartialText = trimmedCandidate
        return trimmedCandidate
    }

    private func trimmedTranscriptText(from text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func shouldIgnoreMinorRollback(candidate: String, previous: String) -> Bool {
        guard candidate.count < previous.count else {
            return false
        }

        guard previous.hasPrefix(candidate) else {
            return false
        }

        return previous.count - candidate.count <= 6
    }

    private static func normalizeComparisonText(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}
