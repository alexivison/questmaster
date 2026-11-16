import Foundation

/// The known git states in a master's live watch scope; zero states may be absent on the wire.
public struct PullRequestCounts: Decodable, Equatable {
    public let open: Int
    public let draft: Int
    public let merged: Int
    public let closed: Int

    public init(open: Int = 0, draft: Int = 0, merged: Int = 0, closed: Int = 0) {
        self.open = open
        self.draft = draft
        self.merged = merged
        self.closed = closed
    }

    private enum CodingKeys: String, CodingKey {
        case open, draft, merged, closed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        open = try container.decodeIfPresent(Int.self, forKey: .open) ?? 0
        draft = try container.decodeIfPresent(Int.self, forKey: .draft) ?? 0
        merged = try container.decodeIfPresent(Int.self, forKey: .merged) ?? 0
        closed = try container.decodeIfPresent(Int.self, forKey: .closed) ?? 0
    }
}
