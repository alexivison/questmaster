import Darwin
import Foundation

enum UnixSocketIO {
    static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ServeClientError.connect(String(cString: strerror(errno)))
        }
        do {
            try withAddress(path) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else {
                    throw ServeClientError.connect(String(cString: strerror(errno)))
                }
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    static func withAddress<T>(
        _ socketPath: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw ServeClientError.connect("socket path is too long")
        }

        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { path in
                for index in 0..<capacity {
                    path[index] = 0
                }
                for (index, byte) in pathBytes.enumerated() {
                    path[index] = CChar(bitPattern: byte)
                }
            }
        }

        var copy = address
        return try withUnsafePointer(to: &copy) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                try body(sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written < 0 {
                    throw ServeClientError.write(String(cString: strerror(errno)))
                }
                if written == 0 {
                    throw ServeClientError.write("socket write made no progress")
                }
                offset += written
            }
        }
    }

    static func setReadTimeout(on fd: Int32, seconds: Int) throws {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let result = withUnsafePointer(to: &timeout) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<timeval>.size) { raw in
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, raw, socklen_t(MemoryLayout<timeval>.size))
            }
        }
        if result != 0 {
            throw ServeClientError.protocolError("set socket read timeout: \(String(cString: strerror(errno)))")
        }
    }
}
