import Foundation

public enum ArtifactNavigationDecision: Equatable {
    case allowFile
    case openExternal(URL)
    case block
}

public enum ArtifactNavigationPolicy {
    public static func decide(url: URL?, userInitiated: Bool) -> ArtifactNavigationDecision {
        guard let url else {
            return .block
        }
        if url.isFileURL {
            return .allowFile
        }
        let scheme = url.scheme?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if userInitiated, scheme == "http" || scheme == "https" {
            return .openExternal(url)
        }
        return .block
    }
}
