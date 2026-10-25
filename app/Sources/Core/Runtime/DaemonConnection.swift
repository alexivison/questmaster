import Foundation

public struct DaemonRecord: Decodable, Equatable {
    public let running: Bool
    public let root: String
    public let identity: String
    public let socket: String
    public let executable: String
    public let shimDirectory: String
    public let build: String
    public let generation: Int
    public let accepting: Bool

    private enum CodingKeys: String, CodingKey {
        case running, root, identity, socket, executable, build, generation, accepting
        case shimDirectory = "shim_directory"
    }

    public func shouldCheckUpgrade(diskBuild: String?) -> Bool {
        guard let diskBuild, !diskBuild.isEmpty else { return false }
        return build != diskBuild
    }
}

public struct DaemonHandshake: Decodable {
    public let root: String
    public let identity: String
    public let protocolVersion: Int
    public let accepting: Bool

    private enum CodingKeys: String, CodingKey {
        case root, identity, accepting
        case protocolVersion = "protocol_version"
    }

    public func validate(against record: DaemonRecord) throws {
        guard root == record.root, identity == record.identity else {
            throw ServeClientError.protocolError("daemon identity mismatch")
        }
        try ServeContract.requireProtocolVersion(protocolVersion)
        guard accepting else {
            throw ServeClientError.protocolError("backend finishing a previous operation")
        }
    }
}

public enum DaemonWaitingStatus {
    public static func message(after seconds: TimeInterval) -> String {
        seconds >= 5 ? "backend finishing a previous operation" : "connecting to backend..."
    }
}
