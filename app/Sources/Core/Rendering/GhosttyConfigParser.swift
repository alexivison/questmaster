import Foundation

public enum GhosttyConfigParser {
    /// The primary `font-family` of a Ghostty config: Ghostty treats the key as a list (the first entry
    /// is the primary font, later ones are fallbacks) and an empty value clears the list.
    public static func primaryFontFamily(in configText: String) -> String? {
        var families: [String] = []
        for rawLine in configText.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
                continue
            }
            guard line[..<separator].trimmingCharacters(in: .whitespaces) == "font-family" else {
                continue
            }
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if value.isEmpty {
                families.removeAll()
            } else {
                families.append(value)
            }
        }
        return families.first
    }
}
