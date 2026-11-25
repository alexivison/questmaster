import Foundation
import QuestmasterCore

/// The master's company in its slot: the fit rule's fixed-step row, its "+n" overflow, the designed rows from the user's spacing designs
/// (the master never moves; the workers stand beside it, then in front of it), the drop below the feet, and the familiars' scales and rows
/// from their files.
struct TrackerCompanyLayoutTests {
    static func run() {
        fireRowGrowsLeftwardOneFixedAdvancePerWorker()
        slimFamiliarsShowMoreThanSix()
        wideFamiliarsOverlapOnlyToHoldSix()
        mixedFamiliarsKeepTheirOwnAdvances()
        noWorkersShowNothing()
        liveWorkersAreTheMastersStartedWorkersInSpawnOrder()
        designedFullRowStartsAtTen()
        designedFullRowIsTheDesignsRowExactly()
        designedRowStandsWorkersBesideTheMaster()
        oneWorkerStandsBesideTheMasterInFourClasses()
        designedRowExtendsLeftInFrontOfTheMasterAtItsSwitch()
        designedRowMovesInSmallSteps()
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
        for count in 1...6 {
            let result = layout(Array(fire.prefix(count)))
            expect(result.familiars.count == count && result.overflow == 0, "\(count) Fire workers should all show, got \(result.familiars.count) and \(result.overflow) counted")
            expect(abs(result.familiars[0].left - Double(15 + (6 - count) * 32)) < 1e-6,
                   "worker one of \(count) should start at \(15 + (6 - count) * 32), got \(result.familiars[0].left)")
            for pair in zip(result.familiars, result.familiars.dropFirst()) {
                expect(abs(pair.1.left - pair.0.left - 32) < 1e-6, "neighbours should stand one advance (32) apart, got \(pair.1.left - pair.0.left)")
            }
        }
        let eight = layout(fire)
        expect(eight.familiars.count == 6 && eight.overflow == 2, "eight Fire workers should show six and count two, got \(eight.familiars.count) and \(eight.overflow)")
        expect(eight.familiars.last.map { $0.left + $0.restWidth <= 204 + 1e-6 } == true, "the row should end inside the overflow reserve")
    }

    /// A slim familiar keeps its own gap and holds more than six: the Light Spirit (18 pt) shows eight, the Hawk (15.5 pt) nine.
    private static func slimFamiliarsShowMoreThanSix() {
        let hawks = layout(Array(repeating: 15.5, count: 10))
        expect(hawks.familiars.count == 9 && hawks.overflow == 1, "ten Hawks should show nine and count one, got \(hawks.familiars.count) and \(hawks.overflow)")
        expect(abs(hawks.familiars[1].left - hawks.familiars[0].left - 21.5) < 1e-6, "Hawks should stand 21.5 apart (width plus the gap)")
        let spirits = layout(Array(repeating: 18, count: 10))
        expect(spirits.familiars.count == 8, "ten Light Spirits should show eight, got \(spirits.familiars.count)")
    }

    /// A wide familiar overlaps its neighbours only as far as six fit: the Bear (84.5 pt) advances 20.9 pt, a 63.6 pt overlap, and the War
    /// Hound at 75% (45.75 pt) advances 28.65 pt.
    private static func wideFamiliarsOverlapOnlyToHoldSix() {
        let bears = layout(Array(repeating: 84.5, count: 7))
        expect(bears.familiars.count == 6 && bears.overflow == 1, "seven Bears should show six and count one, got \(bears.familiars.count) and \(bears.overflow)")
        expect(abs(bears.familiars[1].left - bears.familiars[0].left - 20.9) < 1e-6, "Bears should advance 20.9 pt, got \(bears.familiars[1].left - bears.familiars[0].left)")
        let hounds = layout(Array(repeating: 45.75, count: 8))
        expect(hounds.familiars.count == 6, "eight War Hounds at 75% should show six, got \(hounds.familiars.count)")
        expect(abs(hounds.familiars[1].left - hounds.familiars[0].left - 28.65) < 1e-6, "War Hounds should advance 28.65 pt")
    }

    /// Workers of different familiars keep their own advances: the first worker's advance is its own width plus the gap, not the next one's.
    private static func mixedFamiliarsKeepTheirOwnAdvances() {
        let mixed = layout([26, 84.5])
        expect(mixed.familiars.count == 2, "a Fire and a Bear should both show, got \(mixed.familiars.count)")
        expect(abs(mixed.familiars[1].left - mixed.familiars[0].left - 32) < 1e-6,
               "the Fire should advance by its own 32 pt, got \(mixed.familiars[1].left - mixed.familiars[0].left)")
    }

    /// With no workers neither rule shows a familiar or counts one. The master is not in either layout: it never moves.
    private static func noWorkersShowNothing() {
        let fit = layout([])
        expect(fit.familiars.isEmpty && fit.overflow == 0, "no workers should show nothing under the fit rule, got \(fit.familiars.count) and \(fit.overflow) counted")
        let none = designed(0, TrackerCompanyRow(pitch: 35, capacity: 7), TrackerCompanyLayout.MasterReach(left: 40, right: 45))
        expect(none.familiars.isEmpty && none.overflow == 0, "no workers should show nothing in a designed row, got \(none.familiars.count) and \(none.overflow) counted")
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

    /// The full row starts its first familiar at 10 pt and every next one a pitch further right, whatever the master's reach.
    private static func designedFullRowStartsAtTen() {
        let fire = TrackerCompanyRow(pitch: 35, capacity: 7)
        let master = TrackerCompanyLayout.MasterReach(left: 40, right: 45)
        let full = designed(7, fire, master)
        expect(full.familiars.count == 7 && full.overflow == 0, "a full Fire row should show seven, got \(full.familiars.count) and \(full.overflow) counted")
        for (index, place) in full.familiars.enumerated() {
            expect(abs(place.left - Double(10 + index * 35)) < 1e-6, "Fire \(index + 1) should start at \(10 + index * 35), got \(place.left)")
        }
    }

    /// A full row's places are the design's: the first familiar at 10 pt and one pitch apart, whatever the master's reach. The full row must
    /// come out exactly as it always did, with no rounding in the places.
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
                expect(full.familiars.count == entry.row.capacity && full.overflow == 0, "a full row should show its capacity and count none")
                for (index, place) in full.familiars.enumerated() {
                    expect(place.left == TrackerCompanyLayout.designInset + Double(index) * entry.row.pitch,
                           "a full row's place \(index + 1) should be \(TrackerCompanyLayout.designInset + Double(index) * entry.row.pitch) exactly, got \(place.left)")
                }
            }
        }
    }

    /// The Wizard's master (its visible right edge 30 pt past the slot's centre, at 170) with Fire Elementals (26 pt, pitch 35, a full row of
    /// seven whose right-most place is 220): the first worker stands 10 pt past the master's visible edge, at 180, and a second at pitch, at 215.
    /// A third would stand at 250, past the right-most place, so all three stand at the full row's places from there leftwards: 150, 185 and
    /// 220, the first over the master's edge.
    private static func designedRowStandsWorkersBesideTheMaster() {
        let fire = TrackerCompanyRow(pitch: 35, capacity: 7)
        let wizard = TrackerCompanyLayout.MasterReach(left: 36, right: 30)
        let cases: [(count: Int, lefts: [Double])] = [(1, [180]), (2, [180, 215]), (3, [150, 185, 220])]
        for entry in cases {
            let result = designed(entry.count, fire, wizard, width: 26)
            expect(result.familiars.map(\.left).elementsAlmostEqual(entry.lefts), "\(entry.count) Fire should stand at \(entry.lefts), got \(result.familiars.map(\.left))")
        }
    }

    /// The study's four classes with one worker each, from their files: the familiar's visible left edge. Necromancer, Wizard and Ranger stand
    /// 10 pt past their master's visible right edge (208, 180 and 181). The Fighter's 10 pt would put its War Hound at 213, past the full row's
    /// right-most place (200), so it stands there, 3 pt over the master's edge.
    private static func oneWorkerStandsBesideTheMasterInFourClasses() {
        let cases: [(name: String, master: TrackerCompanyLayout.MasterReach, width: Double, row: TrackerCompanyRow, familiarLeft: Double)] = [
            ("necromancer", TrackerCompanyLayout.MasterReach(left: 28, right: 58), 25, TrackerCompanyRow(pitch: 35, capacity: 7), 208),
            ("wizard", TrackerCompanyLayout.MasterReach(left: 36, right: 30), 26, TrackerCompanyRow(pitch: 35, capacity: 7), 180),
            ("fighter", TrackerCompanyLayout.MasterReach(left: 38, right: 63), 50, TrackerCompanyRow(pitch: 38, capacity: 6), 200),
            ("ranger", TrackerCompanyLayout.MasterReach(left: 30, right: 31), 22, TrackerCompanyRow(pitch: 31, capacity: 8), 181),
        ]
        for entry in cases {
            let one = designed(1, entry.row, entry.master, width: entry.width)
            guard let place = one.familiars.first else {
                fail("\(entry.name) should show its one worker")
            }
            expect(abs(place.left - entry.familiarLeft) < 1e-9, "\(entry.name)'s familiar should stand at \(entry.familiarLeft), got \(place.left)")
        }
    }

    /// A row stands beside its master until the next worker would pass the full row's right-most place; from then on the workers extend left
    /// from that place, in front of the master. The worker count where that starts: Necromancer 2, Wizard 3, Fighter 1, Ranger 3. The first
    /// familiar then stands over the master's visible right edge (185 under 198, 150 under 170, 200 under 203, 165 under 171).
    private static func designedRowExtendsLeftInFrontOfTheMasterAtItsSwitch() {
        let cases: [(name: String, master: TrackerCompanyLayout.MasterReach, width: Double, row: TrackerCompanyRow, switchCount: Int)] = [
            ("necromancer", TrackerCompanyLayout.MasterReach(left: 28, right: 58), 25, TrackerCompanyRow(pitch: 35, capacity: 7), 2),
            ("wizard", TrackerCompanyLayout.MasterReach(left: 36, right: 30), 26, TrackerCompanyRow(pitch: 35, capacity: 7), 3),
            ("fighter", TrackerCompanyLayout.MasterReach(left: 38, right: 63), 50, TrackerCompanyRow(pitch: 38, capacity: 6), 1),
            ("ranger", TrackerCompanyLayout.MasterReach(left: 30, right: 31), 22, TrackerCompanyRow(pitch: 31, capacity: 8), 3),
        ]
        for entry in cases {
            let beside = slot / 2 + entry.master.right + TrackerCompanyLayout.sideBySideGap
            let switchCount = (1...entry.row.capacity).first { count in
                designed(count, entry.row, entry.master, width: entry.width).familiars[0].left < beside - 1e-9
            }
            expect(switchCount == entry.switchCount, "\(entry.name)'s row should extend left in front of its master at \(entry.switchCount) workers, got \(String(describing: switchCount))")
            if let switchCount {
                let first = designed(switchCount, entry.row, entry.master, width: entry.width).familiars[0].left
                expect(first < slot / 2 + entry.master.right, "\(entry.name)'s first familiar should stand over the master's visible edge at \(switchCount) workers, got \(first)")
            }
        }
    }

    /// As workers arrive the row moves in small steps and never to the right. Each count stands either beside the master, with the first
    /// familiar at its 10 pt gap, or anchored at the full row's right-most place. No worker's place moves more than one pitch, and the last
    /// familiar stays inside that right-most place.
    private static func designedRowMovesInSmallSteps() {
        let cases: [(master: TrackerCompanyLayout.MasterReach, width: Double, row: TrackerCompanyRow)] = [
            (TrackerCompanyLayout.MasterReach(left: 28, right: 58), 25, TrackerCompanyRow(pitch: 35, capacity: 7)),
            (TrackerCompanyLayout.MasterReach(left: 36, right: 30), 26, TrackerCompanyRow(pitch: 35, capacity: 7)),
            (TrackerCompanyLayout.MasterReach(left: 38, right: 63), 50, TrackerCompanyRow(pitch: 38, capacity: 6)),
            (TrackerCompanyLayout.MasterReach(left: 30, right: 31), 22, TrackerCompanyRow(pitch: 31, capacity: 8)),
        ]
        for entry in cases {
            let rightMost = TrackerCompanyLayout.designInset + Double(entry.row.capacity - 1) * entry.row.pitch
            let beside = slot / 2 + entry.master.right + TrackerCompanyLayout.sideBySideGap
            var previous: TrackerCompanyLayout.Result?
            for count in 1...(entry.row.capacity + 1) {
                let result = designed(count, entry.row, entry.master, width: entry.width)
                guard let first = result.familiars.first, let last = result.familiars.last else {
                    fail("\(count) workers should show a familiar")
                }
                expect(abs(first.left - beside) < 1e-9 || abs(last.left - rightMost) < 1e-9,
                       "a row should stand beside its master or be anchored at its right-most place (\(rightMost)), got \(first.left) and \(last.left) at \(count) workers")
                expect(last.left <= rightMost + 1e-9, "the last familiar should stay at or left of the right-most place (\(rightMost)), got \(last.left) at \(count) workers")
                if let previous, let before = previous.familiars.first {
                    expect(first.left <= before.left + 1e-9, "the row should never move right, got a step of \(first.left - before.left) at \(count) workers")
                    expect(before.left - first.left <= entry.row.pitch + 1e-9,
                           "a worker's place should move no more than one pitch (\(entry.row.pitch)), got \(before.left - first.left) at \(count) workers")
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

    /// A familiar's company row comes from its file, and a file without one (the Werebear until its art ships) has none. A
    /// row needs a pitch above 0 and a capacity of at least one.
    private static func companyRowComesFromTheFile() {
        expect(AvatarAnimationFixture.familiar("bard").companyRow == TrackerCompanyRow(pitch: 34, capacity: 7), "the Imp's row should be 34 pt and seven")
        expect(AvatarAnimationFixture.familiar("barbarian").companyRow == nil, "the old Bear keeps the fit rule: no company row")
        expect(AvatarAnimationFixture.familiar("rogue").companyRow == TrackerCompanyRow(pitch: 40.6, capacity: 6), "the slim Shadow's row should be 40.6 pt and six")
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

    private static func layout(_ widths: [Double]) -> TrackerCompanyLayout.Result {
        // The fit rule's numbers are the study's at its first 240 pt slot.
        TrackerCompanyLayout.layout(restWidths: widths, slotWidth: 240)
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
