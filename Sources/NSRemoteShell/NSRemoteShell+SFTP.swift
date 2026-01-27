import Foundation
import CSSH2
import Darwin

public extension NSRemoteShell {
    func connectSFTP() async throws {
        guard let session else { throw RemoteShellError.disconnected }
        guard isAuthenticated else { throw RemoteShellError.authenticationRequired }
        if self.sftp != nil {
            return
        }
        let sftpSession = try await openSFTP(session: session)
        self.sftp = sftpSession
        isConnectedFileTransfer = true
    }

    func disconnectSFTP() async {
        if let sftp {
            _ = await closeSFTP(sftp)
            self.sftp = nil
        }
        isConnectedFileTransfer = false
    }

    func listFiles(at path: String) async throws -> [RemoteFile] {
        let (session, sftp) = try requireSFTP()
        let handle = try await openSFTPHandle(session: session, sftp: sftp, path: path, flags: 0, mode: 0, openType: LIBSSH2_SFTP_OPENDIR)
        defer { _ = closeSFTPHandle(handle) }

        var results: [RemoteFile] = []
        var buffer = [UInt8](repeating: 0, count: 512)

        while true {
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()
            let readCount = buffer.withUnsafeMutableBytes { raw in
                let ptr = raw.bindMemory(to: Int8.self).baseAddress
                return Int(libssh2_sftp_readdir(handle, ptr, raw.count, &attributes))
            }
            if readCount > 0 {
                let name = String(decoding: buffer.prefix(readCount), as: UTF8.self)
                if name != "." && name != ".." {
                    results.append(RemoteFile(name: name, attributes: attributes))
                }
                continue
            }
            if readCount == 0 {
                break
            }
            if readCount == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: Date().addingTimeInterval(configuration.timeout))
                continue
            }
            let error = session.lastError(fallback: "Failed to read directory")
            lastFileTransferError = error.errorDescription
            throw error
        }

        return results.sorted { $0.name < $1.name }
    }

    func fileInfo(at path: String) async throws -> RemoteFile {
        let (session, sftp) = try requireSFTP()
        let handle = try await openSFTPHandle(session: session, sftp: sftp, path: path, flags: UInt32(LIBSSH2_FXF_READ), mode: 0, openType: LIBSSH2_SFTP_OPENFILE)
        defer { _ = closeSFTPHandle(handle) }

        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        let deadline = Date().addingTimeInterval(configuration.timeout)
        while true {
            let rc = libssh2_sftp_fstat(handle, &attributes)
            if rc == 0 {
                break
            }
            if rc == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            let error = session.lastError(fallback: "Failed to stat file")
            lastFileTransferError = error.errorDescription
            throw error
        }
        return RemoteFile(name: URL(fileURLWithPath: path).lastPathComponent, attributes: attributes)
    }

    func renameFile(at path: String, to newPath: String) async throws {
        let (session, sftp) = try requireSFTP()
        guard path.hasPrefix("/") && newPath.hasPrefix("/") else {
            throw RemoteShellError.invalidConfiguration("SFTP rename requires absolute paths")
        }
        let deadline = Date().addingTimeInterval(configuration.timeout)
        while true {
            let flags = UInt32(LIBSSH2_SFTP_RENAME_OVERWRITE | LIBSSH2_SFTP_RENAME_ATOMIC | LIBSSH2_SFTP_RENAME_NATIVE)
            let rc = path.withCString { source in
                newPath.withCString { destination in
                    libssh2_sftp_rename_ex(sftp,
                                           source,
                                           UInt32(strlen(source)),
                                           destination,
                                           UInt32(strlen(destination)),
                                           flags)
                }
            }
            if rc == 0 {
                break
            }
            if rc == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            let error = session.lastError(fallback: "Failed to rename remote file")
            lastFileTransferError = error.errorDescription
            throw error
        }
    }

    func createDirectory(at path: String) async throws {
        let (session, sftp) = try requireSFTP()
        if let info = try? await fileInfo(at: path), info.isDirectory {
            return
        }
        let deadline = Date().addingTimeInterval(configuration.timeout)
        while true {
            let mode = UInt32(LIBSSH2_SFTP_S_IRWXU | LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IXGRP | LIBSSH2_SFTP_S_IROTH | LIBSSH2_SFTP_S_IXOTH)
            let rc = path.withCString { cPath in
                libssh2_sftp_mkdir_ex(sftp, cPath, UInt32(strlen(cPath)), mode)
            }
            if rc == 0 {
                break
            }
            if rc == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            let error = session.lastError(fallback: "Failed to create remote directory")
            lastFileTransferError = error.errorDescription
            throw error
        }
    }

    func deleteFile(at path: String, onProgress: @Sendable (String) -> Void, shouldContinue: @Sendable () -> Bool = { true }) async throws {
        let (session, sftp) = try requireSFTP()
        try await deleteRecursively(session: session, sftp: sftp, path: path, depth: 0, onProgress: onProgress, shouldContinue: shouldContinue)
    }

    func uploadFile(
        at localPath: String,
        to remoteDirectory: String,
        onProgress: @Sendable (Progress, Double) -> Void,
        shouldContinue: @Sendable () -> Bool = { true }
    ) async throws {
        let expandedPath = NSString(string: localPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            let remoteTarget = URL(fileURLWithPath: remoteDirectory).appendingPathComponent(url.lastPathComponent)
            try await createDirectory(at: remoteTarget.path)
            let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
            for entry in contents {
                let childLocal = url.appendingPathComponent(entry)
                try await uploadFile(at: childLocal.path, to: remoteTarget.path, onProgress: onProgress, shouldContinue: shouldContinue)
            }
            return
        }

        guard let session else { throw RemoteShellError.disconnected }
        let remoteFile = URL(fileURLWithPath: remoteDirectory).appendingPathComponent(url.lastPathComponent)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        let channel = try await openSCPSend(session: session, path: remoteFile.path, mode: mode, size: size)
        defer { closeChannel(channel) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let start = Date()
        var lastProgress = Date(timeIntervalSince1970: 0)
        var sent: UInt64 = 0
        while sent < size {
            if !shouldContinue() || !isConnectedFileTransfer {
                break
            }
            let data = handle.readData(ofLength: SSHConstants.sftpBufferSize)
            if data.isEmpty { break }
            let bytes = [UInt8](data)
            try await writeChannelBytes(session: session, channel: channel, buffer: bytes, count: bytes.count)
            sent += UInt64(bytes.count)
            if lastProgress.timeIntervalSinceNow < -0.2 {
                lastProgress = Date()
                let interval = max(Date().timeIntervalSince(start), 0.001)
                let speed = Double(sent) / interval
                let progress = Progress(totalUnitCount: Int64(size))
                progress.completedUnitCount = Int64(sent)
                await MainActor.run {
                    onProgress(progress, speed)
                }
            }
        }

        let interval = max(Date().timeIntervalSince(start), 0.001)
        let speed = Double(sent) / interval
        let progress = Progress(totalUnitCount: Int64(size))
        progress.completedUnitCount = Int64(sent)
        await MainActor.run {
            onProgress(progress, speed)
        }

        if sent < size {
            lastFileTransferError = "Upload incomplete"
            throw RemoteShellError.libssh2Error(code: -1, message: "Upload incomplete")
        }
    }

    func downloadFile(
        at remotePath: String,
        to localPath: String,
        onProgress: @Sendable (Progress, Double) -> Void,
        shouldContinue: @Sendable () -> Bool = { true }
    ) async throws {
        let (session, _) = try requireSFTP()
        try await downloadRecursive(session: session, remotePath: remotePath, localPath: localPath, depth: 0, onProgress: onProgress, shouldContinue: shouldContinue)
    }
}

private extension NSRemoteShell {
    func requireSFTP() throws -> (SSHSession, OpaquePointer) {
        guard let session else { throw RemoteShellError.disconnected }
        guard let sftp else { throw RemoteShellError.fileTransferUnavailable }
        return (session, sftp)
    }

    func openSFTP(session: SSHSession) async throws -> OpaquePointer {
        let deadline = Date().addingTimeInterval(configuration.timeout)
        while true {
            if deadline.timeIntervalSinceNow <= 0 {
                throw RemoteShellError.timeout
            }
            if let sftp = libssh2_sftp_init(session.session) {
                return sftp
            }
            if libssh2_session_last_errno(session.session) == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            let error = session.lastError(fallback: "Failed to initialize SFTP")
            lastFileTransferError = error.errorDescription
            throw error
        }
    }

    func closeSFTP(_ sftp: OpaquePointer) async -> Bool {
        guard let session else { return false }
        while libssh2_sftp_shutdown(sftp) == LIBSSH2_ERROR_EAGAIN {
            try? await session.waitForSocket(deadline: Date().addingTimeInterval(configuration.timeout))
        }
        return true
    }

    func openSFTPHandle(
        session: SSHSession,
        sftp: OpaquePointer,
        path: String,
        flags: UInt32,
        mode: Int32,
        openType: Int32
    ) async throws -> OpaquePointer {
        let deadline = Date().addingTimeInterval(configuration.timeout)
        while true {
            if deadline.timeIntervalSinceNow <= 0 {
                throw RemoteShellError.timeout
            }
            let handle = path.withCString { cPath in
                libssh2_sftp_open_ex(
                    sftp,
                    cPath,
                    UInt32(strlen(cPath)),
                    UInt(flags),
                    mode,
                    openType
                )
            }
            if let handle {
                return handle
            }
            if libssh2_session_last_errno(session.session) == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            let error = session.lastError(fallback: "Failed to open SFTP handle")
            lastFileTransferError = error.errorDescription
            throw error
        }
    }

    func closeSFTPHandle(_ handle: OpaquePointer) -> Bool {
        while libssh2_sftp_close_handle(handle) == LIBSSH2_ERROR_EAGAIN {}
        return true
    }

    func deleteRecursively(
        session: SSHSession,
        sftp: OpaquePointer,
        path: String,
        depth: Int,
        onProgress: @Sendable (String) -> Void,
        shouldContinue: @Sendable () -> Bool
    ) async throws {
        if depth > SSHConstants.sftpRecursiveDepth {
            throw RemoteShellError.invalidConfiguration("SFTP delete exceeded depth limit")
        }
        if !shouldContinue() {
            throw RemoteShellError.invalidConfiguration("Delete cancelled")
        }

        if let info = try? await fileInfo(at: path), info.isDirectory {
            let children = try await listFiles(at: path)
            for child in children {
                let childPath = URL(fileURLWithPath: path).appendingPathComponent(child.name).path
                try await deleteRecursively(session: session, sftp: sftp, path: childPath, depth: depth + 1, onProgress: onProgress, shouldContinue: shouldContinue)
            }
            await MainActor.run { onProgress(path) }
            try await removeDirectory(session: session, sftp: sftp, path: path)
        } else {
            await MainActor.run { onProgress(path) }
            try await unlinkFile(session: session, sftp: sftp, path: path)
        }
    }

    func removeDirectory(session: SSHSession, sftp: OpaquePointer, path: String) async throws {
        let deadline = Date().addingTimeInterval(configuration.timeout)
        while true {
            let rc = path.withCString { cPath in
                libssh2_sftp_rmdir_ex(sftp, cPath, UInt32(strlen(cPath)))
            }
            if rc == 0 { return }
            if rc == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            let error = session.lastError(fallback: "Failed to remove directory")
            lastFileTransferError = error.errorDescription
            throw error
        }
    }

    func unlinkFile(session: SSHSession, sftp: OpaquePointer, path: String) async throws {
        let deadline = Date().addingTimeInterval(configuration.timeout)
        while true {
            let rc = path.withCString { cPath in
                libssh2_sftp_unlink_ex(sftp, cPath, UInt32(strlen(cPath)))
            }
            if rc == 0 { return }
            if rc == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            let error = session.lastError(fallback: "Failed to delete file")
            lastFileTransferError = error.errorDescription
            throw error
        }
    }

    func openSCPSend(session: SSHSession, path: String, mode: Int, size: UInt64) async throws -> OpaquePointer {
        let deadline = Date().addingTimeInterval(configuration.timeout)
        while true {
            if deadline.timeIntervalSinceNow <= 0 {
                throw RemoteShellError.timeout
            }
            let channel = path.withCString { cPath in
                libssh2_scp_send64(
                    session.session,
                    cPath,
                    Int32(mode & 0o644),
                    size,
                    0,
                    0
                )
            }
            if let channel {
                return channel
            }
            if libssh2_session_last_errno(session.session) == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            let error = session.lastError(fallback: "Failed to open SCP upload channel")
            lastFileTransferError = error.errorDescription
            throw error
        }
    }

    func downloadRecursive(
        session: SSHSession,
        remotePath: String,
        localPath: String,
        depth: Int,
        onProgress: @Sendable (Progress, Double) -> Void,
        shouldContinue: @Sendable () -> Bool
    ) async throws {
        if depth > SSHConstants.sftpRecursiveDepth {
            throw RemoteShellError.invalidConfiguration("SFTP download exceeded depth limit")
        }
        if !shouldContinue() {
            throw RemoteShellError.invalidConfiguration("Download cancelled")
        }

        let info = try await fileInfo(at: remotePath)
        let remoteURL = URL(fileURLWithPath: remotePath)
        let localURL = URL(fileURLWithPath: localPath)
        let targetURL = localPath.hasSuffix("/") ? localURL.appendingPathComponent(remoteURL.lastPathComponent) : localURL

        if info.isDirectory {
            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true, attributes: nil)
            let children = try await listFiles(at: remotePath)
            for child in children {
                let childRemote = remoteURL.appendingPathComponent(child.name).path
                let childLocal = targetURL.appendingPathComponent(child.name).path
                try await downloadRecursive(session: session, remotePath: childRemote, localPath: childLocal, depth: depth + 1, onProgress: onProgress, shouldContinue: shouldContinue)
            }
            return
        }

        let (channel, size) = try await openSCPReceive(session: session, path: remotePath)
        defer { closeChannel(channel) }

        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        FileManager.default.createFile(atPath: targetURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: targetURL)
        defer { try? handle.close() }

        var buffer = [UInt8](repeating: 0, count: SSHConstants.sftpBufferSize)
        var received: UInt64 = 0
        let start = Date()
        var lastProgress = Date(timeIntervalSince1970: 0)

        while received < size {
            if !shouldContinue() || !isConnectedFileTransfer {
                break
            }
            let readCount = try await readChannelBytes(session: session, channel: channel, buffer: &buffer, stderr: false, deadline: nil)
            if readCount > 0 {
                handle.write(Data(buffer.prefix(readCount)))
                received += UInt64(readCount)
            }

            if lastProgress.timeIntervalSinceNow < -0.1 {
                lastProgress = Date()
                let interval = max(Date().timeIntervalSince(start), 0.001)
                let speed = Double(received) / interval
                let progress = Progress(totalUnitCount: Int64(size))
                progress.completedUnitCount = Int64(received)
                await MainActor.run {
                    onProgress(progress, speed)
                }
            }
        }

        let interval = max(Date().timeIntervalSince(start), 0.001)
        let speed = Double(received) / interval
        let progress = Progress(totalUnitCount: Int64(size))
        progress.completedUnitCount = Int64(received)
        await MainActor.run {
            onProgress(progress, speed)
        }

        if received < size {
            lastFileTransferError = "Download incomplete"
            throw RemoteShellError.libssh2Error(code: -1, message: "Download incomplete")
        }
    }

    func openSCPReceive(session: SSHSession, path: String) async throws -> (OpaquePointer, UInt64) {
        let deadline = Date().addingTimeInterval(configuration.timeout)
        var info = stat()
        while true {
            if deadline.timeIntervalSinceNow <= 0 {
                throw RemoteShellError.timeout
            }
            let channel = path.withCString { cPath in
                libssh2_scp_recv(session.session, cPath, &info)
            }
            if let channel {
                return (channel, UInt64(info.st_size))
            }
            if libssh2_session_last_errno(session.session) == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            let error = session.lastError(fallback: "Failed to open SCP download channel")
            lastFileTransferError = error.errorDescription
            throw error
        }
    }
}
