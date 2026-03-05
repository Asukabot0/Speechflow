import Foundation

internal final class FasterWhisperProcessSession: @unchecked Sendable {
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

internal struct FasterWhisperTranscriptionResponse {
    let text: String
    let segments: [String]
}
