import CSSH2
import Foundation

extension NSRemoteShell {
    func readChannelBytes(
        session: SSHSession,
        channel: OpaquePointer,
        buffer: inout [UInt8],
        stderr: Bool,
        deadline: Date?
    ) async throws -> Int {
        while true {
            let count: Int = session.withLock {
                buffer.withUnsafeMutableBytes { raw in
                    let ptr = raw.bindMemory(to: Int8.self).baseAddress
                    if stderr {
                        return Int(libssh2_channel_read_ex(channel, Int32(SSH_EXTENDED_DATA_STDERR), ptr, raw.count))
                    }
                    return Int(libssh2_channel_read_ex(channel, 0, ptr, raw.count))
                }
            }
            if count == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            if count < 0 {
                throw session.lastError(fallback: "Channel read failed")
            }
            return count
        }
    }

    func readChannelBytesNonBlocking(
        session: SSHSession,
        channel: OpaquePointer,
        buffer: inout [UInt8],
        stderr: Bool
    ) throws -> Int? {
        let count: Int = session.withLock {
            buffer.withUnsafeMutableBytes { raw in
                let ptr = raw.bindMemory(to: Int8.self).baseAddress
                if stderr {
                    return Int(libssh2_channel_read_ex(channel, Int32(SSH_EXTENDED_DATA_STDERR), ptr, raw.count))
                }
                return Int(libssh2_channel_read_ex(channel, 0, ptr, raw.count))
            }
        }
        if count == LIBSSH2_ERROR_EAGAIN {
            return nil
        }
        if count < 0 {
            throw session.lastError(fallback: "Channel read failed")
        }
        return count
    }

    func writeChannelBytes(
        session: SSHSession,
        channel: OpaquePointer,
        buffer: [UInt8],
        count: Int
    ) async throws {
        var sent = 0
        while sent < count {
            let written = session.withLock {
                buffer.withUnsafeBytes { raw in
                    let ptr = raw.bindMemory(to: Int8.self).baseAddress
                    return Int(libssh2_channel_write_ex(channel, 0, ptr?.advanced(by: sent), count - sent))
                }
            }
            if written == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: nil)
                continue
            }
            if written < 0 {
                throw session.lastError(fallback: "Channel write failed")
            }
            sent += written
        }
    }

    func closeChannel(session: SSHSession, _ channel: OpaquePointer) {
        while session.withLock({ libssh2_channel_send_eof(channel) }) == LIBSSH2_ERROR_EAGAIN {}
        while session.withLock({ libssh2_channel_close(channel) }) == LIBSSH2_ERROR_EAGAIN {}
        while session.withLock({ libssh2_channel_wait_closed(channel) }) == LIBSSH2_ERROR_EAGAIN {}
        while session.withLock({ libssh2_channel_free(channel) }) == LIBSSH2_ERROR_EAGAIN {}
    }
}
