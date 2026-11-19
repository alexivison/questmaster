import Foundation
import QuestmasterCore

struct FuzzySearchTests {
    static func run() {
        matchesAbbreviatedTermsInAnyOrder()
        preservesCharacterOrderAndRepeatedCharacters()
        ignoresCaseAccentsAndSurroundingWhitespace()
        ranksLiteralMatchesBeforeFuzzyMatchesWithStableTies()
        ranksContiguousTermsBeforeScatteredCharacters()
        blankSearchKeepsEveryItemInOrder()
        print("FuzzySearchTests: all tests passed")
    }

    private static func matchesAbbreviatedTermsInAnyOrder() {
        let id = "anthropic/claude-opus-5.5"
        for query in ["anthr opus 5", "opus anthr 5", "  ANTHR\tOPUS\n5  ", "anthropus55"] {
            expect(FuzzySearch(query).matches(id), "\(query) should match \(id)")
        }
        expect(!FuzzySearch("anthr opus 6").matches(id), "every term must match")
        expect(!FuzzySearch("anthr opus 5").matches("openai/gpt-5.5"), "every term must be present in the candidate")
    }

    private static func preservesCharacterOrderAndRepeatedCharacters() {
        expect(!FuzzySearch("supo").matches("opus"), "characters within a term must appear in order")
        expect(FuzzySearch("55").matches("opus-5.5"), "a repeated character needs a separate occurrence")
        expect(!FuzzySearch("555").matches("opus-5.5"), "one occurrence cannot satisfy several characters")
        expect(!FuzzySearch("x").matches(""), "a nonempty query cannot match empty text")
    }

    private static func ignoresCaseAccentsAndSurroundingWhitespace() {
        expect(FuzzySearch(" CAFE ").matches("Café"), "case and accents should not hide a result")
        expect(FuzzySearch("東 大").matches("東京大学"), "matching should support Unicode characters")
    }

    private static func ranksLiteralMatchesBeforeFuzzyMatchesWithStableTies() {
        let items = ["o---p---s", "the ops model", "ops-plus", "OPS", "unrelated", "o_p_s", "ops-next"]
        expect(
            FuzzySearch("ops").ranked(items, key: { $0 }) == ["OPS", "ops-plus", "ops-next", "the ops model", "o---p---s", "o_p_s"],
            "exact, prefix, substring and fuzzy matches should rank in that order, with stable ties"
        )
    }

    private static func blankSearchKeepsEveryItemInOrder() {
        let items = ["last", "", "first"]
        let search = FuzzySearch(" \t\n ")
        expect(items.allSatisfy { search.matches($0) }, "a blank search should match every value")
        expect(search.ranked(items, key: { $0 }) == items, "browsing should preserve the original order")
    }

    private static func ranksContiguousTermsBeforeScatteredCharacters() {
        let items = ["anthropic/claude-sonnet-5.5", "anthropic/claude-opus-5.5"]
        expect(
            FuzzySearch("anthr opus 5").ranked(items, key: { $0 }) == Array(items.reversed()),
            "matching each term contiguously should outrank characters scattered across an ID"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError("FuzzySearchTests failed: \(message)")
        }
    }
}
