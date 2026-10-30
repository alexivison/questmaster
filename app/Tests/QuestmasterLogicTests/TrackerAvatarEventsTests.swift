import Foundation
import QuestmasterCore

struct TrackerAvatarEventsTests {
    static func run() {
        firstPayloadIsTheBaseline()
        spawnFiresForANewWorkerOfTheAttachedMaster()
        attachAndSwitchAreBaselines()
        otherMastersAndNonBardsFireNothing()
        exchangesFireOnlyWhenTheyChange()
        print("TrackerAvatarEventsTests: all tests passed")
    }

    private static let master = "qm-m1"
    private static let at = "2026-10-28T09:00:00Z"

    private static func rows(
        workers: [TrackerSession] = [],
        masterClass: String? = "bard",
        masterID: String = master
    ) -> [TrackerSession] {
        [AvatarSessionFixture.session(id: masterID, sessionClass: masterClass)] + workers
    }

    private static func worker(_ id: String, parent: String = master, exchange: (kind: String, at: String)? = nil) -> TrackerSession {
        AvatarSessionFixture.session(id: id, sessionClass: nil, state: "working", parentID: parent, exchange: exchange)
    }

    private static func firstPayloadIsTheBaseline() {
        var detector = TrackerAvatarEventDetector(catalog: AvatarAnimationFixture.catalog())
        let events = detector.observe(rows(workers: [worker("qm-w1")]), attachedID: master)
        expect(events.isEmpty, "the first payload should be a baseline, got \(events)")
    }

    private static func spawnFiresForANewWorkerOfTheAttachedMaster() {
        var detector = TrackerAvatarEventDetector(catalog: AvatarAnimationFixture.catalog())
        _ = detector.observe(rows(workers: [worker("qm-w1")]), attachedID: master)
        let events = detector.observe(rows(workers: [worker("qm-w1"), worker("qm-w2")]), attachedID: master)
        expect(events == [.spawned(worker: "qm-w2")], "a new worker should spawn once, got \(events)")
        expect(detector.observe(rows(workers: [worker("qm-w1"), worker("qm-w2")]), attachedID: master).isEmpty, "a settled roster should fire nothing")
    }

    private static func attachAndSwitchAreBaselines() {
        var detector = TrackerAvatarEventDetector(catalog: AvatarAnimationFixture.catalog())
        _ = detector.observe(rows(workers: [worker("qm-w1")]), attachedID: master)
        expect(detector.observe(rows(workers: [worker("qm-w1")]), attachedID: nil).isEmpty, "detaching should fire nothing")
        let attach = detector.observe(rows(workers: [worker("qm-w1"), worker("qm-w2")]), attachedID: master)
        expect(attach.isEmpty, "attaching should not fire for workers already there, got \(attach)")
        let switched = detector.observe(rows(workers: [worker("qm-w1")], masterID: "qm-m2"), attachedID: "qm-m2")
        expect(switched.isEmpty, "a switch should not fire for the other master's workers, got \(switched)")
    }

    private static func otherMastersAndNonBardsFireNothing() {
        var detector = TrackerAvatarEventDetector(catalog: AvatarAnimationFixture.catalog())
        _ = detector.observe(rows(workers: [worker("qm-w1")], masterClass: "wizard"), attachedID: master)
        let wizard = detector.observe(rows(workers: [worker("qm-w1"), worker("qm-w2")], masterClass: "wizard"), attachedID: master)
        expect(wizard.isEmpty, "a wizard master should show no events, got \(wizard)")

        var other = TrackerAvatarEventDetector(catalog: AvatarAnimationFixture.catalog())
        _ = other.observe(rows(workers: [worker("qm-w1", parent: "qm-m2")]), attachedID: master)
        let elsewhere = other.observe(rows(workers: [worker("qm-w1", parent: "qm-m2", exchange: ("report", at))]), attachedID: master)
        expect(elsewhere.isEmpty, "another master's worker should show no events, got \(elsewhere)")
    }

    private static func exchangesFireOnlyWhenTheyChange() {
        var detector = TrackerAvatarEventDetector(catalog: AvatarAnimationFixture.catalog())
        _ = detector.observe(rows(workers: [worker("qm-w1")]), attachedID: master)
        let message = detector.observe(rows(workers: [worker("qm-w1", exchange: ("instructions", at))]), attachedID: master)
        expect(message == [.messaged(worker: "qm-w1")], "a new instruction should be a message, got \(message)")
        let repeated = detector.observe(rows(workers: [worker("qm-w1", exchange: ("instructions", at))]), attachedID: master)
        expect(repeated.isEmpty, "the same exchange should fire once, got \(repeated)")
        let report = detector.observe(rows(workers: [worker("qm-w1", exchange: ("report", "2026-10-28T09:01:00Z"))]), attachedID: master)
        expect(report == [.reported(worker: "qm-w1")], "a new report should be a report, got \(report)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("TrackerAvatarEventsTests failed: \(message)\n", stderr)
        exit(1)
    }
}
