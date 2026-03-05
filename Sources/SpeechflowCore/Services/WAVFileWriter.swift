import Foundation

internal enum WAVFileWriter {
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

internal extension Data {
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
