import Foundation
import QuestmasterCore

/// The master's company in its slot: the designed rows from the user's spacing designs (the master never moves; its workers stand at their
/// pitch, centred on a point that starts 20 pt right of the body column and moves toward the full row's centre), the "+n" marker, the drop
/// below the feet, and the familiars' scales and rows from their files.
struct TrackerCompanyLayoutTests {
    static func run() {
        noWorkersShowNothing()
        liveWorkersAreTheMastersStartedWorkersInSpawnOrder()
        designedFullRowStartsAtTen()
        designedFullRowIsTheDesignsRowExactly()
        oneWorkerStandsRightOfTheBodyColumnInEveryClass()
        fewerWorkersStandAtPitchOnTheBlendedCentre()
        newestWorkerIsAlwaysRightMost()
        groupCentreMovesInEqualStepsTowardTheFullRow()
        designedRowCountsWorkersPastItsCapacity()
        designedRowsEndLeftOfTheMarker()
        visibleBottomsDropBelowTheFeet()
        familiarScalesComeFromTheirFiles()
        companyRowComesFromTheFile()
        companySizesComeFromTheirFiles()
        companySizeFollowsTheCount()
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

    /// One worker stands `soloOffset` (20 pt) right of the master's body column in every class: its visible middle is 160, where the body
    /// column is 140.
    private static func oneWorkerStandsRightOfTheBodyColumnInEveryClass() {
        expect(TrackerCompanyLayout.soloOffset == 20, "a lone worker should stand 20 pt right of the body column, got \(TrackerCompanyLayout.soloOffset)")
        for entry in classRows {
            let one = designed(1, entry.row, width: entry.width)
            guard let centre = rowCentre(one, width: entry.width) else {
                fail("\(entry.name) should show its one worker")
            }
            expect(abs(centre - (bodyCentre + 20)) < 1e-9, "\(entry.name)'s one worker should stand 20 pt right of the body column (\(bodyCentre + 20)), got \(centre)")
        }
    }

    /// Fire Elementals (pitch 35, a full row of seven whose centre is 128, 12 pt left of the body column at 140): the group's centre starts
    /// 20 pt right of the body column, at 160, and steps toward 128 by 16/3 pt a worker. So one worker stands at 147 (its centre on 160), two
    /// at 745/6 and 955/6 (centre 464/3), and three at 304/3, 409/3 and 514/3 (centre 448/3).
    private static func fewerWorkersStandAtPitchOnTheBlendedCentre() {
        let fire = TrackerCompanyRow(pitch: 35, capacity: 7)
        let cases: [(count: Int, lefts: [Double])] = [(1, [147]), (2, [745.0 / 6, 955.0 / 6]), (3, [304.0 / 3, 409.0 / 3, 514.0 / 3])]
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

    /// The row's centre starts 20 pt right of the body column and moves toward the full row's centre in equal steps: one worker there, the full
    /// row on its own centre (the midpoint between its first place's visible left edge and its last place's visible right edge), and each
    /// worker between them moves the centre by the same amount, always in the same direction.
    private static func groupCentreMovesInEqualStepsTowardTheFullRow() {
        let start = bodyCentre + TrackerCompanyLayout.soloOffset
        for entry in classRows {
            let target = fullCentre(entry)
            let step = (target - start) / Double(entry.row.capacity - 1)
            var previous: Double?
            for count in 1...entry.row.capacity {
                let result = designed(count, entry.row, width: entry.width)
                guard let centre = rowCentre(result, width: entry.width) else {
                    fail("\(entry.name) should show \(count) workers")
                }
                let expected = start + (target - start) * Double(count - 1) / Double(entry.row.capacity - 1)
                expect(abs(centre - expected) < 1e-9, "\(entry.name)'s row centre at \(count) workers should be \(expected), got \(centre)")
                expect(centre >= min(start, target) - 1e-9 && centre <= max(start, target) + 1e-9,
                       "\(entry.name)'s row centre at \(count) workers should lie between the start and the full row's centre, got \(centre)")
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
    /// A 0% scale is refused, and so is one above 150 (a company's largest size, 1.5 times the War Hound's 82%, is 123%).
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
        json["scale"] = 150
        expect((try? AvatarAnimationFixture.decodeFamiliar(json))?.scalePercent == 150, "a 150% scale, the company's cap, should read")
        json["scale"] = 150.5
        do {
            _ = try AvatarAnimationFixture.decodeFamiliar(json)
            fail("a familiar with a 150.5% scale should not read")
        } catch let error as TrackerAvatarAnimationError {
            expect(error == .invalidScale(150.5), "a 150.5% scale should be rejected as invalid, got \(error)")
        } catch {
            fail("a 150.5% scale should give invalid scale, got \(error)")
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

    /// The eleven classes' company sizes, from the 1.5x size down to 1x: each size's full row in workers, as the converter measures it from the
    /// shipped frames. The Werebear's 1.25x row is its 1.5x row, so its company goes from 1.5x straight to 1x.
    private static let sizeRows: [(name: String, rows: [Int])] = [
        ("barbarian", [3, 3, 5]), ("bard", [4, 5, 7]), ("cleric", [4, 5, 7]), ("druid", [4, 4, 6]), ("fighter", [3, 4, 6]),
        ("necromancer", [4, 5, 7]), ("paladin", [4, 4, 6]), ("ranger", [5, 6, 8]), ("rogue", [4, 4, 6]), ("sorcerer", [4, 4, 6]),
        ("wizard", [4, 5, 7]),
    ]
    private static let sizeNames = ["1.5x", "1.25x", "1x"]

    /// A familiar's company size as its bundled file reads, or a failure when it does not read.
    private static func companySize(_ classID: String, _ size: String) -> TrackerAvatarAnimation {
        do {
            return try AvatarAnimationFixture.decodeFamiliar(AvatarAnimationFixture.companySizeJSON(classID, size))
        } catch {
            fail("the \(classID)'s \(size) company size should read, got \(error)")
        }
    }

    /// Each class's three company sizes come from their files: the 1.5x size draws at 1.5 times the designed scale, the 1.25x at 1.25 times,
    /// and the 1x at the designed one, each with the full row `sizeRows` names. The 1x row is the familiar's own company row.
    private static func companySizesComeFromTheirFiles() {
        let multipliers = [1.5, 1.25, 1.0]
        for entry in sizeRows {
            let designed = AvatarAnimationFixture.familiar(entry.name)
            let sizes = sizeNames.map { companySize(entry.name, $0) }
            for (animation, multiplier) in zip(sizes, multipliers) {
                expect(abs(animation.scalePercent - designed.scalePercent * multiplier) < 1e-6,
                       "the \(entry.name)'s size should draw at \(designed.scalePercent * multiplier)%, got \(animation.scalePercent)%")
            }
            expect(sizes.map { $0.companyRow?.capacity ?? 0 } == entry.rows,
                   "the \(entry.name)'s full rows should be \(entry.rows), got \(sizes.map { $0.companyRow?.capacity ?? 0 })")
            expect(sizes[2].companyRow == designed.companyRow, "the \(entry.name)'s 1x size should carry the familiar's own company row")
        }
        expect(companySize("fighter", "1.5x").scalePercent == 123, "the War Hound's 1.5x size should draw at 123%")
    }

    /// A company draws at the largest size whose full row holds every worker. At every count up to the 1x full row plus two, each class's
    /// size is the first of 1.5x, 1.25x and 1x whose row holds the count; past the 1x row, the 1x size draws and its "+n" marker counts the rest.
    private static func companySizeFollowsTheCount() {
        expect(TrackerCompanyLayout.sizeIndex(count: 1, rows: []) == nil, "a company with no sizes should name none")
        for entry in sizeRows {
            let rows = sizeNames.compactMap { companySize(entry.name, $0).companyRow }
            expect(rows.count == 3, "the \(entry.name) should have three company rows, got \(rows.count)")
            for count in 1...(entry.rows[2] + 2) {
                let expected = rows.firstIndex { count <= $0.capacity } ?? 2
                expect(TrackerCompanyLayout.sizeIndex(count: count, rows: rows) == expected,
                       "the \(entry.name)'s \(count) workers should draw at size \(expected), got \(String(describing: TrackerCompanyLayout.sizeIndex(count: count, rows: rows)))")
            }
            expect(TrackerCompanyLayout.sizeIndex(count: 1, rows: rows) == 0, "one \(entry.name) worker should draw at 1.5x")
            expect(TrackerCompanyLayout.sizeIndex(count: rows[2].capacity + 1, rows: rows) == 2,
                   "past the \(entry.name)'s 1x full row the 1x size should draw, with the marker")
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
