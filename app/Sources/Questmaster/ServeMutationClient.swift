import Darwin
import Foundation
import QuestmasterCore

struct ServeMutationAck {
    let data: Any?

    var sessionID: String? {
        guard let data = data as? [String: Any] else {
            return nil
        }
        let value = data["session_id"] as? String ?? data["id"] as? String
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean?.isEmpty == false ? clean : nil
    }
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
    private static let responseTimeoutSeconds = 35

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
        let fd = try UnixSocketIO.connect(path: socketPath)
        defer {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }

        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0a)
        try UnixSocketIO.setReadTimeout(on: fd, seconds: responseTimeoutSeconds)
        try UnixSocketIO.write(data, to: fd)
        let line = try readLine(from: fd)
        return try decodeAck(line)
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
