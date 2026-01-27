import CSSH2
import Foundation

enum RemoteShellError: Error, LocalizedError {
    case notInitialized
    case invalidConfiguration(String)
    case socketError(code: Int32, message: String)
    case libssh2Error(code: Int32, message: String)
    case timeout
    case disconnected
    case authenticationRequired
    case fileTransferUnavailable

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            "libssh2 initialization failed"
        case let .invalidConfiguration(message):
            message
        case let .socketError(code, message):
            "Socket error (\(code)): \(message)"
        case let .libssh2Error(code, message):
            "libssh2 error (\(code)): \(message)"
        case .timeout:
            "Operation timed out"
        case .disconnected:
            "Session is disconnected"
        case .authenticationRequired:
            "Authentication required"
        case .fileTransferUnavailable:
            "File transfer session is not connected"
        }
    }

    static func libssh2(session: OpaquePointer?, fallback: String) -> RemoteShellError {
        var errorMessage: UnsafeMutablePointer<Int8>?
        var errorLength: Int32 = 0
        let errorCode = libssh2_session_last_error(session, &errorMessage, &errorLength, 0)
        if let errorMessage, let message = String(utf8String: errorMessage) {
            return .libssh2Error(code: errorCode, message: message)
        }
        return .libssh2Error(code: errorCode, message: fallback)
    }
}
