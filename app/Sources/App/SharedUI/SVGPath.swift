import SwiftUI

/// A minimal absolute-command SVG path-data parser (M/L/H/V/C/Z, the only commands the design
/// outlines use), with an optional translation applied as it builds. Scientific notation is not
/// supported, so design literals must be written in plain decimals.
enum SVGPath {
    static func parse(_ d: String, dx: CGFloat = 0, dy: CGFloat = 0) -> Path {
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        func shifted(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x + dx, y: y + dy)
        }

        let tokens = tokenize(d)
        var index = 0
        func nextNumber() -> CGFloat {
            defer { index += 1 }
            return CGFloat(Double(tokens[index]) ?? 0)
        }

        while index < tokens.count {
            let command = tokens[index]
            index += 1
            switch command {
            case "M":
                current = shifted(nextNumber(), nextNumber())
                subpathStart = current
                path.move(to: current)
            case "L":
                current = shifted(nextNumber(), nextNumber())
                path.addLine(to: current)
            case "H":
                current = shifted(nextNumber(), current.y - dy)
                path.addLine(to: current)
            case "V":
                current = shifted(current.x - dx, nextNumber())
                path.addLine(to: current)
            case "C":
                let control1 = shifted(nextNumber(), nextNumber())
                let control2 = shifted(nextNumber(), nextNumber())
                let end = shifted(nextNumber(), nextNumber())
                path.addCurve(to: end, control1: control1, control2: control2)
                current = end
            case "Z":
                path.closeSubpath()
                current = subpathStart
            default:
                break
            }
        }
        return path
    }

    /// Splits "M58.5 18C58.5 18 ..." into ["M", "58.5", "18", "C", "58.5", "18", ...].
    private static func tokenize(_ d: String) -> [String] {
        var tokens: [String] = []
        var numberBuffer = ""
        func flushNumber() {
            guard !numberBuffer.isEmpty else { return }
            tokens.append(numberBuffer)
            numberBuffer = ""
        }
        for character in d {
            if "MLHVCZ".contains(character) {
                flushNumber()
                tokens.append(String(character))
            } else if character == "," || character.isWhitespace {
                flushNumber()
            } else if character == "-" {
                flushNumber()
                numberBuffer.append(character)
            } else {
                numberBuffer.append(character)
            }
        }
        flushNumber()
        return tokens
    }
}
