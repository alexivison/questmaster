import Foundation

/// Normalizes a raw session identifier: trims surrounding whitespace/newlines and
/// maps an empty result to `nil`. Single implementation that the previously duplicated
/// private cleaners (`ArtifactDisplayState`, `TerminalSessionChipResolver`, `ServeProcess`)
/// now delegate to, so session ids are cleaned the same way everywhere.
public func cleanSessionID(_ raw: String?) -> String? {
    let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return clean.isEmpty ? nil : clean
}
