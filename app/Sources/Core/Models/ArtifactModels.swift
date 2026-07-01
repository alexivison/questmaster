import Foundation

public struct ArtifactReference: Decodable, Equatable, Identifiable {
    public var id: String { path }
    public var resolvedKind: ArtifactKind { ArtifactKind.classify(kind: kind, path: path) }
    public var kind: String
    public var path: String
    public var label: String
    public var addedAt: String
    public var missing: Bool

    public init(kind: String, path: String, label: String, addedAt: String, missing: Bool = false) {
        self.kind = kind
        self.path = path
        self.label = label
        self.addedAt = addedAt
        self.missing = missing
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case label
        case added_at
        case missing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "html"
        label = try container.decodeIfPresent(String.self, forKey: .label)
            ?? URL(fileURLWithPath: path).lastPathComponent
        addedAt = try container.decodeIfPresent(String.self, forKey: .added_at) ?? ""
        missing = try container.decodeIfPresent(Bool.self, forKey: .missing) ?? false
    }
}
