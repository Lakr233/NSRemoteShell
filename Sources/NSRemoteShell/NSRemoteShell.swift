import CoreGraphics
import CSSH2
import Foundation

public actor NSRemoteShell {
    public struct Configuration: Sendable {
        public var host: String
        public var port: Int
        public var timeout: TimeInterval

        public init(host: String, port: Int = 22, timeout: TimeInterval = 8) {
            self.host = host
            self.port = port
            self.timeout = timeout
        }
    }

    public internal(set) var isConnected = false
    public internal(set) var isConnectedFileTransfer = false
    public internal(set) var isAuthenticated = false

    public internal(set) var resolvedRemoteIpAddress: String?
    public internal(set) var remoteBanner: String?
    public internal(set) var remoteFingerPrint: String?

    public internal(set) var lastError: String?
    public internal(set) var lastFileTransferError: String?

    public private(set) var configuration: Configuration

    var session: SSHSession?
    var sftp: OpaquePointer?
    var keepAliveFailures = 0
    var keepAliveTask: Task<Void, Never>?
    var forwardTasks: [UUID: Task<Void, Never>] = [:]

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public init(host: String, port: Int = 22, timeout: TimeInterval = 8) {
        configuration = Configuration(host: host, port: port, timeout: timeout)
    }

    public func updateConfiguration(_ update: (inout Configuration) -> Void) {
        update(&configuration)
    }

    deinit {
        Task { [weak self] in
            await self?.disconnect()
        }
    }
}
