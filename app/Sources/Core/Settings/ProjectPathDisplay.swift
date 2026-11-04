import Foundation

/// A project's folder as the Projects list shows it: the home directory written as `~`.
public enum ProjectPathDisplay {
    public static func shortened(_ path: String, homeDirectory: String) -> String {
        let home = homeDirectory.count > 1 && homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else {
            return path
        }
        return "~" + String(path.dropFirst(home.count))
    }
}
