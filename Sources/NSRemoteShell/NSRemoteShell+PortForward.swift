import Foundation
import CSSH2

public extension NSRemoteShell {
    func startLocalPortForward(
        localPort: Int,
        targetHost: String,
        targetPort: Int,
        shouldContinue: @Sendable () -> Bool = { true }
    ) async throws -> PortForwardHandle {
        guard let session else { throw RemoteShellError.disconnected }
        let listenSocket = try SocketUtilities.createListener(on: localPort)
        let state = ForwardState()
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runLocalForward(
                session: session,
                listenSocket: listenSocket,
                localPort: localPort,
                targetHost: targetHost,
                targetPort: targetPort,
                state: state,
                shouldContinue: shouldContinue
            )
        }
        forwardTasks[id] = task
        return PortForwardHandle(state: state, boundPort: localPort)
    }

    func startRemotePortForward(
        remotePort: Int,
        targetHost: String,
        targetPort: Int,
        shouldContinue: @Sendable () -> Bool = { true }
    ) async throws -> PortForwardHandle {
        guard let session else { throw RemoteShellError.disconnected }
        let state = ForwardState()
        let (listener, boundPort) = try await openRemoteListener(session: session, remotePort: remotePort)
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRemoteForward(
                session: session,
                listener: listener,
                targetHost: targetHost,
                targetPort: targetPort,
                state: state,
                shouldContinue: shouldContinue
            )
        }
        forwardTasks[id] = task
        return PortForwardHandle(state: state, boundPort: boundPort)
    }
}

extension NSRemoteShell {
    func shutdownForwards() async {
        for (_, task) in forwardTasks {
            task.cancel()
        }
        forwardTasks.removeAll()
    }
}

private extension NSRemoteShell {
    func runLocalForward(
        session: SSHSession,
        listenSocket: Int32,
        localPort: Int,
        targetHost: String,
        targetPort: Int,
        state: ForwardState,
        shouldContinue: @Sendable () -> Bool
    ) async {
        defer { SocketUtilities.closeSocket(listenSocket) }
        while await !state.isCancelled(), shouldContinue(), isConnected {
            let ready = (try? await KQueuePoller.waitAsync(socket: listenSocket, events: [.read], timeout: 1)) ?? false
            if !ready {
                continue
            }
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenSocket, $0, &length)
                }
            }
            if client < 0 {
                continue
            }
            try? SocketUtilities.setNonBlocking(client)

            do {
                let channel = try await openDirectChannel(
                    session: session,
                    targetHost: targetHost,
                    targetPort: targetPort,
                    originHost: "127.0.0.1",
                    originPort: localPort
                )
                Task { [weak self] in
                    await self?.bridge(
                        session: session,
                        channel: channel,
                        socket: client,
                        state: state,
                        shouldContinue: shouldContinue
                    )
                }
            } catch {
                SocketUtilities.closeSocket(client)
            }
        }
    }

    func runRemoteForward(
        session: SSHSession,
        listener: OpaquePointer,
        targetHost: String,
        targetPort: Int,
        state: ForwardState,
        shouldContinue: @Sendable () -> Bool
    ) async {
        defer {
            while libssh2_channel_forward_cancel(listener) == LIBSSH2_ERROR_EAGAIN {}
        }

        while await !state.isCancelled(), shouldContinue(), isConnected {
            guard let channel = await acceptRemoteChannel(session: session, listener: listener) else {
                continue
            }
            let socket = try? SocketUtilities.createConnectedSocket(host: targetHost, port: targetPort, nonBlocking: true)
            guard let socket else {
                closeChannel(channel)
                continue
            }
            Task { [weak self] in
                await self?.bridge(
                    session: session,
                    channel: channel,
                    socket: socket,
                    state: state,
                    shouldContinue: shouldContinue
                )
            }
        }
    }

    func openRemoteListener(session: SSHSession, remotePort: Int) async throws -> (OpaquePointer, Int) {
        var boundPort: Int32 = 0
        let deadline = Date().addingTimeInterval(configuration.timeout)
        while true {
            if deadline.timeIntervalSinceNow <= 0 {
                throw RemoteShellError.timeout
            }
            let listener = libssh2_channel_forward_listen_ex(
                session.session,
                nil,
                Int32(remotePort),
                &boundPort,
                Int32(SSHConstants.socketQueueSize)
            )
            if let listener {
                return (listener, Int(boundPort))
            }
            if libssh2_session_last_errno(session.session) == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            throw session.lastError(fallback: "Failed to open remote listener")
        }
    }

    func acceptRemoteChannel(session: SSHSession, listener: OpaquePointer) async -> OpaquePointer? {
        let deadline = Date().addingTimeInterval(configuration.timeout)
        while true {
            if deadline.timeIntervalSinceNow <= 0 {
                return nil
            }
            if let channel = libssh2_channel_forward_accept(listener) {
                return channel
            }
            if libssh2_session_last_errno(session.session) == LIBSSH2_ERROR_EAGAIN {
                try? await session.waitForSocket(deadline: deadline)
                continue
            }
            return nil
        }
    }

    func openDirectChannel(
        session: SSHSession,
        targetHost: String,
        targetPort: Int,
        originHost: String,
        originPort: Int
    ) async throws -> OpaquePointer {
        let deadline = Date().addingTimeInterval(configuration.timeout)
        while true {
            if deadline.timeIntervalSinceNow <= 0 {
                throw RemoteShellError.timeout
            }
            let channel = targetHost.withCString { targetCString in
                originHost.withCString { originCString in
                    libssh2_channel_direct_tcpip_ex(
                        session.session,
                        targetCString,
                        Int32(targetPort),
                        originCString,
                        Int32(originPort)
                    )
                }
            }
            if let channel {
                return channel
            }
            if libssh2_session_last_errno(session.session) == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            throw session.lastError(fallback: "Failed to create direct TCP/IP channel")
        }
    }

    func bridge(
        session: SSHSession,
        channel: OpaquePointer,
        socket: Int32,
        state: ForwardState,
        shouldContinue: @Sendable () -> Bool
    ) async {
        defer {
            SocketUtilities.closeSocket(socket)
            closeChannel(channel)
        }

        var buffer = [UInt8](repeating: 0, count: SSHConstants.bufferSize)
        while await !state.isCancelled(), shouldContinue(), isConnected {
            var didWork = false

            let recvCount = buffer.withUnsafeMutableBytes { raw in
                recv(socket, raw.baseAddress, raw.count, 0)
            }
            if recvCount > 0 {
                do {
                    try await writeChannelBytes(session: session, channel: channel, buffer: buffer, count: Int(recvCount))
                    didWork = true
                } catch {
                    break
                }
            } else if recvCount == 0 {
                break
            }

            do {
                let channelRead = try await readChannelBytes(session: session, channel: channel, buffer: &buffer, stderr: false, deadline: nil)
                if channelRead > 0 {
                    var sent = 0
                    while sent < channelRead {
                        let sendCount = buffer.withUnsafeBytes { raw in
                            let ptr = raw.bindMemory(to: Int8.self).baseAddress
                            return send(socket, ptr?.advanced(by: sent), channelRead - sent, 0)
                        }
                        if sendCount > 0 {
                            sent += sendCount
                            continue
                        }
                        if errno == EAGAIN || errno == EWOULDBLOCK {
                            _ = try await KQueuePoller.waitAsync(socket: socket, events: [.write], timeout: nil)
                            continue
                        }
                        sent = channelRead
                        break
                    }
                    didWork = true
                }
            } catch {
                break
            }

            if !didWork {
                do {
                    try await waitForForwardActivity(localSocket: socket, session: session)
                } catch {
                    break
                }
            }
        }
    }

    func waitForForwardActivity(localSocket: Int32, session: SSHSession) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await KQueuePoller.waitAsync(socket: localSocket, events: [.read], timeout: nil)
            }
            group.addTask {
                try await session.waitForSocket(deadline: nil)
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}
