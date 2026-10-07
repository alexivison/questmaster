import Foundation

/// Reads the `font-family` list the way Ghostty builds it from its config files, as pure functions over
/// file contents so the load order, includes and list semantics are testable.
public enum GhosttyConfigParser {
    private static let maxIncludeDepth = 10

    private enum Entry {
        case fontFamily(String)
        case windowPaddingX(String)
        case windowPaddingY(String)
        case include(String)
    }

    /// The ordered `font-family` list after loading `directories` in order (Ghostty reads `config.ghostty`
    /// and then `config` in each). The key repeats: every line appends a fallback, and an empty value
    /// clears the list. A file's `config-file` includes are read after the file itself.
    public static func fontFamilies(inDirectories directories: [String], read: (String) -> String?) -> [String] {
        var families: [String] = []
        for case .fontFamily(let value) in allEntries(inDirectories: directories, read: read) {
            apply(value, to: &families)
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

    /// The last `window-padding-x`/`-y` set across `directories`' config files — Ghostty's own
    /// "last one wins" semantics for a non-repeating key, unlike `font-family`'s fallback list.
    /// `nil` for an axis nothing set (not the same as an explicit `0`).
    ///
    /// Ghostty also accepts a two-value form (`"10,20"`, left/top and right/bottom padding) —
    /// this shell has one gap per axis, not a separate leading/trailing one, so only the first
    /// value is used; a malformed or empty component gives `nil` for that line rather than a
    /// wrong number.
    public static func windowPadding(inDirectories directories: [String], read: (String) -> String?) -> (x: Double, y: Double)? {
        var x: Double?
        var y: Double?
        for entry in allEntries(inDirectories: directories, read: read) {
            switch entry {
            case .windowPaddingX(let value): x = firstComponent(of: value) ?? x
            case .windowPaddingY(let value): y = firstComponent(of: value) ?? y
            default: break
            }
        }
        guard let x, let y else {
            return nil
        }
        return (x, y)
    }

    /// `"10"` or the first of `"10,20"` — never a comma-joined string parsed whole, which would
    /// silently fail `Double(_:)` and leave the previous value in place.
    private static func firstComponent(of value: String) -> Double? {
        guard let first = value.split(separator: ",").first else {
            return nil
        }
        return Double(first.trimmingCharacters(in: .whitespaces))
    }

    /// The first family the system can resolve, so an uninstalled primary falls through to its fallbacks.
    public static func firstInstalled(of families: [String], isInstalled: (String) -> Bool) -> String? {
        families.first(where: isInstalled)
    }

    private static func allEntries(inDirectories directories: [String], read: (String) -> String?) -> [Entry] {
        var all: [Entry] = []
        for directory in directories {
            for name in ["config.ghostty", "config"] {
                load("\(directory)/\(name)", depth: 0, stack: [], into: &all, read: read)
            }
        }
        return all
    }

    private static func load(_ path: String, depth: Int, stack: [String], into all: inout [Entry], read: (String) -> String?) {
        guard depth <= maxIncludeDepth, !stack.contains(path), let text = read(path) else {
            return
        }
        let fileEntries = entries(in: text)
        all.append(contentsOf: fileEntries)
        let directory = (path as NSString).deletingLastPathComponent
        for case .include(let include) in fileEntries {
            let optionalStripped = include.hasPrefix("?") ? String(include.dropFirst()) : include
            let target = optionalStripped.hasPrefix("/") ? optionalStripped : "\(directory)/\(optionalStripped)"
            load((target as NSString).standardizingPath, depth: depth + 1, stack: stack + [path], into: &all, read: read)
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
            case "window-padding-x": entries.append(.windowPaddingX(value))
            case "window-padding-y": entries.append(.windowPaddingY(value))
            case "config-file": entries.append(.include(value))
            default: break
            }
        }
        return entries
    }
}
