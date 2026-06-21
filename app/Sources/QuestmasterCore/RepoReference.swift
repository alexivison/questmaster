import Foundation

public struct RepoReference: Decodable {
    public var identity: String
    public var name: String
    public var color: String
    public var path: String

    public init(identity: String = "", name: String = "", color: String = "", path: String = "") {
        self.identity = identity
        self.name = name.isEmpty ? identity : name
        self.color = color
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case identity
        case id
        case name
        case repo
        case color
        case path
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let repoName = try? container.decode(String.self) {
            self.init(identity: repoName, name: repoName)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let identity = try container.decodeIfPresent(String.self, forKey: .identity)
            ?? container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decodeIfPresent(String.self, forKey: .repo)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? ""
        let name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .repo)
            ?? identity
        let color = try container.decodeIfPresent(String.self, forKey: .color) ?? ""
        let path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        self.init(identity: identity, name: name, color: color, path: path)
    }
}
