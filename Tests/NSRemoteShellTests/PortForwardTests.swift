import Foundation
@testable import NSRemoteShell
import Testing

@Suite
struct PortForwardTests {
    @Test
    func portForward16MBEcho() async throws {
        print("testPortForward16MBEcho: start")
        let echoServer = try LocalEchoServer(multiClient: true)
        defer { echoServer.stop() }
        print("testPortForward16MBEcho: echo server port \(echoServer.port)")

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
        print("testPortForward16MBEcho: remote forward bound port \(remotePort)")
        let localHandle = try await clientShell.startLocalPortForward(
            localPort: 0,
            targetHost: "127.0.0.1",
            targetPort: remotePort
        )
        defer { Task { await localHandle.cancel() } }

        let localPort = await localHandle.boundPort
        print("testPortForward16MBEcho: local forward bound port \(localPort)")

        let sizeMB = 16
        let sizeBytes = sizeMB * 1024 * 1024
        let result = try await runLargeEchoClient(port: localPort, sizeBytes: sizeBytes, timeout: 120)

        print("testPortForward16MBEcho: sent=\(result.sent) received=\(result.received) matched=\(result.matched)")
        #expect(result.sent == sizeBytes)
        #expect(result.received == sizeBytes)
        #expect(result.matched)
    }

    @Test
    func portForward32MBEchoWithCancel() async throws {
        print("testPortForward32MBEchoWithCancel: start")
        let echoServer = try LocalEchoServer(multiClient: true)
        defer { echoServer.stop() }
        print("testPortForward32MBEchoWithCancel: echo server port \(echoServer.port)")

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
        print("testPortForward32MBEchoWithCancel: remote forward bound port \(remotePort)")
        let localHandle = try await clientShell.startLocalPortForward(
            localPort: 0,
            targetHost: "127.0.0.1",
            targetPort: remotePort
        )
        defer { Task { await localHandle.cancel() } }

        let localPort = await localHandle.boundPort
        print("testPortForward32MBEchoWithCancel: local forward bound port \(localPort)")

        let sizeMB = 32
        let sizeBytes = sizeMB * 1024 * 1024
        let cancelled = AtomicBool(false)
        let startTime = Date()

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            print("testPortForward32MBEchoWithCancel: setting cancel flag")
            cancelled.set(true)
        }

        let result = try await runLargeEchoClient(
            port: localPort,
            sizeBytes: sizeBytes,
            timeout: 120,
            shouldContinue: { !cancelled.get() }
        )

        let elapsed = Date().timeIntervalSince(startTime)
        print("testPortForward32MBEchoWithCancel: elapsed=\(elapsed)s sent=\(result.sent) received=\(result.received) cancelled=\(result.cancelled)")

        #expect(result.cancelled)
        #expect(result.sent < sizeBytes)
        #expect(elapsed < 30)
    }

    @Test
    func portForwardCancel() async throws {
        print("testPortForwardCancel: start")
        let echoServer = try LocalEchoServer(multiClient: true)
        defer { echoServer.stop() }

        guard let shell = try await connectShell() else { return }
        defer { Task { await shell.disconnect() } }

        let handle = try await shell.startLocalPortForward(
            localPort: 0,
            targetHost: "127.0.0.1",
            targetPort: echoServer.port
        )

        let boundPort = await handle.boundPort
        print("testPortForwardCancel: local forward bound port \(boundPort)")

        let socketBefore = try? SocketUtilities.createConnectedSocket(host: "127.0.0.1", port: boundPort, nonBlocking: false)
        let canConnectBefore = socketBefore != nil
        if let sock = socketBefore {
            SocketUtilities.closeSocket(sock)
        }
        print("testPortForwardCancel: connection before cancel succeeded=\(canConnectBefore)")
        #expect(canConnectBefore)

        await handle.cancel()
        print("testPortForwardCancel: handle cancelled")

        try? await Task.sleep(nanoseconds: 500_000_000)

        var canConnectAfter = false
        do {
            let sock = try SocketUtilities.createConnectedSocket(host: "127.0.0.1", port: boundPort, nonBlocking: false)
            SocketUtilities.closeSocket(sock)
            canConnectAfter = true
            print("testPortForwardCancel: connection after cancel unexpectedly succeeded")
        } catch {
            print("testPortForwardCancel: connection after cancel failed (expected): \(error)")
        }
        #expect(!canConnectAfter)
    }
}
