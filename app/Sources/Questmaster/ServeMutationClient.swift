import Darwin
import Foundation
import QuestmasterCore

struct ServeMutationAck {
    let data: Any?
}

struct DirectorySuggestionResponse {
    let suggestions: [String]
    let recents: [String]
}

protocol ServeMutationSending: AnyObject {
    func send(_ request: ServeMutationRequest, completion: @escaping (Result<ServeMutationAck, Error>) -> Void)
}

protocol ServeDirectorySuggesting: AnyObject {
    func suggestDirectories(query: String, completion: @escaping (Result<DirectorySuggestionResponse, Error>) -> Void)
}

final class UnixSocketMutationClient: ServeMutationSending {
    private let socketPath: String
    private let queue = DispatchQueue(label: "Questmaster.UnixSocketMutationClient")
    private static let responseTimeoutSeconds = 30

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func send(_ request: ServeMutationRequest, completion: @escaping (Result<ServeMutationAck, Error>) -> Void) {
        queue.async { [socketPath] in
            do {
                let id = UUID().uuidString
                let ack = try Self.sendObject(request.jsonObject(id: id), socketPath: socketPath)
                completion(.success(ack))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func sendObject(_ object: [String: Any], socketPath: String) throws -> ServeMutationAck {
        let fd = try connectSocket(path: socketPath)
        defer {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }

        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0a)
        try setReadTimeout(on: fd, seconds: responseTimeoutSeconds)
        try write(data, to: fd)
        let line = try readLine(from: fd)
        return try decodeAck(line)
    }

    private static func connectSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ServeClientError.connect(String(cString: strerror(errno)))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw ServeClientError.connect("socket path is too long")
        }

        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { target in
                for index in 0..<capacity {
                    target[index] = 0
                }
                for (index, byte) in pathBytes.enumerated() {
                    target[index] = CChar(bitPattern: byte)
                }
            }
        }

        var copy = address
        let result = withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw ServeClientError.connect(message)
        }
        return fd
    }

    private static func write(_ data: Data, to fd: Int32) throws {
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
                offset += written
            }
        }
    }

    private static func setReadTimeout(on fd: Int32, seconds: Int) throws {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let result = withUnsafePointer(to: &timeout) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<timeval>.size) { raw in
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, raw, socklen_t(MemoryLayout<timeval>.size))
            }
        }
        if result != 0 {
            throw ServeClientError.protocolError("set mutation read timeout: \(String(cString: strerror(errno)))")
        }
    }

    private static func readLine(from fd: Int32) throws -> Data {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 {
                throw ServeClientError.protocolError("serve closed before mutation response")
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw ServeClientError.protocolError("mutation response timed out")
                }
                throw ServeClientError.protocolError(String(cString: strerror(errno)))
            }
            pending.append(buffer, count: count)
            if let newline = pending.firstRange(of: Data([0x0a])) {
                return pending.subdata(in: pending.startIndex..<newline.lowerBound)
            }
        }
    }

    private static func decodeAck(_ line: Data) throws -> ServeMutationAck {
        guard !line.isEmpty,
              let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw ServeClientError.protocolError("mutation response is not a JSON object")
        }
        if object["type"] as? String == "response", object["ok"] as? Bool == false {
            throw ServeClientError.protocolError(object["error"] as? String ?? "mutation failed")
        }
        guard object["type"] as? String == "response", object["ok"] as? Bool == true else {
            throw ServeClientError.protocolError("mutation response was not an ok response")
        }
        return ServeMutationAck(data: object["data"])
    }
}

extension UnixSocketMutationClient: ServeDirectorySuggesting {
    func suggestDirectories(query: String, completion: @escaping (Result<DirectorySuggestionResponse, Error>) -> Void) {
        queue.async { [socketPath] in
            do {
                let ack = try Self.sendObject([
                    "id": UUID().uuidString,
                    "method": "dir_suggest",
                    "data": ["query": query],
                ], socketPath: socketPath)
                guard let data = ack.data as? [String: Any] else {
                    throw ServeClientError.protocolError("dir_suggest response missing data")
                }
                completion(.success(DirectorySuggestionResponse(
                    suggestions: Self.stringArray(data["suggestions"]),
                    recents: Self.stringArray(data["recents"])
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }
}
