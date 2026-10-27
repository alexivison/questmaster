import Foundation

/// Keeps the app on the motion rules (AGENTS.md, "Motion") by scanning app/Sources/App, beside the spacing scan. A
/// one-shot transition takes a `Motion` step; a view never states a duration or a curve. Three rules:
///
/// - raw-duration: no number literal as an animation's duration or delay (`duration: 0.2`, `.duration = 0.18`,
///   `.delay(0.1)`, `setAnimationDuration(0.3)`), and no SwiftUI curve built outside the token layer (`.easeOut`,
///   `.snappy`, `.spring` … in `withAnimation`, `.animation` or an `Animation` value), which carry a default duration
///   of their own. 0 is allowed. A SwiftUI animation chained straight into `.repeatForever` on the same line is a
///   continuous one (the skeletons' pulse), which keeps its own period; that is the rule's only exception, and it goes
///   when those pulses take a token.
/// - duration-constant: a constant or local whose name ends in an animation-timing word (duration, delay, time, fade,
///   crossfade, sweep, flash, transition, glide, unroll) isn't a number literal, typed or inferred (`let fadeTime =
///   0.4`); it comes from a step. A continuous animation names its `period` instead.
/// - raw-easing: no curve built outside the token layer, whatever the animation: no `CAMediaTimingFunction(` (by name
///   or control points) and no `.timingCurve(`. A one-shot takes `Motion.timingFunction`, a pulse that breathes takes
///   `Motion.breathingTimingFunction`; there is no exception by file or by neighbouring line.
///
/// The scan reads lines, so it can't see a duration passed through a helper's parameter or built by arithmetic.
struct MotionRulesScanTests {
    static let tokenLayer = "SharedUI/DesignTokens.swift"
    /// Render fixtures, self-tests and the ring preview tool, not views.
    static let exempt = SpacingRulesScanTests.exempt

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
    private static let rawEasing = SpacingRulesScanTests.regex(#"\bCAMediaTimingFunction\(|\.timingCurve\("#)
    private static let repeatsForever = SpacingRulesScanTests.regex(#"\brepeatForever\b"#)

    static func run() {
        scannerCatchesEachRule()
        appSourcesFollowTheRules()
        print("MotionRulesScanTests: all tests passed")
    }

    /// Each rule fires on its deliberate break, and spares comments, steps, the tokens and the token layer.
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
            "breath.timingFunction = Motion.breathingTimingFunction",
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

        // No curve is built outside the token layer: by name or control points, one-shot or repeating, in any file, and
        // whatever lies near it. A pulse takes the breathing token.
        let curves = [
            "sweep.timingFunction = CAMediaTimingFunction(name: .easeOut)",
            "fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)",
            "fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)",
            ".animation(.timingCurve(0.2, 0, 0.8, 1, duration: Motion.duration(.fast)), value: open)",
            // A finite fade beside a pulse's repeat marker is still a raw curve.
            "breath.repeatCount = .infinity\nfade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)",
            // So is a pulse's own curve, however far from its repeat marker it sits.
            "breath.repeatCount = .infinity\nbreath.duration = period\nbreath.autoreverses = true\nbreath.fromValue = 0\nbreath.toValue = 1\nbreath.beginTime = start\nbreath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)",
            "breath.autoreverses = true\nbreath.repeatCount = .infinity\nbreath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)",
        ]
        for file in ["Quest/Example.swift", "Tracker/TrackerCastRow.swift", "Tracker/TrackerPortraitStatus.swift"] {
            for source in curves {
                expect(violations(in: source, file: file)["raw-easing"] != nil, "raw-easing should fire in \(file) on \(source)")
            }
            expect(violations(in: "static let exitFade: CFTimeInterval = 0.4", file: file)["duration-constant"] != nil, "\(file) is held to the step tokens for a finite duration")
            expect(violations(in: "let fadeTime = 0.4", file: file)["duration-constant"] != nil, "\(file) is held to the step tokens for a finite local")
            expect(violations(in: "context.duration = 0.18", file: file)["raw-duration"] != nil, "\(file) is not excused from raw durations passed to an animation")
            let pulse = "breath.autoreverses = true\nbreath.repeatCount = .infinity\nbreath.timingFunction = Motion.breathingTimingFunction\nsweep.duration = Self.shimmerPeriod"
            expect(violations(in: pulse, file: file).isEmpty, "a pulse on the breathing token is clean in \(file), got \(violations(in: pulse, file: file))")
            expect(violations(in: "static let shimmerPeriod: CFTimeInterval = 1.2", file: file).isEmpty, "\(file) names its continuous periods")
        }
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
            if SpacingRulesScanTests.matches(rawEasing, code) {
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

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
