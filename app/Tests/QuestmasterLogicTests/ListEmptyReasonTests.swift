import Foundation
import QuestmasterCore

struct ListEmptyReasonTests {
    static func run() {
        nothingToListIsNothingYet()
        filterThatHidAllIsNoMatch()
        partlyShownIsNotNoMatch()
        questLogSaysWhetherItsFilterHidAllQuests()
        print("ListEmptyReasonTests: all tests passed")
    }

    private static func nothingToListIsNothingYet() {
        expect(ListEmptyReason.of(total: 0, shown: 0) == .nothingYet, "an empty list with nothing behind it has nothing yet")
    }

    private static func filterThatHidAllIsNoMatch() {
        expect(ListEmptyReason.of(total: 3, shown: 0) == .noMatch, "a filter that hid all three items is a no-match")
    }

    private static func partlyShownIsNotNoMatch() {
        expect(ListEmptyReason.of(total: 3, shown: 1) == .nothingYet, "a list with something shown is not a no-match")
    }

    private static func questLogSaysWhetherItsFilterHidAllQuests() {
        let store = QuestLogStore()
        store.sync(quests: [], repos: [])
        expect(store.emptyReason == .nothingYet, "no quests at all is nothing yet")
        store.sync(quests: [QuestItem(id: "q1", content: "Write the tests", projectID: "p")], repos: [], query: "zzz")
        expect(store.emptyReason == .noMatch, "a search that hid the only quest is a no-match")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("ListEmptyReasonTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
