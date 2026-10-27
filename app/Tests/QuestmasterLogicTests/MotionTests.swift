import Foundation
import QuestmasterCore

/// The motion tokens (AGENTS.md, "Motion"): two steps, one easing, and Reduce Motion skipping a transition.
struct MotionTests {
    static func run() {
        stepsAreShortAndFastIsFaster()
        reduceMotionSkipsTheStepInsteadOfShorteningIt()
        theEasingRunsFromZeroToOneAndEasesOut()
        theBreathingEasingEasesInAndOutSymmetrically()
        print("MotionTests: all tests passed")
    }

    /// A pulse that eases up and back has its own curve, the system's ease in and out: slow at both ends, mirrored, and
    /// unlike the one-shot's, which starts at full speed.
    private static func theBreathingEasingEasesInAndOutSymmetrically() {
        let breathing = MotionEasing.breathingControlPoints
        let oneShot = MotionEasing.controlPoints
        expect(breathing.x1 > 0 && breathing.y1 == 0, "it starts slow: its first control point leaves the start along the time axis, got \(breathing)")
        expect(breathing.y2 == 1 && breathing.x2 < 1, "it ends slow: its last control point arrives at full progress before the end, got \(breathing)")
        expect(abs((1 - breathing.x2) - breathing.x1) < 1e-9, "it mirrors itself, so the way down matches the way up, got \(breathing)")
        expect(oneShot.x1 == 0, "the one-shot starts at full speed")
        expect(breathing.x1 != oneShot.x1 || breathing.x2 != oneShot.x2, "the breathing curve is its own, not the one-shot's")
    }

    private static func stepsAreShortAndFastIsFaster() {
        expect(MotionStep.fast.seconds == 0.12, "the fast step is 0.12s, got \(MotionStep.fast.seconds)")
        expect(MotionStep.standard.seconds == 0.18, "the standard step is 0.18s (the dock panels' motion), got \(MotionStep.standard.seconds)")
        expect(MotionStep.fast.seconds < MotionStep.standard.seconds, "fast is faster than standard")
    }

    private static func reduceMotionSkipsTheStepInsteadOfShorteningIt() {
        for step in [MotionStep.fast, .standard] {
            expect(step.duration(reduceMotion: false) == step.seconds, "\(step) runs its own length")
            expect(step.duration(reduceMotion: true) == 0, "\(step) doesn't run under Reduce Motion")
        }
    }

    private static func theEasingRunsFromZeroToOneAndEasesOut() {
        expect(MotionEasing.eased(0) == 0 && MotionEasing.eased(1) == 1, "the easing runs from 0 to 1")
        expect(MotionEasing.eased(-1) == 0 && MotionEasing.eased(2) == 1, "progress outside 0...1 clamps")
        expect(MotionEasing.eased(0.5) > 0.5, "it eases out: past halfway at half the time, got \(MotionEasing.eased(0.5))")
        let samples = stride(from: 0.0, through: 1.0, by: 0.05).map(MotionEasing.eased)
        expect(zip(samples, samples.dropFirst()).allSatisfy { $0 < $1 }, "it rises steadily: \(samples)")
        let gains = zip(samples, samples.dropFirst()).map { $1 - $0 }
        expect(zip(gains, gains.dropFirst()).allSatisfy { $0 >= $1 - 1e-9 }, "quick at first, settling: each step gains no more than the last, got \(gains)")
        // The system's own ease-out, cubic-bezier(0, 0, 0.58, 1), is at 0.684 halfway through the time.
        expect(abs(MotionEasing.eased(0.5) - 0.684) < 0.005, "it traces the system ease-out, got \(MotionEasing.eased(0.5)) at 0.5")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
