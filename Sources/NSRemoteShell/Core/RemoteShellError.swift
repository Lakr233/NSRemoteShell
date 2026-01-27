import Foundation
import CSSH2

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
            return "libssh2 initialization failed"
        case .invalidConfiguration(let message):
            return message
        case .socketError(let code, let message):
            return "Socket error (\(code)): \(message)"
        case .libssh2Error(let code, let message):
            return "libssh2 error (\(code)): \(message)"
        case .timeout:
            return "Operation timed out"
        case .disconnected:
            return "Session is disconnected"
        case .authenticationRequired:
            return "Authentication required"
        case .fileTransferUnavailable:
            return "File transfer session is not connected"
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
