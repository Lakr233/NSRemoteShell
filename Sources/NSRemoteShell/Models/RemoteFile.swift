import CSSH2
import Foundation

public struct RemoteFile: Hashable, Sendable {
    public let name: String
    public let size: UInt64?
    public let isRegularFile: Bool
    public let isDirectory: Bool
    public let isLink: Bool
    public let modificationDate: Date?
    public let lastAccess: Date?
    public let ownerUID: UInt
    public let ownerGID: UInt
    public let permissionDescription: String

    init(name: String, attributes: LIBSSH2_SFTP_ATTRIBUTES) {
        self.name = name
        size = attributes.filesize
        modificationDate = Date(timeIntervalSince1970: TimeInterval(attributes.mtime))
        lastAccess = Date(timeIntervalSince1970: TimeInterval(attributes.atime))
        ownerUID = UInt(attributes.uid)
        ownerGID = UInt(attributes.gid)
        let mode = UInt32(attributes.permissions)
        permissionDescription = RemoteFile.permissionDescription(for: UInt(mode))
        let type = mode & RemoteFile.sftpTypeMask
        isRegularFile = type == RemoteFile.sftpRegular
        isDirectory = type == RemoteFile.sftpDirectory
        isLink = type == RemoteFile.sftpLink
    }

    private static func permissionDescription(for mode: UInt) -> String {
        let rwx = ["---", "--x", "-w-", "-wx", "r--", "r-x", "rw-", "rwx"]
        var bits = [Character](repeating: "-", count: 10)
        bits[0] = fileTypeLetter(for: mode)

        let owner = rwx[Int((mode >> 6) & 7)]
        let group = rwx[Int((mode >> 3) & 7)]
        let other = rwx[Int(mode & 7)]

        for (index, char) in owner.enumerated() {
            bits[1 + index] = char
        }
        for (index, char) in group.enumerated() {
            bits[4 + index] = char
        }
        for (index, char) in other.enumerated() {
            bits[7 + index] = char
        }

        if mode & UInt(S_ISUID) != 0 { bits[3] = (mode & 0o100) != 0 ? "s" : "S" }
        if mode & UInt(S_ISGID) != 0 { bits[6] = (mode & 0o010) != 0 ? "s" : "l" }
        if mode & UInt(S_ISVTX) != 0 { bits[9] = (mode & 0o100) != 0 ? "t" : "T" }
        return String(bits)
    }

    private static func fileTypeLetter(for mode: UInt) -> Character {
        if mode & UInt(S_IFMT) == UInt(S_IFREG) { return "-" }
        if mode & UInt(S_IFMT) == UInt(S_IFDIR) { return "d" }
        if mode & UInt(S_IFMT) == UInt(S_IFBLK) { return "b" }
        if mode & UInt(S_IFMT) == UInt(S_IFCHR) { return "c" }
        if mode & UInt(S_IFMT) == UInt(S_IFIFO) { return "p" }
        if mode & UInt(S_IFMT) == UInt(S_IFLNK) { return "l" }
        if mode & UInt(S_IFMT) == UInt(S_IFSOCK) { return "s" }
        return "?"
    }

    private static let sftpTypeMask: UInt32 = 0o170000
    private static let sftpRegular: UInt32 = 0o100000
    private static let sftpDirectory: UInt32 = 0o040000
    private static let sftpLink: UInt32 = 0o120000
}
