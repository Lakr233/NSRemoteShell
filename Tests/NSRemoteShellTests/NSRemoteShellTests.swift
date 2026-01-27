import Testing
import Foundation
import CoreGraphics
import Dispatch
import Darwin
@testable import NSRemoteShell

private struct SSHTestConfig {
    let host: String
    let port: Int
    let timeout: TimeInterval
    let username: String
    let password: String?
    let publicKey: String?
    let privateKey: String?
    let keyPassphrase: String?
}

private enum TestEnv {
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

private final class OutputBuffer: @unchecked Sendable {
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
}

private final class InputQueue: @unchecked Sendable {
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

private func errnoMessage(_ code: Int32) -> String {
    String(cString: strerror(code))
}

private final class LocalEchoServer: @unchecked Sendable {
    let socket: Int32
    let port: Int
    private let lock = NSLock()
    private var stopped = false

    init() throws {
        socket = try SocketUtilities.createListener(on: 0)
        port = try SocketUtilities.boundPort(for: socket)
        print("LocalEchoServer: listening on 127.0.0.1:\(port)")
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
                    usleep(10_000)
                    continue
                }
                let code = errno
                print("LocalEchoServer: accept failed errno=\(code) message=\(errnoMessage(code))")
                break
            }
            print("LocalEchoServer: accepted connection")
            _ = try? SocketUtilities.setNonBlocking(client)
            handleClient(client)
            break
        }
    }

    private func handleClient(_ client: Int32) {
        defer { SocketUtilities.closeSocket(client) }
        var buffer = [UInt8](repeating: 0, count: 4096)

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
                        usleep(5_000)
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
            if readCount < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                usleep(5_000)
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

private func requireConfig() -> SSHTestConfig? {
    guard let host = TestEnv.firstValue(["NSREMOTE_SSH_HOST", "SSH_TEST_HOST"]),
          let username = TestEnv.firstValue(["NSREMOTE_SSH_USERNAME", "SSH_TEST_USER"]) else {
        print("Skipping SSH tests: set NSREMOTE_SSH_HOST/NSREMOTE_SSH_USERNAME (or SSH_TEST_HOST/SSH_TEST_USER).")
        return nil
    }

    let port = Int(TestEnv.firstValue(["NSREMOTE_SSH_PORT", "SSH_TEST_PORT"]) ?? "22") ?? 22
    let timeout = Double(TestEnv.firstValue(["NSREMOTE_SSH_TIMEOUT", "SSH_TEST_TIMEOUT"]) ?? "") ?? 8
    let password = TestEnv.firstValue(["NSREMOTE_SSH_PASSWORD", "SSH_TEST_PASSWORD"])
    let privateKey = TestEnv.firstValue(["NSREMOTE_SSH_PRIVATE_KEY", "SSH_TEST_PRIVATE_KEY"])
    if password == nil && privateKey == nil {
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

private func connectShell() async throws -> NSRemoteShell? {
    guard let config = requireConfig() else { return nil }
    var lastError: Error?
    for attempt in 0..<3 {
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

private func executeCapture(
    _ shell: NSRemoteShell,
    _ command: String,
    timeout: TimeInterval? = nil
) async throws -> (Int32, String) {
    let output = OutputBuffer()
    let status = try await shell.execute(command, timeout: timeout, onOutput: { output.append($0) })
    return (status, output.value())
}

private func runLocalEchoClient(port: Int, payload: String, timeout: TimeInterval = 10) async throws -> Bool {
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
            received.append(contentsOf: buffer[0..<readCount])
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

@Suite
struct NSRemoteShellTests {
    @Test
    func testCommandExec() async throws {
        print("testCommandExec: start")
        guard let shell = try await connectShell() else { return }
        defer { Task { await shell.disconnect() } }

        let payload = "NSREMOTE_EXEC_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        print("testCommandExec: payload bytes \(payload.utf8.count)")
        let (status, output) = try await executeCapture(shell, "printf '\(payload)'")
        print("testCommandExec: status \(status) output bytes \(output.utf8.count)")

        #expect(status == 0)
        #expect(output.contains(payload))

        await shell.disconnect()
    }

    @Test
    func testPTYShellInteractive() async throws {
        print("testPTYShellInteractive: start")
        guard let shell = try await connectShell() else { return }
        defer { Task { await shell.disconnect() } }

        let payload = "NSREMOTE_PTY_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        print("testPTYShellInteractive: payload bytes \(payload.utf8.count)")
        let input = InputQueue(["echo \(payload)\n", "exit\n"])
        let output = OutputBuffer()
        let deadline = Date().addingTimeInterval(10)

        try await shell.openShell(
            terminalType: "xterm-256color",
            terminalSize: { CGSize(width: 80, height: 24) },
            writeData: { input.pop() },
            onOutput: { output.append($0) },
            shouldContinue: { Date() < deadline }
        )

        #expect(output.value().contains(payload))

        await shell.disconnect()
    }

    @Test
    func testSFTPRoundTrip() async throws {
        print("testSFTPRoundTrip: start")
        guard let shell = try await connectShell() else { return }
        defer { Task { await shell.disconnect() } }

        try await shell.connectSFTP()
        defer { Task { await shell.disconnectSFTP() } }

        let remoteDir = "/tmp/nsremoteshell-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        print("testSFTPRoundTrip: remote dir \(remoteDir)")
        let (mkdirStatus, _) = try await executeCapture(shell, "mkdir -p \(remoteDir)")
        #expect(mkdirStatus == 0)

        let localDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nsremoteshell-" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true, attributes: nil)
        print("testSFTPRoundTrip: local dir \(localDir.path)")

        let payload = "NSREMOTE_SFTP_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        print("testSFTPRoundTrip: payload bytes \(payload.utf8.count)")
        let uploadURL = localDir.appendingPathComponent("upload.txt")
        try payload.write(to: uploadURL, atomically: true, encoding: .utf8)
        print("testSFTPRoundTrip: upload \(uploadURL.path)")

        try await shell.uploadFile(at: uploadURL.path, to: remoteDir, onProgress: { _, _ in })

        let downloadURL = localDir.appendingPathComponent("download.txt")
        try await shell.downloadFile(at: "\(remoteDir)/upload.txt", to: downloadURL.path, onProgress: { _, _ in })
        print("testSFTPRoundTrip: download \(downloadURL.path)")

        let downloaded = try String(contentsOf: downloadURL, encoding: .utf8)
        #expect(downloaded == payload)

        let files = try await shell.listFiles(at: remoteDir)
        print("testSFTPRoundTrip: remote files \(files.count)")
        #expect(files.contains { $0.name == "upload.txt" })

        try? await shell.deleteFile(at: remoteDir, onProgress: { _ in })

        await shell.disconnectSFTP()
        await shell.disconnect()
    }

    @Test
    func testPortForwardEchoRoundTrip() async throws {
        let echoServer = try LocalEchoServer()
        defer { echoServer.stop() }
        print("testPortForwardEchoRoundTrip: echo server port \(echoServer.port)")

        guard let forwardShell = try await connectShell() else { return }
        defer { Task { await forwardShell.disconnect() } }

        let remoteHandle = try await forwardShell.startRemotePortForward(
            remotePort: 0,
            targetHost: "127.0.0.1",
            targetPort: echoServer.port
        )
        defer { Task { await remoteHandle.cancel() } }

        guard let clientShell = try await connectShell() else { return }
        defer { Task { await clientShell.disconnect() } }

        let remotePort = await remoteHandle.boundPort
        print("testPortForwardEchoRoundTrip: remote forward bound port \(remotePort)")
        let localHandle = try await clientShell.startLocalPortForward(
            localPort: 0,
            targetHost: "127.0.0.1",
            targetPort: remotePort
        )
        defer { Task { await localHandle.cancel() } }

        let payload = "NSREMOTE_ECHO_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let localPort = await localHandle.boundPort
        print("testPortForwardEchoRoundTrip: local forward bound port \(localPort)")
        print("testPortForwardEchoRoundTrip: sending payload bytes \(payload.utf8.count)")
        let didEcho = try await runLocalEchoClient(port: localPort, payload: payload)
        #expect(didEcho)
    }
}
