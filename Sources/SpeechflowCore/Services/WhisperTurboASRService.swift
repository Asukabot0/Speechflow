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

            if TextChunkingHelper.endsWithTerminalPunctuation(segmentDrivenText) {
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

        if TextChunkingHelper.endsWithTerminalPunctuation(text) {
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

    private static func isSemanticChunkCandidate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        guard !TextChunkingHelper.endsWithWeakTrailingConnector(trimmed) else {
            return false
        }

        let tokenCount = TextChunkingHelper.wordTokenCount(in: trimmed)
        if tokenCount >= 3 && trimmed.count >= 8 {
            return true
        }

        if tokenCount <= 1 {
            return trimmed.count >= 8
        }

        return false
    }

    private static func extractCommittedPrefix(
        from text: String
    ) -> (prefix: String, remainder: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let characters = Array(trimmed)
        guard characters.count > TextChunkingHelper.splitMinimumTerminalCharacters + TextChunkingHelper.splitMinimumTailCharacters else {
            return nil
        }

        let tokenCount = TextChunkingHelper.wordTokenCount(in: trimmed)
        let terminalOffsets = boundaryOffsets(in: characters, matching: TextChunkingHelper.terminalPunctuation)
        if trimmed.count >= TextChunkingHelper.splitTerminalTriggerCharacters,
           let split = earliestValidSplit(
               in: trimmed,
               candidateOffsets: terminalOffsets,
               minimumPrefixCharacters: TextChunkingHelper.splitMinimumTerminalCharacters,
               minimumPrefixTokens: TextChunkingHelper.splitMinimumTerminalTokens
           ) {
            return split
        }

        let clauseOffsets = boundaryOffsets(in: characters, matching: TextChunkingHelper.clauseBoundaryPunctuation)
        if (trimmed.count >= TextChunkingHelper.splitClauseTriggerCharacters || tokenCount >= TextChunkingHelper.splitClauseTriggerTokens),
           let split = earliestValidSplit(
               in: trimmed,
               candidateOffsets: clauseOffsets,
               minimumPrefixCharacters: TextChunkingHelper.splitMinimumClauseCharacters,
               minimumPrefixTokens: TextChunkingHelper.splitMinimumClauseTokens
           ) {
            return split
        }

        guard trimmed.count >= TextChunkingHelper.splitForceCharacters || tokenCount >= TextChunkingHelper.splitForceTokens else {
            return nil
        }

        return earliestValidSplit(
            in: trimmed,
            candidateOffsets: tokenBoundaryOffsets(in: trimmed),
            minimumPrefixCharacters: TextChunkingHelper.splitMinimumForcedCharacters,
            minimumPrefixTokens: TextChunkingHelper.splitMinimumForcedTokens
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
        guard tokens.count >= TextChunkingHelper.splitMinimumForcedTokens + TextChunkingHelper.splitMinimumTailTokens else {
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
            if prefixTokenCount >= TextChunkingHelper.splitMinimumForcedTokens,
               remainderTokenCount >= TextChunkingHelper.splitMinimumTailTokens {
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
              normalizedRemainder.count >= TextChunkingHelper.splitMinimumTailCharacters else {
            return false
        }

        let prefixTokens = TextChunkingHelper.wordTokenCount(in: normalizedPrefix)
        let remainderTokens = TextChunkingHelper.wordTokenCount(in: normalizedRemainder)

        return prefixTokens >= minimumPrefixTokens && remainderTokens >= TextChunkingHelper.splitMinimumTailTokens
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


