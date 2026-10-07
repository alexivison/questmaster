import Foundation
import QuestmasterCore

struct GhosttyConfigParserTests {
    static func run() {
        readsTheFamilyAndIgnoresOtherKeys()
        keepsTheFallbackListAfterTheLastReset()
        quotedEmptyValueResets()
        commentsAreIgnored()
        similarKeysDoNotMatch()
        crlfLineEndingsParse()
        configLoadsAfterConfigGhosttyAndAppSupportAfterXDG()
        includesResolveRelativeToTheirFileAndLoadAfterIt()
        optionalMissingAndCyclicIncludesAreHarmless()
        anUnavailablePrimaryFallsThroughToAnInstalledFamily()
        readsWindowPaddingAndKeepsTheLastValue()
        windowPaddingIsNilWhenNeitherAxisIsSet()
        print("GhosttyConfigParserTests: all tests passed")
    }

    private static func readsTheFamilyAndIgnoresOtherKeys() {
        expect(GhosttyConfigParser.fontFamilies(in: "theme = dark\nfont-family = JetBrainsMono Nerd Font\nfont-size = 12\n") == ["JetBrainsMono Nerd Font"], "should read the family")
        expect(GhosttyConfigParser.fontFamilies(in: "font-size = 12\n").isEmpty, "no family should give an empty list")
        expect(GhosttyConfigParser.fontFamilies(in: "font-family = \"Fira Code\"") == ["Fira Code"], "quotes should be stripped")
    }

    private static func keepsTheFallbackListAfterTheLastReset() {
        let config = "font-family = A\nfont-family = B\nfont-family =\nfont-family = C\nfont-family = D\n"
        expect(GhosttyConfigParser.fontFamilies(in: config) == ["C", "D"], "a reset should drop earlier families and keep later ones in order")
    }

    private static func quotedEmptyValueResets() {
        expect(GhosttyConfigParser.fontFamilies(in: "font-family = A\nfont-family = \"\"\n").isEmpty, "a quoted empty value should reset the list")
    }

    private static func commentsAreIgnored() {
        expect(GhosttyConfigParser.fontFamilies(in: "# font-family = Commented\n  # font-family = Indented\nfont-family = Real\n") == ["Real"], "comments should not count")
    }

    private static func similarKeysDoNotMatch() {
        let config = "font-family-bold = Bold Face\nfont-family-italic = Italic Face\nfont-family = Regular\n"
        expect(GhosttyConfigParser.fontFamilies(in: config) == ["Regular"], "font-family-bold and friends should not count")
    }

    private static func crlfLineEndingsParse() {
        expect(GhosttyConfigParser.fontFamilies(in: "font-size = 12\r\nfont-family = A\r\nfont-family = B\r\n") == ["A", "B"], "CRLF lines should parse cleanly")
    }

    private static func configLoadsAfterConfigGhosttyAndAppSupportAfterXDG() {
        let files = [
            "/xdg/ghostty/config.ghostty": "font-family = XDG ghostty",
            "/xdg/ghostty/config": "font-family = XDG config",
            "/app/config.ghostty": "font-family = App ghostty",
            "/app/config": "font-family = App config",
        ]
        let families = GhosttyConfigParser.fontFamilies(inDirectories: ["/xdg/ghostty", "/app"]) { files[$0] }
        expect(families == ["XDG ghostty", "XDG config", "App ghostty", "App config"], "load order should be config.ghostty then config, XDG then app support, got \(families)")

        let reset = ["/xdg/ghostty/config.ghostty": "font-family = A", "/xdg/ghostty/config": "font-family =\nfont-family = B"]
        expect(GhosttyConfigParser.fontFamilies(inDirectories: ["/xdg/ghostty"]) { reset[$0] } == ["B"], "config should reset what config.ghostty set")
    }

    private static func includesResolveRelativeToTheirFileAndLoadAfterIt() {
        let files = [
            "/d/config": "config-file = extra/fonts\nfont-family = Own",
            "/d/extra/fonts": "font-family = Included\nconfig-file = ../more",
            "/d/more": "font-family = Nested",
        ]
        let families = GhosttyConfigParser.fontFamilies(inDirectories: ["/d"]) { files[$0] }
        expect(families == ["Own", "Included", "Nested"], "includes should load after their file, relative to it, got \(families)")
    }

    private static func optionalMissingAndCyclicIncludesAreHarmless() {
        let files = [
            "/d/config": "config-file = ?missing\nconfig-file = a\nfont-family = Own",
            "/d/a": "font-family = A\nconfig-file = b",
            "/d/b": "font-family = B\nconfig-file = a",
        ]
        let families = GhosttyConfigParser.fontFamilies(inDirectories: ["/d"]) { files[$0] }
        expect(families == ["Own", "A", "B"], "a missing optional include and a cycle should not break loading, got \(families)")
    }

    private static func anUnavailablePrimaryFallsThroughToAnInstalledFamily() {
        let installed: Set<String> = ["Fallback Mono"]
        expect(GhosttyConfigParser.firstInstalled(of: ["Missing Mono", "Fallback Mono"]) { installed.contains($0) } == "Fallback Mono", "should skip the uninstalled primary")
        expect(GhosttyConfigParser.firstInstalled(of: ["Missing Mono"]) { installed.contains($0) } == nil, "no installed family should give nil")
    }

    private static func readsWindowPaddingAndKeepsTheLastValue() {
        let files = [
            "/d/config.ghostty": "window-padding-x = 10\nwindow-padding-y = 10",
            "/d/config": "font-family = Own\nwindow-padding-x = 20",
        ]
        let padding = GhosttyConfigParser.windowPadding(inDirectories: ["/d"]) { files[$0] }
        expect(padding?.x == 20, "config should overwrite config.ghostty's x, got \(String(describing: padding?.x))")
        expect(padding?.y == 10, "y should keep config.ghostty's value when config doesn't set it, got \(String(describing: padding?.y))")
    }

    private static func windowPaddingIsNilWhenNeitherAxisIsSet() {
        let files = ["/d/config": "font-family = Own"]
        expect(GhosttyConfigParser.windowPadding(inDirectories: ["/d"]) { files[$0] } == nil, "no window-padding keys should give nil")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("GhosttyConfigParserTests: \(message)")
        }
    }
}
