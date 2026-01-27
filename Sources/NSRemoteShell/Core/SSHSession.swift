import Foundation
import CSSH2

final class SSHSession {
    let session: OpaquePointer
    let socket: Int32
    var timeout: TimeInterval
    private let lock = NSLock()

    init(session: OpaquePointer, socket: Int32, timeout: TimeInterval) {
        self.session = session
        self.socket = socket
        self.timeout = timeout
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func waitForSocket(deadline: Date?) async throws {
        let blockDirections = withLock { libssh2_session_block_directions(session) }
        var events: SocketEvents = []
        if (blockDirections & LIBSSH2_SESSION_BLOCK_INBOUND) != 0 {
            events.insert(.read)
        }
        if (blockDirections & LIBSSH2_SESSION_BLOCK_OUTBOUND) != 0 {
            events.insert(.write)
        }
        events.insert(.read)

        let remaining = deadline?.timeIntervalSinceNow
        if let remaining, remaining <= 0 {
            throw RemoteShellError.timeout
        }
        let ready = try await KQueuePoller.waitAsync(socket: socket, events: events, timeout: remaining)
        if !ready {
            throw RemoteShellError.timeout
        }
    }

    func retrying<T>(timeout: TimeInterval?, operation: () -> T, shouldRetry: (T) -> Bool) async throws -> T {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            let result = withLock { operation() }
            if shouldRetry(result) {
                try await waitForSocket(deadline: deadline)
                continue
            }
            return result
        }
    }

    func lastError(fallback: String) -> RemoteShellError {
        withLock { RemoteShellError.libssh2(session: session, fallback: fallback) }
    }
}
