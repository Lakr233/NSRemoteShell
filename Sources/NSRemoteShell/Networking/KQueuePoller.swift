import Foundation
import Dispatch

struct SocketEvents: OptionSet, Sendable {
    let rawValue: Int

    static let read = SocketEvents(rawValue: 1 << 0)
    static let write = SocketEvents(rawValue: 1 << 1)
}

enum KQueuePoller {
    static func waitAsync(socket: Int32, events: SocketEvents, timeout: TimeInterval?) async throws -> Bool {
        guard !events.isEmpty else { return false }
        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue.global(qos: .utility)
            let lock = NSLock()
            var completed = false
            var sources: [DispatchSourceProtocol] = []
            var timeoutItem: DispatchWorkItem?

            func finish(_ ready: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !completed else { return }
                completed = true
                timeoutItem?.cancel()
                sources.forEach { $0.cancel() }
                continuation.resume(returning: ready)
            }

            if let timeout, timeout <= 0 {
                finish(false)
                return
            }

            if events.contains(.read) {
                let source = DispatchSource.makeReadSource(fileDescriptor: Int(socket), queue: queue)
                source.setEventHandler { finish(true) }
                source.setCancelHandler {}
                source.resume()
                sources.append(source)
            }

            if events.contains(.write) {
                let source = DispatchSource.makeWriteSource(fileDescriptor: Int(socket), queue: queue)
                source.setEventHandler { finish(true) }
                source.setCancelHandler {}
                source.resume()
                sources.append(source)
            }

            if let timeout, timeout > 0 {
                let item = DispatchWorkItem { finish(false) }
                timeoutItem = item
                queue.asyncAfter(deadline: .now() + timeout, execute: item)
            }
        }
    }
}
