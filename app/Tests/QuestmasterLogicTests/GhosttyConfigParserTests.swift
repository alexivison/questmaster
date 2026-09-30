import Foundation
import QuestmasterCore

struct GhosttyConfigParserTests {
    static func run() {
        readsTheFamilyAndIgnoresOtherKeys()
        firstEntryAfterTheLastResetIsPrimary()
        emptyValueResets()
        commentsAreIgnored()
        print("GhosttyConfigParserTests: all tests passed")
    }

    private static func readsTheFamilyAndIgnoresOtherKeys() {
        let config = "theme = dark\nfont-family = JetBrainsMono Nerd Font\nfont-size = 12\n"
        expect(GhosttyConfigParser.primaryFontFamily(in: config) == "JetBrainsMono Nerd Font", "should read the family")
        expect(GhosttyConfigParser.primaryFontFamily(in: "font-size = 12\n") == nil, "no family should give nil")
        expect(GhosttyConfigParser.primaryFontFamily(in: "font-family = \"Fira Code\"") == "Fira Code", "quotes should be stripped")
    }

    private static func firstEntryAfterTheLastResetIsPrimary() {
        let config = "font-family = A\nfont-family = B\nfont-family =\nfont-family = C\nfont-family = D\n"
        expect(GhosttyConfigParser.primaryFontFamily(in: config) == "C", "a reset should drop earlier families")
        expect(GhosttyConfigParser.primaryFontFamily(in: "font-family = A\nfont-family = B") == "A", "the first family stays primary")
    }

    private static func emptyValueResets() {
        expect(GhosttyConfigParser.primaryFontFamily(in: "font-family = A\nfont-family =\n") == nil, "a trailing reset should clear the family")
    }

    private static func commentsAreIgnored() {
        let config = "# font-family = Commented\n  # font-family = Indented\nfont-family = Real\n"
        expect(GhosttyConfigParser.primaryFontFamily(in: config) == "Real", "comments should not count")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("GhosttyConfigParserTests: \(message)")
        }
    }
}
