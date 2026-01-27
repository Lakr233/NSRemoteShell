import Foundation
@testable import NSRemoteShell
import Testing

@Suite
struct SFTPTests {
    @Test
    func sftpMultiFileUploadDownload() async throws {
        print("testSFTPMultiFileUploadDownload: start")
        guard let shell = try await connectShell() else { return }
        defer { Task { await shell.disconnect() } }

        try await shell.connectSFTP()
        defer { Task { await shell.disconnectSFTP() } }

        let testId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let remoteDir = "/tmp/nsremoteshell-multi-\(testId)"
        let localUploadDir = FileManager.default.temporaryDirectory.appendingPathComponent("nsremoteshell-upload-\(testId)")
        let localDownloadDir = FileManager.default.temporaryDirectory.appendingPathComponent("nsremoteshell-download-\(testId)")

        try FileManager.default.createDirectory(at: localUploadDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localDownloadDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: localUploadDir)
            try? FileManager.default.removeItem(at: localDownloadDir)
        }

        let fileCount = 5
        var fileContents: [String: String] = [:]
        for i in 1 ... fileCount {
            let name = "file_\(i).txt"
            let content = "CONTENT_\(i)_" + UUID().uuidString
            fileContents[name] = content
            let url = localUploadDir.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
            print("testSFTPMultiFileUploadDownload: created \(name) with \(content.utf8.count) bytes")
        }

        let (mkdirStatus, _) = try await executeCapture(shell, "mkdir -p \(remoteDir)")
        #expect(mkdirStatus == 0)
        defer { Task { try? await shell.deleteFile(at: remoteDir, onProgress: { _ in }) } }

        for (name, _) in fileContents {
            let localPath = localUploadDir.appendingPathComponent(name).path
            print("testSFTPMultiFileUploadDownload: uploading \(name)")
            try await shell.uploadFile(at: localPath, to: remoteDir, onProgress: { _, _ in })
        }

        let remoteFiles = try await shell.listFiles(at: remoteDir)
        print("testSFTPMultiFileUploadDownload: remote files count=\(remoteFiles.count)")
        #expect(remoteFiles.count == fileCount)

        for (name, expectedContent) in fileContents {
            let remotePath = "\(remoteDir)/\(name)"
            let localPath = localDownloadDir.appendingPathComponent(name).path
            print("testSFTPMultiFileUploadDownload: downloading \(name)")
            try await shell.downloadFile(at: remotePath, to: localPath, onProgress: { _, _ in })

            let downloaded = try String(contentsOfFile: localPath, encoding: .utf8)
            #expect(downloaded == expectedContent)
        }

        print("testSFTPMultiFileUploadDownload: all files verified")
    }

    @Test
    func sftpDeleteEmptyDirectory() async throws {
        print("testSFTPDeleteEmptyDirectory: start")
        guard let shell = try await connectShell() else { return }
        defer { Task { await shell.disconnect() } }

        try await shell.connectSFTP()
        defer { Task { await shell.disconnectSFTP() } }

        let testId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let remoteDir = "/tmp/nsremoteshell-empty-\(testId)"

        try await shell.createDirectory(at: remoteDir)
        print("testSFTPDeleteEmptyDirectory: created directory \(remoteDir)")

        let infoBeforeDelete = try? await shell.fileInfo(at: remoteDir)
        #expect(infoBeforeDelete != nil)
        #expect(infoBeforeDelete?.isDirectory == true)

        var deletedPaths: [String] = []
        try await shell.deleteFile(at: remoteDir, onProgress: { path in
            deletedPaths.append(path)
            print("testSFTPDeleteEmptyDirectory: deleted \(path)")
        })

        #expect(deletedPaths.contains(remoteDir))

        let (lsStatus, lsOutput) = try await executeCapture(shell, "ls -d \(remoteDir) 2>&1 || true")
        print("testSFTPDeleteEmptyDirectory: ls status=\(lsStatus) output=\(lsOutput)")
        #expect(lsOutput.contains("No such file") || lsOutput.contains("cannot access") || lsStatus != 0 || !lsOutput.contains(remoteDir.split(separator: "/").last!))
    }

    @Test
    func sftpDeleteNonEmptyDirectory() async throws {
        print("testSFTPDeleteNonEmptyDirectory: start")
        guard let shell = try await connectShell() else { return }
        defer { Task { await shell.disconnect() } }

        try await shell.connectSFTP()
        defer { Task { await shell.disconnectSFTP() } }

        let testId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let remoteDir = "/tmp/nsremoteshell-nonempty-\(testId)"
        let localDir = FileManager.default.temporaryDirectory.appendingPathComponent("nsremoteshell-nonempty-\(testId)")

        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDir) }

        let (mkdirStatus, _) = try await executeCapture(shell, "mkdir -p \(remoteDir)/subdir1/subdir2")
        #expect(mkdirStatus == 0)

        let files = ["root.txt", "subdir1/file1.txt", "subdir1/subdir2/file2.txt"]
        for file in files {
            let content = "content_\(file)_" + UUID().uuidString
            let localFile = localDir.appendingPathComponent(String(file.split(separator: "/").last!))
            try content.write(to: localFile, atomically: true, encoding: .utf8)

            let remotePath = "\(remoteDir)/\(file)"
            let remoteParent = (remotePath as NSString).deletingLastPathComponent
            try await shell.uploadFile(at: localFile.path, to: remoteParent, onProgress: { _, _ in })
            print("testSFTPDeleteNonEmptyDirectory: uploaded \(file)")
        }

        var deletedPaths: [String] = []
        try await shell.deleteFile(at: remoteDir, onProgress: { path in
            deletedPaths.append(path)
            print("testSFTPDeleteNonEmptyDirectory: deleted \(path)")
        })

        print("testSFTPDeleteNonEmptyDirectory: deleted \(deletedPaths.count) items")
        #expect(deletedPaths.count >= 4)

        let (lsStatus, _) = try await executeCapture(shell, "ls -d \(remoteDir) 2>&1")
        #expect(lsStatus != 0)
    }

    @Test
    func sftpDownloadCancel() async throws {
        print("testSFTPDownloadCancel: start")
        guard let shell = try await connectShell() else { return }
        defer { Task { await shell.disconnect() } }

        try await shell.connectSFTP()
        defer { Task { await shell.disconnectSFTP() } }

        let testId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let remoteFile = "/tmp/nsremoteshell-large-\(testId).bin"
        let localFile = FileManager.default.temporaryDirectory.appendingPathComponent("nsremoteshell-large-\(testId).bin")
        defer { try? FileManager.default.removeItem(at: localFile) }

        let sizeMB = 10
        let (ddStatus, _) = try await executeCapture(
            shell,
            "dd if=/dev/zero of=\(remoteFile) bs=1M count=\(sizeMB) 2>/dev/null",
            timeout: 30
        )
        #expect(ddStatus == 0)
        defer { Task { try? await executeCapture(shell, "rm -f \(remoteFile)") } }

        let cancelled = AtomicBool(false)
        var bytesReceived: Int64 = 0
        let startTime = Date()

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            print("testSFTPDownloadCancel: setting cancel flag")
            cancelled.set(true)
        }

        do {
            try await shell.downloadFile(
                at: remoteFile,
                to: localFile.path,
                onProgress: { progress, _ in
                    bytesReceived = progress.completedUnitCount
                },
                shouldContinue: { !cancelled.get() }
            )
        } catch {
            print("testSFTPDownloadCancel: download threw error (expected): \(error)")
        }

        let elapsed = Date().timeIntervalSince(startTime)
        print("testSFTPDownloadCancel: elapsed=\(elapsed)s bytesReceived=\(bytesReceived)")

        #expect(elapsed < 5)
        #expect(bytesReceived < Int64(sizeMB * 1024 * 1024))
    }
}
