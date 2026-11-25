import Foundation
import QuestmasterCore

/// The master's company in its slot: the fixed-step row, its "+n" overflow, the master's gradual push, and the familiars' scales.
struct TrackerCompanyLayoutTests {
    static func run() {
        fireRowGrowsLeftwardOneFixedAdvancePerWorker()
        slimFamiliarsShowMoreThanSix()
        wideFamiliarsOverlapOnlyToHoldSix()
        mixedFamiliarsKeepTheirOwnAdvances()
        theMasterPushesLeftGraduallyAndStopsAtItsEdge()
        noWorkersLeavesTheSlotAsItWas()
        liveWorkersAreTheMastersStartedWorkersInSpawnOrder()
        familiarScalesComeFromTheirFiles()
        print("TrackerCompanyLayoutTests: all tests passed")
    }

    /// The study's Fire Elemental at 50%: 26 pt wide, so the advance is 32 pt. Its first slot's left edge runs 175, 143, 111, 79, 47, 15
    /// as workers one to six arrive, and each new worker pushes the others one advance left.
    private static func fireRowGrowsLeftwardOneFixedAdvancePerWorker() {
        let fire = Array(repeating: 26.0, count: 8)
        let master = TrackerCompanyLayout.MasterReach(left: 40, right: 45)
        for count in 1...6 {
            let result = layout(Array(fire.prefix(count)), master: master)
            expect(result.familiars.count == count && result.overflow == 0, "\(count) Fire workers should all show, got \(result.familiars.count) and \(result.overflow) counted")
            expect(abs(result.familiars[0].left - Double(15 + (6 - count) * 32)) < 1e-6,
                   "worker one of \(count) should start at \(15 + (6 - count) * 32), got \(result.familiars[0].left)")
            for pair in zip(result.familiars, result.familiars.dropFirst()) {
                expect(abs(pair.1.left - pair.0.left - 32) < 1e-6, "neighbours should stand one advance (32) apart, got \(pair.1.left - pair.0.left)")
            }
        }
        let eight = layout(fire, master: master)
        expect(eight.familiars.count == 6 && eight.overflow == 2, "eight Fire workers should show six and count two, got \(eight.familiars.count) and \(eight.overflow)")
        expect(eight.familiars.last.map { $0.left + $0.restWidth <= 204 + 1e-6 } == true, "the row should end inside the overflow reserve")
    }

    /// A slim familiar keeps its own gap and holds more than six: the Light Spirit (18 pt) shows eight, the Hawk (15.5 pt) nine.
    private static func slimFamiliarsShowMoreThanSix() {
        let master = TrackerCompanyLayout.MasterReach(left: 40, right: 45)
        let hawks = layout(Array(repeating: 15.5, count: 10), master: master)
        expect(hawks.familiars.count == 9 && hawks.overflow == 1, "ten Hawks should show nine and count one, got \(hawks.familiars.count) and \(hawks.overflow)")
        expect(abs(hawks.familiars[1].left - hawks.familiars[0].left - 21.5) < 1e-6, "Hawks should stand 21.5 apart (width plus the gap)")
        let spirits = layout(Array(repeating: 18, count: 10), master: master)
        expect(spirits.familiars.count == 8, "ten Light Spirits should show eight, got \(spirits.familiars.count)")
    }

    /// A wide familiar overlaps its neighbours only as far as six fit: the Bear (84.5 pt) advances 20.9 pt, a 63.6 pt overlap, and the War
    /// Hound at 75% (45.75 pt) advances 28.65 pt.
    private static func wideFamiliarsOverlapOnlyToHoldSix() {
        let master = TrackerCompanyLayout.MasterReach(left: 40, right: 45)
        let bears = layout(Array(repeating: 84.5, count: 7), master: master)
        expect(bears.familiars.count == 6 && bears.overflow == 1, "seven Bears should show six and count one, got \(bears.familiars.count) and \(bears.overflow)")
        expect(abs(bears.familiars[1].left - bears.familiars[0].left - 20.9) < 1e-6, "Bears should advance 20.9 pt, got \(bears.familiars[1].left - bears.familiars[0].left)")
        let hounds = layout(Array(repeating: 45.75, count: 8), master: master)
        expect(hounds.familiars.count == 6, "eight War Hounds at 75% should show six, got \(hounds.familiars.count)")
        expect(abs(hounds.familiars[1].left - hounds.familiars[0].left - 28.65) < 1e-6, "War Hounds should advance 28.65 pt")
    }

    /// Workers of different familiars keep their own advances: the first worker's advance is its own width plus the gap, not the next one's.
    private static func mixedFamiliarsKeepTheirOwnAdvances() {
        let master = TrackerCompanyLayout.MasterReach(left: 40, right: 45)
        let mixed = layout([26, 84.5], master: master)
        expect(mixed.familiars.count == 2, "a Fire and a Bear should both show, got \(mixed.familiars.count)")
        expect(abs(mixed.familiars[1].left - mixed.familiars[0].left - 32) < 1e-6,
               "the Fire should advance by its own 32 pt, got \(mixed.familiars[1].left - mixed.familiars[0].left)")
    }

    /// The master moves left a gradual 16 pt per worker at 50% (32 × scale), so the study's Wizard reaches his edge at worker five and
    /// stays there; the row's room can push him further only up to that edge.
    private static func theMasterPushesLeftGraduallyAndStopsAtItsEdge() {
        let master = TrackerCompanyLayout.MasterReach(left: 40, right: 45)
        let fire = Array(repeating: 26.0, count: 8)
        // The row's own room can need more than the gradual push: with four Fire workers the row's left edge (79) is already inside the
        // master's right reach plus the gap, so the push there is the room needed (92), capped at the master's edge (80).
        expect(abs(layout(Array(fire.prefix(1)), master: master).masterShift - 16) < 1e-6, "one worker should push the master 16 pt")
        expect(abs(layout(Array(fire.prefix(2)), master: master).masterShift - 32) < 1e-6, "two workers should push the master 32 pt")
        expect(abs(layout(Array(fire.prefix(3)), master: master).masterShift - 60) < 1e-6, "three workers should need 60 pt of room")
        expect(abs(layout(Array(fire.prefix(4)), master: master).masterShift - 80) < 1e-6, "four workers should push the master to its edge, 80 pt")
        expect(abs(layout(fire, master: master).masterShift - 80) < 1e-6, "more workers should not push the master past its edge")
    }

    private static func noWorkersLeavesTheSlotAsItWas() {
        let result = layout([], master: TrackerCompanyLayout.MasterReach(left: 40, right: 45))
        expect(result.familiars.isEmpty && result.overflow == 0 && result.masterShift == 0, "no workers should leave the master where it stands")
    }

    /// A master's live workers are its children that are not stopped, in the payload's order; another master's and stopped rows aren't.
    private static func liveWorkersAreTheMastersStartedWorkersInSpawnOrder() {
        let master = AvatarSessionFixture.session(id: "qm-m", sessionClass: "fighter")
        let rows = [
            master,
            AvatarSessionFixture.session(id: "qm-w2", sessionClass: "fighter", parentID: "qm-m"),
            AvatarSessionFixture.session(id: "qm-x", sessionClass: "fighter", parentID: "qm-other"),
            AvatarSessionFixture.session(id: "qm-w3", sessionClass: "fighter", status: "stopped", parentID: "qm-m"),
            AvatarSessionFixture.session(id: "qm-w1", sessionClass: "fighter", state: "done", parentID: "qm-m"),
        ]
        let live = TrackerCompanyLayout.liveWorkers(of: master, in: rows).map(\.id)
        expect(live == ["qm-w2", "qm-w1"], "a master's live workers should be its unstopped children in payload order, got \(live)")
    }

    /// The familiars' scales come from their files: the War Hound is 75%, the Imp 50%, and a class always draws at 100.
    private static func familiarScalesComeFromTheirFiles() {
        expect(AvatarAnimationFixture.familiar("fighter").scalePercent == 75, "the War Hound should draw at 75%")
        expect(AvatarAnimationFixture.familiar("bard").scalePercent == 50, "the Imp should draw at 50%")
        expect(AvatarAnimationFixture.bard().scalePercent == 100, "a class should draw at 100%")
        var json = AvatarAnimationFixture.familiarJSON("bard")
        json["scale"] = 0
        do {
            _ = try AvatarAnimationFixture.decodeFamiliar(json)
            fail("a familiar with a 0% scale should not read")
        } catch let error as TrackerAvatarAnimationError {
            expect(error == .invalidScale(0), "a 0% scale should be rejected as invalid, got \(error)")
        } catch {
            fail("a 0% scale should give invalid scale, got \(error)")
        }
    }

    private static func layout(_ widths: [Double], master: TrackerCompanyLayout.MasterReach) -> TrackerCompanyLayout.Result {
        TrackerCompanyLayout.layout(restWidths: widths, pushPerWorker: 16, master: master, slotWidth: 240)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("TrackerCompanyLayoutTests failed: \(message)\n", stderr)
        exit(1)
    }
}
