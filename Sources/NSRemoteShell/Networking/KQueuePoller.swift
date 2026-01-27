import Foundation
import Darwin

struct SocketEvents: OptionSet, Sendable {
    let rawValue: Int

    static let read = SocketEvents(rawValue: 1 << 0)
    static let write = SocketEvents(rawValue: 1 << 1)
}

enum KQueuePoller {
    private typealias KEvent = kevent

    static func wait(socket: Int32, events: SocketEvents, timeout: TimeInterval?) throws -> Bool {
        let queue = kqueue()
        guard queue >= 0 else {
            throw RemoteShellError.socketError(code: errno, message: String(cString: strerror(errno)))
        }
        defer { close(queue) }

        var changes = [KEvent]()
        if events.contains(.read) {
            var change = KEvent()
            change.ident = UInt(socket)
            change.filter = Int16(EVFILT_READ)
            change.flags = UInt16(EV_ADD | EV_ENABLE)
            change.fflags = 0
            change.data = 0
            change.udata = nil
            changes.append(change)
        }
        if events.contains(.write) {
            var change = KEvent()
            change.ident = UInt(socket)
            change.filter = Int16(EVFILT_WRITE)
            change.flags = UInt16(EV_ADD | EV_ENABLE)
            change.fflags = 0
            change.data = 0
            change.udata = nil
            changes.append(change)
        }

        var outputEvent = KEvent()
        var timeoutSpec = timespec()
        let result: Int32 = changes.withUnsafeBufferPointer { buffer in
            let timeoutPtr: UnsafePointer<timespec>? = {
                guard let timeout else { return nil }
                let clamped = max(timeout, 0)
                timeoutSpec.tv_sec = Int(clamped)
                timeoutSpec.tv_nsec = Int((clamped - Double(timeoutSpec.tv_sec)) * 1_000_000_000)
                return withUnsafePointer(to: &timeoutSpec) { $0 }
            }()
            return kevent(queue, buffer.baseAddress, Int32(buffer.count), &outputEvent, 1, timeoutPtr)
        }
        if result == 0 {
            return false
        }
        if result < 0 {
            throw RemoteShellError.socketError(code: errno, message: String(cString: strerror(errno)))
        }
        return true
    }

    static func waitAsync(socket: Int32, events: SocketEvents, timeout: TimeInterval?) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let ready = try wait(socket: socket, events: events, timeout: timeout)
                    continuation.resume(returning: ready)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
