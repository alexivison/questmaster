import Foundation

/// Surfaces how many malformed items the lossy decoders have skipped.
///
/// Lossy array decoding (below) silently drops items that fail to decode so a single bad element
/// from the serve backend cannot break a whole update. Previously the only signal was an stderr
/// line; this counter gives the app a programmatic signal it can surface in the UI (Phase 1 /
/// Phase 5 of `app/docs/architecture-modernization-plan.md`). Surfacing it in the UI is a later
/// increment; for now the count is observable and testable.
public enum RuntimeDecodingDiagnostics {
    private static let lock = NSLock()
    private static var skipped = 0

    /// Total number of malformed array items skipped since the last `reset()`.
    public static var skippedItemCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return skipped
    }

    static func recordSkippedItem() {
        lock.lock()
        skipped += 1
        lock.unlock()
    }

    /// Resets the counter. Intended for tests and for the app to zero the count after surfacing it.
    public static func reset() {
        lock.lock()
        skipped = 0
        lock.unlock()
    }
}

private struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [Element] = []

        while !container.isAtEnd {
            do {
                decoded.append(try container.decode(Element.self))
            } catch {
                RuntimeDecodingDiagnostics.recordSkippedItem()
                fputs("Questmaster: skipped bad \(Element.self) in serve payload: \(error)\n", stderr)
                _ = try? container.decode(DiscardedJSONValue.self)
            }
        }

        elements = decoded
    }
}

private struct DiscardedJSONValue: Decodable {
    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd {
                _ = try? array.decode(DiscardedJSONValue.self)
            }
            return
        }

        if let object = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            for key in object.allKeys {
                _ = try? object.decode(DiscardedJSONValue.self, forKey: key)
            }
            return
        }

        let scalar = try decoder.singleValueContainer()
        if scalar.decodeNil() {
            return
        }
        if (try? scalar.decode(Bool.self)) != nil {
            return
        }
        if (try? scalar.decode(Double.self)) != nil {
            return
        }
        _ = try? scalar.decode(String.self)
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension KeyedDecodingContainer {
    func decodeLossyArray<Element: Decodable>(_ type: Element.Type, forKey key: Key) -> [Element] {
        (try? decode(LossyArray<Element>.self, forKey: key).elements) ?? []
    }
}
