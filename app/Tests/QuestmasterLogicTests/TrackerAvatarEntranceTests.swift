import Foundation
import QuestmasterCore

/// A company size's `entrance`: how its ticks read and index, what its shape must be, and that every bundled familiar has one at each size
/// with its art beside it.
struct TrackerAvatarEntranceTests {
    static func run() {
        everyBundledCompanySizeHasItsEntrance()
        anEntranceReadsItsPartsAndEffectsByTick()
        aTickIsIndexedByItsElapsedTime()
        anEntrancePlaysAtThePlaybackSpeed()
        anEntranceRejectsAShapeItCannotPlay()
        print("TrackerAvatarEntranceTests: all tests passed")
    }

    private static let classIDs = [
        "paladin", "wizard", "druid", "barbarian", "rogue", "cleric", "bard", "ranger", "necromancer", "sorcerer", "fighter",
    ]
    private static let sizes = ["1.5x", "1.25x", "1x"]

    /// The bundled company size's folder, from `Resources/Familiars/<class>/company/<size>/`.
    private static func companyFolder(_ classID: String, _ size: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Resources/Familiars/\(classID)/company/\(size)", isDirectory: true)
    }

    private static func everyBundledCompanySizeHasItsEntrance() {
        for classID in classIDs {
            for size in sizes {
                let json = AvatarAnimationFixture.companySizeJSON(classID, size)
                guard let animation = try? AvatarAnimationFixture.decodeFamiliar(json) else {
                    fail("the \(classID) \(size) company file should decode")
                }
                guard let entrance = animation.entrance else {
                    fail("the \(classID) \(size) company size should carry its entrance")
                }
                expect(entrance.steps >= 10 && entrance.steps <= 60, "the \(classID) \(size) entrance plays 0.5 to 3 s, got \(entrance.steps) ticks")
                // Every image the entrance names is in its folder, so the App can draw it.
                let folder = companyFolder(classID, size)
                let names = (entrance.behind + entrance.front).compactMap { $0 } + entrance.parts.flatMap { part in
                    part.steps.compactMap { $0?.image }
                }
                for name in Set(names) {
                    expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path),
                           "the \(classID) \(size) entrance names \(name), which is not in its folder")
                }
            }
        }
    }

    private static func anEntranceReadsItsPartsAndEffectsByTick() {
        guard let entrance = try? TrackerAvatarEntrance(
            tick: MotionTick.seconds,
            origin: .init(x: 1, y: -2),
            parts: [
                .init(name: "figure", steps: [
                    nil,
                    .init(image: nil, dx: 2, dy: -4, window: .init(x0: 0, y0: 0, x1: 260, y1: 94)),
                    .init(image: "entrance-dither-f1.png", dx: 0, dy: 0, window: nil),
                    .init(image: nil, dx: 0, dy: 0, window: nil),
                ]),
            ],
            behind: [nil, "entrance-behind-f1.png", nil, nil],
            front: [nil, nil, "entrance-front-f1.png", nil]
        ) else {
            fail("a valid entrance should build")
        }
        expect(entrance.steps == 4, "the entrance has its four ticks")
        expect(abs(entrance.seconds - 4 * TrackerAvatarEntrance.playbackTickSeconds) < 1e-9, "the entrance lasts its ticks at the playback speed, got \(entrance.seconds)")
        expect(entrance.origin == .init(x: 1, y: -2), "the effects' origin is kept")
        expect(entrance.parts.map(\.name) == ["figure"], "the parts are kept in name order")
        expect(entrance.parts[0].steps[1]?.dy == -4 && entrance.parts[0].steps[1]?.window?.y1 == 94, "a step keeps its offset and window")
        expect(entrance.parts[0].steps[0] == nil, "a nil step hides its part on that tick")
        expect(entrance.behind[1] == "entrance-behind-f1.png" && entrance.front[2] == "entrance-front-f1.png", "the effects are per tick")
    }

    private static func aTickIsIndexedByItsElapsedTime() {
        guard let entrance = try? TrackerAvatarEntrance(
            tick: MotionTick.seconds, origin: .init(x: 0, y: 0),
            parts: [.init(name: "figure", steps: [nil, nil, .init(image: nil, dx: 0, dy: 0, window: nil)])],
            behind: [nil, nil, nil], front: [nil, nil, nil]
        ) else {
            fail("a three-tick entrance should build")
        }
        let tick = TrackerAvatarEntrance.playbackTickSeconds
        expect(entrance.index(at: -0.01) == nil, "nothing shows before the entrance starts")
        expect(entrance.index(at: 0) == 0, "the first tick is at 0")
        expect(entrance.index(at: tick) == 1, "the second tick starts one playback tick in, despite the division's rounding")
        expect(entrance.index(at: 2 * tick + 0.001) == 2, "the last tick holds to the end")
        expect(entrance.index(at: 3 * tick) == nil, "the entrance is over once its last tick has run")
    }

    /// The same file reads at the playback speed the app plays avatars at: its tick is the authored one divided by the speed, so the entrance
    /// is shorter and each tick comes sooner than at speed 1.
    private static func anEntrancePlaysAtThePlaybackSpeed() {
        let rest = TrackerAvatarEntrance.Step(image: nil, dx: 0, dy: 0, window: nil)
        func entrance(speed: Double) throws -> TrackerAvatarEntrance {
            try TrackerAvatarEntrance(tick: MotionTick.seconds, origin: .init(x: 0, y: 0),
                                      parts: [.init(name: "figure", steps: [nil, rest])],
                                      behind: [nil, nil], front: [nil, nil], speed: speed)
        }
        guard let authored = try? entrance(speed: 1), let played = try? entrance(speed: TrackerAvatarAnimation.playbackSpeed) else {
            fail("a two-tick entrance should read at speed 1 and at the playback speed")
        }
        expect(abs(authored.tickSeconds - MotionTick.seconds) < 1e-9, "at speed 1 a tick is the authored 0.05 s, got \(authored.tickSeconds)")
        expect(abs(played.tickSeconds - MotionTick.seconds / TrackerAvatarAnimation.playbackSpeed) < 1e-9,
               "at the playback speed a tick is the authored tick divided by it, got \(played.tickSeconds)")
        expect(played.seconds < authored.seconds, "the entrance is shorter at the playback speed")
        expect(authored.index(at: 0.045) == 0 && played.index(at: 0.045) == 1,
               "a tick sooner than the authored 0.05 s shows the next frame at the playback speed only")
        expect((try? entrance(speed: 0)) == nil, "a speed of zero reads no entrance")
    }

    private static func anEntranceRejectsAShapeItCannotPlay() {
        let rest = TrackerAvatarEntrance.Step(image: nil, dx: 0, dy: 0, window: nil)
        func build(tick: Double = MotionTick.seconds, figure: [TrackerAvatarEntrance.Step?] = [rest, nil], behind: [String?] = [nil, nil],
                   front: [String?] = [nil, nil]) throws -> TrackerAvatarEntrance {
            try TrackerAvatarEntrance(tick: tick, origin: .init(x: 0, y: 0), parts: [.init(name: "figure", steps: figure)], behind: behind, front: front)
        }
        let cases: [(String, () throws -> TrackerAvatarEntrance)] = [
            ("a tick that is not 0.05 s", { try build(tick: 0.1) }),
            ("effects that do not match the parts' ticks", { try build(behind: [nil]) }),
            ("a part with the wrong number of ticks", { try build(figure: [rest]) }),
            ("an odd device pixel offset", { try build(figure: [.init(image: nil, dx: 1, dy: 0, window: nil), rest]) }),
            ("a figure that does not end at rest", { try build(figure: [rest, .init(image: nil, dx: 0, dy: 2, window: nil)]) }),
            ("nothing drawn on the last tick", { try build(figure: [rest, nil]) }),
            ("an effect still drawn on the last tick", { try build(behind: [nil, "entrance-behind-f1.png"]) }),
            ("an empty window", { try build(figure: [rest, .init(image: nil, dx: 0, dy: 0, window: .init(x0: 4, y0: 0, x1: 4, y1: 9))]) }),
            ("an image that is not a PNG in the folder", { try build(figure: [rest, .init(image: "shared/bubble.png", dx: 0, dy: 0, window: nil)]) }),
        ]
        for (name, make) in cases {
            do {
                _ = try make()
                fail("an entrance with \(name) should not read")
            } catch TrackerAvatarAnimationError.invalidEntrance {
                continue
            } catch {
                fail("an entrance with \(name) should fail as invalidEntrance, got \(error)")
            }
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("TrackerAvatarEntranceTests: \(message)\n", stderr)
        exit(1)
    }
}
