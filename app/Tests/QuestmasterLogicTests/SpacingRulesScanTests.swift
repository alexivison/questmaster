import Foundation

/// Keeps the app on the spacing rules (AGENTS.md, "Spacing") by scanning app/Sources/App, beside the
/// interaction-state scan. Three rules:
///
/// - raw-spacing: a view states no layout number. `.padding`, a stack's or NSStackView's `spacing`, `.frame`
///   sizes, `EdgeInsets`, constraint constants and `.offset` take a `Space` step or a named constant. 0 and 1
///   (spacers, hairlines) are allowed, and so is anything inside an `enum` named `*Metrics`, `*Layout` or
///   `*Design`, the home for named geometry.
/// - scale-restated: a gap, inset, spacing, margin, padding or gutter constant of 5, 10, 20 or 40 names its
///   `Space` step instead of the number.
/// - off-rhythm: a CGFloat constant or default whose name says it is a layout length (gap, spacing, margin,
///   padding, gutter, pitch, indent, inset, clearance, offset, height, width, side, size) is a multiple of 5, or 0
///   or 1. Names that say they aren't spacing are exempt: baselines and line heights (typography), radii, strokes,
///   borders, rings and glows (stroke widths), point sizes and fonts, and art, design, glyph, icon, logo, mark,
///   symbol and ink geometry (path data and glyph sizes). No marker excuses a spacing or a control size.
///
/// The scan reads lines, so it can't see arithmetic on literals, CGPoint/CGSize/CGRect literals, or numbers passed
/// through a helper's parameter; the render-pitch self-test (`LogicSelfTests`) measures what the lines can't.
struct SpacingRulesScanTests {
    static let exempt = StateRulesScanTests.exempt + ["Runtime/RingPreview.swift", "SharedUI/DesignTokens.swift"]

    /// A number other than 0 and 1.
    private static let number = #"(?<![\w.])-?(?!0(?![\d.])|1(?:\.0+)?(?![\d.]))(?:0\.\d*[1-9]\d*|[1-9]\d*(?:\.\d+)?)(?![\w.])"#
    private static let rawLayout = [
        #"\.padding\(\s*(?:\.[a-zA-Z]+\s*,\s*)?(?:[^)]*\?\s*)?"# + number,
        #"\b(?:[HVZ]Stack|LazyVStack|LazyHStack|Grid)\([^)]*spacing:\s*(?:[^,)]*\?\s*)?"# + number,
        #"\.spacing\s*=\s*"# + number,
        #"\.frame\([^)]*\b(?:width|height|min\w*|max\w*|ideal\w*):\s*(?:[^,)]*\?\s*)?"# + number,
        #"\b(?:EdgeInsets|NSEdgeInsets)\([^)]*:\s*"# + number,
        #"[cC]onstant:\s*"# + number,
        #"\.offset\([^)]*\b[xy]:\s*"# + number,
    ].map(regex)
    private static let metricsEnum = regex(#"\benum\s+\w*(?:Metrics|Layout|Design)\b"#)
    private static let constant = regex(#"\b(?:let|var)\s+(\w+)\s*(?::\s*CGFloat)?\s*=\s*(-?\d+(?:\.\d+)?)\s*(?://.*)?$"#)
    private static let nameWord = regex(#"[A-Z]?[a-z]+|[A-Z]+(?![a-z])"#)

    private static let lengthWords: Set = ["gap", "spacing", "margin", "padding", "gutter", "pitch", "indent", "inset", "clearance", "offset", "height", "width", "side", "size"]
    private static let spacingWords: Set = ["gap", "spacing", "margin", "padding", "gutter", "inset"]
    private static let notSpacingWords: Set = ["baseline", "radius", "stroke", "border", "ring", "glow", "point", "font", "art", "design", "glyph", "icon", "logo", "mark", "symbol", "ink"]

    static func run() {
        scannerCatchesEachRule()
        appSourcesFollowTheRules()
        print("SpacingRulesScanTests: all tests passed")
    }

    /// Each rule fires on its deliberate break, and spares comments, metrics enums and the exempt names.
    private static func scannerCatchesEachRule() {
        let breaks = """
        Text("x").padding(.top, 21)
        static let rowGap: CGFloat = 10
        static let rowHeight: CGFloat = 26
        // .padding(.top, 21) in a comment is fine
        """
        let found = violations(in: breaks, file: "Quest/Example.swift")
        for rule in ["raw-spacing", "scale-restated", "off-rhythm"] {
            expect(found[rule]?.count == 1, "\(rule) should fire once on its deliberate break, got \(found[rule] ?? [])")
        }
        let raws = [".padding(8)", "VStack(spacing: 6) {", "stack.spacing = 8", ".frame(width: 420)", ".frame(height: open ? 12 : 0)",
                    "EdgeInsets(top: 24, leading: 0, bottom: 0, trailing: 0)", "view.topAnchor.constraint(equalTo: top, constant: -18)", ".offset(x: 1.5)"]
        for line in raws {
            expect(violations(in: line, file: "Quest/Example.swift")["raw-spacing"] != nil, "raw-spacing should fire on \(line)")
        }
        let clean = """
        Color.clear.frame(width: Space.item, height: 1)
        .padding(.top, 0)
        .frame(maxWidth: .infinity)
        enum ExampleMetrics {
            static let titleBaseline: CGFloat = 21.5
            static let artBandHeight: CGFloat = 17
            static let bodyLineHeight: CGFloat = 16
            static let borderStrokeWidth: CGFloat = 3
            static let rowHeight = ControlHeight.compact
            static let shadow = Text("x").padding(8)
        }
        """
        expect(violations(in: clean, file: "Quest/Example.swift").isEmpty, "steps, spacers, metrics enums and exempt names are no break: \(violations(in: clean, file: "Quest/Example.swift"))")
    }

    private static func appSourcesFollowTheRules() {
        var failures: [String] = []
        for (file, source) in StateRulesScanTests.appSources(except: exempt) {
            for (rule, lines) in violations(in: source, file: file).sorted(by: { $0.key < $1.key }) {
                failures.append("\(rule) \(file): line(s) \(lines.map(String.init).joined(separator: ", "))")
            }
        }
        expect(failures.isEmpty, "spacing rules (AGENTS.md):\n" + failures.joined(separator: "\n"))
    }

    /// Rule name to the line numbers that break it. Comment lines don't count.
    static func violations(in source: String, file: String) -> [String: [Int]] {
        var found: [String: [Int]] = [:]
        // One entry per open brace: whether it opened, or sits inside, a metrics enum.
        var braces: [Bool] = []
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            let code = line.components(separatedBy: "//")[0]
            let isComment = line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            if !isComment {
                let inMetrics = braces.last ?? false
                if !inMetrics && rawLayout.contains(where: { matches($0, code) }) {
                    found["raw-spacing", default: []].append(index + 1)
                }
                if let rule = constantRule(line) {
                    found[rule, default: []].append(index + 1)
                }
            }
            var opensMetrics = matches(metricsEnum, code)
            for character in code {
                if character == "{" {
                    braces.append(opensMetrics || (braces.last ?? false))
                    opensMetrics = false
                } else if character == "}" {
                    _ = braces.popLast()
                }
            }
        }
        return found
    }

    /// The rule a named constant breaks, if any.
    private static func constantRule(_ line: String) -> String? {
        guard let match = constant.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let nameRange = Range(match.range(at: 1), in: line),
              let valueRange = Range(match.range(at: 2), in: line),
              let value = Double(line[valueRange]) else {
            return nil
        }
        let name = String(line[nameRange])
        let words = nameWord.matches(in: name, range: NSRange(name.startIndex..., in: name)).compactMap { Range($0.range, in: name).map { name[$0].lowercased() } }
        let isLineHeight = zip(words, words.dropFirst()).contains { $0 == ("line", "height") }
        guard !lengthWords.isDisjoint(with: words), notSpacingWords.isDisjoint(with: words), !isLineHeight else {
            return nil
        }
        if [5, 10, 20, 40].contains(value) && !spacingWords.isDisjoint(with: words) {
            return "scale-restated"
        }
        if value != 0 && value != 1 && value.truncatingRemainder(dividingBy: 5) != 0 {
            return "off-rhythm"
        }
        return nil
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            fatalError("bad pattern \(pattern)")
        }
        return regex
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
