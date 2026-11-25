import Foundation
import QuestmasterCore

/// The master's company in its slot: the fit rule's fixed-step row, its "+n" overflow, the master's gradual push, the designed rows from
/// the user's spacing designs, the drop below the feet, and the familiars' scales and rows from their files.
struct TrackerCompanyLayoutTests {
    static func run() {
        fireRowGrowsLeftwardOneFixedAdvancePerWorker()
        slimFamiliarsShowMoreThanSix()
        wideFamiliarsOverlapOnlyToHoldSix()
        mixedFamiliarsKeepTheirOwnAdvances()
        theMasterPushesLeftGraduallyAndStopsAtItsEdge()
        noWorkersLeavesTheSlotAsItWas()
        liveWorkersAreTheMastersStartedWorkersInSpawnOrder()
        designedFullRowStartsAtTen()
        designedFullRowIsTheDesignsRowExactly()
        designedRowShowsFewerWorkersSideBySideWithTheMaster()
        oneWorkerStandsNextToTheMasterInFourClasses()
        designedRowMovesInSmallStepsAndKeepsItsGap()
        designedRowCountsWorkersPastItsCapacity()
        designedRowsEndLeftOfTheMarker()
        visibleBottomsDropBelowTheFeet()
        familiarScalesComeFromTheirFiles()
        companyRowComesFromTheFile()
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

    // MARK: The designed rows

    /// The design's slot is 280 pt wide (the tracker column), and its marker's disc starts 25 pt from the right edge (20 pt disc, 5 pt in).
    private static let slot = 280.0
    private static let markerLeft = 255.0

    /// The full row starts its first familiar at 10 pt, every next one a pitch further right; with no workers the master's body is at the
    /// slot's centre, and a full row moves it to the slot's left edge.
    private static func designedFullRowStartsAtTen() {
        let fire = TrackerCompanyRow(pitch: 35, capacity: 7)
        let master = TrackerCompanyLayout.MasterReach(left: 40, right: 45)
        let full = designed(7, fire, master)
        expect(full.familiars.count == 7 && full.overflow == 0, "a full Fire row should show seven, got \(full.familiars.count) and \(full.overflow) counted")
        for (index, place) in full.familiars.enumerated() {
            expect(abs(place.left - Double(10 + index * 35)) < 1e-6, "Fire \(index + 1) should start at \(10 + index * 35), got \(place.left)")
        }
        expect(abs(full.masterShift - 100) < 1e-6, "a full row should move the master to the slot's left edge (140 - 40 = 100), got \(full.masterShift)")
        let none = designed(0, fire, master)
        expect(none.familiars.isEmpty && none.masterShift == 0, "no workers should leave the designed slot as it was")
    }

    /// A full row's places are the design's: the first familiar at 10 pt, one pitch apart, and the master at the slot's left edge. Whatever the
    /// master's reach, the full row must come out exactly as it always did, with no rounding in the places or the shift.
    private static func designedFullRowIsTheDesignsRowExactly() {
        let rows: [(row: TrackerCompanyRow, width: Double)] = [
            (TrackerCompanyRow(pitch: 47, capacity: 5), 50), (TrackerCompanyRow(pitch: 35, capacity: 7), 25),
            (TrackerCompanyRow(pitch: 31, capacity: 8), 22), (TrackerCompanyRow(pitch: 38, capacity: 6), 50),
        ]
        let masters = [TrackerCompanyLayout.MasterReach(left: 40, right: 45), TrackerCompanyLayout.MasterReach(left: 28, right: 58),
                       TrackerCompanyLayout.MasterReach(left: 36, right: 30)]
        for master in masters {
            for entry in rows {
                let full = designed(entry.row.capacity, entry.row, master, width: entry.width)
                for (index, place) in full.familiars.enumerated() {
                    expect(place.left == TrackerCompanyLayout.designInset + Double(index) * entry.row.pitch,
                           "a full row's place \(index + 1) should be \(TrackerCompanyLayout.designInset + Double(index) * entry.row.pitch) exactly, got \(place.left)")
                }
                expect(full.masterShift == max(0, slot / 2 - master.left), "a full row should move the master to the slot's left edge exactly, got \(full.masterShift)")
            }
        }
    }

    /// With fewer workers the master and the shown workers form one group centred in the slot: the master's visible right edge, 10 pt, then the
    /// familiars at pitch. Three Fire Elementals (26 pt, pitch 35) start 10 pt past the master's visible edge, and the group's visible
    /// extents (the master's left to the last familiar's right) sum to the slot's width, so they are centred.
    private static func designedRowShowsFewerWorkersSideBySideWithTheMaster() {
        let fire = TrackerCompanyRow(pitch: 35, capacity: 7)
        let master = TrackerCompanyLayout.MasterReach(left: 40, right: 45)
        let one = designed(1, fire, master)
        expect(one.familiars.count == 1 && abs(one.familiars[0].left - 174.5) < 1e-9, "one Fire should stand 10 pt past the master's edge (174.5), got \(one.familiars.map(\.left))")
        expect(abs(one.masterShift - 20.5) < 1e-9, "one Fire should move the master 20.5 pt to centre the pair, got \(one.masterShift)")
        let three = designed(3, fire, master)
        expect(three.familiars.map(\.left).elementsAlmostEqual([139.5, 174.5, 209.5]), "three Fire should stand at 139.5, 174.5 and 209.5, got \(three.familiars.map(\.left))")
        expect(abs(three.masterShift - 55.5) < 1e-9, "three Fire should move the master 55.5 pt, got \(three.masterShift)")
        let groupLeft = slot / 2 - three.masterShift - master.left
        let groupRight = (three.familiars.last?.left ?? 0) + 26
        expect(abs(groupLeft + groupRight - slot) < 1e-9, "the group's visible extents should be centred on the slot, got \(groupLeft) to \(groupRight)")
    }

    /// The study's four classes with one worker each, from their files: the master's visible left edge and the familiar's left edge, with the
    /// 10 pt gap between them and the pair centred on the slot. Necromancer 79.5 and 175.5; Wizard 89 and 165; Fighter 59.5 and 170.5;
    /// Ranger 93.5 and 164.5.
    private static func oneWorkerStandsNextToTheMasterInFourClasses() {
        let cases: [(name: String, master: TrackerCompanyLayout.MasterReach, width: Double, row: TrackerCompanyRow, masterLeft: Double, familiarLeft: Double)] = [
            ("necromancer", TrackerCompanyLayout.MasterReach(left: 28, right: 58), 25, TrackerCompanyRow(pitch: 35, capacity: 7), 79.5, 175.5),
            ("wizard", TrackerCompanyLayout.MasterReach(left: 36, right: 30), 26, TrackerCompanyRow(pitch: 35, capacity: 7), 89, 165),
            ("fighter", TrackerCompanyLayout.MasterReach(left: 38, right: 63), 50, TrackerCompanyRow(pitch: 38, capacity: 6), 59.5, 170.5),
            ("ranger", TrackerCompanyLayout.MasterReach(left: 30, right: 31), 22, TrackerCompanyRow(pitch: 31, capacity: 8), 93.5, 164.5),
        ]
        for entry in cases {
            let one = designed(1, entry.row, entry.master, width: entry.width)
            guard let place = one.familiars.first else {
                fail("\(entry.name) should show its one worker")
            }
            let masterLeft = slot / 2 - one.masterShift - entry.master.left
            let masterRight = slot / 2 - one.masterShift + entry.master.right
            expect(abs(masterLeft - entry.masterLeft) < 1e-9, "\(entry.name)'s master should stand with its visible left edge at \(entry.masterLeft), got \(masterLeft)")
            expect(abs(place.left - entry.familiarLeft) < 1e-9, "\(entry.name)'s familiar should stand at \(entry.familiarLeft), got \(place.left)")
            expect(abs(place.left - masterRight - 10) < 1e-9, "\(entry.name)'s familiar should keep 10 pt from the master's visible edge, got \(place.left - masterRight)")
            expect(abs(masterLeft + place.left + entry.width - slot) < 1e-9, "\(entry.name)'s pair should be centred on the slot by its visible extents")
        }
    }

    /// As workers arrive the row moves in steps: a group centred side by side moves each place half a pitch a worker; a row pinned at its
    /// right-most place moves a pitch at once. No worker's place moves more than one pitch, the last familiar stays inside its full row's
    /// right-most place, and until the master reaches the slot's edge it keeps its 10 pt gap to the first familiar.
    private static func designedRowMovesInSmallStepsAndKeepsItsGap() {
        let cases: [(master: TrackerCompanyLayout.MasterReach, width: Double, row: TrackerCompanyRow)] = [
            (TrackerCompanyLayout.MasterReach(left: 28, right: 58), 25, TrackerCompanyRow(pitch: 35, capacity: 7)),
            (TrackerCompanyLayout.MasterReach(left: 36, right: 30), 26, TrackerCompanyRow(pitch: 35, capacity: 7)),
            (TrackerCompanyLayout.MasterReach(left: 38, right: 63), 50, TrackerCompanyRow(pitch: 38, capacity: 6)),
            (TrackerCompanyLayout.MasterReach(left: 30, right: 31), 22, TrackerCompanyRow(pitch: 31, capacity: 8)),
        ]
        for entry in cases {
            let rightMost = TrackerCompanyLayout.designInset + Double(entry.row.capacity - 1) * entry.row.pitch
            var previous: TrackerCompanyLayout.Result?
            for count in 1...(entry.row.capacity + 1) {
                let result = designed(count, entry.row, entry.master, width: entry.width)
                let masterLeft = slot / 2 - result.masterShift - entry.master.left
                let masterRight = slot / 2 - result.masterShift + entry.master.right
                expect(masterLeft >= -1e-9, "the master's visible left edge should stay in the slot, got \(masterLeft) at \(count) workers")
                if let last = result.familiars.last {
                    expect(last.left <= rightMost + 1e-9, "the last familiar should stay at or left of the right-most place (\(rightMost)), got \(last.left) at \(count) workers")
                }
                if let first = result.familiars.first, masterLeft > 1e-9 {
                    expect(abs(first.left - masterRight - 10) < 1e-9, "the master should keep its 10 pt gap while its edge is free, got \(first.left - masterRight) at \(count) workers")
                }
                if let previous, let before = previous.familiars.first, let now = result.familiars.first {
                    expect(abs(now.left - before.left) <= entry.row.pitch + 1e-9,
                           "a worker's place should move no more than one pitch (\(entry.row.pitch)), got \(now.left - before.left) at \(count) workers")
                }
                previous = result
            }
        }
    }

    /// Past its capacity a designed row shows the capacity and counts the rest in the marker; the places stay where the full row put them.
    private static func designedRowCountsWorkersPastItsCapacity() {
        let fire = TrackerCompanyRow(pitch: 35, capacity: 7)
        let master = TrackerCompanyLayout.MasterReach(left: 40, right: 45)
        let nine = designed(9, fire, master)
        expect(nine.familiars.count == 7 && nine.overflow == 2, "nine Fire should show seven and count two, got \(nine.familiars.count) and \(nine.overflow)")
        expect(nine.familiars.map(\.left).elementsAlmostEqual(designed(7, fire, master).familiars.map(\.left)), "a full row shows the same places however many more there are")
        expect(abs(nine.masterShift - 100) < 1e-6, "a full row holds the master at the slot's left edge, got \(nine.masterShift)")
    }

    /// Each design's full row ends left of the marker's disc, with its gap as designed: a row's last right edge, from its pitch, capacity and
    /// resting width, stays at least 5 pt from the marker (the Druid's row is the tightest, at 5 pt).
    private static func designedRowsEndLeftOfTheMarker() {
        // The study's rows: pitch, full row and resting width at scale (points), per class.
        let rows: [(name: String, row: TrackerCompanyRow, width: Double)] = [
            ("barbarian", TrackerCompanyRow(pitch: 47, capacity: 5), 50),
            ("bard", TrackerCompanyRow(pitch: 34, capacity: 7), 32),
            ("cleric", TrackerCompanyRow(pitch: 35, capacity: 7), 25),
            ("druid", TrackerCompanyRow(pitch: 40, capacity: 6), 40),
            ("fighter", TrackerCompanyRow(pitch: 38, capacity: 6), 50),
            ("necromancer", TrackerCompanyRow(pitch: 35, capacity: 7), 25),
            ("paladin", TrackerCompanyRow(pitch: 39, capacity: 6), 34),
            ("ranger", TrackerCompanyRow(pitch: 31, capacity: 8), 22),
            ("rogue", TrackerCompanyRow(pitch: 40.6, capacity: 6), 32),
            ("sorcerer", TrackerCompanyRow(pitch: 40, capacity: 6), 37),
            ("wizard", TrackerCompanyRow(pitch: 35, capacity: 7), 26),
        ]
        let master = TrackerCompanyLayout.MasterReach(left: 40, right: 45)
        for entry in rows {
            let full = designed(entry.row.capacity, entry.row, master, width: entry.width)
            guard let last = full.familiars.last else {
                fail("\(entry.name) should show a full row")
            }
            let gap = markerLeft - (last.left + entry.width)
            expect(gap >= 5 - 1e-9, "\(entry.name)'s full row should end at least 5 pt left of the marker, got a gap of \(gap)")
            expect(abs(full.familiars[0].left - 10) < 1e-6, "\(entry.name)'s first familiar should start at 10 pt")
        }
    }

    /// The feet stand on the baseline, so a familiar with no hover drops `belowFeet` (5 pt, its visible bottom at 155 against the feet's
    /// 150); a hover's gap above the feet, 10 art pixels at 50%, is taken out, so the hoverer lands on the same line too.
    private static func visibleBottomsDropBelowTheFeet() {
        expect(abs(TrackerCompanyLayout.drop(footRow: 174, lowestRow: 174, scale: 0.5) - 5) < 1e-9, "a familiar standing on its feet should drop 5 pt")
        expect(abs(TrackerCompanyLayout.drop(footRow: 174, lowestRow: 164, scale: 0.5) - 10) < 1e-9,
               "a hoverer 10 px above its feet at 50% should drop 5 pt more, to 10 pt")
        expect(abs(TrackerCompanyLayout.drop(footRow: 174, lowestRow: 174, scale: 0.694) - 5) < 1e-9, "the drop should not depend on the scale when there is no hover")
    }

    /// The familiars' scales come from their files: the War Hound is 82%, the Imp 60.4%, and a class always draws at 100. A 0% scale is
    /// refused, and so is one above 100.
    private static func familiarScalesComeFromTheirFiles() {
        expect(AvatarAnimationFixture.familiar("fighter").scalePercent == 82, "the War Hound should draw at 82%, got \(AvatarAnimationFixture.familiar("fighter").scalePercent)")
        expect(AvatarAnimationFixture.familiar("bard").scalePercent == 60.4, "the Imp should draw at 60.4%, got \(AvatarAnimationFixture.familiar("bard").scalePercent)")
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

    /// A familiar's company row comes from its file, and a file without one (the Werebear and Shadow until their art ships) has none. A
    /// row needs a pitch above 0 and a capacity of at least one.
    private static func companyRowComesFromTheFile() {
        expect(AvatarAnimationFixture.familiar("bard").companyRow == TrackerCompanyRow(pitch: 34, capacity: 7), "the Imp's row should be 34 pt and seven")
        expect(AvatarAnimationFixture.familiar("barbarian").companyRow == nil, "the old Bear keeps the fit rule: no company row")
        expect(AvatarAnimationFixture.familiar("rogue").companyRow == nil, "the old Shadow keeps the fit rule: no company row")
        expect(AvatarAnimationFixture.bard().companyRow == nil, "a class has no company row")
        var json = AvatarAnimationFixture.familiarJSON("bard")
        json["company"] = ["pitch": 34, "capacity": 0]
        do {
            _ = try AvatarAnimationFixture.decodeFamiliar(json)
            fail("a company row with no capacity should not read")
        } catch let error as TrackerAvatarAnimationError {
            expect(error == .invalidCompany, "a zero capacity should be rejected as an invalid company row, got \(error)")
        } catch {
            fail("a zero capacity should give an invalid company row, got \(error)")
        }
    }

    // MARK: Helpers

    private static func layout(_ widths: [Double], master: TrackerCompanyLayout.MasterReach) -> TrackerCompanyLayout.Result {
        // The fit rule's numbers are the study's at its first 240 pt slot.
        TrackerCompanyLayout.layout(restWidths: widths, pushPerWorker: 16, master: master, slotWidth: 240)
    }

    private static func designed(_ count: Int, _ row: TrackerCompanyRow, _ master: TrackerCompanyLayout.MasterReach, width: Double = 26) -> TrackerCompanyLayout.Result {
        TrackerCompanyLayout.designLayout(count: count, row: row, restWidth: width, master: master, slotWidth: slot)
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

private extension Array where Element == Double {
    /// Whether the numbers match `others` within a rounding error, in order.
    func elementsAlmostEqual(_ others: [Double]) -> Bool {
        count == others.count && zip(self, others).allSatisfy { abs($0 - $1) < 1e-6 }
    }
}
