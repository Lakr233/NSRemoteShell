import Darwin
import Foundation

enum SocketUtilities {
    static func isValidPort(_ port: Int) -> Bool {
        port >= 0 && port <= 65535
    }

    static func createListener(on port: Int) throws -> Int32 {
        guard isValidPort(port) else {
            throw RemoteShellError.invalidConfiguration("Invalid port \(port)")
        }
        let socketFd = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFd >= 0 else {
            throw RemoteShellError.socketError(code: errno, message: String(cString: strerror(errno)))
        }

        var reuse = Int32(1)
        if setsockopt(socketFd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse))) == -1 {
            let error = errno
            close(socketFd)
            throw RemoteShellError.socketError(code: error, message: String(cString: strerror(error)))
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let error = errno
            close(socketFd)
            throw RemoteShellError.socketError(code: error, message: String(cString: strerror(error)))
        }

        try setNonBlocking(socketFd)

        guard listen(socketFd, Int32(SSHConstants.socketQueueSize)) == 0 else {
            let error = errno
            close(socketFd)
            throw RemoteShellError.socketError(code: error, message: String(cString: strerror(error)))
        }
        return socketFd
    }

    static func createConnectedSocket(host: String, port: Int, nonBlocking: Bool) throws -> Int32 {
        guard isValidPort(port) else {
            throw RemoteShellError.invalidConfiguration("Invalid port \(port)")
        }
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let head = result else {
            throw RemoteShellError.socketError(code: Int32(status), message: String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(head) }

        var current = head
        while true {
            let address = current.pointee
            guard let addr = address.ai_addr else {
                if let next = address.ai_next {
                    current = next
                    continue
                }
                break
            }

            let socketFd = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
            if socketFd < 0 {
                if let next = address.ai_next {
                    current = next
                    continue
                }
                break
            }

            if address.ai_family == AF_INET {
                var ipv4 = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                ipv4.sin_port = in_port_t(UInt16(port).bigEndian)
                let connectResult = withUnsafePointer(to: &ipv4) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(socketFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if connectResult == 0 {
                    if nonBlocking { try? setNonBlocking(socketFd) }
                    return socketFd
                }
            } else if address.ai_family == AF_INET6 {
                var ipv6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                ipv6.sin6_port = in_port_t(UInt16(port).bigEndian)
                let connectResult = withUnsafePointer(to: &ipv6) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(socketFd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
                if connectResult == 0 {
                    if nonBlocking { try? setNonBlocking(socketFd) }
                    return socketFd
                }
            }

            close(socketFd)
            if let next = address.ai_next {
                current = next
                continue
            }
            break
        }
        throw RemoteShellError.socketError(code: errno, message: String(cString: strerror(errno)))
    }

    static func setNonBlocking(_ socket: Int32) throws {
        let flags = fcntl(socket, F_GETFL)
        guard flags >= 0 else {
            throw RemoteShellError.socketError(code: errno, message: String(cString: strerror(errno)))
        }
        if fcntl(socket, F_SETFL, flags | O_NONBLOCK) == -1 {
            throw RemoteShellError.socketError(code: errno, message: String(cString: strerror(errno)))
        }
    }

    static func closeSocket(_ socket: Int32) {
        if socket > 0 {
            close(socket)
        }
    }

    static func peerAddress(for socket: Int32) -> String? {
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(socket, $0, &length)
            }
        }
        guard result == 0 else { return nil }

        if address.ss_family == sa_family_t(AF_INET) {
            var addr = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let converted = inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
            return converted.map { String(cString: $0) }
        } else if address.ss_family == sa_family_t(AF_INET6) {
            var addr = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let converted = inet_ntop(AF_INET6, &addr.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
            return converted.map { String(cString: $0) }
        }
        return nil
    }

    static func boundPort(for socket: Int32) throws -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &length)
            }
        }
        guard result == 0 else {
            throw RemoteShellError.socketError(code: Int32(errno), message: String(cString: strerror(errno)))
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
