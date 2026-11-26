import Foundation
import QuestmasterCore

/// The master's company in its slot: the designed rows from the user's spacing designs (the master never moves; its workers stand at their
/// pitch, centred on a point that moves from the body column toward the full row's centre), the "+n" marker, the drop below the feet, and the
/// familiars' scales and rows from their files.
struct TrackerCompanyLayoutTests {
    static func run() {
        noWorkersShowNothing()
        liveWorkersAreTheMastersStartedWorkersInSpawnOrder()
        designedFullRowStartsAtTen()
        designedFullRowIsTheDesignsRowExactly()
        oneWorkerIsCentredOnTheBodyColumnInEveryClass()
        fewerWorkersStandAtPitchOnTheBlendedCentre()
        newestWorkerIsAlwaysRightMost()
        groupCentreMovesInEqualStepsTowardTheFullRow()
        designedRowCountsWorkersPastItsCapacity()
        designedRowsEndLeftOfTheMarker()
        visibleBottomsDropBelowTheFeet()
        familiarScalesComeFromTheirFiles()
        companyRowComesFromTheFile()
        print("TrackerCompanyLayoutTests: all tests passed")
    }

    /// The design's slot is 280 pt wide (the tracker column); its master's body column stands at its centre, 140 pt.
    private static let slot = 280.0
    private static var bodyCentre: Double { slot / 2 }
    /// The marker's disc starts 25 pt from the right edge (20 pt disc, 5 pt in).
    private static let markerLeft = 255.0

    /// The eleven classes' rows and resting widths at scale, from the user's spacing designs (points), by class.
    private static let classRows: [(name: String, row: TrackerCompanyRow, width: Double)] = [
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

    /// With no workers the designed row shows nothing and counts nothing. The master is not in the layout: it never moves.
    private static func noWorkersShowNothing() {
        let none = designed(0, TrackerCompanyRow(pitch: 35, capacity: 7))
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

    /// The full row starts its first familiar at 10 pt and every next one a pitch further right.
    private static func designedFullRowStartsAtTen() {
        let fire = TrackerCompanyRow(pitch: 35, capacity: 7)
        let full = designed(7, fire)
        expect(full.familiars.count == 7 && full.overflow == 0, "a full Fire row should show seven, got \(full.familiars.count) and \(full.overflow) counted")
        for (index, place) in full.familiars.enumerated() {
            expect(abs(place.left - Double(10 + index * 35)) < 1e-6, "Fire \(index + 1) should start at \(10 + index * 35), got \(place.left)")
        }
    }

    /// A full row's places are the design's, exactly, for every class: the first familiar at 10 pt and one pitch apart, with no rounding.
    private static func designedFullRowIsTheDesignsRowExactly() {
        for entry in classRows {
            let full = designed(entry.row.capacity, entry.row, width: entry.width)
            expect(full.familiars.count == entry.row.capacity && full.overflow == 0, "\(entry.name)'s full row should show its capacity and count none")
            for (index, place) in full.familiars.enumerated() {
                expect(place.left == TrackerCompanyLayout.designInset + Double(index) * entry.row.pitch,
                       "\(entry.name)'s full row's place \(index + 1) should be \(TrackerCompanyLayout.designInset + Double(index) * entry.row.pitch) exactly, got \(place.left)")
            }
        }
    }

    /// One worker stands on the master's body column in every class: its visible middle is the slot's centre.
    private static func oneWorkerIsCentredOnTheBodyColumnInEveryClass() {
        for entry in classRows {
            let one = designed(1, entry.row, width: entry.width)
            guard let centre = rowCentre(one, width: entry.width) else {
                fail("\(entry.name) should show its one worker")
            }
            expect(abs(centre - bodyCentre) < 1e-9, "\(entry.name)'s one worker should stand centred on the body column (\(bodyCentre)), got \(centre)")
        }
    }

    /// Fire Elementals (pitch 35, a full row of seven whose centre is 128, 12 pt left of the body column at 140): the group's centre steps
    /// from 140 toward 128 by 2 pt a worker, so one worker stands at 127 (its centre on 140), two at 107.5 and 142.5, and three at 88, 123 and
    /// 158.
    private static func fewerWorkersStandAtPitchOnTheBlendedCentre() {
        let fire = TrackerCompanyRow(pitch: 35, capacity: 7)
        let cases: [(count: Int, lefts: [Double])] = [(1, [127]), (2, [107.5, 142.5]), (3, [88, 123, 158])]
        for entry in cases {
            let result = designed(entry.count, fire, width: 26)
            expect(result.familiars.map(\.left).elementsAlmostEqual(entry.lefts), "\(entry.count) Fire should stand at \(entry.lefts), got \(result.familiars.map(\.left))")
        }
    }

    /// The newest worker is always the right-most, for every class and every count: the places run left to right in spawn order.
    private static func newestWorkerIsAlwaysRightMost() {
        for entry in classRows {
            for count in 1...entry.row.capacity {
                let result = designed(count, entry.row, width: entry.width)
                let lefts = result.familiars.map(\.left)
                expect(result.familiars.map(\.index) == Array(0..<count), "\(entry.name)'s familiars should keep spawn order at \(count) workers")
                expect(zip(lefts, lefts.dropFirst()).allSatisfy { $0 < $1 }, "\(entry.name)'s newest worker should be right-most at \(count) workers, got \(lefts)")
            }
        }
    }

    /// The row's centre moves from the body column toward the full row's centre in equal steps: one worker on the body column, the full row on
    /// its own centre (the midpoint between its first place's visible left edge and its last place's visible right edge), and each worker
    /// between them moves the centre by the same amount, always in the same direction.
    private static func groupCentreMovesInEqualStepsTowardTheFullRow() {
        for entry in classRows {
            let target = fullCentre(entry)
            let step = (target - bodyCentre) / Double(entry.row.capacity - 1)
            var previous: Double?
            for count in 1...entry.row.capacity {
                let result = designed(count, entry.row, width: entry.width)
                guard let centre = rowCentre(result, width: entry.width) else {
                    fail("\(entry.name) should show \(count) workers")
                }
                let expected = bodyCentre + (target - bodyCentre) * Double(count - 1) / Double(entry.row.capacity - 1)
                expect(abs(centre - expected) < 1e-9, "\(entry.name)'s row centre at \(count) workers should be \(expected), got \(centre)")
                expect(centre >= min(bodyCentre, target) - 1e-9 && centre <= max(bodyCentre, target) + 1e-9,
                       "\(entry.name)'s row centre at \(count) workers should lie between the body column and the full row's centre, got \(centre)")
                if let previous {
                    expect(abs(centre - previous - step) < 1e-9, "\(entry.name)'s centre should move \(step) a worker, got \(centre - previous) at \(count) workers")
                    expect((centre - previous) * step >= 0, "\(entry.name)'s centre should move monotonically, got \(centre - previous) at \(count) workers")
                }
                previous = centre
            }
        }
    }

    /// Past its capacity a designed row shows the capacity and counts the rest in the marker; the places stay where the full row put them.
    private static func designedRowCountsWorkersPastItsCapacity() {
        let fire = TrackerCompanyRow(pitch: 35, capacity: 7)
        let nine = designed(9, fire)
        expect(nine.familiars.count == 7 && nine.overflow == 2, "nine Fire should show seven and count two, got \(nine.familiars.count) and \(nine.overflow)")
        expect(nine.familiars.map(\.left).elementsAlmostEqual(designed(7, fire).familiars.map(\.left)), "a full row shows the same places however many more there are")
    }

    /// Each design's full row ends left of the marker's disc, with its gap as designed: a row's last right edge, from its pitch, capacity and
    /// resting width, stays at least 5 pt from the marker (the Druid's row is the tightest, at 5 pt).
    private static func designedRowsEndLeftOfTheMarker() {
        for entry in classRows {
            let full = designed(entry.row.capacity, entry.row, width: entry.width)
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

    /// The familiars' scales come from their files: the War Hound is 82%, the Imp 60.4%, the Werebear 58.8%, and a class always draws at 100.
    /// A 0% scale is refused, and so is one above 100.
    private static func familiarScalesComeFromTheirFiles() {
        expect(AvatarAnimationFixture.familiar("fighter").scalePercent == 82, "the War Hound should draw at 82%, got \(AvatarAnimationFixture.familiar("fighter").scalePercent)")
        expect(AvatarAnimationFixture.familiar("bard").scalePercent == 60.4, "the Imp should draw at 60.4%, got \(AvatarAnimationFixture.familiar("bard").scalePercent)")
        expect(AvatarAnimationFixture.familiar("barbarian").scalePercent == 58.8, "the Werebear should draw at 58.8%, got \(AvatarAnimationFixture.familiar("barbarian").scalePercent)")
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

    /// Every familiar's company row comes from its file: the Imp's is 34 pt and seven, the Werebear's 47 pt and five. A familiar's file must
    /// give one (a file without it does not read), and a row needs a pitch above 0 and a capacity of at least one. A class has none.
    private static func companyRowComesFromTheFile() {
        expect(AvatarAnimationFixture.familiar("bard").companyRow == TrackerCompanyRow(pitch: 34, capacity: 7), "the Imp's row should be 34 pt and seven")
        expect(AvatarAnimationFixture.familiar("barbarian").companyRow == TrackerCompanyRow(pitch: 47, capacity: 5), "the Werebear's row should be 47 pt and five")
        expect(AvatarAnimationFixture.familiar("rogue").companyRow == TrackerCompanyRow(pitch: 40.6, capacity: 6), "the slim Shadow's row should be 40.6 pt and six")
        expect(AvatarAnimationFixture.bard().companyRow == nil, "a class has no company row")
        var missing = AvatarAnimationFixture.familiarJSON("bard")
        missing.removeValue(forKey: "company")
        do {
            _ = try AvatarAnimationFixture.decodeFamiliar(missing)
            fail("a familiar with no company row should not read")
        } catch let error as TrackerAvatarAnimationError {
            expect(error == .missingCompany, "a familiar with no company row should be rejected as missing it, got \(error)")
        } catch {
            fail("a familiar with no company row should give missing company, got \(error)")
        }
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

    private static func designed(_ count: Int, _ row: TrackerCompanyRow, width: Double = 26) -> TrackerCompanyLayout.Result {
        TrackerCompanyLayout.designLayout(count: count, row: row, restWidth: width, slotWidth: slot)
    }

    /// The full row's centre: the midpoint between its first place's visible left edge (the design's inset) and its last place's right edge.
    private static func fullCentre(_ entry: (name: String, row: TrackerCompanyRow, width: Double)) -> Double {
        TrackerCompanyLayout.designInset + (Double(entry.row.capacity - 1) * entry.row.pitch + entry.width) / 2
    }

    /// The centre of a shown row: the midpoint between its first familiar's visible left edge and its last one's visible right edge.
    private static func rowCentre(_ result: TrackerCompanyLayout.Result, width: Double) -> Double? {
        guard let first = result.familiars.first, let last = result.familiars.last else {
            return nil
        }
        return (first.left + last.left + width) / 2
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
