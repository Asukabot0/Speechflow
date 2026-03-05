@preconcurrency import AVFoundation
import Foundation

internal final class PCMResampler: @unchecked Sendable {
    private let targetSampleRate: Double
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var cachedSourceSignature: SourceSignature?
    private let stateLock = NSLock()

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
        stateLock.lock()
        defer { stateLock.unlock() }
        converter = nil
        cachedSourceSignature = nil
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        stateLock.lock()
        defer { stateLock.unlock() }

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
