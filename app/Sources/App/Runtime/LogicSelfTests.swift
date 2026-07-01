#if DEBUG
import Foundation
import QuestmasterCore

enum LogicSelfTests {
    private static let cases: [(name: String, body: () throws -> Void)] = [
        ("testNavigationTogglesFocusShownRegionAndHideToTerminal", testNavigationTogglesFocusShownRegionAndHideToTerminal),
        ("testDirectionalRegionFocusMapping", testDirectionalRegionFocusMapping),
        ("testKeymapErgonomicsBindings", testKeymapErgonomicsBindings),
        ("testArtifactNavigationPolicy", testArtifactNavigationPolicy),
    ]

    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--run-logic-tests") else {
            return false
        }

        guard !cases.isEmpty else {
            fputs("Questmaster self-tests failed: no test cases registered\n", stderr)
            exit(1)
        }

        var passed = 0
        for testCase in cases {
            do {
                try testCase.body()
                passed += 1
            } catch {
                fputs("Questmaster self-tests failed: \(testCase.name): \(error)\n", stderr)
                exit(1)
            }
        }
        print("Questmaster self-tests: \(passed) passed")
        exit(0)
    }

    private static func testNavigationTogglesFocusShownRegionAndHideToTerminal() throws {
        var state = AppNavigationState(trackerVisible: false, dockVisible: false)
        try expect(state.toggleTracker() == .focused(.tracker), "showing tracker should focus tracker")
        try expect(state.trackerVisible, "tracker should show")
        try expect(state.focusedRegion == .tracker, "showing tracker should focus tracker")

        state = AppNavigationState(focusedRegion: .dock, trackerVisible: false, dockVisible: true)
        try expect(state.toggleTracker() == .focused(.tracker), "showing tracker should focus tracker from dock")
        try expect(state.trackerVisible, "tracker should show while dock is focused")
        try expect(state.focusedRegion == .tracker, "showing tracker should take focus from dock")

        state = AppNavigationState(focusedRegion: .tracker)
        try expect(state.toggleTracker() == .focused(.terminal), "hiding focused tracker should focus terminal")
        try expect(!state.trackerVisible, "tracker should hide")
        try expect(state.focusedRegion == .terminal, "hidden tracker should not keep focus")

        state = AppNavigationState(focusedRegion: .tracker, dockVisible: true)
        try expect(state.toggleDock() == .focused(.terminal), "hiding non-focused dock should focus terminal")
        try expect(!state.dockVisible, "dock should hide")
        try expect(state.focusedRegion == .terminal, "hiding non-focused dock should focus terminal")
    }

    private static func testDirectionalRegionFocusMapping() throws {
        try expect(AppNavigationState.directionalRegionTarget(from: .terminal, direction: .left) == .tracker, "terminal left should target tracker")
        try expect(AppNavigationState.directionalRegionTarget(from: .terminal, direction: .right) == .dock, "terminal right should target dock")
        try expect(AppNavigationState.directionalRegionTarget(from: .tracker, direction: .right) == .terminal, "tracker right should target terminal")
        try expect(AppNavigationState.directionalRegionTarget(from: .tracker, direction: .left) == .tracker, "tracker left should stay")
        try expect(AppNavigationState.directionalRegionTarget(from: .dock, direction: .left) == .terminal, "dock left should target terminal")
        try expect(AppNavigationState.directionalRegionTarget(from: .dock, direction: .right) == .dock, "dock right should stay")

        var state = AppNavigationState(trackerVisible: false, dockVisible: false)
        try expect(state.directionalRegionFocus(.left) == .unchanged, "terminal left should no-op when tracker is hidden")
        try expect(state.directionalRegionFocus(.right) == .unchanged, "terminal right should no-op when dock is hidden")

        state = AppNavigationState(trackerVisible: false, dockVisible: true)
        try expect(state.directionalRegionFocus(.right) == .focused(.dock), "terminal right should focus visible dock")

        state = AppNavigationState(trackerVisible: true, dockVisible: false)
        try expect(state.directionalRegionFocus(.left) == .focused(.tracker), "terminal left should focus visible tracker")
    }

    private static func testKeymapErgonomicsBindings() throws {
        try expect(Keymap.List.moveUpCharacters.keys == ["k"], "list k should move up")
        try expect(Keymap.List.moveUpKeyCodes.keyCodes.isEmpty, "list should not bind up arrow")
        try expect(Keymap.List.moveDownKeyCodes.keyCodes.isEmpty, "list should not bind down arrow")
        try expect(Keymap.List.open.keyCodes == [36, 76], "list Enter should open selection")
        try expect(!Keymap.List.open.matches(124), "list right arrow should not open selection")
        try expect(Keymap.List.delete.keys == ["d"], "list delete should be d")
        try expect(!Keymap.List.delete.matches("x"), "x should not delete list items")
        try expect(Keymap.Viewer.backKeyCodes.keyCodes == [123], "viewer back should include left arrow")
        try expect(Keymap.Viewer.back.keys.contains("h"), "viewer h should go back")
    }

    private static func testArtifactNavigationPolicy() throws {
        let httpURL = URL(string: "https://example.com")!
        try expect(
            ArtifactNavigationPolicy.decide(url: URL(string: "file:///tmp/report.html"), userInitiated: false) == .allowFile,
            "local artifact navigation should be allowed"
        )
        try expect(
            ArtifactNavigationPolicy.decide(url: httpURL, userInitiated: false) == .block,
            "non-user remote resource loads should be blocked"
        )
        try expect(
            ArtifactNavigationPolicy.decide(url: httpURL, userInitiated: true) == .openExternal(httpURL),
            "user remote clicks should open externally"
        )
        try expect(
            ArtifactNavigationPolicy.decide(url: URL(string: "javascript:alert(1)"), userInitiated: true) == .block,
            "javascript URLs should be blocked"
        )
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw TestFailure(message)
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
