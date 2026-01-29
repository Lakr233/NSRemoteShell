import Foundation
@testable import NSRemoteShell
import Testing

@Suite
struct SFTPTests {
    @Test
    func sftpMultiFileUploadDownload() async throws {
        try await withSerialTestLock {
            print("testSFTPMultiFileUploadDownload: start")
            _ = try await withConnectedShell { shell in
                try await withSFTP(shell: shell) {
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

                    try? await shell.deleteFile(at: remoteDir, onProgress: { _ in })
                    print("testSFTPMultiFileUploadDownload: all files verified")
                }
            }
        }
    }

    @Test
    func sftpDeleteEmptyDirectory() async throws {
        try await withSerialTestLock {
            print("testSFTPDeleteEmptyDirectory: start")
            _ = try await withConnectedShell { shell in
                try await withSFTP(shell: shell) {
                    let testId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    let remoteDir = "/tmp/nsremoteshell-empty-\(testId)"

                    try await shell.createDirectory(at: remoteDir)
                    print("testSFTPDeleteEmptyDirectory: created directory \(remoteDir)")

                    let infoBeforeDelete = try? await shell.fileInfo(at: remoteDir)
                    #expect(infoBeforeDelete != nil)
                    #expect(infoBeforeDelete?.isDirectory == true)

                    let deletedRoot = AtomicBool(false)
                    try await shell.deleteFile(at: remoteDir, onProgress: { path in
                        if path == remoteDir {
                            deletedRoot.set(true)
                        }
                        print("testSFTPDeleteEmptyDirectory: deleted \(path)")
                    })

                    #expect(deletedRoot.get())

                    let (lsStatus, lsOutput) = try await executeCapture(shell, "ls -d \(remoteDir) 2>&1 || true")
                    print("testSFTPDeleteEmptyDirectory: ls status=\(lsStatus) output=\(lsOutput)")
                    #expect(lsOutput.contains("No such file") || lsOutput.contains("cannot access") || lsStatus != 0 || !lsOutput.contains(remoteDir.split(separator: "/").last!))
                }
            }
        }
    }

    @Test
    func sftpDeleteNonEmptyDirectory() async throws {
        try await withSerialTestLock {
            print("testSFTPDeleteNonEmptyDirectory: start")
            _ = try await withConnectedShell { shell in
                try await withSFTP(shell: shell) {
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

                    let deletedCount = AtomicInt(0)
                    try await shell.deleteFile(at: remoteDir, onProgress: { path in
                        _ = deletedCount.increment()
                        print("testSFTPDeleteNonEmptyDirectory: deleted \(path)")
                    })

                    print("testSFTPDeleteNonEmptyDirectory: deleted \(deletedCount.get()) items")
                    #expect(deletedCount.get() >= 4)

                    let (lsStatus, _) = try await executeCapture(shell, "ls -d \(remoteDir) 2>&1")
                    #expect(lsStatus != 0)
                }
            }
        }
    }

    @Test
    func sftpDownloadCancel() async throws {
        try await withSerialTestLock {
            print("testSFTPDownloadCancel: start")
            _ = try await withConnectedShell { shell in
                try await withSFTP(shell: shell) {
                    let testId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    let remoteFile = "/tmp/nsremoteshell-large-\(testId).bin"
                    let localFile = FileManager.default.temporaryDirectory.appendingPathComponent("nsremoteshell-large-\(testId).bin")
                    defer { try? FileManager.default.removeItem(at: localFile) }

                    let sizeMB = 32
                    let (ddStatus, _) = try await executeCapture(
                        shell,
                        "dd if=/dev/zero of=\(remoteFile) bs=1M count=\(sizeMB) 2>/dev/null",
                        timeout: 30
                    )
                    #expect(ddStatus == 0)

                    let cancelled = AtomicBool(false)
                    let continueCalls = AtomicInt(0)
                    let bytesReceived = AtomicInt(0)
                    let startTime = Date()

                    let cancelAfterCalls = 4
                    var didThrow = false
                    do {
                        try await shell.downloadFile(
                            at: remoteFile,
                            to: localFile.path,
                            onProgress: { progress, _ in
                                bytesReceived.set(Int(progress.completedUnitCount))
                            },
                            shouldContinue: {
                                let callCount = continueCalls.increment()
                                if callCount >= cancelAfterCalls {
                                    if !cancelled.get() {
                                        print("testSFTPDownloadCancel: setting cancel flag after \(callCount) reads")
                                    }
                                    cancelled.set(true)
                                    return false
                                }
                                return true
                            }
                        )
                        print("testSFTPDownloadCancel: download completed before cancellation (unexpected)")
                    } catch {
                        didThrow = true
                        print("testSFTPDownloadCancel: download threw error (expected): \(error)")
                    }

                    let elapsed = Date().timeIntervalSince(startTime)
                    print("testSFTPDownloadCancel: elapsed=\(elapsed)s bytesReceived=\(bytesReceived.get()) continueCalls=\(continueCalls.get())")

                    _ = try? await executeCapture(shell, "rm -f \(remoteFile)")
                    #expect(didThrow)
                    #expect(cancelled.get())
                    #expect(elapsed < 10)
                    #expect(bytesReceived.get() < sizeMB * 1024 * 1024)
                }
            }
        }
    }
}
