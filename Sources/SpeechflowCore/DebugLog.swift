import Foundation
import os

private let logger = Logger(subsystem: "com.speechflow.core", category: "Debug")

public func debugLog(_ message: String) {
    logger.debug("\(message, privacy: .public)")
    let formatted = "\(Date()) [DEBUG] \(message)\n"
    if let data = formatted.data(using: .utf8) {
        let url = URL(fileURLWithPath: "/tmp/speechflow_debug.log")
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: url)
        }
    }
}
