import Foundation

internal final class FasterWhisperTurboRuntime: WhisperTurboRuntime, @unchecked Sendable {
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
