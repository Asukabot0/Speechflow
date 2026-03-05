import AVFoundation
import Foundation

public enum AudioBufferProcessing {
    public static func applyGain(to buffer: AVAudioPCMBuffer, boostFactor: Float) {
        guard boostFactor > 1.0 || boostFactor < 1.0 else { return }
        guard let channelData = buffer.floatChannelData else { return }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)

        for channelIndex in 0..<channelCount {
            let samples = channelData[channelIndex]
            for frameIndex in 0..<frameLength {
                samples[frameIndex] *= boostFactor
            }
        }
    }
}
