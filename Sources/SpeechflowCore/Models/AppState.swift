import Foundation

public enum AppState: Equatable, Sendable {
    case idle
    case listening
    case paused
    case error(AppErrorContext)
}

public struct AppErrorContext: Equatable, Sendable {
    public let code: String
    public let message: String
    public let isRecoverable: Bool

    public init(code: String, message: String, isRecoverable: Bool = true) {
        self.code = code
        self.message = message
        self.isRecoverable = isRecoverable
    }
}
