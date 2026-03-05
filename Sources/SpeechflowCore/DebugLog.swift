import os

private let logger = Logger(subsystem: "com.speechflow.core", category: "Debug")

public func debugLog(_ message: String) {
    logger.debug("\(message, privacy: .public)")
}
