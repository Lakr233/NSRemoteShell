import Foundation
import CSSH2

public extension NSRemoteShell {
    func connect() async throws {
        try LibSSH2Runtime.ensureInitialized()
        guard !configuration.host.isEmpty else {
            throw RemoteShellError.invalidConfiguration("Remote host is required")
        }
        let socket = try SocketUtilities.createConnectedSocket(
            host: configuration.host,
            port: configuration.port,
            nonBlocking: true
        )
        guard let sessionPtr = libssh2_session_init_ex(nil, nil, nil, nil) else {
            SocketUtilities.closeSocket(socket)
            throw RemoteShellError.libssh2Error(code: -1, message: "Unable to initialize session")
        }

        let session = SSHSession(session: sessionPtr, socket: socket, timeout: configuration.timeout)
        libssh2_session_set_blocking(sessionPtr, 0)

        do {
            let rc: Int32 = try await session.retrying(timeout: configuration.timeout, operation: {
                libssh2_session_handshake(sessionPtr, socket)
            }, shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN })
            if rc != 0 {
                throw session.lastError(fallback: "Session handshake failed")
            }
        } catch {
            libssh2_session_free(sessionPtr)
            SocketUtilities.closeSocket(socket)
            throw error
        }

        self.session = session
        isConnected = true
        resolvedRemoteIpAddress = SocketUtilities.peerAddress(for: socket)
        remoteBanner = libssh2_session_banner_get(sessionPtr).map { String(cString: $0) }
        remoteFingerPrint = Self.formatFingerprint(from: sessionPtr)
        startKeepAlive()
    }

    func disconnect() async {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        keepAliveFailures = 0

        isConnected = false
        isAuthenticated = false
        isConnectedFileTransfer = false

        await shutdownForwards()

        if let sftp {
            _ = await closeSFTP(sftp)
            self.sftp = nil
        }

        if let session = session {
            var message = "closed by client"
            message.withCString { cString in
                _ = libssh2_session_disconnect(session.session, cString)
            }
            libssh2_session_free(session.session)
            SocketUtilities.closeSocket(session.socket)
        }
        session = nil
    }

    func authenticate(username: String, password: String) async throws {
        guard let session else {
            throw RemoteShellError.disconnected
        }
        let rc: Int32 = try await session.retrying(timeout: configuration.timeout, operation: {
            libssh2_userauth_password_ex(session.session,
                                         username,
                                         UInt32(username.utf8.count),
                                         password,
                                         UInt32(password.utf8.count),
                                         nil)
        }, shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN })
        guard rc == 0 else {
            let error = session.lastError(fallback: "Authentication failed")
            lastError = error.errorDescription
            throw error
        }
        isAuthenticated = true
    }

    func authenticate(username: String, publicKey: String?, privateKey: String, password: String?) async throws {
        guard let session else {
            throw RemoteShellError.disconnected
        }
        let rc: Int32 = try await session.retrying(timeout: configuration.timeout, operation: {
            libssh2_userauth_publickey_fromfile_ex(session.session,
                                                   username,
                                                   UInt32(username.utf8.count),
                                                   publicKey,
                                                   privateKey,
                                                   password)
        }, shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN })
        guard rc == 0 else {
            let error = session.lastError(fallback: "Authentication failed")
            lastError = error.errorDescription
            throw error
        }
        isAuthenticated = true
    }
}

private extension NSRemoteShell {
    func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(SSHConstants.keepAliveInterval * 1_000_000_000))
                await self.sendKeepAlive()
            }
        }
    }

    func sendKeepAlive() async {
        guard let session, isConnected else { return }
        var nextInterval: Int32 = 0
        let rc: Int32 = (try? await session.retrying(timeout: configuration.timeout, operation: {
            libssh2_keepalive_send(session.session, &nextInterval)
        }, shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN })) ?? -1

        if rc == 0 {
            keepAliveFailures = 0
            return
        }

        keepAliveFailures += 1
        if keepAliveFailures > SSHConstants.keepAliveErrorTolerance {
            await disconnect()
        }
    }

    static func formatFingerprint(from session: OpaquePointer) -> String? {
        guard let hash = libssh2_hostkey_hash(session, Int32(LIBSSH2_HOSTKEY_HASH_SHA1)) else {
            return nil
        }
        var output = ""
        for index in 0..<20 {
            output += String(format: "%02x", hash[index])
        }
        return output
    }
}
