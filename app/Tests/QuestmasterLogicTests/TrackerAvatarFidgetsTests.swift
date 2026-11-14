import Foundation
import QuestmasterCore

struct TrackerAvatarFidgetsTests {
    static func run() {
        gapsAreEightToFifteenSeconds()
        aFidgetPlaysItsFramesWithItsTimings()
        aFidgetNeverFollowsItself()
        aFidgetWithMissingArtIsSkipped()
        anyOtherPoseStopsAFidgetAtOnce()
        noFidgetsUnderReduceMotion()
        print("TrackerAvatarFidgetsTests: all tests passed")
    }

    /// The bard's fidgets, as his file gives them: the hat and the yawn.
    private static let bardFidgets = AvatarAnimationFixture.bard().fidgets

    /// A generator with a fixed seed, so the gaps and picks repeat exactly.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// One frame of a played fidget: its art frame, and how long it showed, in hundredths of a second.
    private struct Shown: Equatable {
        let frame: Int
        let centiseconds: Int
    }

    /// Walks the idle pose forward to `end`, collecting each fidget as the frames it showed, in order.
    private static func fidgetsPlayed(_ fidgets: inout TrackerAvatarFidgets<SeededGenerator>, until end: TimeInterval) -> [[Shown]] {
        var played: [[Shown]] = []
        var current: [Shown] = []
        var now: TimeInterval = 0
        while now < end {
            let frame = fidgets.frame(pose: .idle, at: now)
            guard let next = frame.nextChange else {
                break
            }
            if let artFrame = frame.artFrame {
                current.append(Shown(frame: artFrame, centiseconds: Int(((next - now) * 100).rounded())))
            } else if !current.isEmpty {
                played.append(current)
                current = []
            }
            now = next
        }
        if !current.isEmpty {
            played.append(current)
        }
        return played
    }

    private static func gapsAreEightToFifteenSeconds() {
        for seed: UInt64 in 1...20 {
            var fidgets = TrackerAvatarFidgets(available: bardFidgets, reducesMotion: false, random: SeededGenerator(state: seed))
            let first = fidgets.frame(pose: .idle, at: 0)
            expect(first.artFrame == nil, "he should breathe at rest before his first fidget")
            guard let due = first.nextChange else {
                fail("the first fidget should be due")
            }
            expect(TrackerAvatarFidgetTiming.gapSeconds.contains(due), "the first gap should be 8 to 15 s, got \(due) for seed \(seed)")
        }
    }

    /// Each fidget plays its frames in the table's order, each for the table's time.
    private static func aFidgetPlaysItsFramesWithItsTimings() {
        let table: [[Shown]] = [
            [Shown(frame: 2, centiseconds: 20), Shown(frame: 3, centiseconds: 20), Shown(frame: 2, centiseconds: 20)],
            [Shown(frame: 7, centiseconds: 60)],
        ]
        var fidgets = TrackerAvatarFidgets(available: bardFidgets, reducesMotion: false, random: SeededGenerator(state: 3))
        let played = fidgetsPlayed(&fidgets, until: 400)
        expect(played.count >= 10, "a few hundred seconds should hold several fidgets, got \(played.count)")
        for fidget in played {
            expect(table.contains(fidget), "a fidget should play one table sequence, got \(fidget)")
        }
    }

    /// No two fidgets in a row are the same one. Each fidget starts on its own first frame, so the first frame tells them apart.
    private static func aFidgetNeverFollowsItself() {
        var fidgets = TrackerAvatarFidgets(available: bardFidgets, reducesMotion: false, random: SeededGenerator(state: 11))
        let played = fidgetsPlayed(&fidgets, until: 3000)
        expect(played.count >= 100, "a long stretch should hold many fidgets, got \(played.count)")
        for (earlier, later) in zip(played, played.dropFirst()) {
            expect(earlier.first?.frame != later.first?.frame, "the same fidget should not play twice in a row")
        }
        let kinds = Set(played.compactMap { $0.first?.frame })
        expect(kinds == [2, 7], "every fidget should come up over a long stretch, got \(kinds.sorted())")
    }

    /// A fidget whose art is missing is skipped. With only the yawn's art in, the yawn plays, then its slot is empty, and it plays
    /// again on a later gap. With no art at all, nothing plays.
    private static func aFidgetWithMissingArtIsSkipped() {
        var yawnOnly = TrackerAvatarFidgets(available: bardFidgets.filter { $0.name == "yawn" }, reducesMotion: false, random: SeededGenerator(state: 5))
        let yawns = fidgetsPlayed(&yawnOnly, until: 600)
        expect(yawns.count >= 5, "the yawn should keep coming back, got \(yawns.count)")
        expect(yawns.allSatisfy { $0 == [Shown(frame: 7, centiseconds: 60)] }, "only the yawn should play, got \(yawns)")

        var nothing = TrackerAvatarFidgets(available: [], reducesMotion: false, random: SeededGenerator(state: 5))
        expect(fidgetsPlayed(&nothing, until: 600).isEmpty, "with no art, no fidget should play")
    }

    /// A cast, calling out or any other pose stops the fidget where it is, and the idle gap starts again once he is idle.
    private static func anyOtherPoseStopsAFidgetAtOnce() {
        var fidgets = TrackerAvatarFidgets(available: bardFidgets, reducesMotion: false, random: SeededGenerator(state: 2))
        let due = fidgets.frame(pose: .idle, at: 0).nextChange ?? 0
        let playing = fidgets.frame(pose: .idle, at: due)
        expect(playing.artFrame != nil, "a fidget should be playing when it is due")
        let interrupted = fidgets.frame(pose: .callingOut, at: due + 0.05)
        expect(interrupted.artFrame == nil && interrupted.nextChange == nil, "calling out should stop the fidget at once, got \(interrupted)")
        let idle = fidgets.frame(pose: .idle, at: due + 1)
        expect(idle.artFrame == nil, "he should breathe again once calling out ends")
        expect(TrackerAvatarFidgetTiming.gapSeconds.contains((idle.nextChange ?? 0) - (due + 1)), "his idle gap should start again, got \(String(describing: idle.nextChange))")
    }

    private static func noFidgetsUnderReduceMotion() {
        var fidgets = TrackerAvatarFidgets(available: bardFidgets, reducesMotion: true, random: SeededGenerator(state: 9))
        expect(fidgetsPlayed(&fidgets, until: 600).isEmpty, "no fidget should play under Reduce Motion")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TrackerAvatarFidgetsTests failed: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("TrackerAvatarFidgetsTests failed: \(message)\n", stderr)
        exit(1)
    }
}
