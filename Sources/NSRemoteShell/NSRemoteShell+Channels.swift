import Foundation
import CoreGraphics
import CSSH2

public extension NSRemoteShell {
    @discardableResult
    func execute(
        _ command: String,
        timeout: TimeInterval? = nil,
        onCreate: (() -> Void)? = nil,
        onOutput: @Sendable (String) -> Void,
        shouldContinue: @Sendable () -> Bool = { true }
    ) async throws -> Int32 {
        guard let session else { throw RemoteShellError.disconnected }
        let channel = try await openSessionChannel(session: session)
        defer { closeChannel(channel) }

        let rc: Int32 = try await session.retrying(timeout: timeout ?? configuration.timeout, operation: {
            command.withCString { cString in
                libssh2_channel_exec(channel, cString)
            }
        }, shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN })
        guard rc == 0 else {
            let error = session.lastError(fallback: "Failed to exec command")
            lastError = error.errorDescription
            throw error
        }
        onCreate?()

        var outputBuffer = [UInt8](repeating: 0, count: SSHConstants.bufferSize)
        var errorBuffer = [UInt8](repeating: 0, count: SSHConstants.bufferSize)
        let deadline = timeout.map { Date().addingTimeInterval($0) }

        while true {
            if let deadline, deadline.timeIntervalSinceNow <= 0 {
                break
            }
            if !shouldContinue() {
                break
            }

            var didRead = false
            let stdout = try await readChannelBytes(session: session, channel: channel, buffer: &outputBuffer, stderr: false, deadline: deadline)
            if stdout > 0 {
                let output = String(decoding: outputBuffer.prefix(stdout), as: UTF8.self)
                onOutput(output)
                didRead = true
            }
            let stderr = try await readChannelBytes(session: session, channel: channel, buffer: &errorBuffer, stderr: true, deadline: deadline)
            if stderr > 0 {
                let output = String(decoding: errorBuffer.prefix(stderr), as: UTF8.self)
                onOutput(output)
                didRead = true
            }

            if !didRead {
                let eof = libssh2_channel_eof(channel)
                if eof == 1 {
                    break
                }
                try await session.waitForSocket(deadline: deadline)
            }
        }

        let exitStatus = libssh2_channel_get_exit_status(channel)
        return exitStatus
    }

    func openShell(
        terminalType: String? = nil,
        onCreate: (() -> Void)? = nil,
        terminalSize: @Sendable () -> CGSize = { .zero },
        writeData: @Sendable () -> String? = { nil },
        onOutput: @Sendable (String) -> Void,
        shouldContinue: @Sendable () -> Bool = { true }
    ) async throws {
        guard let session else { throw RemoteShellError.disconnected }
        let channel = try await openSessionChannel(session: session)
        defer { closeChannel(channel) }

        if let terminalType {
            let rc: Int32 = try await session.retrying(timeout: configuration.timeout, operation: {
                libssh2_channel_request_pty_ex(channel,
                                               terminalType,
                                               UInt32(terminalType.utf8.count),
                                               nil,
                                               0,
                                               80,
                                               24,
                                               0,
                                               0)
            }, shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN })
            guard rc == 0 else {
                let error = session.lastError(fallback: "Failed to request PTY")
                lastError = error.errorDescription
                throw error
            }
        }

        let shellRc: Int32 = try await session.retrying(timeout: configuration.timeout, operation: {
            libssh2_channel_shell(channel)
        }, shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN })
        guard shellRc == 0 else {
            let error = session.lastError(fallback: "Failed to open shell")
            lastError = error.errorDescription
            throw error
        }
        onCreate?()

        var lastTerminalSize = CGSize.zero
        var buffer = [UInt8](repeating: 0, count: SSHConstants.bufferSize)

        while shouldContinue() {
            let size = terminalSize()
            if size != lastTerminalSize {
                lastTerminalSize = size
                _ = try await session.retrying(timeout: configuration.timeout, operation: {
                    libssh2_channel_request_pty_size(channel,
                                                     UInt32(size.width),
                                                     UInt32(size.height))
                }, shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN })
            }

            if let data = writeData(), !data.isEmpty {
                try await writeChannel(channel: channel, data: data)
            }

            let readCount = try await readChannelBytes(session: session, channel: channel, buffer: &buffer, stderr: false, deadline: nil)
            if readCount > 0 {
                let output = String(decoding: buffer.prefix(readCount), as: UTF8.self)
                onOutput(output)
                continue
            }

            let eof = libssh2_channel_eof(channel)
            if eof == 1 {
                break
            }

            try await session.waitForSocket(deadline: nil)
        }
    }
}

private extension NSRemoteShell {
    func openSessionChannel(session: SSHSession) async throws -> OpaquePointer {
        let deadline = Date().addingTimeInterval(configuration.timeout)
        while true {
            if deadline.timeIntervalSinceNow <= 0 {
                throw RemoteShellError.timeout
            }
            if let channel = libssh2_channel_open_session(session.session) {
                return channel
            }
            let rc = libssh2_session_last_errno(session.session)
            if rc == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            throw session.lastError(fallback: "Unable to open channel")
        }
    }

    func writeChannel(channel: OpaquePointer, data: String) async throws {
        guard let session else { throw RemoteShellError.disconnected }
        let buffer = Array(data.utf8)
        try await writeChannelBytes(session: session, channel: channel, buffer: buffer, count: buffer.count)
    }
}
