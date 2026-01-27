import Foundation

enum SSHConstants {
    static let bufferSize = 131_072
    static let keepAliveInterval: TimeInterval = 1
    static let keepAliveErrorTolerance = 8
    static let operationTimeout: TimeInterval = 30
    static let sftpBufferSize = bufferSize
    static let sftpRecursiveDepth = 32
    static let socketQueueSize = 16
    static let channelWindowSize: UInt32 = 2 * 1024 * 1024
    static let channelPacketSize: UInt32 = 32_768
}
