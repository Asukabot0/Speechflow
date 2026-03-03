import Foundation

private let logFile: FileHandle? = {
    let path = "/tmp/speechflow_debug.log"
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}()

public func debugLog(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(message)\n"
    if let data = line.data(using: .utf8) {
        logFile?.seekToEndOfFile()
        logFile?.write(data)
    }
}
