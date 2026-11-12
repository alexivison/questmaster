import Darwin
import Foundation
import QuestmasterCore

enum UnixSocketIO {
    static var pathCapacity: Int {
        let address = sockaddr_un()
        return MemoryLayout.size(ofValue: address.sun_path)
    }

    static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ServeClientError.connect(String(cString: strerror(errno)))
        }
        // A write after the other end has gone (the daemon hung up, or the serve client's stop shut the socket down)
        // must fail, not raise SIGPIPE, which the app doesn't ignore. It is set before connecting, as a socket that is
        // already disconnected refuses it.
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
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

    /// Reads from `fd` until the first newline and returns the bytes before it (newline excluded).
    /// Shared by one-shot request/response callers; the streaming client keeps its own buffered
    /// read loop because it must retain bytes across many lines.
    static func readLine(from fd: Int32, maxBytes: Int? = nil) throws -> Data {
        try readLine(from: fd, maxBytes: maxBytes, deadline: nil, isCancelled: { false })
    }

    /// Reads a bounded handshake line while a stop signal can interrupt the wait. The socket owner also shuts down
    /// `fd` on cancellation, which wakes `poll` immediately instead of waiting out the deadline.
    static func readLine(
        from fd: Int32,
        maxBytes: Int?,
        timeout: TimeInterval,
        isCancelled: () -> Bool
    ) throws -> Data {
        try readLine(from: fd, maxBytes: maxBytes, deadline: DispatchTime.now() + timeout, isCancelled: isCancelled)
    }

    private static func readLine(
        from fd: Int32,
        maxBytes: Int?,
        deadline: DispatchTime?,
        isCancelled: () -> Bool
    ) throws -> Data {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if isCancelled() {
                throw CancellationError()
            }
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waitMilliseconds: Int32
            if let deadline {
                let now = DispatchTime.now().uptimeNanoseconds
                let remaining = deadline.uptimeNanoseconds > now ? deadline.uptimeNanoseconds - now : 0
                let roundedMilliseconds = remaining == 0 ? 0 : (remaining + 999_999) / 1_000_000
                waitMilliseconds = Int32(min(roundedMilliseconds, UInt64(Int32.max)))
            } else {
                waitMilliseconds = -1
            }
            let readyCount = poll(&ready, 1, waitMilliseconds)
            if readyCount < 0 {
                if errno == EINTR { continue }
                throw ServeClientError.protocolError(String(cString: strerror(errno)))
            }
            if isCancelled() {
                throw CancellationError()
            }
            if readyCount == 0 {
                throw ServeClientError.protocolError("socket read timed out")
            }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 {
                if isCancelled() { throw CancellationError() }
                throw ServeClientError.protocolError("socket closed before a full line was read")
            }
            if count < 0 {
                if errno == EINTR { continue }
                if isCancelled() { throw CancellationError() }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw ServeClientError.protocolError("socket read timed out")
                }
                throw ServeClientError.protocolError(String(cString: strerror(errno)))
            }
            // Only the new bytes can hold the newline; rescanning the whole buffer made a large reply quadratic.
            let scanStart = pending.endIndex
            pending.append(buffer, count: count)
            if let maxBytes, pending.count > maxBytes {
                throw ServeClientError.protocolError("socket line exceeded \(maxBytes) bytes")
            }
            if let newline = pending[scanStart...].firstIndex(of: 0x0a) {
                return pending.subdata(in: pending.startIndex..<newline)
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
