import CoreGraphics
import Foundation
@testable import NSRemoteShell
import Testing

@Suite
struct NSRemoteShellTests {
    @Test
    func commandExec() async throws {
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
    func pTYShellInteractive() async throws {
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
    func sFTPRoundTrip() async throws {
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
    func portForwardEchoRoundTrip() async throws {
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
