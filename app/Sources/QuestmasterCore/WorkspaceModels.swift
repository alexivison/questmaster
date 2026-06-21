import Foundation

public struct RuntimeViewerItem: Decodable {
    public var id: String
    public var type: String
    public var title: String
    public var questID: String
    public var path: String
    public var url: String
    public var html: String

    public var normalizedType: String {
        let explicit = type.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return RuntimeViewerTypeNormalizer.normalizedType(explicit)
        }
        if !questID.isEmpty {
            return "quest"
        }
        if isHTMLPath(path) || isHTMLPath(url) {
            return "html"
        }
        return "unknown"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case viewerType
        case viewer_type
        case contentType
        case content_type
        case title
        case questID
        case quest_id
        case path
        case file
        case url
        case html
        case content
    }

    public init(
        id: String = "",
        type: String,
        title: String,
        questID: String = "",
        path: String = "",
        url: String = "",
        html: String = ""
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.questID = questID
        self.path = path
        self.url = url
        self.html = html
    }

    public static func workspace(_ item: WorkspaceItem) -> RuntimeViewerItem {
        RuntimeViewerItem(
            id: item.id,
            type: item.type,
            title: item.displayTitle,
            path: item.artifact.path,
            html: item.artifact.inline
        )
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let raw = try? container.decode(String.self) {
            id = raw
            type = isHTMLPath(raw) ? "html" : "unknown"
            title = raw
            questID = ""
            path = raw
            url = ""
            html = ""
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type)
            ?? container.decodeIfPresent(String.self, forKey: .viewerType)
            ?? container.decodeIfPresent(String.self, forKey: .viewer_type)
            ?? container.decodeIfPresent(String.self, forKey: .contentType)
            ?? container.decodeIfPresent(String.self, forKey: .content_type)
            ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        questID = try container.decodeIfPresent(String.self, forKey: .questID)
            ?? container.decodeIfPresent(String.self, forKey: .quest_id)
            ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path)
            ?? container.decodeIfPresent(String.self, forKey: .file)
            ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        html = try container.decodeIfPresent(String.self, forKey: .html)
            ?? container.decodeIfPresent(String.self, forKey: .content)
            ?? ""
    }
}

public struct ItemsPayload: Decodable {
    public var items: [WorkspaceItem]
    public var observedLabel: String

    private enum CodingKeys: String, CodingKey {
        case items
        case observedAt
        case observed_at
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = container.decodeLossyArray(WorkspaceItem.self, forKey: .items)
        observedLabel = try container.decodeIfPresent(String.self, forKey: .observedAt)
            ?? container.decodeIfPresent(String.self, forKey: .observed_at)
            ?? ""
    }
}

public struct WorkspaceItem: Decodable {
    public var id: String
    public var type: String
    public var title: String
    public var createdAt: String
    public var artifact: WorkspaceArtifact
    public var loose: Bool
    public var attachmentCount: Int
    public var questIDs: [String]

    public var displayTitle: String {
        title.isEmpty ? id : title
    }

    public var metaLabel: String {
        let usage = loose ? "loose" : "\(attachmentCount) quest\(attachmentCount == 1 ? "" : "s")"
        let source: String
        if !artifact.path.isEmpty {
            source = URL(fileURLWithPath: artifact.path).lastPathComponent
        } else if !artifact.inline.isEmpty {
            source = "inline"
        } else {
            source = "empty"
        }
        return "\(type.isEmpty ? "unknown" : type)  \(usage)  \(source)"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case createdAt
        case created_at
        case artifact
        case path
        case inline
        case html
        case content
        case loose
        case attachmentCount
        case attachment_count
        case questIDs
        case quest_ids
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            ?? container.decodeIfPresent(String.self, forKey: .created_at)
            ?? ""
        artifact = try container.decodeIfPresent(WorkspaceArtifact.self, forKey: .artifact)
            ?? WorkspaceArtifact(
                path: try container.decodeIfPresent(String.self, forKey: .path) ?? "",
                inline: try container.decodeIfPresent(String.self, forKey: .inline)
                    ?? container.decodeIfPresent(String.self, forKey: .html)
                    ?? container.decodeIfPresent(String.self, forKey: .content)
                    ?? ""
            )
        loose = try container.decodeIfPresent(Bool.self, forKey: .loose) ?? false
        attachmentCount = try container.decodeIfPresent(Int.self, forKey: .attachmentCount)
            ?? container.decodeIfPresent(Int.self, forKey: .attachment_count)
            ?? 0
        questIDs = try container.decodeIfPresent([String].self, forKey: .questIDs)
            ?? container.decodeIfPresent([String].self, forKey: .quest_ids)
            ?? []
    }
}

public struct WorkspaceArtifact: Decodable {
    public var path: String
    public var inline: String

    public init(path: String = "", inline: String = "") {
        self.path = path
        self.inline = inline
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case inline
        case html
        case content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        inline = try container.decodeIfPresent(String.self, forKey: .inline)
            ?? container.decodeIfPresent(String.self, forKey: .html)
            ?? container.decodeIfPresent(String.self, forKey: .content)
            ?? ""
    }
}

private func isHTMLPath(_ value: String) -> Bool {
    let lower = value.lowercased()
    return lower.hasSuffix(".html") || lower.hasSuffix(".htm")
}

public enum RuntimeViewerTypeNormalizer {
    public static func normalizedType(_ type: String) -> String {
        switch type.lowercased() {
        case "quest":
            return "quest"
        case "html", "htm", "text/html", "workspace_html", "workspace-html", "file.html":
            return "html"
        default:
            return type.lowercased()
        }
    }
}
