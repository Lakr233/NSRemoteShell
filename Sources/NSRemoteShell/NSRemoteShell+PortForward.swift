import CSSH2
import Foundation

private func forwardLog(_ message: String) {
    if ProcessInfo.processInfo.environment["NSREMOTE_FORWARD_DEBUG"] == "1" {
        print("PortForward: \(message)")
    }
}

public extension NSRemoteShell {
    func startLocalPortForward(
        localPort: Int,
        targetHost: String,
        targetPort: Int,
        shouldContinue: @Sendable @escaping () -> Bool = { true }
    ) async throws -> PortForwardHandle {
        guard let session else { throw RemoteShellError.disconnected }
        let listenSocket = try SocketUtilities.createListener(on: localPort)
        let boundPort: Int
        do {
            boundPort = try SocketUtilities.boundPort(for: listenSocket)
        } catch {
            SocketUtilities.closeSocket(listenSocket)
            throw error
        }
        let state = ForwardState()
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await runLocalForward(
                session: session,
                listenSocket: listenSocket,
                localPort: boundPort,
                targetHost: targetHost,
                targetPort: targetPort,
                state: state,
                shouldContinue: shouldContinue
            )
        }
        forwardTasks[id] = task
        return PortForwardHandle(state: state, boundPort: boundPort)
    }

    func startRemotePortForward(
        remotePort: Int,
        targetHost: String,
        targetPort: Int,
        shouldContinue: @Sendable @escaping () -> Bool = { true }
    ) async throws -> PortForwardHandle {
        guard let session else { throw RemoteShellError.disconnected }
        let state = ForwardState()
        let (listener, boundPort) = try await openRemoteListener(session: session, remotePort: remotePort)
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await runRemoteForward(
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
        shouldContinue: @Sendable @escaping () -> Bool
    ) async {
        defer { SocketUtilities.closeSocket(listenSocket) }
        while await !state.isCancelled(), shouldContinue(), isConnected, !Task.isCancelled {
            let ready = await (try? KQueuePoller.waitAsync(socket: listenSocket, events: [.read], timeout: SSHConstants.socketWaitSlice)) ?? false
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
            forwardLog("local forward accepted client")

            do {
                let channel = try await openDirectChannel(
                    session: session,
                    targetHost: targetHost,
                    targetPort: targetPort,
                    originHost: "127.0.0.1",
                    originPort: localPort
                )
                forwardLog("local forward direct channel opened to \(targetHost):\(targetPort)")
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
                forwardLog("local forward channel open failed error=\(error)")
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
        shouldContinue: @Sendable @escaping () -> Bool
    ) async {
        defer {
            while session.withLock({ libssh2_channel_forward_cancel(listener) }) == LIBSSH2_ERROR_EAGAIN {}
        }

        while await !state.isCancelled(), shouldContinue(), isConnected, !Task.isCancelled {
            guard let channel = await acceptRemoteChannel(session: session, listener: listener) else {
                continue
            }
            forwardLog("remote forward accepted channel")
            let socket = try? SocketUtilities.createConnectedSocket(host: targetHost, port: targetPort, nonBlocking: true)
            guard let socket else {
                forwardLog("remote forward target connect failed to \(targetHost):\(targetPort)")
                closeChannel(session: session, channel)
                continue
            }
            forwardLog("remote forward connected to \(targetHost):\(targetPort)")
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
            let listener = session.withLock {
                libssh2_channel_forward_listen_ex(
                    session.session,
                    nil,
                    Int32(remotePort),
                    &boundPort,
                    Int32(SSHConstants.socketQueueSize)
                )
            }
            if let listener {
                return (listener, Int(boundPort))
            }
            if session.withLock({ libssh2_session_last_errno(session.session) }) == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            throw session.lastError(fallback: "Failed to open remote listener")
        }
    }

    func acceptRemoteChannel(session: SSHSession, listener: OpaquePointer) async -> OpaquePointer? {
        let deadline = Date().addingTimeInterval(configuration.timeout)
        while true {
            if Task.isCancelled {
                return nil
            }
            if deadline.timeIntervalSinceNow <= 0 {
                return nil
            }
            if let channel = session.withLock({ libssh2_channel_forward_accept(listener) }) {
                return channel
            }
            if session.withLock({ libssh2_session_last_errno(session.session) }) == LIBSSH2_ERROR_EAGAIN {
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
            let channel = session.withLock {
                targetHost.withCString { targetCString in
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
            }
            if let channel {
                return channel
            }
            if session.withLock({ libssh2_session_last_errno(session.session) }) == LIBSSH2_ERROR_EAGAIN {
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
        shouldContinue: @Sendable @escaping () -> Bool
    ) async {
        defer {
            SocketUtilities.closeSocket(socket)
            closeChannel(session: session, channel)
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                await pumpSocketToChannel(
                    session: session,
                    channel: channel,
                    socket: socket,
                    state: state,
                    shouldContinue: shouldContinue
                )
            }
            group.addTask { [weak self] in
                guard let self else { return }
                await pumpChannelToSocket(
                    session: session,
                    channel: channel,
                    socket: socket,
                    state: state,
                    shouldContinue: shouldContinue
                )
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    func pumpSocketToChannel(
        session: SSHSession,
        channel: OpaquePointer,
        socket: Int32,
        state: ForwardState,
        shouldContinue: @Sendable @escaping () -> Bool
    ) async {
        var buffer = [UInt8](repeating: 0, count: SSHConstants.bufferSize)
        while await !state.isCancelled(), shouldContinue(), isConnected, !Task.isCancelled {
            let recvCount = buffer.withUnsafeMutableBytes { raw in
                recv(socket, raw.baseAddress, raw.count, 0)
            }
            if recvCount > 0 {
                forwardLog("socket->channel bytes=\(recvCount)")
                do {
                    try await writeChannelBytes(session: session, channel: channel, buffer: buffer, count: Int(recvCount))
                } catch {
                    forwardLog("socket->channel write failed error=\(error)")
                    break
                }
                continue
            }
            if recvCount == 0 {
                forwardLog("socket closed")
                break
            }
            let code = errno
            if code == EAGAIN || code == EWOULDBLOCK {
                _ = try? await KQueuePoller.waitAsync(socket: socket, events: [.read], timeout: SSHConstants.socketWaitSlice)
                continue
            }
            forwardLog("socket recv failed errno=\(code) message=\(String(cString: strerror(code)))")
            break
        }
    }

    func pumpChannelToSocket(
        session: SSHSession,
        channel: OpaquePointer,
        socket: Int32,
        state: ForwardState,
        shouldContinue: @Sendable @escaping () -> Bool
    ) async {
        var buffer = [UInt8](repeating: 0, count: SSHConstants.bufferSize)
        while await !state.isCancelled(), shouldContinue(), isConnected, !Task.isCancelled {
            do {
                let channelRead = try await readChannelBytes(
                    session: session,
                    channel: channel,
                    buffer: &buffer,
                    stderr: false,
                    deadline: nil
                )
                if channelRead > 0 {
                    forwardLog("channel->socket bytes=\(channelRead)")
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
                        let code = errno
                        if code == EAGAIN || code == EWOULDBLOCK {
                            _ = try await KQueuePoller.waitAsync(socket: socket, events: [.write], timeout: SSHConstants.socketWaitSlice)
                            continue
                        }
                        forwardLog("channel->socket send failed errno=\(code) message=\(String(cString: strerror(code)))")
                        sent = channelRead
                        break
                    }
                    continue
                }
                forwardLog("channel closed")
                break
            } catch {
                forwardLog("channel read failed error=\(error)")
                break
            }
        }
    }
}
