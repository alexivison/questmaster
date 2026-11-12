import Foundation

/// Reads the settings and file list used by the bundled Ghostty config loader, as pure functions over file contents.
public enum GhosttyConfigParser {
    private enum Entry {
        case fontFamily(String)
        case windowPaddingX(String)
        case windowPaddingY(String)
        case include(String)
        case resetIncludes
    }

    /// The ordered `font-family` list after loading default files in directory order, then queued includes.
    /// Ghostty reads `config` before `config.ghostty` in each directory. The key repeats: every line appends
    /// a fallback, and an empty value clears the list.
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

    /// The readable files loaded by the bundled Ghostty precedence and include traversal.
    public static func loadedFiles(
        inDirectories directories: [String],
        homeDirectory: String = NSHomeDirectory(),
        read: (String) -> String?
    ) -> [String] {
        loadConfiguration(inDirectories: directories, homeDirectory: homeDirectory, read: read).paths
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
        loadConfiguration(inDirectories: directories, homeDirectory: NSHomeDirectory(), read: read).entries
    }

    private struct Include {
        let path: String
        let relativeTo: String
    }

    private static func loadConfiguration(
        inDirectories directories: [String],
        homeDirectory: String,
        read: (String) -> String?
    ) -> (entries: [Entry], paths: [String]) {
        var all: [Entry] = []
        var paths: [String] = []
        var includes: [Include] = []

        for directory in directories {
            for name in ["config", "config.ghostty"] {
                let path = "\(directory)/\(name)"
                guard let text = read(path) else {
                    continue
                }
                paths.append(path)
                let fileEntries = entries(in: text)
                all.append(contentsOf: fileEntries)
                appendIncludes(from: fileEntries, relativeTo: directory, into: &includes)
            }
        }

        var includeIndex = 0
        var loadedIncludes: Set<String> = []
        while includeIndex < includes.count {
            let include = includes[includeIndex]
            includeIndex += 1

            let path = resolve(include.path, relativeTo: include.relativeTo, homeDirectory: homeDirectory)
            guard loadedIncludes.insert(path).inserted, let text = read(path) else {
                continue
            }

            paths.append(path)
            let fileEntries = entries(in: text)
            all.append(contentsOf: fileEntries)
            appendIncludes(from: fileEntries, relativeTo: (path as NSString).deletingLastPathComponent, into: &includes)
        }

        return (all, paths)
    }

    private static func appendIncludes(from entries: [Entry], relativeTo directory: String, into includes: inout [Include]) {
        for entry in entries {
            switch entry {
            case .include(let path):
                includes.append(Include(path: path, relativeTo: directory))
            case .resetIncludes:
                includes.removeAll(keepingCapacity: true)
            default:
                break
            }
        }
    }

    private static func resolve(_ path: String, relativeTo directory: String, homeDirectory: String) -> String {
        if path.hasPrefix("~/") {
            let expanded = homeDirectory + "/" + String(path.dropFirst(2))
            return (expanded as NSString).standardizingPath
        }
        let target = path.hasPrefix("/") ? path : "\(directory)/\(path)"
        return (target as NSString).standardizingPath
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
            let rawValue = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            switch key {
            case "font-family": entries.append(.fontFamily(value))
            case "window-padding-x": entries.append(.windowPaddingX(value))
            case "window-padding-y": entries.append(.windowPaddingY(value))
            case "config-file":
                if rawValue.isEmpty {
                    entries.append(.resetIncludes)
                } else if let include = includeEntry(rawValue) {
                    entries.append(include)
                }
            default: break
            }
        }
        return entries
    }

    /// Matches Ghostty's repeatable path parsing: blank clears the list, while empty optional or quoted paths are ignored.
    private static func includeEntry(_ rawValue: String) -> Entry? {
        var value = rawValue
        if value.hasPrefix("?") {
            value = String(value.dropFirst())
        }
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty else {
            return nil
        }
        return .include(value)
    }
}
