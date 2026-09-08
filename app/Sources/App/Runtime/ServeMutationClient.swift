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

/// The serve `models` response: what the backend resolved for one agent and
/// role, plus the role default it would apply on its own.
struct ModelSuggestionResponse {
    let models: [SessionModelOption]
    let defaultModel: String
}

/// The serve `reasoning_efforts` response: the levels one agent/role/model
/// accepts, plus the level the harness applies on its own (empty when it
/// forces none, like OpenCode with no override).
struct ReasoningEffortSuggestionResponse {
    let efforts: [String]
    let defaultEffort: String
}

protocol ServeMutationSending: AnyObject {
    func send(_ request: ServeMutationRequest, completion: @escaping (Result<ServeMutationAck, Error>) -> Void)
}

protocol ServeDirectorySuggesting: AnyObject {
    func suggestDirectories(query: String, completion: @escaping (Result<DirectorySuggestionResponse, Error>) -> Void)
}

protocol ServeModelSuggesting: AnyObject {
    /// `refresh` forces the backend to bypass its catalog cache (models.dev is
    /// refetched even if the cached copy is still within its TTL). Pass it only
    /// for an explicit user refresh action — the sheet's normal resolves
    /// (opening, agent/role changes) leave it false and take the cache.
    func suggestModels(
        agent: String,
        role: String,
        refresh: Bool,
        completion: @escaping (Result<ModelSuggestionResponse, Error>) -> Void
    )
}

protocol ServeReasoningEffortSuggesting: AnyObject {
    func suggestReasoningEfforts(
        agent: String,
        role: String,
        model: String,
        completion: @escaping (Result<ReasoningEffortSuggestionResponse, Error>) -> Void
    )
}

final class UnixSocketMutationClient: ServeMutationSending {
    private let socketPath: String
    private let queue = DispatchQueue(label: "Questmaster.UnixSocketMutationClient")
    /// Model resolution can ask a harness to enumerate its own models, which
    /// means waiting on a subprocess. It gets its own queue so a slow harness
    /// never delays the mutation the user is actually waiting on.
    private let modelQueue = DispatchQueue(label: "Questmaster.UnixSocketMutationClient.models")
    private static let responseTimeoutSeconds = 35
    /// Mirrors UnixSocketServeClient's own backoff schedule: the app-launched
    /// `qm serve` can take a few seconds to bind its socket (see
    /// ServeProcess.waitForSocket), and this client has no equivalent
    /// reconnect loop of its own — a New Session sheet opened (or a menu
    /// mutation fired) in that window would otherwise fail once, silently,
    /// with nothing to prompt a second try. Retried only before any bytes are
    /// written, so a mutation already in flight is never repeated.
    static let connectRetryDelays: [TimeInterval] = [0, 0.15, 0.3, 0.6, 1.0]

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

    /// `connect`/`sleep` are injectable so LogicSelfTests can prove the
    /// retry/give-up behavior without a real socket or real delays.
    static func connectWithRetry(
        socketPath: String,
        connect: (String) throws -> Int32 = UnixSocketIO.connect,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws -> Int32 {
        var lastError: Error = ServeClientError.connect("unknown connection failure")
        for delay in connectRetryDelays {
            if delay > 0 {
                sleep(delay)
            }
            do {
                return try connect(socketPath)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func sendObject(_ object: [String: Any], socketPath: String) throws -> ServeMutationAck {
        let fd = try connectWithRetry(socketPath: socketPath)
        defer {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }

        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0a)
        try UnixSocketIO.setReadTimeout(on: fd, seconds: responseTimeoutSeconds)
        try UnixSocketIO.write(data, to: fd)
        let line = try UnixSocketIO.readLine(from: fd)
        return try decodeAck(line)
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

extension UnixSocketMutationClient: ServeModelSuggesting {
    /// The picker is cycled with ←/→, so it asks for a ranked head of the list
    /// (recents, aliases, then newest first) rather than every model a harness
    /// could run — `questmaster models` is the exhaustive view.
    private static let modelSuggestionLimit = 20

    func suggestModels(
        agent: String,
        role: String,
        refresh: Bool,
        completion: @escaping (Result<ModelSuggestionResponse, Error>) -> Void
    ) {
        modelQueue.async { [socketPath] in
            do {
                let ack = try Self.sendObject([
                    "id": UUID().uuidString,
                    "method": "models",
                    "data": [
                        "agent": agent,
                        "role": role,
                        "limit": Self.modelSuggestionLimit,
                        "refresh": refresh,
                    ] as [String: Any],
                ], socketPath: socketPath)
                guard let data = ack.data as? [String: Any] else {
                    throw ServeClientError.protocolError("models response missing data")
                }
                completion(.success(ModelSuggestionResponse(
                    models: Self.modelOptions(data["models"]),
                    defaultModel: data["default"] as? String ?? ""
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func modelOptions(_ value: Any?) -> [SessionModelOption] {
        guard let rows = value as? [Any] else {
            return []
        }
        return rows.compactMap { row in
            guard let row = row as? [String: Any],
                  let id = (row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else {
                return nil
            }
            let rawLabel = (row["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return SessionModelOption(
                id: id,
                label: rawLabel.isEmpty ? id : rawLabel,
                note: row["note"] as? String ?? ""
            )
        }
    }
}

extension UnixSocketMutationClient: ServeReasoningEffortSuggesting {
    func suggestReasoningEfforts(
        agent: String,
        role: String,
        model: String,
        completion: @escaping (Result<ReasoningEffortSuggestionResponse, Error>) -> Void
    ) {
        modelQueue.async { [socketPath] in
            do {
                let ack = try Self.sendObject([
                    "id": UUID().uuidString,
                    "method": "reasoning_efforts",
                    "data": [
                        "agent": agent,
                        "role": role,
                        "model": model,
                    ] as [String: Any],
                ], socketPath: socketPath)
                guard let data = ack.data as? [String: Any] else {
                    throw ServeClientError.protocolError("reasoning_efforts response missing data")
                }
                completion(.success(ReasoningEffortSuggestionResponse(
                    efforts: Self.stringArray(data["efforts"]),
                    defaultEffort: data["default"] as? String ?? ""
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
