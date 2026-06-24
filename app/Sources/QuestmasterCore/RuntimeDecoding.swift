import Foundation

private struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [Element] = []

        while !container.isAtEnd {
            do {
                decoded.append(try container.decode(Element.self))
            } catch {
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
