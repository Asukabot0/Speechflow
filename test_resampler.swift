import AVFoundation

let targetSampleRate = 16000.0
let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: targetSampleRate,
    channels: 1,
    interleaved: false
)!

let sourceFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 48000.0,
    channels: 1,
    interleaved: false
)!

let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)!

let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 48000)!
inputBuffer.frameLength = 48000

let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 16000)!

class InputStateBox { var didProvideInput = false }
let inputState = InputStateBox()
var conversionError: NSError?

let status = converter.convert(to: outputBuffer, error: &conversionError) { inPacketCount, outStatus in
    if inputState.didProvideInput {
        outStatus.pointee = .noDataNow // <--- WAIT! Is it endOfStream or noDataNow?
        return nil
    }
    inputState.didProvideInput = true
    outStatus.pointee = .haveData
    return inputBuffer
}

if let error = conversionError {
    print("Error:", error)
}
print("Status:", status.rawValue)
print("Output length:", outputBuffer.frameLength)
