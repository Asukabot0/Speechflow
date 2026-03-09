import AVFoundation

let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16000.0,
    channels: 1,
    interleaved: false
)!

let sourceFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 48000.0,
    channels: 1,
    interleaved: false
)!

let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
if converter == nil {
    print("FAILED TO CREATE CONVERTER")
} else {
    print("CONVERTER CREATED SUCCESSFULLY")
}
