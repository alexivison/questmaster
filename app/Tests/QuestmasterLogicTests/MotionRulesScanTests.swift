import Foundation

/// Keeps the app on the motion rules (AGENTS.md, "Motion") by scanning app/Sources/App, beside the spacing scan. A
/// one-shot transition takes a `Motion` step; a view never states a duration or a curve. Three rules:
///
/// - raw-duration: no number literal as an animation's duration or delay (`duration: 0.2`, `.duration = 0.18`,
///   `.delay(0.1)`, `setAnimationDuration(0.3)`), and no SwiftUI curve built outside the token layer (`.easeOut`,
///   `.snappy`, `.spring` … in `withAnimation`, `.animation` or an `Animation` value), which carry a default duration
///   of their own. 0 is allowed. A line that repeats forever is a continuous animation (a skeleton's pulse), which keeps
///   its own period and is out of the rule.
/// - duration-constant: a `TimeInterval` named for an animation (duration, delay, fade, sweep, transition) isn't a
///   number literal; it comes from a step. The cast bar and the status glows (`continuousFiles`) are left to their
///   own durations.
/// - raw-easing: no `CAMediaTimingFunction(name:)`; Core Animation and AppKit take `Motion.timingFunction`. The same
///   two files keep their breathing pulses' and exit sweep's own easing.
///
/// The scan reads lines, so it can't see a duration passed through a helper's parameter or built by arithmetic.
struct MotionRulesScanTests {
    static let tokenLayer = "SharedUI/DesignTokens.swift"
    /// Render fixtures, self-tests and the ring preview tool, not views.
    static let exempt = SpacingRulesScanTests.exempt
    /// The cast bar's fill, pulse and flash and the portrait status ring's glows and exit: continuous or status
    /// animations that run on their own durations.
    static let continuousFiles = ["Tracker/TrackerCastRow.swift", "Tracker/TrackerPortraitStatus.swift"]

    private static let notZero = #"(?!0(?![\d.]))\d"#
    private static let curve = #"(?:default|linear|easeIn|easeOut|easeInOut|spring|snappy|smooth|bouncy|interpolatingSpring|interactiveSpring|timingCurve)"#
    private static let rawDuration = [
        #"\b[dD]uration\s*[:=]\s*"# + notZero,
        #"\.delay\(\s*"# + notZero,
        #"\bsetAnimationDuration\(\s*"# + notZero,
        #"(?:\bwithAnimation|\.animation)\(\s*(?:Animation)?\.\#(curve)\b"#,
        #"\bAnimation\??\s*=[^\n]*\.\#(curve)\b"#,
    ].map(SpacingRulesScanTests.regex)
    private static let durationConstant = SpacingRulesScanTests.regex(
        #"(?i)\b(?:let|var)\s+\w*(?:duration|delay|fade|sweep|transition)\w*\s*:\s*(?:CF)?TimeInterval\s*=\s*\d|\b(?:let|var)\s+\w*(?:Duration|Delay)\s*=\s*\d"#
    )
    private static let rawEasing = SpacingRulesScanTests.regex(#"\bCAMediaTimingFunction\(\s*name:"#)
    private static let repeatsForever = SpacingRulesScanTests.regex(#"\brepeatForever\b"#)

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
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        // .animation(.easeOut(duration: 0.16), value: open) in a comment is fine
        """
        let found = violations(in: breaks, file: "Quest/Example.swift")
        expect(found["raw-duration"] == [1], "raw-duration should fire on its deliberate break, got \(found["raw-duration"] ?? [])")
        expect(found["duration-constant"] == [2], "duration-constant should fire on its deliberate break, got \(found["duration-constant"] ?? [])")
        expect(found["raw-easing"] == [3], "raw-easing should fire on its deliberate break, got \(found["raw-easing"] ?? [])")

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
            "static let crossfade: CFTimeInterval = 0.2", "static let pageTransition: TimeInterval = 0.12",
        ]
        for line in constants {
            expect(violations(in: line, file: "Quest/Example.swift")["duration-constant"] != nil, "duration-constant should fire on \(line)")
        }
        let clean = [
            ".animation(Motion.animation(.fast), value: open)", "withAnimation(Motion.animation(.standard, after: .fast)) {", "context.duration = 0",
            "Motion.configure(context, .standard)", "glide.duration = Motion.duration(.standard)", "context.timingFunction = Motion.timingFunction",
            "withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulsing = true }",
            "static let pulsePeriod: TimeInterval = 1.2", "static let overflowFadeHeight: CGFloat = 40", "private let debounceInterval: TimeInterval = 0.15",
            "let delay = Motion.duration(.fast)", "static let settle: TimeInterval = 0.8",
            "// context.duration = 0.18",
        ]
        for line in clean {
            expect(violations(in: line, file: "Quest/Example.swift").isEmpty, "\(line) is no break: \(violations(in: line, file: "Quest/Example.swift"))")
        }
        expect(violations(in: "context.duration = 0.18", file: tokenLayer).isEmpty, "the token layer may state durations")
        for file in continuousFiles {
            expect(violations(in: "static let exitFade: CFTimeInterval = 0.4\nx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)", file: file).isEmpty, "\(file) keeps its own durations and easing")
            expect(violations(in: "context.duration = 0.18", file: file)["raw-duration"] != nil, "\(file) is not excused from raw durations passed to an animation")
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
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
            let code = SpacingRulesScanTests.withoutComment(line)
            let isContinuous = continuousFiles.contains(file)
            if !SpacingRulesScanTests.matches(repeatsForever, code), rawDuration.contains(where: { SpacingRulesScanTests.matches($0, code) }) {
                found["raw-duration", default: []].append(index + 1)
            }
            if !isContinuous, SpacingRulesScanTests.matches(durationConstant, code) {
                found["duration-constant", default: []].append(index + 1)
            }
            if !isContinuous, SpacingRulesScanTests.matches(rawEasing, code) {
                found["raw-easing", default: []].append(index + 1)
            }
        }
        return found
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
