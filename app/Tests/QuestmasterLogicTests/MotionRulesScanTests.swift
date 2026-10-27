import Foundation

/// Keeps the app on the motion rules (AGENTS.md, "Motion") by scanning app/Sources/App, beside the spacing scan. A
/// one-shot transition takes a `Motion` step; a view never states a duration or a curve. Three rules:
///
/// - raw-duration: no number literal as an animation's duration or delay (`duration: 0.2`, `.duration = 0.18`,
///   `.delay(0.1)`, `setAnimationDuration(0.3)`), and no SwiftUI curve built outside the token layer (`.easeOut`,
///   `.snappy`, `.spring` … in `withAnimation`, `.animation` or an `Animation` value), which carry a default duration
///   of their own. 0 is allowed. A line that repeats forever is a continuous animation (a skeleton's pulse), which keeps
///   its own period and is out of the rule.
/// - duration-constant: a constant or local whose name ends in an animation-timing word (duration, delay, time, fade,
///   crossfade, sweep, flash, transition, glide, unroll) isn't a number literal, typed or inferred (`let fadeTime =
///   0.4`); it comes from a step. A continuous animation names its `period` instead.
/// - raw-easing: no `CAMediaTimingFunction(name:)`; Core Animation and AppKit take `Motion.timingFunction`. The one
///   exception is a repeating animation's own breathing curve (`.easeInEaseOut` beside a `repeatCount`/`.infinity`/
///   `repeatForever`) in a file of `continuousFiles`; a finite animation there is held to the rule like anywhere else.
///
/// The scan reads lines, so it can't see a duration passed through a helper's parameter or built by arithmetic.
struct MotionRulesScanTests {
    static let tokenLayer = "SharedUI/DesignTokens.swift"
    /// Render fixtures, self-tests and the ring preview tool, not views.
    static let exempt = SpacingRulesScanTests.exempt
    /// Files whose continuous animations (the cast bar's overrun pulse, the status ring's) breathe on their own easing.
    static let continuousFiles = ["Tracker/TrackerCastRow.swift", "Tracker/TrackerPortraitStatus.swift"]
    /// How far from an easing a repeat marker still makes it that repeating animation's own.
    private static let repeatReach = 4

    private static let notZero = #"(?!0(?![\d.]))\d"#
    private static let curve = #"(?:default|linear|easeIn|easeOut|easeInOut|spring|snappy|smooth|bouncy|interpolatingSpring|interactiveSpring|timingCurve)"#
    private static let rawDuration = [
        #"\b[dD]uration\s*[:=]\s*"# + notZero,
        #"\.delay\(\s*"# + notZero,
        #"\bsetAnimationDuration\(\s*"# + notZero,
        #"(?:\bwithAnimation|\.animation)\(\s*(?:Animation)?\.\#(curve)\b"#,
        #"\bAnimation\??\s*=[^\n]*\.\#(curve)\b"#,
    ].map(SpacingRulesScanTests.regex)
    /// A `let` or `var` given a non-zero number literal, with or without a type: its name and the literal.
    private static let literalConstant = SpacingRulesScanTests.regex(#"\b(?:let|var)\s+(\w+)\s*(?::\s*[\w.?]+)?\s*=\s*"# + notZero)
    private static let timingWords: Set = ["duration", "delay", "time", "fade", "crossfade", "sweep", "flash", "transition", "glide", "unroll"]
    private static let rawEasing = SpacingRulesScanTests.regex(#"\bCAMediaTimingFunction\(\s*name:"#)
    private static let breathingEasing = SpacingRulesScanTests.regex(#"\bCAMediaTimingFunction\(\s*name:\s*\.easeInEaseOut\)"#)
    private static let repeatsForever = SpacingRulesScanTests.regex(#"\brepeatForever\b"#)
    private static let repeats = SpacingRulesScanTests.regex(#"\brepeatCount\b|\.infinity\b|\brepeatForever\b"#)

    static func run() {
        scannerCatchesEachRule()
        appSourcesFollowTheRules()
        print("MotionRulesScanTests: all tests passed")
    }

    /// Each rule fires on its deliberate break, and spares comments, steps, continuous animations and the allowed files.
    private static func scannerCatchesEachRule() {
        let breaks = """
        .animation(.easeOut(duration: 0.16), value: open)
        static let glideDuration: CFTimeInterval = 0.2
        let fadeTime = 0.4
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        // .animation(.easeOut(duration: 0.16), value: open) in a comment is fine
        """
        let found = violations(in: breaks, file: "Quest/Example.swift")
        expect(found["raw-duration"] == [1], "raw-duration should fire on its deliberate break, got \(found["raw-duration"] ?? [])")
        expect(found["duration-constant"] == [2, 3], "duration-constant should fire on its deliberate breaks, got \(found["duration-constant"] ?? [])")
        expect(found["raw-easing"] == [4], "raw-easing should fire on its deliberate break, got \(found["raw-easing"] ?? [])")

        // An inferred local passed on as a duration is no way round the rule.
        let inferred = violations(in: "let fadeTime = 0.4\nfade.duration = fadeTime", file: "Quest/Example.swift")
        expect(inferred["duration-constant"] == [1] && inferred["raw-duration"] == nil, "a literal local named for a duration should fire, got \(inferred)")

        let raws = [
            "context.duration = 0.18", "fade.duration = 0.3", "withAnimation(.snappy(duration: 0.22)) {", ".animation(.easeInOut(duration: 0.16), value: mode)",
            "withAnimation(.easeOut) { open = true }", ".animation(.default, value: open)", "withAnimation(Animation.spring()) {",
            "let fade: Animation? = reduceMotion ? nil : .easeInOut(duration: fadeTime)", "withAnimation(.easeOut(duration: 0.18).delay(0.1)) {",
            "CATransaction.setAnimationDuration(0.25)", ".transition(.opacity.animation(.linear(duration: 0.1)))",
        ]
        for line in raws {
            expect(violations(in: line, file: "Quest/Example.swift")["raw-duration"] != nil, "raw-duration should fire on \(line)")
        }
        let constants = [
            "static let unrollDuration = 0.25", "private let enterDelay: TimeInterval = 0.2", "static let exitFade: CFTimeInterval = 0.4",
            "static let crossfade: CFTimeInterval = 0.2", "static let pageTransition: TimeInterval = 0.12", "let fadeTime = 0.4",
            "var sweepTime: Double = 0.25", "let flashDuration = 0.3 * slowdown", "let time = 0.2", "static let flash: CFTimeInterval = 0.3",
        ]
        for line in constants {
            expect(violations(in: line, file: "Quest/Example.swift")["duration-constant"] != nil, "duration-constant should fire on \(line)")
        }
        let clean = [
            ".animation(Motion.animation(.fast), value: open)", "withAnimation(Motion.animation(.standard, after: .fast)) {", "context.duration = 0",
            "Motion.configure(context, .standard)", "glide.duration = Motion.duration(.standard)", "context.timingFunction = Motion.timingFunction",
            "withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulsing = true }",
            "static let pulsePeriod: TimeInterval = 1.2", "static let overflowFadeHeight: CGFloat = 40", "private let debounceInterval: TimeInterval = 0.15",
            "let delay = Motion.duration(.fast)", "static let settle: TimeInterval = 0.8", "let fadeTime = Motion.duration(.standard)",
            "static let flashOpacity: Float = 0.5", "let delay = 0", "let startTime = Date()", "static let shimmerPeriod: CFTimeInterval = 1.2",
            "// context.duration = 0.18", "// let fadeTime = 0.4",
        ]
        for line in clean {
            expect(violations(in: line, file: "Quest/Example.swift").isEmpty, "\(line) is no break: \(violations(in: line, file: "Quest/Example.swift"))")
        }
        expect(violations(in: "context.duration = 0.18\nlet fadeTime = 0.4", file: tokenLayer).isEmpty, "the token layer may state durations")

        // Continuous files keep their repeating animations' breathing curve, and nothing finite.
        let breath = "breath.autoreverses = true\nbreath.repeatCount = .infinity\nbreath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)"
        for file in continuousFiles {
            expect(violations(in: breath, file: file).isEmpty, "\(file) keeps its repeating animations' easing, got \(violations(in: breath, file: file))")
            expect(violations(in: "sweep.timingFunction = CAMediaTimingFunction(name: .easeOut)", file: file)["raw-easing"] != nil, "\(file) is held to the easing token for a finite animation")
            expect(violations(in: "fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)", file: file)["raw-easing"] != nil, "\(file) is held to the easing token for a finite animation, whatever the curve")
            expect(violations(in: "static let exitFade: CFTimeInterval = 0.4", file: file)["duration-constant"] != nil, "\(file) is held to the step tokens for a finite duration")
            expect(violations(in: "let fadeTime = 0.4", file: file)["duration-constant"] != nil, "\(file) is held to the step tokens for a finite local")
            expect(violations(in: "context.duration = 0.18", file: file)["raw-duration"] != nil, "\(file) is not excused from raw durations passed to an animation")
            expect(violations(in: "static let shimmerPeriod: CFTimeInterval = 1.2", file: file).isEmpty, "\(file) names its continuous periods")
        }
        expect(violations(in: breath, file: "Quest/Example.swift")["raw-easing"] != nil, "a repeating animation elsewhere takes the easing token too")
    }

    private static func appSourcesFollowTheRules() {
        var failures: [String] = []
        for (file, source) in StateRulesScanTests.appSources(except: exempt) {
            for (rule, lines) in violations(in: source, file: file).sorted(by: { $0.key < $1.key }) {
                failures.append("\(rule) \(file): line(s) \(lines.map(String.init).joined(separator: ", "))")
            }
        }
        expect(failures.isEmpty, "motion rules (AGENTS.md): a one-shot transition takes a Motion step, never a literal duration or curve; a continuous animation names its period:\n" + failures.joined(separator: "\n"))
    }

    /// Rule name to the line numbers that break it. Comment lines don't count.
    static func violations(in source: String, file: String) -> [String: [Int]] {
        guard file != tokenLayer else { return [:] }
        var found: [String: [Int]] = [:]
        let lines = source.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
            let code = SpacingRulesScanTests.withoutComment(line)
            if !SpacingRulesScanTests.matches(repeatsForever, code), rawDuration.contains(where: { SpacingRulesScanTests.matches($0, code) }) {
                found["raw-duration", default: []].append(index + 1)
            }
            if isTimingConstant(code) {
                found["duration-constant", default: []].append(index + 1)
            }
            if SpacingRulesScanTests.matches(rawEasing, code), !isRepeatingBreath(code, at: index, in: lines, file: file) {
                found["raw-easing", default: []].append(index + 1)
            }
        }
        return found
    }

    /// A number literal given to a name that ends in an animation-timing word, typed or inferred.
    private static func isTimingConstant(_ code: String) -> Bool {
        guard let match = literalConstant.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
              let nameRange = Range(match.range(at: 1), in: code) else {
            return false
        }
        let name = String(code[nameRange])
        let words = SpacingRulesScanTests.nameWord.matches(in: name, range: NSRange(name.startIndex..., in: name)).compactMap { Range($0.range, in: name).map { name[$0].lowercased() } }
        return words.last.map(timingWords.contains) ?? false
    }

    /// A continuous file's repeating animation's own `.easeInEaseOut`: a repeat marker within `repeatReach` lines of it.
    private static func isRepeatingBreath(_ code: String, at index: Int, in lines: [String], file: String) -> Bool {
        guard continuousFiles.contains(file), SpacingRulesScanTests.matches(breathingEasing, code) else { return false }
        let nearby = lines[max(0, index - repeatReach)...min(lines.count - 1, index + repeatReach)]
        return nearby.contains { SpacingRulesScanTests.matches(repeats, SpacingRulesScanTests.withoutComment($0)) }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
