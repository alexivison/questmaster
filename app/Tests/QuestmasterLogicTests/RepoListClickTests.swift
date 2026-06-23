import Foundation
import QuestmasterCore

struct RepoListClickTests {
    static func run() {
        boardSingleClickSelectsClickedRow()
        trackerSingleClickSelectsAndOpensClickedRow()
        boardDoubleClickSelectsAndOpensClickedRow()
        invalidClicksDoNothing()
        print("RepoListClickTests: all tests passed")
    }

    private static func boardSingleClickSelectsClickedRow() {
        let resolution = RepoListClick.resolve(
            clickedID: "row-2",
            clickCount: 1,
            ids: ["row-1", "row-2", "row-3"],
            openPolicy: .doubleClick
        )

        expect(
            resolution == RepoListClickResolution(selectedID: "row-2", shouldOpen: false),
            "board single click should select only"
        )
    }

    private static func trackerSingleClickSelectsAndOpensClickedRow() {
        let resolution = RepoListClick.resolve(
            clickedID: "row-2",
            clickCount: 1,
            ids: ["row-1", "row-2", "row-3"],
            openPolicy: .singleClick
        )

        expect(
            resolution == RepoListClickResolution(selectedID: "row-2", shouldOpen: true),
            "tracker single click should select and open"
        )
    }

    private static func boardDoubleClickSelectsAndOpensClickedRow() {
        let resolution = RepoListClick.resolve(
            clickedID: "row-3",
            clickCount: 2,
            ids: ["row-1", "row-2", "row-3"],
            openPolicy: .doubleClick
        )

        expect(
            resolution == RepoListClickResolution(selectedID: "row-3", shouldOpen: true),
            "double click should select and open"
        )
    }

    private static func invalidClicksDoNothing() {
        expect(
            RepoListClick.resolve(clickedID: "missing", clickCount: 1, ids: ["row-1"]) == nil,
            "stale clicked rows should be ignored"
        )
        expect(
            RepoListClick.resolve(clickedID: "row-1", clickCount: 0, ids: ["row-1"]) == nil,
            "zero click count should be ignored"
        )
        expect(
            RepoListClick.resolve(clickedID: "row-1", clickCount: 1, ids: []) == nil,
            "empty lists should ignore clicks"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("RepoListClickTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
