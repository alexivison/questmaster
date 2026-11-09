import Foundation
import QuestmasterCore

struct TrackerAvatarIdleTimelineTests {
    static func run() {
        resumesFromTheAuthoredFrameAndWrapsSparseFiles()
        poseAndFidgetSuspensionRestartAtResumeFrame()
        appliesTheCurrentFrameStencilOnlyDuringBlink()
        aStillIdleUsesItsStencilWithoutAFrameLoop()
        print("TrackerAvatarIdleTimelineTests: all tests passed")
    }

    private static func animation(blink: Bool = true, breathing: Bool = true) -> TrackerAvatarIdleAnimation {
        var json = AvatarAnimationFixture.bardJSON()
        var idle = json["idle"] as? [String: Any] ?? [:]
        idle["blink"] = blink
        if breathing {
            idle["breathing"] = [
                "resume_frame": "01-idle-breath-f3.png",
                "frames": [
                    ["file": "01-idle-breath-f1.png", "seconds": 0.2, "lid_pixels": [[4, 5], [4, 6]]],
                    ["file": "01-idle-breath-f3.png", "seconds": 0.4, "lid_pixels": [[8, 9], [9, 9], [9, 10]]],
                ],
            ]
        }
        json["idle"] = idle
        guard let decoded = try? AvatarAnimationFixture.decode(json), let result = decoded.idle else {
            fputs("TrackerAvatarIdleTimelineTests: fixture should decode\n", stderr)
            exit(1)
        }
        return result
    }

    private static func resumesFromTheAuthoredFrameAndWrapsSparseFiles() {
        var timeline = TrackerAvatarIdleTimeline(animation: animation())
        let start = timeline.frame(pose: .idle, fidgeting: false, at: 10)
        expect(start?.file == "01-idle-breath-f3.png", "the resume frame should start idle")
        expect(start?.nextChange == 10.4, "the first frame should use its authored duration")
        expect(timeline.frame(pose: .idle, fidgeting: false, at: 10.4)?.file == "01-idle-breath-f1.png",
               "the next authored frame should follow, even with a sparse filename")
        expect(timeline.frame(pose: .idle, fidgeting: false, at: 10.6)?.file == "01-idle-breath-f3.png",
               "the authored sequence should wrap to resume_frame")
    }

    private static func poseAndFidgetSuspensionRestartAtResumeFrame() {
        var timeline = TrackerAvatarIdleTimeline(animation: animation())
        _ = timeline.frame(pose: .idle, fidgeting: false, at: 0)
        expect(timeline.frame(pose: .idle, fidgeting: true, at: 0.1) == nil, "a fidget should suspend idle art")
        expect(timeline.frame(pose: .idle, fidgeting: false, at: 20)?.file == "01-idle-breath-f3.png",
               "idle should restart at resume_frame after a fidget")
        expect(timeline.frame(pose: .studying, fidgeting: false, at: 20.1) == nil, "another pose should suspend idle art")
        expect(timeline.frame(pose: .idle, fidgeting: false, at: 50)?.file == "01-idle-breath-f3.png",
               "idle should restart at resume_frame after another pose")
    }

    private static func appliesTheCurrentFrameStencilOnlyDuringBlink() {
        var timeline = TrackerAvatarIdleTimeline(animation: animation())
        let open = timeline.frame(pose: .idle, fidgeting: false, at: 0)
        let closed = timeline.frame(pose: .idle, fidgeting: false, blinkClosed: true, at: 0.4)
        expect(open?.lidPixels.isEmpty == true, "open eyes should have no painted lid pixels")
        expect(closed?.lidPixels == [TrackerAvatarPixel(x: 4, y: 5), TrackerAvatarPixel(x: 4, y: 6)],
               "blink pixels should follow the current sparse frame's full stencil")
        var neverBlink = TrackerAvatarIdleTimeline(animation: animation(blink: false))
        expect(neverBlink.frame(pose: .idle, fidgeting: false, blinkClosed: true, at: 0)?.lidPixels.isEmpty == true,
               "blink:false should keep the authored stencil hidden")
    }

    private static func aStillIdleUsesItsStencilWithoutAFrameLoop() {
        var timeline = TrackerAvatarIdleTimeline(animation: animation(breathing: false))
        let idle = timeline.frame(pose: .idle, fidgeting: false, blinkClosed: true, at: 5)
        expect(idle?.file == "01-idle-f1.png" && idle?.nextChange == nil, "an idle without breathing should rest on its still image")
        expect(idle?.lidPixels.count == 8, "the old eye shorthand should still produce its inclusive lid stencil")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TrackerAvatarIdleTimelineTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
