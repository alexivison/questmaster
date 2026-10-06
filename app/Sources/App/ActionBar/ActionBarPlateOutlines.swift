import SwiftUI

/// Literal outlines traced from the design's own SVGs, per the first review round: the plate
/// geometry doesn't scale cleanly through `TrackerPlatePaths`' parametric shield math, so these
/// are copied directly from `action-bar.svg` (the slot bar and the master session panel) and
/// `session-panel-variants.svg` (the standalone and worker/none session panels), translated only
/// enough to land each variant's portrait at the same (58, 53) point the master's own sits at —
/// the panel is otherwise drawn exactly as exported, at 1:1 scale.
enum ActionBarPlateOutlines {
    /// `action-bar.svg`'s slot bar (a separate plate from the session panel, overlapping it).
    static let slotBar = SVGPath.parse("""
    M686.82 26.75C690.381 29.0212 692.989 29.3892 694.787 29.0791C695.485 28.9588 696.041 28.7389 696.467 28.5088L700.232 46L696.467 63.4902C696.041 63.2602 695.484 63.0412 694.787 62.9209C692.989 62.6108 690.381 62.9788 686.82 65.25H285.18C281.619 62.9788 279.011 62.6108 277.213 62.9209C276.515 63.0412 275.958 63.26 275.532 63.4902L271.767 46L275.532 28.5088C275.958 28.7391 276.515 28.9587 277.213 29.0791C279.011 29.3892 281.619 29.0212 285.18 26.75H686.82Z
    """)

    /// `action-bar.svg`'s own session panel (the shield variant) — already in the target frame.
    static let masterPanel = SVGPath.parse("""
    M58.5112 18C58.5112 18 63.0875 18.8205 72.9037 21H305.442C305.442 21 305.651 27.2764 311.219 30.792C316.198 34.3076 318.172 31.7139 318.172 31.7139L321.006 46L318.172 60.2861C318.172 60.2861 316.198 57.6924 311.219 61.208C305.651 64.7236 305.442 71 305.442 71H85.3276C77.9098 81.4104 65.9771 87.8954 58.5092 92C48.6403 86.5758 30.9715 76.9965 26.2338 59.6914C20.3658 38.2543 21.0326 26.4102 21.0326 26.4102C21.0906 26.395 25.6491 25.2069 38.5033 22.2646C52.1543 19.1403 58.4679 18.0077 58.5112 18Z
    """)

    /// `session-panel-variants.svg`'s standalone (notched circle) panel, shifted so its own
    /// portrait centre (56.0092, 144) lands on the master's (58, 53).
    static let standalonePanel = SVGPath.parse("""
    M41.9027 112C41.9027 112 41.6886 118.289 36.0023 121.812C30.9186 125.334 28.9027 122.735 28.9027 122.735L27.5697 129.333C25.8793 132.611 24.765 136.159 24.2826 139.823C23.7341 143.99 24.0123 148.223 25.1 152.282C26.1876 156.341 28.0633 160.147 30.6215 163.48C33.1797 166.814 36.3699 169.612 40.0092 171.713C43.6485 173.814 47.666 175.178 51.8324 175.727C55.9988 176.275 60.2323 175.997 64.2914 174.909C68.3504 173.822 72.1558 171.946 75.4896 169.388C78.1656 167.334 80.4948 164.873 82.3969 162.1H303.119C303.119 162.1 303.333 155.811 309.019 152.288C314.08 148.781 316.101 151.341 316.119 151.363L319.012 137.05L316.119 122.735C316.119 122.735 314.103 125.334 309.019 121.812C303.335 118.29 303.119 112.004 303.119 112H41.9027Z
    """, dx: 58 - 56.0092, dy: 53 - 144)

    /// `session-panel-variants.svg`'s worker/none (plain circle) panel, shifted so its own
    /// portrait centre (56.0061, 228) lands on the master's (58, 53).
    static let workerPanel = SVGPath.parse("""
    M299.006 196C301.767 196 304.006 198.239 304.006 201V241C304.006 243.761 301.767 246 299.006 246H82.4658C76.7059 254.451 67.0043 260 56.0059 260C38.3327 260 24.0059 245.673 24.0059 228C24.0059 210.926 37.3785 196.975 54.2217 196.05V196H299.006Z
    """, dx: 58 - 56.0061, dy: 53 - 228)
}

/// A minimal absolute-command SVG path-data parser (M/L/H/V/C/Z — the only commands the traced
/// outlines above use), with an optional translation applied as it builds.
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

    /// Splits "M58.5 18C58.5 18 ..." into ["M","58.5","18","C","58.5","18",...]. All four traced
    /// outlines use only absolute (uppercase) commands and plain decimals — no relative commands,
    /// no scientific notation, no implicit command repetition.
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
