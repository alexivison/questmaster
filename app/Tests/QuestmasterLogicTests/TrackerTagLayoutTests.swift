import Foundation
import QuestmasterCore

struct TrackerTagLayoutTests {
    static func run() {
        theFigureRunsFromItsFootToItsTopRow()
        theReservedHeightRoundsUpToTheStep()
        theTallestFigureKeepsTheListGap()
        aShorterFigureDropsTheTagByTheDifference()
        aMissingFigureSitsWhereTheTallestDoes()
        aFigureTallerThanTheTallestNeverOverlapsTheList()
        eachBundledClassPlacesItsTag()
        print("TrackerTagLayoutTests: all tests passed")
    }

    /// The bundled classes' idle art, as their `animation.json` and first frame give it: every canvas has two clear rows above
    /// the head, so the top opaque row is 2.
    private static let bundledClasses: [(name: String, topRow: Int, footRow: Int, figure: Int)] = [
        ("bard", 2, 160, 159),
        ("cleric", 2, 156, 155),
        ("paladin", 2, 172, 171),
        ("wizard", 2, 151, 150),
    ]

    private static func theFigureRunsFromItsFootToItsTopRow() {
        expect(TrackerTagLayout.figureHeight(topRow: 2, footRow: 172) == 171, "the paladin's figure should run 171 px above its sole")
        expect(TrackerTagLayout.figureHeight(topRow: 0, footRow: 0) == 1, "a figure in one row should be 1 px tall")
    }

    private static func theReservedHeightRoundsUpToTheStep() {
        expect(TrackerTagLayout.reservedHeight(tallestFigure: 171, step: 5) == 175, "171 should reserve 175 on the 5 pt step")
        expect(TrackerTagLayout.reservedHeight(tallestFigure: 175, step: 5) == 175, "a figure on the step should reserve itself")
        expect(TrackerTagLayout.reservedHeight(tallestFigure: 0, step: 5) == 0, "no figure should reserve nothing")
    }

    private static func theTallestFigureKeepsTheListGap() {
        expect(TrackerTagLayout.offsetBelowList(figureHeight: 171, tallestFigure: 171, listGap: 40) == 40,
               "the tallest figure's tag should sit the list gap below the list")
    }

    private static func aShorterFigureDropsTheTagByTheDifference() {
        expect(TrackerTagLayout.offsetBelowList(figureHeight: 150, tallestFigure: 171, listGap: 40) == 61,
               "a figure 21 px shorter should drop its tag 21 px")
    }

    private static func aMissingFigureSitsWhereTheTallestDoes() {
        expect(TrackerTagLayout.offsetBelowList(figureHeight: nil, tallestFigure: 171, listGap: 40) == 40,
               "a shell, nothing attached or a class with no art should sit where the tallest figure does")
    }

    private static func aFigureTallerThanTheTallestNeverOverlapsTheList() {
        expect(TrackerTagLayout.offsetBelowList(figureHeight: 175, tallestFigure: 171, listGap: 40) == 36,
               "a figure 4 px taller should bring its tag 4 px nearer the list")
        expect(TrackerTagLayout.offsetBelowList(figureHeight: 220, tallestFigure: 171, listGap: 40) == 0,
               "a figure taller than the list gap allows should leave its tag at the list's edge")
    }

    private static func eachBundledClassPlacesItsTag() {
        for sprite in bundledClasses {
            let figure = TrackerTagLayout.figureHeight(topRow: sprite.topRow, footRow: sprite.footRow)
            expect(figure == sprite.figure, "the \(sprite.name)'s figure should run \(sprite.figure) px, got \(figure)")
            let tallest = bundledClasses.map(\.figure).max() ?? 0
            let offset = TrackerTagLayout.offsetBelowList(figureHeight: figure, tallestFigure: tallest, listGap: 40)
            let expected = 40 + tallest - sprite.figure
            expect(offset == expected, "the \(sprite.name)'s tag should sit \(expected) below the list, got \(offset)")
        }
        let reserved = TrackerTagLayout.reservedHeight(tallestFigure: bundledClasses.map(\.figure).max() ?? 0, step: 5)
        expect(reserved == 175, "the bundled classes should reserve 175, got \(reserved)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("TrackerTagLayoutTests failed: \(message)\n", stderr)
        exit(1)
    }
}
