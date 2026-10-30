import Foundation
import QuestmasterCore

struct TrackerAvatarAnimationTests {
    static func run() {
        decodesTheBardsFile()
        aLoopCyclesEachTrackOnItsOwnClock()
        aOneShotHoldsItsLastFrame()
        aFinishLastsItsLongestTrackAndHoldsItsLastFrame()
        aMissingOptionalTrackStillDecodes()
        aPoseWithBehindAndFrontOfDifferentLengthsPlaysEachOnItsOwnClock()
        aFinishChangesAtItsOwnSteps()
        aBadFileThrows()
        aCatalogShowsAnAvatarOnlyForAMasterWhoseClassHasArt()
        print("TrackerAvatarAnimationTests: all tests passed")
    }

    /// The bard's file, read from the app's resources beside this test directory.
    private static func bardJSON() -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Resources/Sprites/bard/animation.json")
        guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fail("the bard's animation.json should read as a JSON object at \(url.path)")
        }
        return json
    }

    private static func decode(_ json: [String: Any]) throws -> TrackerAvatarAnimation {
        try TrackerAvatarAnimation(data: JSONSerialization.data(withJSONObject: json))
    }

    /// The bard's file with one pose's JSON edited.
    private static func bard(editing name: String, _ edit: (inout [String: Any]) -> Void) throws -> TrackerAvatarAnimation {
        var json = bardJSON()
        var poses = json["poses"] as? [String: Any] ?? [:]
        var pose = poses[name] as? [String: Any] ?? [:]
        edit(&pose)
        poses[name] = pose
        json["poses"] = poses
        return try decode(json)
    }

    private static func decodesTheBardsFile() {
        guard let animation = try? decode(bardJSON()) else {
            fail("the bard's file should decode")
        }
        expect(animation.idle == TrackerAvatarIdle(legRows: 37, eyeRow: 48, eyeColumns: 56...63), "idle should carry the bard's leg rows, eye row and eye columns")
        expect(animation.releaseHand == TrackerAvatarPixel(x: 141, y: 64), "the release hand should be the bard's hand pixel")
        expect(animation.fidgets.map(\.name) == ["hat", "yawn"], "fidgets should come in name order")
        expect(animation.fidgets.first?.track.steps.map(\.frame) == [2, 3, 2], "the hat should play its three idle frames")
        expect(animation.fidgets.last?.track.seconds == 0.6, "the yawn should hold its frame for 0.6 s")
        let pondering = animation.animation(for: .pondering)
        expect(pondering?.footRow == 160 && pondering?.bodyColumn == 49, "pondering should stand at the bard's foot row and body column")
        expect(pondering?.loop?.character.steps == [TrackerAvatarStep(frame: 1, seconds: 0.5), TrackerAvatarStep(frame: 2, seconds: 0.5), TrackerAvatarStep(frame: 3, seconds: 0.5)],
               "pondering should cycle f1 to f3 at half a second a frame")
        let calling = animation.animation(for: .callingOut)?.loop
        expect(calling?.front?.steps.map(\.frame) == [1, 2, 3] && calling?.behind == nil, "calling out should cycle a front layer and no behind layer")
        expect(animation.animation(for: .idle)?.loop == nil && animation.animation(for: .idle)?.once == nil, "idle should play no block")
    }

    private static func aLoopCyclesEachTrackOnItsOwnClock() {
        guard let loop = (try? decode(bardJSON()))?.animation(for: .studying)?.loop else {
            fail("studying should have a loop")
        }
        expect(near(loop.character.seconds, 1.2), "a studying loop should be three frames of 0.4 s, got \(loop.character.seconds)")
        expect(loop.character.frame(at: 0.1, looping: true) == 1, "the first 0.4 s should show f1")
        expect(loop.character.frame(at: 0.5, looping: true) == 2, "the next 0.4 s should show f2")
        expect(loop.character.frame(at: 1.3, looping: true) == 1, "a loop should wrap back to f1 after its cycle")
    }

    /// A one-shot plays its steps once and holds the last frame; the summoning's effect and the figure share its length.
    private static func aOneShotHoldsItsLastFrame() {
        guard let once = (try? decode(bardJSON()))?.animation(for: .summoning)?.once else {
            fail("summoning should have a one-shot")
        }
        expect(near(once.seconds, 1), "a summoning should last one second, got \(once.seconds)")
        expect(once.character.starts == [0, 0.18, 0.54], "a summoning should lead in on f2 and strike on f1, got \(once.character.starts)")
        expect(once.character.frame(at: 0, looping: false) == 2, "a summoning should lead in on f2")
        expect(once.character.frame(at: 0.3, looping: false) == 1, "a summoning should strike on f1")
        expect(once.character.frame(at: 0.9, looping: false) == 3, "a summoning should hold f3 to its end")
        expect(once.character.frame(at: 5, looping: false) == 3, "a summoning should hold its last frame past its end")
        expect(once.behind?.frame(at: 0.3, looping: false) == 1, "a summoning's ground circle should strike with the figure")
        expect(once.front == nil, "a summoning has no front layer")
        expect(near((try? decode(bardJSON()))?.animation(for: .bow)?.once?.seconds ?? 0, 2), "a bow should last two seconds")
    }

    private static func aFinishLastsItsLongestTrackAndHoldsItsLastFrame() {
        guard let animation = try? decode(bardJSON()), let studying = animation.animation(for: .studying)?.finish,
              let inscribing = animation.animation(for: .inscribing)?.finish else {
            fail("studying and inscribing should have finishes")
        }
        expect(studying.seconds == 0.75, "a studying finish should last f4 and f5, 0.75 s, got \(studying.seconds)")
        expect(studying.character.frame(at: 0.1, looping: false) == 4, "a finish should open on f4")
        expect(studying.character.frame(at: 0.3, looping: false) == 5, "a finish should move to f5 when f4 has shown")
        expect(studying.character.frame(at: 9, looping: false) == 5, "a finish should hold f5 once it has ended")
        expect(inscribing.seconds == 0.75 && inscribing.character.steps.count == 1, "inscribing's finish should be one frame for the whole finish")
        expect(inscribing.character.frame(at: 0.7, looping: false) == 4, "inscribing should hold f4 for its finish")
    }

    private static func aMissingOptionalTrackStillDecodes() {
        let animation = try? bard(editing: "11-calling-out") { pose in
            var loop = pose["loop"] as? [String: Any] ?? [:]
            loop.removeValue(forKey: "front")
            pose["loop"] = loop
        }
        expect(animation?.animation(for: .callingOut)?.loop?.front == nil, "a loop without its optional front track should decode with none")
    }

    /// A 1-frame character and an 8-frame front each cycle on their own clock, and neither waits for the other.
    private static func aPoseWithBehindAndFrontOfDifferentLengthsPlaysEachOnItsOwnClock() {
        let eightFrames = (1...8).map { [$0, 0.125] as [Any] }
        let animation = try? bard(editing: "11-calling-out") { pose in
            pose["loop"] = [
                "character": [[1, 0.25]],
                "front": eightFrames,
            ]
        }
        guard let loop = animation?.animation(for: .callingOut)?.loop else {
            fail("a loop with a 1-frame character and an 8-frame front should decode")
        }
        expect(loop.character.seconds == 0.25 && loop.front?.seconds == 1, "each track should keep its own length")
        expect(loop.seconds == 1, "the loop should last as long as its longest track")
        for step in 0..<32 {
            let time = Double(step) * 0.0625
            expect(loop.character.frame(at: time, looping: true) == 1, "the 1-frame character should always show f1, at \(time) s")
            expect(loop.front?.frame(at: time, looping: true) == Int(time / 0.125) % 8 + 1, "the 8-frame front should cycle on its own clock, at \(time) s")
        }
    }

    /// A finish changes frame at its own steps, so the director can wake at each one.
    private static func aFinishChangesAtItsOwnSteps() {
        let finish = try? decode(bardJSON()).animation(for: .studying)?.finish
        expect(finish?.changes == [0.25], "a studying finish should change once, at 0.25 s, got \(String(describing: finish?.changes))")
        let finishWithEffect = try? bard(editing: "03-studying") { pose in
            pose["finish"] = [
                "character": [[4, 0.25], [5, 0.5]],
                "front": [[1, 0.125], [2, 0.625]],
            ]
        }.animation(for: .studying)?.finish
        expect(finishWithEffect?.changes == [0.125, 0.25], "a finish should change at every layer's step, got \(String(describing: finishWithEffect?.changes))")
    }

    private static func aBadFileThrows() {
        expectThrows(TrackerAvatarAnimationError.unsupportedVersion(2), "a version the build doesn't read") {
            var json = bardJSON()
            json["version"] = 2
            _ = try decode(json)
        }
        expectThrows(TrackerAvatarAnimationError.missingPose("12-bow"), "a file that leaves out a pose") {
            var json = bardJSON()
            var poses = json["poses"] as? [String: Any] ?? [:]
            poses.removeValue(forKey: "12-bow")
            json["poses"] = poses
            _ = try decode(json)
        }
        expectThrows(TrackerAvatarAnimationError.unknownPose("13-fizzle"), "a pose the avatar doesn't play") {
            var json = bardJSON()
            var poses = json["poses"] as? [String: Any] ?? [:]
            poses["13-fizzle"] = poses["12-bow"]
            json["poses"] = poses
            _ = try decode(json)
        }
        expectThrows(TrackerAvatarAnimationError.misplacedBlock("09-summoning"), "a one-shot with a loop instead of its once") {
            _ = try bard(editing: "09-summoning") { pose in
                pose["loop"] = ["character": [[1, 0.25]]]
                pose.removeValue(forKey: "once")
            }
        }
        expectThrows(TrackerAvatarAnimationError.misplacedBlock("01-idle"), "idle with a loop") {
            _ = try bard(editing: "01-idle") { pose in
                pose["loop"] = ["character": [[1, 0.25]]]
            }
        }
        expectThrows(TrackerAvatarAnimationError.misplacedBlock("02-pondering"), "a finish on a pose that isn't a cast") {
            _ = try bard(editing: "02-pondering") { pose in
                pose["finish"] = ["character": [[4, 0.25]]]
            }
        }
        expectThrows(TrackerAvatarAnimationError.unknownLayer("middle"), "a layer the avatar doesn't draw") {
            _ = try bard(editing: "11-calling-out") { pose in
                pose["loop"] = ["character": [[1, 0.25]], "middle": [[1, 0.25]]]
            }
        }
        expectThrows(TrackerAvatarAnimationError.invalidTrack("02-pondering has no character track"), "a block with no character track") {
            _ = try bard(editing: "02-pondering") { pose in
                pose["loop"] = ["front": [[1, 0.25]]]
            }
        }
        expectThrows(TrackerAvatarAnimationError.invalidTrack("02-pondering character"), "a step held for no time") {
            _ = try bard(editing: "02-pondering") { pose in
                pose["loop"] = ["character": [[1, 0]]]
            }
        }
        expectThrows(TrackerAvatarAnimationError.invalidTrack("02-pondering character"), "a track with no steps") {
            _ = try bard(editing: "02-pondering") { pose in
                pose["loop"] = ["character": [] as [Any]]
            }
        }
        expectThrows(TrackerAvatarAnimationError.invalidEyeColumns, "eye columns that aren't a first and a last column") {
            var json = bardJSON()
            var idle = json["idle"] as? [String: Any] ?? [:]
            idle["eye_columns"] = [56, 60, 63]
            json["idle"] = idle
            _ = try decode(json)
        }
    }

    private static func aCatalogShowsAnAvatarOnlyForAMasterWhoseClassHasArt() {
        guard let animation = try? decode(bardJSON()) else {
            fail("the bard's file should decode")
        }
        let catalog = TrackerAvatarCatalog(animations: ["bard": animation])
        let bard = AvatarSessionFixture.session(sessionClass: "bard")
        expect(catalog.classID(for: bard) == "bard", "a bard master should show the bard's avatar")
        expect(catalog.animation(for: bard) == animation, "a bard master should get the bard's animation")
        expect(catalog.classID(for: AvatarSessionFixture.session(sessionClass: "wizard")) == nil, "a class with no art should show no avatar")
        expect(catalog.classID(for: AvatarSessionFixture.session(sessionClass: "bard", parentID: "qm-1")) == nil, "a worker should show no avatar")
        expect(catalog.classID(for: nil) == nil, "no attached session should show no avatar")
    }

    /// Sums of the file's decimal seconds carry rounding, so durations compare within a nanosecond.
    private static func near(_ value: TimeInterval, _ expected: TimeInterval) -> Bool {
        abs(value - expected) < 1e-9
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func expectThrows(_ expected: TrackerAvatarAnimationError, _ message: String, _ body: () throws -> Void) {
        do {
            try body()
            fail("\(message) should throw \(expected)")
        } catch let error as TrackerAvatarAnimationError {
            expect(error == expected, "\(message) should throw \(expected), got \(error)")
        } catch {
            fail("\(message) should throw \(expected), got \(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("TrackerAvatarAnimationTests failed: \(message)\n", stderr)
        exit(1)
    }
}
