import AVFoundation
import Foundation

internal enum PCMBufferCopying {
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

internal final class PCMBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

internal final class InputStateBox: @unchecked Sendable {
    var didProvideInput = false
}
