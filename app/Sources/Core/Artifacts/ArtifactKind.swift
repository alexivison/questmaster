import Foundation

public enum ArtifactKind: Equatable {
    case html
    case markdown
    case image
    case unsupported(String)

    public static func classify(kind: String, path: String) -> ArtifactKind {
        let cleanKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !cleanKind.isEmpty {
            return from(cleanKind)
        }
        return fromExtension(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    public var isRenderable: Bool {
        switch self {
        case .html, .markdown, .image:
            return true
        case .unsupported:
            return false
        }
    }

    /// Whether a new artifact of this kind opens in the viewer by itself. HTML runs script, so it waits for a click.
    public var opensAutomatically: Bool {
        switch self {
        case .markdown, .image:
            return true
        case .html, .unsupported:
            return false
        }
    }

    private static func from(_ kind: String) -> ArtifactKind {
        switch kind {
        case "html":
            return .html
        case "markdown":
            return .markdown
        case "image":
            return .image
        default:
            return .unsupported(kind)
        }
    }

    private static func fromExtension(_ ext: String) -> ArtifactKind {
        switch ext {
        case "html", "htm":
            return .html
        case "md", "markdown":
            return .markdown
        case "png", "jpg", "jpeg", "gif", "webp", "svg":
            return .image
        default:
            return .html
        }
    }
}
