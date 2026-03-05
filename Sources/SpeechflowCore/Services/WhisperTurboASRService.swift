@preconcurrency import AVFoundation
import Foundation

public enum WhisperTurboASRError: LocalizedError {
    case recognizerAlreadyRunning
    case executableUnavailable(path: String)
    case runnerUnavailable(path: String)
    case modelUnavailable(path: String)
    case transcriberLaunchFailed(message: String)
    case transcriberFailed(message: String)
    case transcriptionOutputMissing

    public var errorDescription: String? {
        switch self {
        case .recognizerAlreadyRunning:
            return "A Whisper Turbo recognition task is already running."
        case .executableUnavailable(let path):
            return "Python 3 was not found at \(path). Install Python 3 or set SPEECHFLOW_FASTER_WHISPER_PYTHON_PATH."
        case .runnerUnavailable(let path):
            return "The bundled ASR runner was not found at \(path)."
        case .modelUnavailable(let path):
            return "The configured ASR model directory was not found at \(path)."
        case .transcriberLaunchFailed(let message):
            return "The ASR runner could not start: \(message)"
        case .transcriberFailed(let message):
            return "ASR transcription failed: \(message)"
        case .transcriptionOutputMissing:
            return "The ASR runner finished without producing any transcript output."
        }
    }
}

public final class PreferredLocalASRService: LocalASRServicing, @unchecked Sendable {
    private enum ActiveBackend {
        case none
        case primary
        case fallback
    }

    private let primary: LocalASRServicing
    private let fallback: LocalASRServicing
    private let coordinationQueue = DispatchQueue(label: "Speechflow.PreferredLocalASRService")
    private let stateLock = NSLock()
    private var activeBackend: ActiveBackend = .none
    private var downstreamEventSink: ((SpeechflowEvent) -> Void)?

    public init(
        primary: LocalASRServicing,
        fallback: LocalASRServicing
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    public func updateLocaleIdentifier(_ localeIdentifier: String) {
        primary.updateLocaleIdentifier(localeIdentifier)
        fallback.updateLocaleIdentifier(localeIdentifier)
    }

    public func startStreaming(eventSink: @escaping (SpeechflowEvent) -> Void) throws {
        stopStreaming()
        debugLog("PreferredLocalASRService starting primary ASR backend")

        stateLock.lock()
        downstreamEventSink = eventSink
        activeBackend = .primary
        stateLock.unlock()

        do {
            try primary.startStreaming { [weak self] event in
                self?.handlePrimaryEvent(event)
            }
            return
        } catch {
            stateLock.lock()
            activeBackend = .none
            stateLock.unlock()
            do {
                try startFallback()
            } catch {
                stateLock.lock()
                downstreamEventSink = nil
                stateLock.unlock()
                throw error
            }
        }
    }

    public func stopStreaming() {
        primary.stopStreaming()
        fallback.stopStreaming()
        stateLock.lock()
        activeBackend = .none
        downstreamEventSink = nil
        stateLock.unlock()
    }

    private func handlePrimaryEvent(_ event: SpeechflowEvent) {
        switch event {
        case .localASRFailed(let message):
            debugLog("PreferredLocalASRService primary ASR failed, switching to fallback: \(message)")
            coordinationQueue.async { [weak self] in
                self?.handlePrimaryFailure(message)
            }
        default:
            guard isPrimaryActive else {
                return
            }
            currentEventSink?(event)
        }
    }

    private func handlePrimaryFailure(_ message: String) {
        guard isPrimaryActive else {
            return
        }

        do {
            try startFallback()
            debugLog("PreferredLocalASRService fallback ASR started")
        } catch {
            debugLog("PreferredLocalASRService fallback ASR failed: \(error.localizedDescription)")
            currentEventSink?(
                .localASRFailed(
                    message: "\(message) Fallback to system speech recognition also failed: \(error.localizedDescription)"
                )
            )
        }
    }

    private func startFallback() throws {
        primary.stopStreaming()

        let sink = currentEventSink
        stateLock.lock()
        activeBackend = .fallback
        stateLock.unlock()
        debugLog("PreferredLocalASRService starting fallback ASR backend")
        do {
            try fallback.startStreaming { [weak self] event in
                guard self?.isFallbackActive ?? true else {
                    return
                }
                sink?(event)
            }
        } catch {
            stateLock.lock()
            activeBackend = .none
            stateLock.unlock()
            throw error
        }
    }

    private var currentEventSink: ((SpeechflowEvent) -> Void)? {
        stateLock.lock()
        let sink = downstreamEventSink
        stateLock.unlock()
        return sink
    }

    private var isPrimaryActive: Bool {
        stateLock.lock()
        let isActive = activeBackend == .primary
        stateLock.unlock()
        return isActive
    }

    private var isFallbackActive: Bool {
        stateLock.lock()
        let isActive = activeBackend == .fallback
        stateLock.unlock()
        return isActive
    }
}

public final class WhisperTurboASRService: LocalASRServicing, @unchecked Sendable {
    private let audioService: AudioEngineServicing
    private let runtime: WhisperTurboRuntime
    private let controlQueue = DispatchQueue(label: "Speechflow.WhisperTurboASRService.control")
    private let sampleQueue = DispatchQueue(label: "Speechflow.WhisperTurboASRService.sample", qos: .userInitiated)
    private let workerQueue = DispatchQueue(label: "Speechflow.WhisperTurboASRService.worker", qos: .userInitiated)

    private var localeIdentifier: String
    private var eventSink: ((SpeechflowEvent) -> Void)?
    private var timer: DispatchSourceTimer?
    private var isRunning = false
    private var isTranscriptionInFlight = false
    private var sessionGeneration: UInt64 = 0
    private var retainedSamples: [Float] = []
    private var lastTranscribedSampleCount = 0
    private var lastDeliveredPartialText = ""
    private var stableRepeatCount = 0
    private var recentCommittedSegments: [String] = []
    private var resampler = PCMResampler(targetSampleRate: WhisperTurboRuntimeDescriptor.defaultSampleRate)
    private var hasLoggedFirstBuffer = false
    private var hasLoggedFirstSampleAppend = false
    private var hasLoggedResamplerFailure = false

    public init(
        audioService: AudioEngineServicing,
        localeIdentifier: String = Locale.current.identifier
    ) {
        self.audioService = audioService
        self.localeIdentifier = localeIdentifier
        self.runtime = FasterWhisperTurboRuntime()
    }

    private init(
        audioService: AudioEngineServicing,
        localeIdentifier: String,
        runtime: WhisperTurboRuntime
    ) {
        self.audioService = audioService
        self.localeIdentifier = localeIdentifier
        self.runtime = runtime
    }

    public func updateLocaleIdentifier(_ localeIdentifier: String) {
        controlQueue.sync {
            self.localeIdentifier = localeIdentifier
        }
    }

    public func startStreaming(eventSink: @escaping (SpeechflowEvent) -> Void) throws {
        try runtime.validateAvailability()
        debugLog("WhisperTurboASRService validated ASR runtime")

        let shouldThrowAlreadyRunning = controlQueue.sync { () -> Bool in
            if isRunning {
                return true
            }

            sessionGeneration &+= 1
            isRunning = true
            isTranscriptionInFlight = false
            retainedSamples.removeAll(keepingCapacity: true)
            lastTranscribedSampleCount = 0
            lastDeliveredPartialText = ""
            stableRepeatCount = 0
            recentCommittedSegments.removeAll(keepingCapacity: true)
            hasLoggedFirstBuffer = false
            hasLoggedFirstSampleAppend = false
            hasLoggedResamplerFailure = false
            self.eventSink = eventSink
            installTimer()
            return false
        }

        if shouldThrowAlreadyRunning {
            throw WhisperTurboASRError.recognizerAlreadyRunning
        }

        sampleQueue.sync {
            self.resampler.reset()
        }

        audioService.setBufferHandler { [weak self] buffer, _ in
            self?.handleIncomingBuffer(buffer)
        }
    }

    public func stopStreaming() {
        controlQueue.sync {
            stopStreamingOnControlQueue()
        }
    }

    private func handleIncomingBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let copy = PCMBufferCopying.copy(buffer) else {
            return
        }

        let bufferBox = PCMBufferBox(buffer: copy)

        controlQueue.async { [weak self] in
            guard let self else {
                return
            }

            if !self.hasLoggedFirstBuffer {
                self.hasLoggedFirstBuffer = true
                debugLog("WhisperTurboASRService received first audio buffer")
            }
        }

        sampleQueue.async { [weak self] in
            guard let self else {
                return
            }

            let samples = self.resampleOnSampleQueue(bufferBox.buffer)
            guard let samples, !samples.isEmpty else {
                return
            }

            self.controlQueue.async { [weak self] in
                self?.appendSamples(samples)
            }
        }
    }

    private func resampleOnSampleQueue(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let samples = resampler.convert(buffer)
        if samples == nil {
            controlQueue.async { [weak self] in
                guard let self, !self.hasLoggedResamplerFailure else {
                    return
                }

                self.hasLoggedResamplerFailure = true
                debugLog(
                    "WhisperTurboASRService failed to resample audio buffer format=\(buffer.format.sampleRate)Hz channels=\(buffer.format.channelCount)"
                )
            }
        }
        return samples
    }

    private func appendSamples(_ samples: [Float]) {
        guard isRunning else {
            return
        }

        retainedSamples.append(contentsOf: samples)

        if !hasLoggedFirstSampleAppend {
            hasLoggedFirstSampleAppend = true
            debugLog("WhisperTurboASRService accepted first resampled audio chunk")
        }

        let maxSamples = runtime.maximumRetainedSampleCount
        if retainedSamples.count > maxSamples {
            retainedSamples.removeFirst(retainedSamples.count - maxSamples)
            lastTranscribedSampleCount = 0
        }
    }

    private func installTimer() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(
            deadline: .now() + runtime.pollingInterval,
            repeating: runtime.pollingInterval
        )
        timer.setEventHandler { [weak self] in
            self?.transcribeIfNeeded()
        }
        self.timer = timer
        timer.resume()
    }

    private func transcribeIfNeeded() {
        guard isRunning, !isTranscriptionInFlight else {
            return
        }

        guard retainedSamples.count >= runtime.minimumStartingSampleCount else {
            return
        }

        let newSampleCount = retainedSamples.count - lastTranscribedSampleCount
        guard newSampleCount >= runtime.minimumIncrementSampleCount ||
                lastDeliveredPartialText.isEmpty else {
            return
        }

        let samples = retainedSamples
        let localeIdentifier = self.localeIdentifier
        let generation = sessionGeneration
        let sampleCount = samples.count
        isTranscriptionInFlight = true
        debugLog("WhisperTurboASRService scheduling transcription for \(sampleCount) samples")

        workerQueue.async { [weak self] in
            guard let self else {
                return
            }

            let result = Result { try self.runtime.transcribe(samples: samples, localeIdentifier: localeIdentifier) }
            self.controlQueue.async {
                self.completeTranscription(
                    result,
                    sampleCount: sampleCount,
                    generation: generation
                )
            }
        }
    }

    private func completeTranscription(
        _ result: Result<FasterWhisperTranscriptionResponse, Error>,
        sampleCount: Int,
        generation: UInt64
    ) {
        guard generation == sessionGeneration else {
            return
        }

        isTranscriptionInFlight = false

        guard isRunning else {
            return
        }

        switch result {
        case .success(let transcription):
            lastTranscribedSampleCount = sampleCount

            let normalized = transcription.text
            guard !normalized.isEmpty else {
                return
            }

            let segmentDrivenText: String
            if transcription.segments.isEmpty {
                let overlapAdjusted = removeLeadingCommittedOverlap(from: normalized)
                guard !overlapAdjusted.isEmpty else {
                    return
                }
                segmentDrivenText = overlapAdjusted
            } else {
                let adjustedSegments = removeLeadingCommittedSegments(
                    from: transcription.segments,
                    fullText: normalized
                )
                guard !adjustedSegments.isEmpty else {
                    return
                }

                if adjustedSegments.count > 1 {
                    commitLeadingChunks(
                        prefixes: [adjustedSegments[0]],
                        remainder: adjustedSegments.dropFirst().joined(separator: " "),
                        fromFullTranscript: adjustedSegments.joined(separator: " ")
                    )
                    return
                }

                segmentDrivenText = adjustedSegments[0]
            }

            if let split = Self.extractCommittedPrefix(from: segmentDrivenText) {
                commitLeadingChunks(
                    prefixes: [split.prefix],
                    remainder: split.remainder,
                    fromFullTranscript: segmentDrivenText
                )
                return
            }

            if segmentDrivenText == lastDeliveredPartialText {
                stableRepeatCount += 1
                if shouldPromoteStablePartialToFinal(segmentDrivenText) {
                    emitFinal(for: segmentDrivenText)
                }
                return
            }

            lastDeliveredPartialText = segmentDrivenText
            stableRepeatCount = 0
            eventSink?(.asrPartialReceived(segmentDrivenText))

            if Self.endsWithTerminalPunctuation(segmentDrivenText) {
                emitFinal(for: segmentDrivenText)
            }
        case .failure(let error):
            let sink = eventSink
            stopStreamingOnControlQueue()
            sink?(.localASRFailed(message: error.localizedDescription))
        }
    }

    private func stopStreamingOnControlQueue() {
        sessionGeneration &+= 1
        isRunning = false
        isTranscriptionInFlight = false
        retainedSamples.removeAll(keepingCapacity: false)
        lastTranscribedSampleCount = 0
        lastDeliveredPartialText = ""
        stableRepeatCount = 0
        recentCommittedSegments.removeAll(keepingCapacity: true)
        eventSink = nil
        hasLoggedFirstBuffer = false
        hasLoggedFirstSampleAppend = false
        hasLoggedResamplerFailure = false
        runtime.stop()
        timer?.cancel()
        timer = nil
        audioService.clearBufferHandler()
        sampleQueue.sync {
            self.resampler.reset()
        }
    }

    private static func normalizeTranscript(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func shouldPromoteStablePartialToFinal(_ text: String) -> Bool {
        guard !text.isEmpty else {
            return false
        }

        if Self.endsWithTerminalPunctuation(text) {
            return true
        }

        guard stableRepeatCount >= 0 else {
            return false
        }

        return Self.isSemanticChunkCandidate(text)
    }

    private func emitFinal(for text: String) {
        guard !text.isEmpty else {
            return
        }

        debugLog("WhisperTurboASRService emitting final ASR segment")
        stableRepeatCount = 0
        lastDeliveredPartialText = ""
        retainedSamples.removeAll(keepingCapacity: true)
        lastTranscribedSampleCount = 0
        recentCommittedSegments.removeAll(keepingCapacity: true)
        eventSink?(.asrFinalReceived(text))
    }

    private func commitLeadingChunks(
        prefixes: [String],
        remainder: String,
        fromFullTranscript fullTranscript: String
    ) {
        let committedPrefixes = prefixes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let remainingSuffix = remainder.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !committedPrefixes.isEmpty else {
            return
        }

        debugLog("WhisperTurboASRService emitting segmented final ASR chunk")
        stableRepeatCount = 0
        let committedCharacterCount = max(
            1,
            fullTranscript.count - remainingSuffix.count
        )
        applyCommittedAudioTrim(
            committedCharacterCount: committedCharacterCount,
            fromFullTranscriptCount: fullTranscript.count
        )
        lastTranscribedSampleCount = 0
        lastDeliveredPartialText = remainingSuffix

        for committedPrefix in committedPrefixes {
            rememberCommittedSegment(committedPrefix)
            eventSink?(.asrFinalReceived(committedPrefix))
        }

        if !remainingSuffix.isEmpty {
            eventSink?(.asrPartialReceived(remainingSuffix))
        }
    }

    private func applyCommittedAudioTrim(
        committedCharacterCount: Int,
        fromFullTranscriptCount fullTranscriptCount: Int
    ) {
        guard !retainedSamples.isEmpty else {
            return
        }

        guard fullTranscriptCount > 0, committedCharacterCount > 0 else {
            retainedSamples.removeAll(keepingCapacity: true)
            return
        }

        let ratio = min(
            0.92,
            max(0.12, Double(committedCharacterCount) / Double(fullTranscriptCount))
        )
        let dropCount = Int((Double(retainedSamples.count) * ratio).rounded(.down))

        guard dropCount > 0 else {
            return
        }

        if dropCount >= retainedSamples.count {
            retainedSamples.removeAll(keepingCapacity: true)
            return
        }

        retainedSamples.removeFirst(dropCount)
    }

    private func rememberCommittedSegment(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }

        recentCommittedSegments.append(normalized)
        if recentCommittedSegments.count > 6 {
            recentCommittedSegments.removeFirst(recentCommittedSegments.count - 6)
        }
    }

    private func removeLeadingCommittedOverlap(from text: String) -> String {
        guard !text.isEmpty, !recentCommittedSegments.isEmpty else {
            return text
        }

        let removal = Self.leadingCommittedOverlap(
            in: text,
            recentSegments: recentCommittedSegments
        )
        guard removal.removedCharacters > 0 else {
            return text
        }

        applyCommittedAudioTrim(
            committedCharacterCount: removal.removedCharacters,
            fromFullTranscriptCount: text.count
        )
        lastTranscribedSampleCount = 0
        return removal.remainingText
    }

    private func removeLeadingCommittedSegments(
        from segments: [String],
        fullText: String
    ) -> [String] {
        guard !segments.isEmpty, !recentCommittedSegments.isEmpty else {
            return segments
        }

        var adjustedSegments = segments
        var removedCharacters = 0
        var didRemove = true

        while didRemove, let firstSegment = adjustedSegments.first {
            didRemove = false

            for recentSegment in recentCommittedSegments {
                guard let overlapLength = Self.leadingWholeSegmentMatchLength(
                    in: firstSegment,
                    segment: recentSegment
                ) else {
                    continue
                }

                removedCharacters += overlapLength
                let remainder = Self.substring(firstSegment, from: overlapLength)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if remainder.isEmpty {
                    adjustedSegments.removeFirst()
                } else {
                    adjustedSegments[0] = remainder
                }

                didRemove = true
                break
            }
        }

        guard removedCharacters > 0 else {
            return adjustedSegments
        }

        applyCommittedAudioTrim(
            committedCharacterCount: removedCharacters,
            fromFullTranscriptCount: max(fullText.count, removedCharacters)
        )
        lastTranscribedSampleCount = 0
        return adjustedSegments
    }

    private static func endsWithTerminalPunctuation(_ text: String) -> Bool {
        guard let lastCharacter = text.last else {
            return false
        }

        return terminalPunctuation.contains(lastCharacter)
    }

    private static let terminalPunctuation: Set<Character> = [
        ".",
        "!",
        "?",
        "。",
        "！",
        "？"
    ]

    private static let weakTrailingConnectors: Set<String> = [
        "a", "an", "and", "are", "as", "at", "but", "by", "for", "from",
        "if", "in", "into", "is", "of", "on", "or", "so", "the", "to",
        "was", "were", "with", "yet"
    ]

    private static let clauseBoundaryPunctuation: Set<Character> = [
        ",",
        ";",
        ":",
        "，",
        "、",
        "；",
        "："
    ]

    private static let splitTerminalTriggerCharacters = 10
    private static let splitClauseTriggerCharacters = 16
    private static let splitClauseTriggerTokens = 3
    private static let splitForceCharacters = 36
    private static let splitForceTokens = 7
    private static let splitMinimumTerminalCharacters = 6
    private static let splitMinimumClauseCharacters = 10
    private static let splitMinimumForcedCharacters = 16
    private static let splitMinimumTailCharacters = 4
    private static let splitMinimumTerminalTokens = 2
    private static let splitMinimumClauseTokens = 2
    private static let splitMinimumForcedTokens = 3
    private static let splitMinimumTailTokens = 1
    private static func isSemanticChunkCandidate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        guard !endsWithWeakTrailingConnector(trimmed) else {
            return false
        }

        let tokenCount = trimmed.split(whereSeparator: \.isWhitespace).count
        if tokenCount >= 3 && trimmed.count >= 8 {
            return true
        }

        if tokenCount <= 1 {
            return trimmed.count >= 8
        }

        return false
    }

    private static func endsWithWeakTrailingConnector(_ text: String) -> Bool {
        guard let lastToken = text
            .split(whereSeparator: \.isWhitespace)
            .last?
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters) else {
            return false
        }

        guard !lastToken.isEmpty else {
            return false
        }

        return weakTrailingConnectors.contains(lastToken)
    }

    private static func extractCommittedPrefix(
        from text: String
    ) -> (prefix: String, remainder: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let characters = Array(trimmed)
        guard characters.count > splitMinimumTerminalCharacters + splitMinimumTailCharacters else {
            return nil
        }

        let tokenCount = wordTokenCount(in: trimmed)
        let terminalOffsets = boundaryOffsets(in: characters, matching: terminalPunctuation)
        if trimmed.count >= splitTerminalTriggerCharacters,
           let split = earliestValidSplit(
               in: trimmed,
               candidateOffsets: terminalOffsets,
               minimumPrefixCharacters: splitMinimumTerminalCharacters,
               minimumPrefixTokens: splitMinimumTerminalTokens
           ) {
            return split
        }

        let clauseOffsets = boundaryOffsets(in: characters, matching: clauseBoundaryPunctuation)
        if (trimmed.count >= splitClauseTriggerCharacters || tokenCount >= splitClauseTriggerTokens),
           let split = earliestValidSplit(
               in: trimmed,
               candidateOffsets: clauseOffsets,
               minimumPrefixCharacters: splitMinimumClauseCharacters,
               minimumPrefixTokens: splitMinimumClauseTokens
           ) {
            return split
        }

        guard trimmed.count >= splitForceCharacters || tokenCount >= splitForceTokens else {
            return nil
        }

        return earliestValidSplit(
            in: trimmed,
            candidateOffsets: tokenBoundaryOffsets(in: trimmed),
            minimumPrefixCharacters: splitMinimumForcedCharacters,
            minimumPrefixTokens: splitMinimumForcedTokens
        )
    }

    private static func earliestValidSplit(
        in text: String,
        candidateOffsets: [Int],
        minimumPrefixCharacters: Int,
        minimumPrefixTokens: Int
    ) -> (prefix: String, remainder: String)? {
        for offset in candidateOffsets {
            let prefix = substring(text, to: offset)
            let remainder = substring(text, from: offset)
            guard isValidSplit(
                prefix: prefix,
                remainder: remainder,
                minimumPrefixCharacters: minimumPrefixCharacters,
                minimumPrefixTokens: minimumPrefixTokens
            ) else {
                continue
            }

            let normalizedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedRemainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedPrefix.isEmpty, !normalizedRemainder.isEmpty else {
                continue
            }

            return (normalizedPrefix, normalizedRemainder)
        }

        return nil
    }

    private static func boundaryOffsets(
        in characters: [Character],
        matching punctuationSet: Set<Character>
    ) -> [Int] {
        var offsets: [Int] = []

        for (index, character) in characters.enumerated() {
            let splitOffset = index + 1
            guard splitOffset < characters.count,
                  punctuationSet.contains(character) else {
                continue
            }

            offsets.append(splitOffset)
        }

        return offsets
    }

    private static func tokenBoundaryOffsets(in text: String) -> [Int] {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard tokens.count >= splitMinimumForcedTokens + splitMinimumTailTokens else {
            return []
        }

        var offsets: [Int] = []
        var running = 0

        for (index, token) in tokens.enumerated() {
            running += token.count
            if index < tokens.count - 1 {
                running += 1
            }

            let prefixTokenCount = index + 1
            let remainderTokenCount = tokens.count - prefixTokenCount
            if prefixTokenCount >= splitMinimumForcedTokens,
               remainderTokenCount >= splitMinimumTailTokens {
                offsets.append(running)
            }
        }

        return offsets
    }

    private static func isValidSplit(
        prefix: String,
        remainder: String,
        minimumPrefixCharacters: Int,
        minimumPrefixTokens: Int
    ) -> Bool {
        let normalizedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRemainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalizedPrefix.count >= minimumPrefixCharacters,
              normalizedRemainder.count >= splitMinimumTailCharacters else {
            return false
        }

        let prefixTokens = wordTokenCount(in: normalizedPrefix)
        let remainderTokens = wordTokenCount(in: normalizedRemainder)

        return prefixTokens >= minimumPrefixTokens && remainderTokens >= splitMinimumTailTokens
    }

    private static func wordTokenCount(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func leadingCommittedOverlap(
        in text: String,
        recentSegments: [String]
    ) -> (remainingText: String, removedCharacters: Int) {
        var working = text
        var removedCharacters = 0
        var didRemove = true

        while didRemove, !working.isEmpty {
            didRemove = false

            for segment in recentSegments {
                guard let overlapLength = leadingWholeSegmentMatchLength(
                    in: working,
                    segment: segment
                ) else {
                    continue
                }

                removedCharacters += overlapLength
                working = substring(working, from: overlapLength)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                didRemove = true
                break
            }
        }

        return (working, removedCharacters)
    }

    private static func leadingWholeSegmentMatchLength(
        in text: String,
        segment: String
    ) -> Int? {
        guard !segment.isEmpty, text.hasPrefix(segment) else {
            return nil
        }

        guard text.count > segment.count else {
            return segment.count
        }

        let boundaryIndex = text.index(text.startIndex, offsetBy: segment.count)
        let boundaryCharacter = text[boundaryIndex]

        if boundaryCharacter.isWhitespace || boundaryCharacter.isPunctuation {
            return segment.count
        }

        return nil
    }

    private static func substring(_ text: String, to offset: Int) -> String {
        let boundedOffset = max(0, min(offset, text.count))
        let index = text.index(text.startIndex, offsetBy: boundedOffset)
        return String(text[..<index])
    }

    private static func substring(_ text: String, from offset: Int) -> String {
        let boundedOffset = max(0, min(offset, text.count))
        let index = text.index(text.startIndex, offsetBy: boundedOffset)
        return String(text[index...])
    }
}

private protocol WhisperTurboRuntime: AnyObject, Sendable {
    var pollingInterval: DispatchTimeInterval { get }
    var minimumStartingSampleCount: Int { get }
    var minimumIncrementSampleCount: Int { get }
    var maximumRetainedSampleCount: Int { get }

    func validateAvailability() throws
    func transcribe(samples: [Float], localeIdentifier: String) throws -> FasterWhisperTranscriptionResponse
    func stop()
}

private final class FasterWhisperTurboRuntime: WhisperTurboRuntime, @unchecked Sendable {
    private let descriptor: WhisperTurboRuntimeDescriptor
    private let stateLock = NSLock()
    private var session: FasterWhisperProcessSession?

    init(descriptor: WhisperTurboRuntimeDescriptor = .preferred()) {
        self.descriptor = descriptor
    }

    var pollingInterval: DispatchTimeInterval {
        .milliseconds(Int((descriptor.pollingInterval * 1_000).rounded()))
    }

    var minimumStartingSampleCount: Int {
        Int((descriptor.minimumStartingWindowSeconds * Double(descriptor.sampleRate)).rounded(.up))
    }

    var minimumIncrementSampleCount: Int {
        Int((descriptor.minimumIncrementalWindowSeconds * Double(descriptor.sampleRate)).rounded(.up))
    }

    var maximumRetainedSampleCount: Int {
        Int((descriptor.maximumRetainedWindowSeconds * Double(descriptor.sampleRate)).rounded(.up))
    }

    func validateAvailability() throws {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: descriptor.pythonPath) else {
            throw WhisperTurboASRError.executableUnavailable(path: descriptor.pythonPath)
        }

        guard fileManager.fileExists(atPath: descriptor.runnerPath) else {
            throw WhisperTurboASRError.runnerUnavailable(path: descriptor.runnerPath)
        }

        if let localModelPath = descriptor.localModelPath,
           !fileManager.fileExists(atPath: localModelPath) {
            throw WhisperTurboASRError.modelUnavailable(path: localModelPath)
        }
    }

    func transcribe(samples: [Float], localeIdentifier: String) throws -> FasterWhisperTranscriptionResponse {
        try validateAvailability()

        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("SpeechflowWhisperTurbo", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let token = UUID().uuidString
        let inputURL = tempDirectory.appendingPathComponent("\(token).wav")

        defer {
            try? fileManager.removeItem(at: inputURL)
        }

        try WAVFileWriter.writeMono16BitPCM(
            samples: samples,
            sampleRate: descriptor.sampleRate,
            to: inputURL
        )

        let processSession = try ensureSession()
        let response = try processSession.transcribe(
            audioPath: inputURL.path,
            languageCode: descriptor.languageCode(for: localeIdentifier),
            timeout: descriptor.requestTimeout
        )

        let normalizedText = Self.normalizeTranscript(response.text)
        guard !normalizedText.isEmpty else {
            throw WhisperTurboASRError.transcriptionOutputMissing
        }

        let normalizedSegments = response.segments
            .map(Self.normalizeTranscript)
            .filter { !$0.isEmpty }

        return FasterWhisperTranscriptionResponse(
            text: normalizedText,
            segments: normalizedSegments.isEmpty ? [normalizedText] : normalizedSegments
        )
    }

    func stop() {
        stateLock.lock()
        let activeSession = session
        session = nil
        stateLock.unlock()

        activeSession?.terminate()
    }

    private func ensureSession() throws -> FasterWhisperProcessSession {
        stateLock.lock()
        if let session {
            stateLock.unlock()
            return session
        }
        stateLock.unlock()
        debugLog("WhisperTurboASRService launching ASR runner")

        let newSession = try FasterWhisperProcessSession(
            pythonPath: descriptor.pythonPath,
            runnerPath: descriptor.runnerPath,
            environment: descriptor.runnerEnvironment(),
            timeout: descriptor.startupTimeout
        )
        debugLog("WhisperTurboASRService ASR runner ready")

        stateLock.lock()
        if let existingSession = session {
            stateLock.unlock()
            newSession.terminate()
            return existingSession
        }

        session = newSession
        stateLock.unlock()
        return newSession
    }

    private static func normalizeTranscript(_ text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

private struct WhisperTurboRuntimeDescriptor {
    static let defaultSampleRate = 16_000
    static let defaultModelName = "Qwen/Qwen3-ASR-1.7B"

    let pythonPath: String
    let runnerPath: String
    let modelName: String
    let downloadRoot: String
    let localModelPath: String?
    let sampleRate: Int
    let pollingInterval: TimeInterval
    let minimumStartingWindowSeconds: TimeInterval
    let minimumIncrementalWindowSeconds: TimeInterval
    let maximumRetainedWindowSeconds: TimeInterval
    let startupTimeout: TimeInterval
    let requestTimeout: TimeInterval

    static func preferred(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> WhisperTurboRuntimeDescriptor {
        WhisperTurboRuntimeDescriptor(
            pythonPath: resolvedPythonPath(from: environment),
            runnerPath: resolvedRunnerPath(),
            modelName: environment["SPEECHFLOW_ASR_MODEL"]
                ?? environment["SPEECHFLOW_FASTER_WHISPER_MODEL"]
                ?? defaultModelName,
            downloadRoot: resolvedDownloadRoot(from: environment),
            localModelPath: resolvedLocalModelPath(from: environment),
            sampleRate: Self.intValue(
                for: "SPEECHFLOW_WHISPER_SAMPLE_RATE",
                defaultValue: defaultSampleRate,
                environment: environment
            ),
            pollingInterval: Self.doubleValue(
                for: "SPEECHFLOW_WHISPER_POLL_SECONDS",
                defaultValue: 0.5,
                environment: environment
            ),
            minimumStartingWindowSeconds: Self.doubleValue(
                for: "SPEECHFLOW_WHISPER_MIN_START_SECONDS",
                defaultValue: 1.0,
                environment: environment
            ),
            minimumIncrementalWindowSeconds: Self.doubleValue(
                for: "SPEECHFLOW_WHISPER_MIN_INCREMENT_SECONDS",
                defaultValue: 0.6,
                environment: environment
            ),
            maximumRetainedWindowSeconds: Self.doubleValue(
                for: "SPEECHFLOW_WHISPER_MAX_WINDOW_SECONDS",
                defaultValue: 4.5,
                environment: environment
            ),
            startupTimeout: Self.doubleValue(
                for: "SPEECHFLOW_FASTER_WHISPER_STARTUP_TIMEOUT_SECONDS",
                defaultValue: 120,
                environment: environment
            ),
            requestTimeout: Self.doubleValue(
                for: "SPEECHFLOW_FASTER_WHISPER_REQUEST_TIMEOUT_SECONDS",
                defaultValue: 45,
                environment: environment
            )
        )
    }

    func languageCode(for localeIdentifier: String) -> String {
        if #available(macOS 13.0, *) {
            let locale = Locale(identifier: localeIdentifier)
            if let identifier = locale.language.languageCode?.identifier,
               !identifier.isEmpty {
                return identifier
            }
        }

        let normalized = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        if let languageComponent = normalized.split(separator: "-").first,
           !languageComponent.isEmpty {
            return String(languageComponent)
        }

        return "auto"
    }

    func runnerEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base

        if let localModelPath {
            if environment["SPEECHFLOW_ASR_MODEL_PATH"] == nil,
               environment["SPEECHFLOW_FASTER_WHISPER_MODEL_PATH"] == nil {
                environment["SPEECHFLOW_ASR_MODEL_PATH"] = localModelPath
            }
        } else if environment["SPEECHFLOW_ASR_MODEL"] == nil,
                  environment["SPEECHFLOW_FASTER_WHISPER_MODEL"] == nil {
            environment["SPEECHFLOW_ASR_MODEL"] = modelName
        }

        if environment["SPEECHFLOW_ASR_DOWNLOAD_ROOT"] == nil,
           environment["SPEECHFLOW_FASTER_WHISPER_DOWNLOAD_ROOT"] == nil {
            environment["SPEECHFLOW_ASR_DOWNLOAD_ROOT"] = downloadRoot
        }

        if environment["SPEECHFLOW_ASR_DEVICE"] == nil,
           environment["SPEECHFLOW_FASTER_WHISPER_DEVICE"] == nil {
            environment["SPEECHFLOW_ASR_DEVICE"] = "cpu"
        }

        if environment["SPEECHFLOW_ASR_COMPUTE_TYPE"] == nil,
           environment["SPEECHFLOW_FASTER_WHISPER_COMPUTE_TYPE"] == nil {
            environment["SPEECHFLOW_ASR_COMPUTE_TYPE"] = "int8"
        }

        return environment
    }

    private static func resolvedPythonPath(from environment: [String: String]) -> String {
        if let override = environment["SPEECHFLOW_FASTER_WHISPER_PYTHON_PATH"],
           let resolved = resolveExecutableCandidate(override, environment: environment) {
            return resolved
        }

        let candidates = [
            "python3",
            "/opt/homebrew/Caskroom/miniconda/base/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]

        for candidate in candidates {
            if let resolved = resolveExecutableCandidate(candidate, environment: environment) {
                return resolved
            }
        }

        return "/usr/bin/python3"
    }

    private static func resolvedRunnerPath() -> String {
        if let bundled = Bundle.module.url(
            forResource: "faster_whisper_runner",
            withExtension: "py"
        )?.path {
            return bundled
        }

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        return URL(fileURLWithPath: packageRoot)
            .appendingPathComponent("Resources/faster_whisper_runner.py")
            .path
    }

    private static func resolvedLocalModelPath(
        from environment: [String: String]
    ) -> String? {
        guard let override = environment["SPEECHFLOW_ASR_MODEL_PATH"]
            ?? environment["SPEECHFLOW_FASTER_WHISPER_MODEL_PATH"],
              !override.isEmpty else {
            return nil
        }

        return expandedPath(for: override)
    }

    private static func resolvedDownloadRoot(
        from environment: [String: String]
    ) -> String {
        if let override = environment["SPEECHFLOW_ASR_DOWNLOAD_ROOT"]
            ?? environment["SPEECHFLOW_FASTER_WHISPER_DOWNLOAD_ROOT"],
           !override.isEmpty {
            return expandedPath(for: override)
        }

        return expandedPath(
            for: "~/Library/Application Support/Speechflow/Models/ASR"
        )
    }

    private static func resolveExecutableCandidate(
        _ candidate: String,
        environment: [String: String]
    ) -> String? {
        let expandedCandidate = expandedPath(for: candidate)
        let fileManager = FileManager.default

        if expandedCandidate.contains("/") {
            return fileManager.isExecutableFile(atPath: expandedCandidate) ? expandedCandidate : nil
        }

        let searchPaths = environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []

        for searchPath in searchPaths {
            let path = URL(fileURLWithPath: searchPath)
                .appendingPathComponent(expandedCandidate)
                .path
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    private static func expandedPath(for path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func doubleValue(
        for key: String,
        defaultValue: TimeInterval,
        environment: [String: String]
    ) -> TimeInterval {
        guard let rawValue = environment[key],
              let value = TimeInterval(rawValue),
              value > 0 else {
            return defaultValue
        }

        return value
    }

    private static func intValue(
        for key: String,
        defaultValue: Int,
        environment: [String: String]
    ) -> Int {
        guard let rawValue = environment[key],
              let value = Int(rawValue),
              value > 0 else {
            return defaultValue
        }

        return value
    }
}

private final class FasterWhisperProcessSession: @unchecked Sendable {
    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stdoutLock = NSLock()
    private let stderrLock = NSLock()
    private let responseSemaphore = DispatchSemaphore(value: 0)

    private var stdoutBuffer = Data()
    private var pendingLines: [String] = []
    private var stderrText = ""

    init(
        pythonPath: String,
        runnerPath: String,
        environment: [String: String],
        timeout: TimeInterval
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [runnerPath]
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading

        startReader(for: stdoutPipe.fileHandleForReading, isErrorStream: false)
        startReader(for: stderrPipe.fileHandleForReading, isErrorStream: true)

        do {
            try process.run()
        } catch {
            throw WhisperTurboASRError.transcriberLaunchFailed(message: error.localizedDescription)
        }

        let readyLine = try waitForLine(timeout: timeout)
        let readyPayload = try decodeJSONLine(readyLine)
        let type = readyPayload["type"] as? String

        if type == "startup_error" {
            let message = readyPayload["message"] as? String ?? recentErrorText
            terminate()
            throw WhisperTurboASRError.transcriberLaunchFailed(message: message)
        }

        guard type == "ready" else {
            let message = "Unexpected runner handshake: \(readyLine)"
            terminate()
            throw WhisperTurboASRError.transcriberLaunchFailed(message: message)
        }
    }

    func transcribe(
        audioPath: String,
        languageCode: String,
        timeout: TimeInterval
    ) throws -> FasterWhisperTranscriptionResponse {
        let request: [String: Any] = [
            "type": "transcribe",
            "audio_path": audioPath,
            "language": languageCode
        ]
        try sendJSONLine(request)

        let line = try waitForLine(timeout: timeout)
        let payload = try decodeJSONLine(line)

        if (payload["type"] as? String) == "error" {
            throw WhisperTurboASRError.transcriberFailed(
                message: payload["message"] as? String ?? recentErrorText
            )
        }

        guard (payload["type"] as? String) == "result" else {
            throw WhisperTurboASRError.transcriberFailed(message: "Unexpected response: \(line)")
        }

        let text = payload["text"] as? String ?? ""
        let segments = payload["segments"] as? [String] ?? []
        return FasterWhisperTranscriptionResponse(text: text, segments: segments)
    }

    func terminate() {
        try? sendJSONLine(["type": "shutdown"])

        stdoutHandle.readabilityHandler = nil

        if process.isRunning {
            process.terminate()
        }
    }

    private func startReader(for handle: FileHandle, isErrorStream: Bool) {
        let queue = DispatchQueue(
            label: isErrorStream
                ? "Speechflow.FasterWhisper.stderr"
                : "Speechflow.FasterWhisper.stdout"
        )

        queue.async { [weak self] in
            guard let self else {
                return
            }

            while true {
                let data = handle.availableData
                guard !data.isEmpty else {
                    break
                }

                if isErrorStream {
                    self.appendErrorData(data)
                } else {
                    self.appendOutputData(data)
                }
            }
        }
    }

    private func appendOutputData(_ data: Data) {
        stdoutLock.lock()
        stdoutBuffer.append(data)

        while let newlineRange = stdoutBuffer.range(of: Data([0x0A])) {
            let lineData = stdoutBuffer.subdata(in: 0..<newlineRange.lowerBound)
            stdoutBuffer.removeSubrange(0..<newlineRange.upperBound)

            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                continue
            }

            pendingLines.append(line)
            responseSemaphore.signal()
        }
        stdoutLock.unlock()
    }

    private func appendErrorData(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else {
            return
        }

        stderrLock.lock()
        stderrText.append(text)
        if stderrText.count > 4_000 {
            stderrText = String(stderrText.suffix(4_000))
        }
        stderrLock.unlock()
    }

    private func waitForLine(timeout: TimeInterval) throws -> String {
        let deadline = DispatchTime.now() + timeout
        let didReceive = responseSemaphore.wait(timeout: deadline)
        guard didReceive == .success else {
            throw WhisperTurboASRError.transcriberFailed(
                message: process.isRunning
                    ? "The ASR runner timed out waiting for a response."
                    : recentErrorText
            )
        }

        stdoutLock.lock()
        let line = pendingLines.isEmpty ? nil : pendingLines.removeFirst()
        stdoutLock.unlock()

        guard let line else {
            throw WhisperTurboASRError.transcriberFailed(message: "Runner returned an empty response.")
        }

        return line
    }

    private func decodeJSONLine(_ line: String) throws -> [String: Any] {
        let data = Data(line.utf8)
        let rawObject = try JSONSerialization.jsonObject(with: data)
        guard let object = rawObject as? [String: Any] else {
            throw WhisperTurboASRError.transcriberFailed(message: "Runner produced invalid JSON.")
        }
        return object
    }

    private func sendJSONLine(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        stdinHandle.write(data)
        stdinHandle.write(Data([0x0A]))
    }

    private var recentErrorText: String {
        stderrLock.lock()
        let text = stderrText
        stderrLock.unlock()
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return "The ASR runner exited unexpectedly."
        }
        return normalized
    }
}

private struct FasterWhisperTranscriptionResponse {
    let text: String
    let segments: [String]
}

private final class PCMResampler {
    private let targetSampleRate: Double
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var cachedSourceSignature: SourceSignature?

    init(targetSampleRate: Int) {
        self.targetSampleRate = Double(targetSampleRate)
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetSampleRate),
            channels: 1,
            interleaved: false
        )!
    }

    func reset() {
        converter = nil
        cachedSourceSignature = nil
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        if abs(buffer.format.sampleRate - targetSampleRate) < 0.5 {
            return directFloatSamples(from: buffer)
        }

        let signature = SourceSignature(format: buffer.format)

        if cachedSourceSignature != signature || converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            cachedSourceSignature = signature
        }

        guard let converter else {
            return nil
        }

        let estimatedFrames = max(
            AVAudioFrameCount(
                (Double(buffer.frameLength) * targetSampleRate / buffer.format.sampleRate).rounded(.up)
            ),
            1
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: estimatedFrames + 32
        ) else {
            return nil
        }

        let inputState = InputStateBox()
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputState.didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            inputState.didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            _ = conversionError
            return nil
        }

        guard (status == .haveData || status == .inputRanDry || status == .endOfStream),
              let channelData = outputBuffer.floatChannelData else {
            return nil
        }

        let frameLength = Int(outputBuffer.frameLength)
        guard frameLength > 0 else {
            return nil
        }

        let pointer = channelData[0]
        let samples = UnsafeBufferPointer(start: pointer, count: frameLength)
        return Array(samples)
    }

    private func directFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else {
            return nil
        }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData else {
                return nil
            }

            if !buffer.format.isInterleaved {
                if channelCount == 1 {
                    return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
                }

                var output = [Float](repeating: 0, count: frameLength)
                for channelIndex in 0..<channelCount {
                    let channel = channelData[channelIndex]
                    for frameIndex in 0..<frameLength {
                        output[frameIndex] += channel[frameIndex]
                    }
                }

                let scale = 1.0 / Float(channelCount)
                for index in 0..<output.count {
                    output[index] *= scale
                }
                return output
            }

            let interleaved = UnsafeBufferPointer(start: channelData[0], count: frameLength * channelCount)
            return deinterleaveToMono(
                samples: interleaved,
                channelCount: channelCount,
                scale: 1.0
            )

        case .pcmFormatInt16:
            let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard let mData = audioBuffers.first?.mData else {
                return nil
            }

            let sampleCount = Int(audioBuffers.first?.mDataByteSize ?? 0) / MemoryLayout<Int16>.size
            let samples = UnsafeBufferPointer(
                start: mData.bindMemory(to: Int16.self, capacity: sampleCount),
                count: sampleCount
            )

            if buffer.format.isInterleaved {
                return deinterleaveToMono(
                    samples: samples,
                    channelCount: channelCount,
                    scale: 1.0 / Float(Int16.max)
                )
            }

            if channelCount == 1 {
                return samples.map { Float($0) / Float(Int16.max) }
            }

            var output = [Float](repeating: 0, count: frameLength)
            for channelIndex in 0..<channelCount {
                guard let channelPointer = buffer.int16ChannelData?[channelIndex] else {
                    return nil
                }

                for frameIndex in 0..<frameLength {
                    output[frameIndex] += Float(channelPointer[frameIndex]) / Float(Int16.max)
                }
            }

            let scale = 1.0 / Float(channelCount)
            for index in 0..<output.count {
                output[index] *= scale
            }
            return output

        case .pcmFormatInt32:
            let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard let mData = audioBuffers.first?.mData else {
                return nil
            }

            let sampleCount = Int(audioBuffers.first?.mDataByteSize ?? 0) / MemoryLayout<Int32>.size
            let samples = UnsafeBufferPointer(
                start: mData.bindMemory(to: Int32.self, capacity: sampleCount),
                count: sampleCount
            )

            if buffer.format.isInterleaved {
                return deinterleaveToMono(
                    samples: samples,
                    channelCount: channelCount,
                    scale: 1.0 / Float(Int32.max)
                )
            }

            if channelCount == 1 {
                return samples.map { Float($0) / Float(Int32.max) }
            }

            var output = [Float](repeating: 0, count: frameLength)
            for channelIndex in 0..<channelCount {
                guard let channelPointer = buffer.int32ChannelData?[channelIndex] else {
                    return nil
                }

                for frameIndex in 0..<frameLength {
                    output[frameIndex] += Float(channelPointer[frameIndex]) / Float(Int32.max)
                }
            }

            let scale = 1.0 / Float(channelCount)
            for index in 0..<output.count {
                output[index] *= scale
            }
            return output

        default:
            return nil
        }
    }

    private func deinterleaveToMono<T: BinaryInteger>(
        samples: UnsafeBufferPointer<T>,
        channelCount: Int,
        scale: Float
    ) -> [Float]? {
        guard channelCount > 0, samples.count >= channelCount else {
            return nil
        }

        let frameLength = samples.count / channelCount
        guard frameLength > 0 else {
            return nil
        }

        var output = [Float](repeating: 0, count: frameLength)
        for frameIndex in 0..<frameLength {
            var mixed = Float.zero
            let baseIndex = frameIndex * channelCount
            for channelIndex in 0..<channelCount {
                mixed += Float(samples[baseIndex + channelIndex]) * scale
            }
            output[frameIndex] = mixed / Float(channelCount)
        }

        return output
    }

    private func deinterleaveToMono(
        samples: UnsafeBufferPointer<Float>,
        channelCount: Int,
        scale: Float
    ) -> [Float]? {
        guard channelCount > 0, samples.count >= channelCount else {
            return nil
        }

        let frameLength = samples.count / channelCount
        guard frameLength > 0 else {
            return nil
        }

        var output = [Float](repeating: 0, count: frameLength)
        for frameIndex in 0..<frameLength {
            var mixed = Float.zero
            let baseIndex = frameIndex * channelCount
            for channelIndex in 0..<channelCount {
                mixed += samples[baseIndex + channelIndex] * scale
            }
            output[frameIndex] = mixed / Float(channelCount)
        }

        return output
    }

    private struct SourceSignature: Equatable {
        let commonFormatRawValue: UInt
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let isInterleaved: Bool

        init(format: AVAudioFormat) {
            commonFormatRawValue = format.commonFormat.rawValue
            sampleRate = format.sampleRate
            channelCount = format.channelCount
            isInterleaved = format.isInterleaved
        }
    }
}

private enum PCMBufferCopying {
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let clone = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else {
            return nil
        }

        clone.frameLength = buffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(clone.mutableAudioBufferList)
        let bufferCount = min(sourceBuffers.count, destinationBuffers.count)

        for index in 0..<bufferCount {
            guard let sourcePointer = sourceBuffers[index].mData,
                  let destinationPointer = destinationBuffers[index].mData else {
                continue
            }

            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
            memcpy(destinationPointer, sourcePointer, byteCount)
        }

        return clone
    }
}

private final class PCMBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private final class InputStateBox: @unchecked Sendable {
    var didProvideInput = false
}

private enum WAVFileWriter {
    static func writeMono16BitPCM(
        samples: [Float],
        sampleRate: Int,
        to url: URL
    ) throws {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = Int(bitsPerSample / 8)
        let byteRate = UInt32(sampleRate * Int(channelCount) * bytesPerSample)
        let blockAlign = UInt16(Int(channelCount) * bytesPerSample)

        var pcmData = Data(capacity: samples.count * bytesPerSample)
        for sample in samples {
            let intSample: Int16
            if sample <= -1 {
                intSample = .min
            } else if sample >= 1 {
                intSample = .max
            } else {
                intSample = Int16((sample * Float(Int16.max)).rounded())
            }

            pcmData.append(littleEndian: intSample)
        }

        var data = Data()
        data.appendASCII("RIFF")
        data.append(littleEndian: UInt32(36 + pcmData.count))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: channelCount)
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)
        data.appendASCII("data")
        data.append(littleEndian: UInt32(pcmData.count))
        data.append(pcmData)

        try data.write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }
}
