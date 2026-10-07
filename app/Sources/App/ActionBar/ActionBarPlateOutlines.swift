import SwiftUI

/// Literal outlines traced from the design's own v2 SVGs (the compact redesign, 2026-10-07): the
/// plate geometry doesn't scale cleanly through `TrackerPlatePaths`' parametric shield math, so
/// these are copied directly from `action-bar-v2.svg` (the slot bar) and
/// `session-panel-variants-v2.svg` (the master, standalone and worker/plain session panels),
/// translated only enough to land each variant's own portrait centre on the shared content row's
/// centre, `(41, 41)` in each source file's own coordinates — the panel is otherwise drawn exactly
/// as exported, at 1:1 scale. A further, single `ActionBarMetrics.verticalShift` (applied to every
/// shape here, same as the slot bar) removes the source files' own Figma frame padding, same as
/// the v1 design before it.
enum ActionBarPlateOutlines {
    /// `action-bar-v2.svg`'s slot bar (a separate plate from the session panel, overlapping it) —
    /// already at the target content-row centreline (y 41), so only the shared vertical shift
    /// applies.
    static let slotBar = SVGPath.parse("""
    M660.141 21.75C663.618 24.019 666.171 24.391 667.938 24.0791C668.607 23.9608 669.145 23.7461 669.559 23.5205L673.232 41L669.559 58.4785C669.145 58.253 668.607 58.0391 667.938 57.9209C666.171 57.609 663.618 57.981 660.141 60.25H267.859C264.382 57.981 261.829 57.609 260.062 57.9209C259.392 58.0392 258.854 58.2529 258.44 58.4785L254.767 41L258.44 23.5205C258.854 23.7462 259.392 23.9608 260.062 24.0791C261.829 24.391 264.382 24.019 267.859 21.75H660.141Z
    """, dy: ActionBarMetrics.verticalShift)

    /// `session-panel-variants-v2.svg`'s master (shield + tip) panel — its own portrait centre,
    /// (49, 46), already matches the target x; only the shared vertical shift applies (its own y
    /// contribution is folded into that same shift, since this panel's own content-row centre is
    /// also y 41... but its portrait sits 5pt above that, at y 46 → the full vertical shift here
    /// is `(41 - 46) + ActionBarMetrics.verticalShift`, matching the other two variants' same
    /// `(41 - theirPortraitY) + verticalShift` pattern below).
    static let masterPanel = SVGPath.parse("""
    M49.0013 21C49.0013 21 53.7129 21.8245 63.9378 24.1123C67.5043 24.9101 70.2149 25.5338 72.2161 26H291.436C291.436 26 291.645 31.0205 297.213 33.833C302.192 36.6455 304.166 34.5713 304.166 34.5713L307 46L304.166 57.4287C304.166 57.4287 302.192 55.3545 297.213 58.167C291.653 60.9754 291.436 65.9855 291.436 66H63.0364C58.2328 70.0624 52.8309 72.9423 49.0003 75C41.6315 71.0418 28.4381 64.051 24.9007 51.4229C20.5316 35.8236 21.0142 27.1859 21.0169 27.1377C21.0169 27.1377 24.4022 26.2732 34.0618 24.1123C44.2553 21.8322 48.9696 21.0055 49.0013 21Z
    """, dx: -8, dy: 41 - 46 + ActionBarMetrics.verticalShift)

    /// `session-panel-variants-v2.svg`'s standalone (notched circle) panel, shifted so its own
    /// portrait centre (49, 136) lands on the shared content row's (41, 41), then by the same
    /// vertical shift that removes the source files' Figma padding.
    static let standalonePanel = SVGPath.parse("""
    M49.0004 111C43.3718 111 38.1779 112.861 33.9994 116H30.0004C30.0004 116 29.849 121.08 27.1068 123C25.1873 124.344 24.0004 124.571 24.0004 124.571L21.0004 136L24.0004 147.429C24.0004 147.429 25.1873 147.656 27.1068 149C29.849 150.92 30.0004 156 30.0004 156H33.9994C38.1779 159.139 43.3718 161 49.0004 161C54.629 161 59.8228 159.139 64.0013 156H292C292.001 155.993 292.153 150.918 294.893 149C296.805 147.662 297.99 147.431 297.999 147.429L301 136L297.999 124.571C297.989 124.569 296.804 124.338 294.893 123C292.151 121.08 292 116 292 116H64.0013C59.8228 112.861 54.629 111 49.0004 111Z
    """, dx: -8, dy: 41 - 136 + ActionBarMetrics.verticalShift)

    /// `session-panel-variants-v2.svg`'s worker/plain (full circle, no notches) panel, shifted so
    /// its own portrait centre (49, 221) lands on the shared content row's (41, 41), then by the
    /// same vertical shift that removes the source files' Figma padding.
    static let workerPanel = SVGPath.parse("""
    M49.001 196C54.6296 196 59.8234 197.861 64.002 201H292C294.761 201 297 203.239 297 206V236.001C297 238.762 294.761 241.001 292 241.001H64.002C59.8234 244.14 54.6297 246.001 49.001 246.001C35.1937 246.001 24.0002 234.808 24 221.001C24 207.194 35.1936 196 49.001 196Z
    """, dx: -8, dy: 41 - 221 + ActionBarMetrics.verticalShift)
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
