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
        configLoadsLegacyBeforeGhosttyAcrossXDGThenAppSupport()
        includesResolveRelativeToTheirFileAndLoadAfterIt()
        reportsLoadedFilesInOrderIncludingNestedIncludes()
        blankConfigFileClearsEarlierIncludes()
        emptyConfigFilePathsDoNotResetAndQuotedQuestionMarkIsLiteral()
        includesExpandHomeDirectory()
        optionalMissingAndCyclicIncludesAreHarmless()
        anUnavailablePrimaryFallsThroughToAnInstalledFamily()
        readsWindowPaddingAndKeepsTheLastValue()
        windowPaddingIsNilWhenNeitherAxisIsSet()
        twoValueWindowPaddingUsesTheFirstComponent()
        malformedWindowPaddingLeavesThePreviousValue()
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

    private static func configLoadsLegacyBeforeGhosttyAcrossXDGThenAppSupport() {
        let files = [
            "/xdg/ghostty/config.ghostty": "font-family = XDG ghostty",
            "/xdg/ghostty/config": "font-family = XDG config",
            "/app/config.ghostty": "font-family = App ghostty",
            "/app/config": "font-family = App config",
        ]
        let families = GhosttyConfigParser.fontFamilies(inDirectories: ["/xdg/ghostty", "/app"]) { files[$0] }
        expect(families == ["XDG config", "XDG ghostty", "App config", "App ghostty"], "load order should be config then config.ghostty, XDG then app support, got \(families)")

        let reset = ["/xdg/ghostty/config.ghostty": "font-family = A", "/xdg/ghostty/config": "font-family =\nfont-family = B"]
        expect(GhosttyConfigParser.fontFamilies(inDirectories: ["/xdg/ghostty"]) { reset[$0] } == ["B", "A"], "config.ghostty should load after and append to the legacy config")
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

    private static func reportsLoadedFilesInOrderIncludingNestedIncludes() {
        let files = [
            "/xdg/ghostty/config.ghostty": "config-file = local/xdg",
            "/xdg/ghostty/local/xdg": "config-file = /shared/base",
            "/shared/base": "font-family = Shared",
            "/xdg/ghostty/config": "font-family = Legacy",
            "/app/config": "font-family = App legacy",
            "/app/config.ghostty": "config-file = nested/app",
            "/app/nested/app": "font-family = App\nconfig-file = /shared/base",
        ]
        let paths = GhosttyConfigParser.loadedFiles(inDirectories: ["/xdg/ghostty", "/app"]) { files[$0] }
        expect(paths == [
            "/xdg/ghostty/config",
            "/xdg/ghostty/config.ghostty",
            "/app/config",
            "/app/config.ghostty",
            "/xdg/ghostty/local/xdg",
            "/app/nested/app",
            "/shared/base",
        ], "loaded file paths should include all default files before queued includes, got \(paths)")
    }

    private static func blankConfigFileClearsEarlierIncludes() {
        let files = [
            "/d/config": "config-file = unused\nconfig-file =\nconfig-file = active\nfont-family = Root",
            "/d/unused": "font-family = Unused",
            "/d/active": "font-family = Active",
        ]

        let paths = GhosttyConfigParser.loadedFiles(inDirectories: ["/d"]) { files[$0] }
        let families = GhosttyConfigParser.fontFamilies(inDirectories: ["/d"]) { files[$0] }
        expect(paths == ["/d/config", "/d/active"], "a blank config-file should discard earlier queued includes, got \(paths)")
        expect(families == ["Root", "Active"], "discarded includes must not contribute settings, got \(families)")
    }

    private static func emptyConfigFilePathsDoNotResetAndQuotedQuestionMarkIsLiteral() {
        let files = [
            "/d/config": "config-file = first\nconfig-file = \"\"\nconfig-file = ?\nconfig-file = ?\"\"\nconfig-file = \"?literal\"",
            "/d/first": "font-family = First",
            "/d/?literal": "font-family = Literal question mark",
        ]

        let paths = GhosttyConfigParser.loadedFiles(inDirectories: ["/d"]) { files[$0] }
        expect(paths == ["/d/config", "/d/first", "/d/?literal"], "empty paths should be ignored and a quoted leading question mark should be literal, got \(paths)")
    }

    private static func includesExpandHomeDirectory() {
        let files = [
            "/d/config": "config-file = ~/included",
            "/home/example/included": "font-family = Home include",
        ]
        let paths = GhosttyConfigParser.loadedFiles(inDirectories: ["/d"], homeDirectory: "/home/example") { files[$0] }
        expect(paths == ["/d/config", "/home/example/included"], "tilde includes should expand under the home directory, got \(paths)")
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
        expect(padding?.x == 10, "config.ghostty should overwrite the legacy config x, got \(String(describing: padding?.x))")
        expect(padding?.y == 10, "y should keep the legacy config value when config.ghostty doesn't set it, got \(String(describing: padding?.y))")
    }

    private static func windowPaddingIsNilWhenNeitherAxisIsSet() {
        let files = ["/d/config": "font-family = Own"]
        expect(GhosttyConfigParser.windowPadding(inDirectories: ["/d"]) { files[$0] } == nil, "no window-padding keys should give nil")
    }

    private static func twoValueWindowPaddingUsesTheFirstComponent() {
        let files = ["/d/config": "window-padding-x = 10,20\nwindow-padding-y = 15, 25"]
        let padding = GhosttyConfigParser.windowPadding(inDirectories: ["/d"]) { files[$0] }
        expect(padding?.x == 10, "two-value x should use the first component, got \(String(describing: padding?.x))")
        expect(padding?.y == 15, "two-value y should use the first component (trimmed), got \(String(describing: padding?.y))")
    }

    private static func malformedWindowPaddingLeavesThePreviousValue() {
        let files = ["/d/config": "window-padding-x = 10\nwindow-padding-x = not-a-number\nwindow-padding-y = 10"]
        let padding = GhosttyConfigParser.windowPadding(inDirectories: ["/d"]) { files[$0] }
        expect(padding?.x == 10, "a malformed later value should not clobber the earlier good one, got \(String(describing: padding?.x))")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("GhosttyConfigParserTests: \(message)")
        }
    }
}
