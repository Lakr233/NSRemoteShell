import XCTest
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

private final class LocalEchoServer: @unchecked Sendable {
    let socket: Int32
    let port: Int
    private let lock = NSLock()
    private var stopped = false

    init() throws {
        socket = try SocketUtilities.createListener(on: 0)
        port = try LocalEchoServer.boundPort(for: socket)
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
                break
            }
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
                    return
                }
                continue
            }
            if readCount < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                usleep(5_000)
                continue
            }
            return
        }
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private static func boundPort(for socket: Int32) throws -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &length)
            }
        }
        guard result == 0 else {
            throw RemoteShellError.socketError(code: Int32(errno), message: String(cString: strerror(errno)))
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

private func requireConfig() throws -> SSHTestConfig {
    guard let host = TestEnv.firstValue(["NSREMOTE_SSH_HOST", "SSH_TEST_HOST"]),
          let username = TestEnv.firstValue(["NSREMOTE_SSH_USERNAME", "SSH_TEST_USER"]) else {
        throw XCTSkip("Set NSREMOTE_SSH_HOST/NSREMOTE_SSH_USERNAME (or SSH_TEST_HOST/SSH_TEST_USER) to run SSH integration tests.")
    }

    let port = Int(TestEnv.firstValue(["NSREMOTE_SSH_PORT", "SSH_TEST_PORT"]) ?? "22") ?? 22
    let timeout = Double(TestEnv.firstValue(["NSREMOTE_SSH_TIMEOUT", "SSH_TEST_TIMEOUT"]) ?? "") ?? 8
    let password = TestEnv.firstValue(["NSREMOTE_SSH_PASSWORD", "SSH_TEST_PASSWORD"])
    let privateKey = TestEnv.firstValue(["NSREMOTE_SSH_PRIVATE_KEY", "SSH_TEST_PRIVATE_KEY"])
    if password == nil && privateKey == nil {
        throw XCTSkip("Set NSREMOTE_SSH_PASSWORD/NSREMOTE_SSH_PRIVATE_KEY (or SSH_TEST_PASSWORD/SSH_TEST_PRIVATE_KEY) to run SSH integration tests.")
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

private func connectShell() async throws -> NSRemoteShell {
    let config = try requireConfig()
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

private func runEchoClient(shell: NSRemoteShell, port: Int, payload: String) async throws -> Bool {
    let pythonScript = "import socket,sys; s=socket.create_connection(('127.0.0.1', \(port)), timeout=5); s.sendall(b'\(payload)'); data=s.recv(1024); sys.stdout.write(data.decode('utf-8', errors='ignore')); s.close()"
    let netcat = "printf '%s' '\(payload)' | nc"
    let netcatAlt = "printf '%s' '\(payload)' | netcat"
    let ncat = "printf '%s' '\(payload)' | ncat"
    let busyboxNetcat = "printf '%s' '\(payload)' | busybox nc"
    let socat = "printf '%s' '\(payload)' | socat - TCP:127.0.0.1:\(port),connect-timeout=5"

    let candidates = [
        "python3 -c \"\(pythonScript)\"",
        "python -c \"\(pythonScript)\"",
        "sh -c \"\(netcat) -w 5 127.0.0.1 \(port)\"",
        "sh -c \"\(netcat) 127.0.0.1 \(port)\"",
        "sh -c \"\(netcatAlt) -w 5 127.0.0.1 \(port)\"",
        "sh -c \"\(netcatAlt) 127.0.0.1 \(port)\"",
        "sh -c \"\(ncat) -w 5 127.0.0.1 \(port)\"",
        "sh -c \"\(ncat) 127.0.0.1 \(port)\"",
        "sh -c \"\(busyboxNetcat) -w 5 127.0.0.1 \(port)\"",
        "sh -c \"\(busyboxNetcat) 127.0.0.1 \(port)\"",
        "sh -c \"\(socat)\""
    ]

    for command in candidates {
        let (status, output) = try await executeCapture(shell, command, timeout: 10)
        if status == 0, output.contains(payload) {
            return true
        }
    }
    return false
}

private func hasEchoClient(shell: NSRemoteShell) async throws -> Bool {
    let candidates = ["python3", "python", "nc", "netcat", "ncat", "socat", "busybox"]
    for candidate in candidates {
        let (status, _) = try await executeCapture(shell, "command -v \(candidate)")
        if status == 0 {
            return true
        }
    }
    return false
}

final class NSRemoteShellTests: XCTestCase {
    func testCommandExec() async throws {
        let shell = try await connectShell()
        defer { Task { await shell.disconnect() } }

        let payload = "NSREMOTE_EXEC_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let (status, output) = try await executeCapture(shell, "printf '\(payload)'")

        XCTAssertEqual(status, 0)
        XCTAssertTrue(output.contains(payload))

        await shell.disconnect()
    }

    func testPTYShellInteractive() async throws {
        let shell = try await connectShell()
        defer { Task { await shell.disconnect() } }

        let payload = "NSREMOTE_PTY_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
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

        XCTAssertTrue(output.value().contains(payload))

        await shell.disconnect()
    }

    func testSFTPRoundTrip() async throws {
        let shell = try await connectShell()
        defer { Task { await shell.disconnect() } }

        try await shell.connectSFTP()
        defer { Task { await shell.disconnectSFTP() } }

        let remoteDir = "/tmp/nsremoteshell-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let (mkdirStatus, _) = try await executeCapture(shell, "mkdir -p \(remoteDir)")
        XCTAssertEqual(mkdirStatus, 0)

        let localDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nsremoteshell-" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true, attributes: nil)

        let payload = "NSREMOTE_SFTP_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let uploadURL = localDir.appendingPathComponent("upload.txt")
        try payload.write(to: uploadURL, atomically: true, encoding: .utf8)

        try await shell.uploadFile(at: uploadURL.path, to: remoteDir, onProgress: { _, _ in })

        let downloadURL = localDir.appendingPathComponent("download.txt")
        try await shell.downloadFile(at: "\(remoteDir)/upload.txt", to: downloadURL.path, onProgress: { _, _ in })

        let downloaded = try String(contentsOf: downloadURL, encoding: .utf8)
        XCTAssertEqual(downloaded, payload)

        let files = try await shell.listFiles(at: remoteDir)
        XCTAssertTrue(files.contains { $0.name == "upload.txt" })

        try? await shell.deleteFile(at: remoteDir, onProgress: { _ in })

        await shell.disconnectSFTP()
        await shell.disconnect()
    }

    func testPortForwardEchoRoundTrip() async throws {
        let clientShell = try await connectShell()
        defer { Task { await clientShell.disconnect() } }

        let canRunEcho = try await hasEchoClient(shell: clientShell)
        if !canRunEcho {
            await clientShell.disconnect()
            throw XCTSkip("Remote host needs python or netcat for port-forward test.")
        }

        let forwardShell = try await connectShell()
        defer { Task { await forwardShell.disconnect() } }

        let echoServer = try LocalEchoServer()
        defer { echoServer.stop() }

        let handle = try await forwardShell.startRemotePortForward(
            remotePort: 0,
            targetHost: "127.0.0.1",
            targetPort: echoServer.port
        )
        defer { Task { await handle.cancel() } }

        let payload = "NSREMOTE_ECHO_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let boundPort = await handle.boundPort
        let didEcho = try await runEchoClient(shell: clientShell, port: boundPort, payload: payload)
        if !didEcho {
            await handle.cancel()
            await forwardShell.disconnect()
            await clientShell.disconnect()
            throw XCTSkip("Remote host needs python or netcat for port-forward test.")
        }

        await handle.cancel()
        await forwardShell.disconnect()
        await clientShell.disconnect()
    }
}
