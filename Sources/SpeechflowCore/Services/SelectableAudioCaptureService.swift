import AVFoundation
import CoreMedia
import Foundation
import Darwin
@preconcurrency import ScreenCaptureKit

public enum SystemAudioCaptureError: LocalizedError {
    case noShareableDisplay
    case failedToConvertAudioBuffer

    public var errorDescription: String? {
        switch self {
        case .noShareableDisplay:
            return "No shareable display is available for system audio capture."
        case .failedToConvertAudioBuffer:
            return "The captured system audio buffer could not be converted into PCM audio."
        }
    }
}

public final class SelectableAudioCaptureService: AudioEngineServicing {
    private let microphoneService: AudioEngineServicing
    private let systemAudioService: AudioEngineServicing

    private var bufferHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var recognitionTuning: RecognitionTuning = .defaultValue
    private var selectedInputSource: AudioInputSource = .microphone
    private var activeService: AudioEngineServicing?
    private let stateLock = NSLock()

    public init(
        microphoneService: AudioEngineServicing,
        systemAudioService: AudioEngineServicing
    ) {
        self.microphoneService = microphoneService
        self.systemAudioService = systemAudioService
    }

    public func setBufferHandler(_ handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        stateLock.lock()
        bufferHandler = handler
        let currentActiveService = activeService
        let currentSelectedSource = selectedInputSource
        stateLock.unlock()

        currentActiveService?.setBufferHandler(handler)
        if currentActiveService == nil {
            service(for: currentSelectedSource).setBufferHandler(handler)
        }
    }

    public func clearBufferHandler() {
        stateLock.lock()
        bufferHandler = nil
        let currentActiveService = activeService
        stateLock.unlock()

        currentActiveService?.clearBufferHandler()
        microphoneService.clearBufferHandler()
        systemAudioService.clearBufferHandler()
    }

    public func updateRecognitionTuning(_ tuning: RecognitionTuning) {
        stateLock.lock()
        recognitionTuning = tuning
        stateLock.unlock()

        microphoneService.updateRecognitionTuning(tuning)
        systemAudioService.updateRecognitionTuning(tuning)
    }

    public func updateInputSource(_ inputSource: AudioInputSource) {
        stateLock.lock()
        selectedInputSource = inputSource
        let handler = bufferHandler
        let currentActiveService = activeService
        stateLock.unlock()

        let selectedService = service(for: inputSource)
        if let handler {
            selectedService.setBufferHandler(handler)
        }

        if let currentActiveService, currentActiveService !== selectedService {
            currentActiveService.clearBufferHandler()
        }
    }

    public func startCapture() throws {
        let selectedService: AudioEngineServicing
        let handler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
        let tuning: RecognitionTuning

        stateLock.lock()
        selectedService = service(for: selectedInputSource)
        handler = bufferHandler
        tuning = recognitionTuning
        stateLock.unlock()

        selectedService.updateRecognitionTuning(tuning)
        if let handler {
            selectedService.setBufferHandler(handler)
        }

        try selectedService.startCapture()

        stateLock.lock()
        activeService = selectedService
        stateLock.unlock()
    }

    public func pauseCapture() {
        stateLock.lock()
        let currentActiveService = activeService
        stateLock.unlock()
        currentActiveService?.pauseCapture()
    }

    public func stopCapture() {
        stateLock.lock()
        let currentActiveService = activeService
        activeService = nil
        stateLock.unlock()

        currentActiveService?.stopCapture()
        microphoneService.clearBufferHandler()
        systemAudioService.clearBufferHandler()
    }

    private func service(for inputSource: AudioInputSource) -> AudioEngineServicing {
        switch inputSource {
        case .microphone:
            return microphoneService
        case .systemAudio:
            return systemAudioService
        }
    }
}

public final class ScreenCaptureSystemAudioService: NSObject, AudioEngineServicing, @unchecked Sendable {
    private let callbackQueue = DispatchQueue(label: "Speechflow.SystemAudioCapture")

    private var bufferHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var recognitionTuning: RecognitionTuning = .defaultValue
    private var stream: SCStream?
    private let stateLock = NSLock()

    public override init() {
        super.init()
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
        stateLock.lock()
        let existingStream = stream
        stateLock.unlock()
        guard existingStream == nil else {
            return
        }

        let newStream = try waitForAsync {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                throw SystemAudioCaptureError.noShareableDisplay
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
            configuration.showsCursor = false
            configuration.capturesAudio = true
            configuration.sampleRate = 16_000
            configuration.channelCount = 1
            configuration.excludesCurrentProcessAudio = true

            let createdStream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: self
            )

            try createdStream.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: self.callbackQueue
            )

            try await createdStream.startCapture()
            return createdStream
        }

        stateLock.lock()
        stream = newStream
        stateLock.unlock()
    }

    public func pauseCapture() {
        stopCapture()
    }

    public func stopCapture() {
        stateLock.lock()
        let currentStream = stream
        stream = nil
        stateLock.unlock()

        guard let currentStream else {
            return
        }

        Task.detached { [callbackQueue] in
            do {
                try currentStream.removeStreamOutput(self, type: .audio)
            } catch {
                // Ignore teardown races if the stream is already stopping.
            }

            do {
                try await currentStream.stopCapture()
            } catch {
                // Ignore teardown races if the stream is already stopped.
            }

            callbackQueue.async {}
        }
    }

    private func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let pcmBuffer = makePCMBuffer(from: sampleBuffer) else {
            return
        }

        let handler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
        let tuning: RecognitionTuning
        stateLock.lock()
        handler = bufferHandler
        tuning = recognitionTuning
        stateLock.unlock()

        applySoftwareGainIfNeeded(to: pcmBuffer, gain: tuning.inputGain)
        handler?(pcmBuffer, AVAudioTime(hostTime: mach_absolute_time()))
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        var streamDescriptionValue = streamDescription.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDescriptionValue) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            return nil
        }

        pcmBuffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )

        guard status == noErr else {
            return nil
        }

        return pcmBuffer
    }

    private func applySoftwareGainIfNeeded(
        to buffer: AVAudioPCMBuffer,
        gain: Double
    ) {
        let appliedGain = Float(max(0.25, min(gain, 4.0)))
        guard abs(appliedGain - 1.0) > 0.001 else {
            return
        }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            for audioBuffer in audioBuffers {
                guard let data = audioBuffer.mData else {
                    continue
                }

                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.bindMemory(to: Float.self, capacity: sampleCount)

                for index in 0..<sampleCount {
                    let amplified = samples[index] * appliedGain
                    samples[index] = min(1.0, max(-1.0, amplified))
                }
            }
        case .pcmFormatInt16:
            for audioBuffer in audioBuffers {
                guard let data = audioBuffer.mData else {
                    continue
                }

                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                let samples = data.bindMemory(to: Int16.self, capacity: sampleCount)

                for index in 0..<sampleCount {
                    let amplified = Float(samples[index]) * appliedGain
                    let clamped = min(Float(Int16.max), max(Float(Int16.min), amplified))
                    samples[index] = Int16(clamped)
                }
            }
        case .pcmFormatInt32:
            for audioBuffer in audioBuffers {
                guard let data = audioBuffer.mData else {
                    continue
                }

                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
                let samples = data.bindMemory(to: Int32.self, capacity: sampleCount)

                for index in 0..<sampleCount {
                    let amplified = Double(samples[index]) * Double(appliedGain)
                    let clamped = min(Double(Int32.max), max(Double(Int32.min), amplified))
                    samples[index] = Int32(clamped)
                }
            }
        default:
            return
        }
    }

    private func waitForAsync<T>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = AsyncResultBox<T>()

        Task.detached {
            defer { semaphore.signal() }

            do {
                resultBox.result = .success(try await operation())
            } catch {
                resultBox.result = .failure(error)
            }
        }

        semaphore.wait()
        return try resultBox.resolve()
    }
}

extension ScreenCaptureSystemAudioService: SCStreamOutput {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else {
            return
        }

        processAudioSampleBuffer(sampleBuffer)
    }
}

extension ScreenCaptureSystemAudioService: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        if self.stream === stream {
            self.stream = nil
        }
        stateLock.unlock()
    }
}

private final class AsyncResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?

    func resolve() throws -> T {
        guard let result else {
            throw CancellationError()
        }

        return try result.get()
    }
}
