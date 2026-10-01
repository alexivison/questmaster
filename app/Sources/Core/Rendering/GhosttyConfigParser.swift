import Foundation

/// Reads the `font-family` list the way Ghostty builds it from its config files, as pure functions over
/// file contents so the load order, includes and list semantics are testable.
public enum GhosttyConfigParser {
    private static let maxIncludeDepth = 10

    private enum Entry {
        case fontFamily(String)
        case include(String)
    }

    /// The ordered `font-family` list after loading `directories` in order (Ghostty reads `config.ghostty`
    /// and then `config` in each). The key repeats: every line appends a fallback, and an empty value
    /// clears the list. A file's `config-file` includes are read after the file itself.
    public static func fontFamilies(inDirectories directories: [String], read: (String) -> String?) -> [String] {
        var families: [String] = []
        for directory in directories {
            for name in ["config.ghostty", "config"] {
                load("\(directory)/\(name)", depth: 0, stack: [], families: &families, read: read)
            }
        }
        return families
    }

    public static func fontFamilies(in text: String) -> [String] {
        var families: [String] = []
        for case .fontFamily(let value) in entries(in: text) {
            apply(value, to: &families)
        }
        return families
    }

    /// The first family the system can resolve, so an uninstalled primary falls through to its fallbacks.
    public static func firstInstalled(of families: [String], isInstalled: (String) -> Bool) -> String? {
        families.first(where: isInstalled)
    }

    private static func load(_ path: String, depth: Int, stack: [String], families: inout [String], read: (String) -> String?) {
        guard depth <= maxIncludeDepth, !stack.contains(path), let text = read(path) else {
            return
        }
        var includes: [String] = []
        for entry in entries(in: text) {
            switch entry {
            case .fontFamily(let value): apply(value, to: &families)
            case .include(let value): includes.append(value)
            }
        }
        let directory = (path as NSString).deletingLastPathComponent
        for include in includes {
            let optionalStripped = include.hasPrefix("?") ? String(include.dropFirst()) : include
            let target = optionalStripped.hasPrefix("/") ? optionalStripped : "\(directory)/\(optionalStripped)"
            load((target as NSString).standardizingPath, depth: depth + 1, stack: stack + [path], families: &families, read: read)
        }
    }

    private static func apply(_ value: String, to families: inout [String]) {
        if value.isEmpty {
            families.removeAll()
        } else {
            families.append(value)
        }
    }

    private static func entries(in text: String) -> [Entry] {
        var entries: [Entry] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            switch key {
            case "font-family": entries.append(.fontFamily(value))
            case "config-file": entries.append(.include(value))
            default: break
            }
        }
        return entries
    }
}
