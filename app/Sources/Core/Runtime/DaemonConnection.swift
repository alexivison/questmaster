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

/// The daemon binary's hash, kept while the file keeps its path, size and modification time, so a record miss (after
/// every dropped connection) doesn't read and hash the whole binary again.
public struct BinaryHashCache {
    public struct Fingerprint: Equatable {
        public let path: String
        public let size: UInt64
        public let modified: Date

        public init(path: String, size: UInt64, modified: Date) {
            self.path = path
            self.size = size
            self.modified = modified
        }
    }

    private var cached: (fingerprint: Fingerprint, hash: String)?

    public init() {}

    /// The hash of the file `fingerprint` describes, from `compute` only when it differs from the last file hashed. A
    /// file that can't be read (no fingerprint, or no hash) has no hash, and nothing is kept for it.
    public mutating func hash(of fingerprint: Fingerprint?, compute: () -> String?) -> String? {
        guard let fingerprint else {
            return nil
        }
        if let cached, cached.fingerprint == fingerprint {
            return cached.hash
        }
        guard let hash = compute() else {
            return nil
        }
        cached = (fingerprint, hash)
        return hash
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
