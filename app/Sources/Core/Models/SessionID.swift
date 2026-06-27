import Foundation

/// Normalizes a raw session identifier: trims surrounding whitespace/newlines and
/// maps an empty result to `nil`. Shared so the active/current session id is cleaned
/// the same way everywhere (matches the previously duplicated private cleaners).
public func cleanSessionID(_ raw: String?) -> String? {
    let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return clean.isEmpty ? nil : clean
}
