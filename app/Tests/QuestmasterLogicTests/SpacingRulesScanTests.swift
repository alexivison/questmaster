import Foundation

/// Keeps the app on the spacing rules (AGENTS.md, "Spacing") by scanning app/Sources/App, beside the
/// interaction-state scan. Three rules:
///
/// - raw-spacing: a view states no layout number. `.padding`, a stack's, grid's or NSStackView's `spacing`, `.frame`
///   sizes, `Spacer(minLength:)`, `EdgeInsets`, constraint constants, `.offset` and `.position` take a `Space` step
///   or a named constant. 0 and 1
///   (spacers, hairlines) are allowed, and so is anything inside an `enum` named `*Metrics`, `*Layout` or
///   `*Design`, the home for named geometry.
/// - scale-restated: a gap, inset, spacing, margin, padding or gutter constant of 5, 10, 20 or 40 names its
///   `Space` step instead of the number.
/// - off-rhythm: a CGFloat constant or default whose name says it is a layout length (gap, spacing, margin,
///   padding, gutter, pitch, indent, inset, clearance, offset, height, width, side, size, lead, trail, nudge, origin;
///   x and y only for a static or metrics constant) is a multiple of 5, or 0 or 1. Names that say they aren't spacing are exempt: baselines and line heights (typography), radii, strokes,
///   borders, rings and glows (stroke widths), point sizes and fonts, a glyph's optical nudge, and `svg` lengths in
///   an SVG's own coordinates (path data, or an art's size that no uniform scale lands on 5s). Art, icon, logo and
///   mark sizes are lengths like any other. No marker excuses a spacing or a control size.
///
/// raw-spacing also reads ternaries, added or subtracted numbers, and scale factors other than 2 and 0.5 in those
/// arguments (`Space.item + 3`, `Space.item * 1.3`), but not an inner call's own arguments; off-rhythm
/// also reads the numbers of an NSSize/CGSize assigned to an inset, padding, margin or gap. The scan reads lines, so it can't see other CGPoint/CGSize/CGRect
/// literals, constants built from arithmetic, or numbers passed through a helper's parameter; the render-pitch
/// self-test (`LogicSelfTests`) measures what the lines can't.
struct SpacingRulesScanTests {
    static let exempt = StateRulesScanTests.exempt + ["Runtime/RingPreview.swift", "SharedUI/DesignTokens.swift"]

    /// A number other than 0 and 1.
    private static let number = #"(?<![\w.])-?(?!0(?![\d.])|1(?:\.0+)?(?![\d.]))(?:0\.\d*[1-9]\d*|[1-9]\d*(?:\.\d+)?)(?![\w.])"#
    /// What leads up to a term in an argument: other terms and a ternary or an added or subtracted term, never an
    /// inner call's own (labelled) arguments.
    private static let leadingTerms = #"(?:[^,()]*?(?:[?+\-]|\s:)\s*)?"#
    /// A scale factor other than halving or doubling (border and centring math).
    private static let notHalving = #"(?!(?:2|0\.5)(?![\d.]))"#
    /// An argument's number: alone, as a ternary's branch, added to or taken from a step, or scaling one by
    /// anything but 2 or 0.5 (`Space.item * 1.3`).
    private static let value: String = [
        "(?:", leadingTerms, number, #"(?!\s*[*/])"#,
        "|", #"[^,()]*?[*/]\s*"#, notHalving, number,
        "|", leadingTerms, notHalving, number, #"(?=\s*[*/]))"#,
    ].joined()
    private static let rawLayout = [
        #"\.padding\(\s*(?:(?:\.[a-zA-Z]+|\[[^\]]*\])\s*,\s*)?"# + value,
        #"\b(?:[HVZ]Stack|LazyVStack|LazyHStack|LazyVGrid|LazyHGrid|Grid)\([^\n]*?\bspacing:\s*"# + value,
        #"\bSpacer\(\s*minLength:\s*"# + value,
        #"\.position\([^)]*\b[xy]:\s*"# + value,
        #"\.spacing\s*=\s*"# + value,
        #"\.frame\([^)]*\b(?:width|height|min\w*|max\w*|ideal\w*):\s*"# + value,
        #"\b(?:EdgeInsets|NSEdgeInsets)\([^)]*:\s*"# + value,
        #"[cC]onstant:\s*"# + value,
        #"\.offset\([^)]*\b[xy]:\s*"# + value,
    ].map(regex)
    /// An NSSize/CGSize assigned to an inset, padding, margin or gap, and the numbers in it.
    private static let insetSize = regex(#"(?i:inset|padding|margin|gap)\w*\s*[:=]\s*(?:NS|CG)Size\(([^)]*)\)"#)
    private static let literal = regex(#"(?<![\w.])\d+(?:\.\d+)?(?![\w.])"#)
    private static let metricsEnum = regex(#"\benum\s+\w*(?:Metrics|Layout|Design)\b"#)
    private static let constant = regex(#"\b(?:let|var)\s+(\w+)\s*(?::\s*CGFloat)?\s*=\s*(-?\d+(?:\.\d+)?)\s*(?://.*)?$"#)
    private static let nameWord = regex(#"[A-Z]?[a-z]+|[A-Z]+(?![a-z])"#)

    private static let lengthWords: Set = ["gap", "spacing", "margin", "padding", "gutter", "pitch", "indent", "inset", "clearance", "offset", "height", "width", "side", "size", "lead", "trail", "nudge", "origin", "x", "y"]
    private static let spacingWords: Set = ["gap", "spacing", "margin", "padding", "gutter", "inset"]
    private static let notSpacingWords: Set = ["baseline", "radius", "stroke", "border", "ring", "glow", "point", "font", "glyph", "svg"]

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
                    "EdgeInsets(top: 24, leading: 0, bottom: 0, trailing: 0)", "view.topAnchor.constraint(equalTo: top, constant: -18)", ".offset(x: 1.5)",
                    ".padding(.top, Space.item + 3)", ".frame(width: open ? Space.item : 7)", ".offset(y: Space.row - 2)",
                    #"Text("https://example.com").padding(8)"#, "Spacer(minLength: 8)", ".padding([.top, .leading], 8)",
                    ".position(x: 13, y: 7)", "LazyVGrid(columns: [GridItem(.flexible())], spacing: 8)", ".frame(width: Space.item * 1.3)"]
        for line in raws {
            expect(violations(in: line, file: "Quest/Example.swift")["raw-spacing"] != nil, "raw-spacing should fire on \(line)")
        }
        for line in ["static let inset = NSSize(width: 6, height: 8.25)", "view.textContainerInset = CGSize(width: Space.item, height: 3)",
                     "static let footerDiamondLead: CGFloat = 8.4", "static let labelX: CGFloat = 12", "static let titleNudge: CGFloat = 2.5",
                     "static let artBandHeight: CGFloat = 17", "static let iconSide: CGFloat = 22", "static let logoSide: CGFloat = 32"] {
            expect(violations(in: line, file: "Quest/Example.swift")["off-rhythm"] != nil, "off-rhythm should fire on \(line)")
        }
        let clean = """
        Color.clear.frame(width: Space.item, height: 1)
        .padding(.top, Space.item + Space.row)
        let canvas = CGSize(width: 340, height: 420)
        static let inset = NSSize(width: Space.item, height: 15)
        .frame(width: barWidth - 2 * Self.border)
        .frame(width: columnWidth(count: 3))
        .frame(width: size / 2, height: size * 0.5)
        let y = 12
        var labelX = 7.5
        Text("a // b").padding(Space.item) // .padding(8) in a trailing comment is fine
        .padding(.top, 0)
        .frame(maxWidth: .infinity)
        enum ExampleMetrics {
            static let titleBaseline: CGFloat = 21.5
            static let ringStroke: CGFloat = 1.5
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
            let code = withoutComment(line)
            let isComment = line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            if !isComment {
                let inMetrics = braces.last ?? false
                if !inMetrics && rawLayout.contains(where: { matches($0, code) }) {
                    found["raw-spacing", default: []].append(index + 1)
                }
                if let rule = constantRule(line, inMetrics: inMetrics) ?? insetSizeRule(code) {
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

    /// An inset size is spacing wherever it is, metrics enums included: each number in it is on the 5pt rhythm.
    private static func insetSizeRule(_ code: String) -> String? {
        guard let match = insetSize.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
              let argumentsRange = Range(match.range(at: 1), in: code) else {
            return nil
        }
        let arguments = String(code[argumentsRange])
        let values = literal.matches(in: arguments, range: NSRange(arguments.startIndex..., in: arguments)).compactMap { Range($0.range, in: arguments).flatMap { Double(arguments[$0]) } }
        return values.contains { $0 != 0 && $0 != 1 && $0.truncatingRemainder(dividingBy: 5) != 0 } ? "off-rhythm" : nil
    }

    /// The line up to a `//` comment; a `//` inside a string literal is no comment.
    private static func withoutComment(_ line: String) -> String {
        var inString = false
        var previous: Character = " "
        for index in line.indices {
            let character = line[index]
            if character == "\"" && previous != "\\" {
                inString.toggle()
            } else if character == "/" && previous == "/" && !inString {
                return String(line[..<line.index(before: index)])
            }
            previous = character
        }
        return line
    }

    /// The rule a named constant breaks, if any. A name that is a length only by x or y counts as a static or metrics
    /// constant, not as a local, so path and drawing code stays free.
    private static func constantRule(_ line: String, inMetrics: Bool) -> String? {
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
        let isNamedConstant = inMetrics || line.contains("static ")
        guard isNamedConstant || !lengthWords.intersection(words).isSubset(of: ["x", "y"]) else {
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
