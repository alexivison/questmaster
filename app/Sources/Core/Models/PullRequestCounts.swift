import Foundation

/// The known git states in a master's live watch scope; zero states may be absent on the wire. An open or draft PR with
/// merge conflicts counts under `conflicts` instead of `open` or `draft`, so each PR counts once.
public struct PullRequestCounts: Decodable, Equatable {
    public let conflicts: Int
    public let open: Int
    public let draft: Int
    public let merged: Int
    public let closed: Int

    public init(conflicts: Int = 0, open: Int = 0, draft: Int = 0, merged: Int = 0, closed: Int = 0) {
        self.conflicts = conflicts
        self.open = open
        self.draft = draft
        self.merged = merged
        self.closed = closed
    }

    private enum CodingKeys: String, CodingKey {
        case conflicts, open, draft, merged, closed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conflicts = try container.decodeIfPresent(Int.self, forKey: .conflicts) ?? 0
        open = try container.decodeIfPresent(Int.self, forKey: .open) ?? 0
        draft = try container.decodeIfPresent(Int.self, forKey: .draft) ?? 0
        merged = try container.decodeIfPresent(Int.self, forKey: .merged) ?? 0
        closed = try container.decodeIfPresent(Int.self, forKey: .closed) ?? 0
    }
}
