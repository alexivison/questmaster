import Foundation
import QuestmasterCore

/// The tiered worker names: the tier each name takes, its stem, the face it must not cover, and the cut to the room over its head.
struct TrackerCompanyNameTagsTests {
    static func run() {
        aSingleNameStandsOnTheLowestTierCentred()
        tiersStepTwentyPointsAboveTheHead()
        aNameOverlappingAnotherClimbsATier()
        twoFarApartNamesShareTheLowestTier()
        aTierThatRunsIntoTheFaceIsSkipped()
        aTierBelowTheFaceIsNotBlocked()
        aNameWithNoRoomIsCutWithAnEllipsis()
        aNameThatFitsNowhereGetsNoChip()
        earlierNamesKeepTheLowerTier()
        print("TrackerCompanyNameTagsTests: all tests passed")
    }

    /// Fake text: 6 pt a character, so a name's width and its cut are easy to read.
    private static let charWidth = 6.0
    private static let slotWidth = 280.0
    private static let headTop = 60.0

    private static func tag(_ name: String, centre: Double) -> TrackerCompanyNameTags.Tag {
        TrackerCompanyNameTags.Tag(name: name, nameWidth: charWidth * Double(name.count), centre: centre, headTop: headTop)
    }

    /// A cut like the App's: the whole name if it fits, else the widest prefix of at least four letters plus an ellipsis.
    private static func fit(_ name: String, _ maxWidth: Double) -> (text: String, width: Double)? {
        let whole = charWidth * Double(name.count)
        if whole <= maxWidth {
            return (name, whole)
        }
        let letters = Array(name)
        for count in stride(from: letters.count - 1, through: 4, by: -1) {
            let text = String(letters[0..<count]) + "…"
            let width = charWidth * Double(count + 1)
            if width <= maxWidth {
                return (text, width)
            }
        }
        return nil
    }

    private static func place(_ tags: [TrackerCompanyNameTags.Tag], face: TrackerCompanyNameTags.Box? = nil,
                              slot: Double = slotWidth) -> [TrackerCompanyNameTags.Placement?] {
        TrackerCompanyNameTags.place(tags, face: face, slotWidth: slot) { name, maxWidth in fit(name, maxWidth) }
    }

    private static func expectPlaced(_ placement: TrackerCompanyNameTags.Placement?, _ name: String) -> TrackerCompanyNameTags.Placement {
        guard let placement else {
            fail("\(name) should get a chip")
        }
        return placement
    }

    /// A name's full chip is its text plus 12 pt of padding, centred over its familiar and held on the lowest tier, 5 pt above the head.
    private static func aSingleNameStandsOnTheLowestTierCentred() {
        let placed = expectPlaced(place([tag("Ember", centre: 140)])[0], "Ember")
        expect(placed.text == "Ember" && !placed.cut, "a name that fits should show whole, got \(placed.text)")
        expect(placed.tier == 0 && abs(placed.bottom - (headTop + 5)) < 1e-9, "a lone name should stand on the lowest tier, 5 pt above the head, got tier \(placed.tier) at \(placed.bottom)")
        expect(abs(placed.width - 42) < 1e-9 && abs(placed.left - 119) < 1e-9, "a 5-letter name should be 42 pt wide, centred on 140 (left 119), got \(placed.width) at \(placed.left)")
        expect(abs(placed.left + placed.width / 2 - 140) < 1e-9, "the chip should be centred over its familiar")
        expect(abs(placed.stemLeft - 139.5) < 1e-9, "the stem should be 1 pt wide and centred on the familiar, got \(placed.stemLeft)")
        expect(placed.left >= 0 && placed.left + placed.width <= slotWidth, "a chip should stay inside the slot")
    }

    /// Each tier is one step, 20 pt, above the last: a chip's stem runs from the head to its chip, and the tiers stay 5 pt clear of each other.
    private static func tiersStepTwentyPointsAboveTheHead() {
        let placed = place([tag("Ember", centre: 140), tag("Ember", centre: 140), tag("Ember", centre: 140)])
        let bottoms = placed.map { $0?.bottom ?? -1 }
        expect(bottoms == [headTop + 5, headTop + 25, headTop + 45], "three names over one head should stand at 5, 25 and 45 pt above it, got \(bottoms)")
        expect(placed.compactMap { $0?.tier } == [0, 1, 2], "the three names should take tiers 0, 1 and 2")
    }

    /// A name that would sit over a placed chip goes up a tier.
    private static func aNameOverlappingAnotherClimbsATier() {
        let placed = place([tag("Ember", centre: 140), tag("Quartz", centre: 150)])
        let second = expectPlaced(placed[1], "Quartz")
        expect(second.tier == 1, "a name over another's chip should climb a tier, got tier \(second.tier)")
    }

    /// Two names well apart share the lowest tier.
    private static func twoFarApartNamesShareTheLowestTier() {
        let placed = place([tag("Ember", centre: 60), tag("Ember", centre: 200)])
        expect(placed.allSatisfy { $0?.tier == 0 }, "two names far apart should both stand on the lowest tier, got \(placed.map { $0?.tier ?? -1 })")
    }

    /// A tier whose band runs into the master's face is blocked where the face is, so the name climbs past it. The face spans 60 to 80 pt
    /// up, so tier 0 (65 to 80) runs into it, and tier 1 (85 to 100) does not.
    private static func aTierThatRunsIntoTheFaceIsSkipped() {
        let face = TrackerCompanyNameTags.Box(minX: 130, maxX: 150, minY: 60, maxY: 80)
        let placed = expectPlaced(place([tag("Ember", centre: 140)], face: face)[0], "Ember")
        expect(placed.tier == 1, "a tier that would cover the face should be skipped, so the name stands on tier 1, got tier \(placed.tier)")
        let covers = placed.left < face.maxX && placed.left + placed.width > face.minX
            && placed.bottom < face.maxY && placed.bottom + TrackerCompanyNameTags.chipHeight > face.minY
        expect(!covers, "the chip should not cover the face")
    }

    /// A face the tier's band doesn't reach blocks nothing: the name stands on the lowest tier even where it is over the face.
    private static func aTierBelowTheFaceIsNotBlocked() {
        let face = TrackerCompanyNameTags.Box(minX: 130, maxX: 150, minY: 0, maxY: 40)
        let placed = expectPlaced(place([tag("Ember", centre: 140)], face: face)[0], "Ember")
        expect(placed.tier == 0, "a face below the tier's band should not move the name, got tier \(placed.tier)")
    }

    /// A name with no room on any tier is cut with an ellipsis, to the widest free run over its head. In a 60 pt slot, "Search index" (84 pt
    /// whole) is cut to "Search …", 48 pt of text, in a 60 pt chip at the slot's left edge.
    private static func aNameWithNoRoomIsCutWithAnEllipsis() {
        let placed = expectPlaced(place([tag("Search index", centre: 30)], slot: 60)[0], "Search index")
        expect(placed.cut && placed.text == "Search …", "a name wider than its room should be cut with an ellipsis, got \(placed.text)")
        expect(abs(placed.width - 60) < 1e-9 && abs(placed.left) < 1e-9, "the cut chip should fill its 60 pt room at the slot's edge, got \(placed.width) at \(placed.left)")
        expect(placed.left >= 0 && placed.left + placed.width <= 60, "the cut chip should stay inside the slot")
    }

    /// A name that cannot keep four letters and an ellipsis in any free run gets no chip.
    private static func aNameThatFitsNowhereGetsNoChip() {
        let placed = TrackerCompanyNameTags.place([tag("Search index", centre: 30)], face: nil, slotWidth: 60) { _, _ in nil }
        expect(placed[0] == nil, "a name that fits nowhere should get no chip")
    }

    /// Spawn order decides: the first name keeps the lower tier when two collide.
    private static func earlierNamesKeepTheLowerTier() {
        let placed = place([tag("Ember", centre: 140), tag("Quartz", centre: 140)])
        expect(placed[0]?.tier == 0 && placed[1]?.tier == 1, "the first name should keep the lower tier, got \(placed.map { $0?.tier ?? -1 })")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("TrackerCompanyNameTagsTests failed: \(message)\n", stderr)
        exit(1)
    }
}
