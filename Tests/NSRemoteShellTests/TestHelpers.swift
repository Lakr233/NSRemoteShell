import CoreGraphics
import Darwin
import Dispatch
import Foundation
@testable import NSRemoteShell

// MARK: - Test Configuration

struct SSHTestConfig {
    let host: String
    let port: Int
    let timeout: TimeInterval
    let username: String
    let password: String?
    let publicKey: String?
    let privateKey: String?
    let keyPassphrase: String?
}

enum TestEnv {
    static func value(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    static func firstValue(_ keys: [String]) -> String? {
        for key in keys {
            if let value = value(key), !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

func requireConfig() -> SSHTestConfig? {
    guard let host = TestEnv.firstValue(["NSREMOTE_SSH_HOST", "SSH_TEST_HOST"]),
          let username = TestEnv.firstValue(["NSREMOTE_SSH_USERNAME", "SSH_TEST_USER"])
    else {
        print("Skipping SSH tests: set NSREMOTE_SSH_HOST/NSREMOTE_SSH_USERNAME (or SSH_TEST_HOST/SSH_TEST_USER).")
        return nil
    }

    let port = Int(TestEnv.firstValue(["NSREMOTE_SSH_PORT", "SSH_TEST_PORT"]) ?? "22") ?? 22
    let timeout = Double(TestEnv.firstValue(["NSREMOTE_SSH_TIMEOUT", "SSH_TEST_TIMEOUT"]) ?? "") ?? 8
    let password = TestEnv.firstValue(["NSREMOTE_SSH_PASSWORD", "SSH_TEST_PASSWORD"])
    let privateKey = TestEnv.firstValue(["NSREMOTE_SSH_PRIVATE_KEY", "SSH_TEST_PRIVATE_KEY"])
    if password == nil, privateKey == nil {
        print("Skipping SSH tests: set NSREMOTE_SSH_PASSWORD or NSREMOTE_SSH_PRIVATE_KEY (or SSH_TEST_PASSWORD/SSH_TEST_PRIVATE_KEY).")
        return nil
    }

    return SSHTestConfig(
        host: host,
        port: port,
        timeout: timeout,
        username: username,
        password: password,
        publicKey: TestEnv.firstValue(["NSREMOTE_SSH_PUBLIC_KEY", "SSH_TEST_PUBLIC_KEY"]),
        privateKey: privateKey,
        keyPassphrase: TestEnv.firstValue(["NSREMOTE_SSH_KEY_PASSPHRASE", "SSH_TEST_KEY_PASSPHRASE"])
    )
}

func connectShell() async throws -> NSRemoteShell? {
    guard let config = requireConfig() else { return nil }
    var lastError: Error?
    for attempt in 0 ..< 3 {
        let shell = NSRemoteShell(configuration: .init(host: config.host, port: config.port, timeout: config.timeout))
        do {
            try await shell.connect()
            if let privateKey = config.privateKey {
                try await shell.authenticate(
                    username: config.username,
                    publicKey: config.publicKey,
                    privateKey: privateKey,
                    password: config.keyPassphrase
                )
            } else if let password = config.password {
                try await shell.authenticate(username: config.username, password: password)
            }
            return shell
        } catch {
            lastError = error
            await shell.disconnect()
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
    throw lastError ?? RemoteShellError.disconnected
}

func withConnectedShell<T>(_ operation: @Sendable (NSRemoteShell) async throws -> T) async throws -> T? {
    guard let shell = try await connectShell() else { return nil }
    do {
        let result = try await operation(shell)
        await shell.disconnect()
        return result
    } catch {
        await shell.disconnect()
        throw error
    }
}

func withSFTP<T>(shell: NSRemoteShell, _ operation: @Sendable () async throws -> T) async throws -> T {
    try await shell.connectSFTP()
    do {
        let result = try await operation()
        await shell.disconnectSFTP()
        return result
    } catch {
        await shell.disconnectSFTP()
        throw error
    }
}

func withPortForwardHandle<T>(_ handle: PortForwardHandle, _ operation: @Sendable () async throws -> T) async rethrows -> T {
    do {
        let result = try await operation()
        await handle.cancel()
        return result
    } catch {
        await handle.cancel()
        throw error
    }
}

func executeCapture(
    _ shell: NSRemoteShell,
    _ command: String,
    timeout: TimeInterval? = nil
) async throws -> (Int32, String) {
    let output = OutputBuffer()
    let status = try await shell.execute(command, timeout: timeout, onOutput: { output.append($0) })
    return (status, output.value())
}

// MARK: - Serial Test Gate

final class SerialTestGate: @unchecked Sendable {
    static let shared = SerialTestGate()
    private let lock = NSLock()
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isLocked {
                waiters.append(continuation)
                lock.unlock()
            } else {
                isLocked = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            isLocked = false
            lock.unlock()
            return
        }
        let continuation = waiters.removeFirst()
        lock.unlock()
        continuation.resume()
    }
}

func withSerialTestLock<T>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
    await SerialTestGate.shared.acquire()
    defer { SerialTestGate.shared.release() }
    return try await operation()
}

// MARK: - Thread-Safe Helpers

final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var output = ""

    func append(_ text: String) {
        lock.lock()
        output += text
        lock.unlock()
    }

    func value() -> String {
        lock.lock()
        defer { lock.unlock() }
        return output
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return output.utf8.count
    }
}

final class ByteBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [UInt8] = []

    func append(_ bytes: [UInt8]) {
        lock.lock()
        data.append(contentsOf: bytes)
        lock.unlock()
    }

    func value() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return data.count
    }
}

final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool

    init(_ value: Bool) {
        flag = value
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set(_ value: Bool) {
        lock.lock()
        flag = value
        lock.unlock()
    }
}

final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(_ value: Int) {
        self.value = value
    }

    func get() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Int) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

final class TerminalSizeProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var size: CGSize

    init(_ size: CGSize) {
        self.size = size
    }

    func get() -> CGSize {
        lock.lock()
        defer { lock.unlock() }
        return size
    }

    func set(_ newSize: CGSize) {
        lock.lock()
        size = newSize
        lock.unlock()
    }
}

final class InputQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String]

    init(_ items: [String]) {
        self.items = items
    }

    func pop() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }
}

// MARK: - Echo Server

func errnoMessage(_ code: Int32) -> String {
    String(cString: strerror(code))
}

final class LocalEchoServer: @unchecked Sendable {
    let socket: Int32
    let port: Int
    private let lock = NSLock()
    private var stopped = false
    private let multiClient: Bool

    init(multiClient: Bool = false) throws {
        self.multiClient = multiClient
        socket = try SocketUtilities.createListener(on: 0)
        port = try SocketUtilities.boundPort(for: socket)
        print("LocalEchoServer: listening on 127.0.0.1:\(port) multiClient=\(multiClient)")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.run()
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        SocketUtilities.closeSocket(socket)
    }

    private func run() {
        defer { SocketUtilities.closeSocket(socket) }
        var transientFailures = 0
        while !isStopped() {
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(socket, $0, &length)
                }
            }
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(10000)
                    continue
                }
                if errno == EINTR || errno == EINVAL {
                    transientFailures += 1
                    if transientFailures < 5 {
                        usleep(10000)
                        continue
                    }
                }
                let code = errno
                print("LocalEchoServer: accept failed errno=\(code) message=\(errnoMessage(code))")
                break
            }
            transientFailures = 0
            print("LocalEchoServer: accepted connection")
            _ = try? SocketUtilities.setNonBlocking(client)
            if multiClient {
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.handleClient(client)
                }
            } else {
                handleClient(client)
                break
            }
        }
    }

    private func handleClient(_ client: Int32) {
        defer { SocketUtilities.closeSocket(client) }
        var buffer = [UInt8](repeating: 0, count: 65536)

        while !isStopped() {
            let readCount = buffer.withUnsafeMutableBytes { raw in
                recv(client, raw.baseAddress, raw.count, 0)
            }
            if readCount > 0 {
                print("LocalEchoServer: received \(readCount) bytes")
                var sent = 0
                while sent < readCount {
                    let sendCount = buffer.withUnsafeBytes { raw in
                        let ptr = raw.bindMemory(to: Int8.self).baseAddress
                        return send(client, ptr?.advanced(by: sent), readCount - sent, 0)
                    }
                    if sendCount > 0 {
                        sent += sendCount
                        continue
                    }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        usleep(1000)
                        continue
                    }
                    let code = errno
                    print("LocalEchoServer: send failed errno=\(code) message=\(errnoMessage(code))")
                    return
                }
                continue
            }
            if readCount == 0 {
                print("LocalEchoServer: client closed connection")
                return
            }
            if readCount < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(1000)
                continue
            }
            let code = errno
            print("LocalEchoServer: recv failed errno=\(code) message=\(errnoMessage(code))")
            return
        }
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

// MARK: - Echo Client Helpers

func runLargeEchoClient(
    port: Int,
    sizeBytes: Int,
    timeout: TimeInterval,
    shouldContinue: @Sendable () -> Bool = { true }
) async throws -> (sent: Int, received: Int, matched: Bool, cancelled: Bool) {
    print("runLargeEchoClient: connecting to 127.0.0.1:\(port) sizeBytes=\(sizeBytes) timeout=\(timeout)s")
    let socket: Int32
    do {
        socket = try SocketUtilities.createConnectedSocket(host: "127.0.0.1", port: port, nonBlocking: true)
    } catch {
        print("runLargeEchoClient: connect failed port=\(port) error=\(error)")
        throw error
    }
    defer { SocketUtilities.closeSocket(socket) }

    var payload = [UInt8](repeating: 0, count: sizeBytes)
    for i in 0 ..< sizeBytes {
        payload[i] = UInt8(i % 256)
    }

    var sent = 0
    var received: [UInt8] = []
    received.reserveCapacity(sizeBytes)
    var recvBuffer = [UInt8](repeating: 0, count: 65536)
    let deadline = Date().addingTimeInterval(timeout)
    var cancelled = false

    while sent < sizeBytes || received.count < sent, !cancelled {
        if deadline.timeIntervalSinceNow <= 0 {
            print("runLargeEchoClient: timeout sent=\(sent) received=\(received.count)")
            break
        }
        if !shouldContinue() {
            print("runLargeEchoClient: cancelled at sent=\(sent) received=\(received.count)")
            cancelled = true
            break
        }

        if sent < sizeBytes {
            let toSend = min(65536, sizeBytes - sent)
            let sendCount = payload.withUnsafeBytes { raw in
                let ptr = raw.bindMemory(to: Int8.self).baseAddress
                return send(socket, ptr?.advanced(by: sent), toSend, 0)
            }
            if sendCount > 0 {
                sent += sendCount
                if sent % (1024 * 1024) < sendCount {
                    print("runLargeEchoClient: sent \(sent / (1024 * 1024))MB")
                }
            } else if sendCount < 0 {
                let code = errno
                if code != EAGAIN, code != EWOULDBLOCK {
                    print("runLargeEchoClient: send failed errno=\(code)")
                    break
                }
            }
        }

        let recvCount = recvBuffer.withUnsafeMutableBytes { raw in
            recv(socket, raw.baseAddress, raw.count, 0)
        }
        if recvCount > 0 {
            received.append(contentsOf: recvBuffer[0 ..< recvCount])
            if received.count % (1024 * 1024) < recvCount {
                print("runLargeEchoClient: received \(received.count / (1024 * 1024))MB")
            }
        } else if recvCount < 0 {
            let code = errno
            if code != EAGAIN, code != EWOULDBLOCK {
                print("runLargeEchoClient: recv failed errno=\(code)")
                break
            }
        }

        if sent >= sizeBytes, received.count < sent {
            _ = try? await KQueuePoller.waitAsync(socket: socket, events: [.read], timeout: 0.1)
        }
    }

    let matched = received.count >= sent && received.prefix(sent).elementsEqual(payload.prefix(sent))
    print("runLargeEchoClient: done sent=\(sent) received=\(received.count) matched=\(matched) cancelled=\(cancelled)")
    return (sent, received.count, matched, cancelled)
}

func runLocalEchoClient(port: Int, payload: String, timeout: TimeInterval = 10) async throws -> Bool {
    print("runLocalEchoClient: connecting to 127.0.0.1:\(port) payloadBytes=\(payload.utf8.count) timeout=\(timeout)s")
    let socket: Int32
    do {
        socket = try SocketUtilities.createConnectedSocket(host: "127.0.0.1", port: port, nonBlocking: true)
    } catch {
        print("runLocalEchoClient: connect failed port=\(port) error=\(error)")
        throw error
    }
    defer { SocketUtilities.closeSocket(socket) }

    let expected = Array(payload.utf8)
    var sent = 0
    var sendWouldBlockCount = 0
    let deadline = Date().addingTimeInterval(timeout)

    while sent < expected.count {
        if deadline.timeIntervalSinceNow <= 0 {
            print("runLocalEchoClient: send timeout after \(sent)/\(expected.count) bytes")
            return false
        }
        let sendCount = expected.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Int8.self).baseAddress
            return send(socket, ptr?.advanced(by: sent), expected.count - sent, 0)
        }
        if sendCount > 0 {
            sent += sendCount
            continue
        }
        if sendCount == 0 {
            print("runLocalEchoClient: send returned 0 after \(sent)/\(expected.count) bytes")
            return false
        }
        let sendError = errno
        if sendError == EAGAIN || sendError == EWOULDBLOCK {
            sendWouldBlockCount += 1
            if sendWouldBlockCount <= 3 {
                print("runLocalEchoClient: send would block, waiting (count=\(sendWouldBlockCount))")
            }
            _ = try await KQueuePoller.waitAsync(socket: socket, events: [.write], timeout: 1)
            continue
        }
        print("runLocalEchoClient: send failed errno=\(sendError) message=\(errnoMessage(sendError))")
        return false
    }
    print("runLocalEchoClient: sent \(sent) bytes")

    var received: [UInt8] = []
    received.reserveCapacity(expected.count)
    var buffer = [UInt8](repeating: 0, count: 4096)
    var readWouldBlockCount = 0

    while received.count < expected.count {
        if deadline.timeIntervalSinceNow <= 0 {
            print("runLocalEchoClient: recv timeout after \(received.count)/\(expected.count) bytes")
            return false
        }
        let readCount = buffer.withUnsafeMutableBytes { raw in
            recv(socket, raw.baseAddress, raw.count, 0)
        }
        if readCount > 0 {
            print("runLocalEchoClient: received \(readCount) bytes")
            received.append(contentsOf: buffer[0 ..< readCount])
            continue
        }
        if readCount == 0 {
            print("runLocalEchoClient: recv returned 0 after \(received.count) bytes")
            break
        }
        let readError = errno
        if readError == EAGAIN || readError == EWOULDBLOCK {
            readWouldBlockCount += 1
            if readWouldBlockCount <= 3 {
                print("runLocalEchoClient: recv would block, waiting (count=\(readWouldBlockCount))")
            }
            _ = try await KQueuePoller.waitAsync(socket: socket, events: [.read], timeout: 1)
            continue
        }
        print("runLocalEchoClient: recv failed errno=\(readError) message=\(errnoMessage(readError))")
        return false
    }

    let didMatch = received.prefix(expected.count).elementsEqual(expected)
    if !didMatch {
        print("runLocalEchoClient: payload mismatch expected=\(expected.count) received=\(received.count)")
    }
    return didMatch
}
