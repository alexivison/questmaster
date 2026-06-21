import Foundation
import QuestmasterCore

struct KeymapTests {
    static func run() {
        commandChordsAreUnique()
        documentedBareKeyOverloadsStayIntentional()
        recolorBindingsUseTUIKeys()
        boardDeleteUsesXWhileTrackerXIsFreed()
        continueBindingIsFoldedIntoEnter()
        toggleTrackerRailUsesCommandT()
        print("KeymapTests: all tests passed")
    }

    private static func commandChordsAreUnique() {
        var seen: [String: String] = [:]
        var duplicates: [String] = []

        for binding in Keymap.commandBindings {
            let chord = binding.chordDescription
            if let existing = seen[chord] {
                duplicates.append("\(chord): \(existing), \(binding.id)")
            } else {
                seen[chord] = binding.id
            }
        }

        expect(duplicates.isEmpty, "duplicate command chords: \(duplicates.joined(separator: "; "))")
    }

    private static func documentedBareKeyOverloadsStayIntentional() {
        let expected: Set<String> = [
            "a:list.attach-to-quest|viewer.approve",
            "d:list.delete|viewer.done",
            "c:tracker-list.recolor-session",
            "C:tracker-list.recolor-repo",
            "x:board-list.delete-quest|tracker-list.freed|viewer.gate-toggle",
        ]
        let actual = Set(Keymap.contextScopedBareKeyOverloads.map { overload in
            "\(overload.key):" + overload.meanings
                .map { "\($0.context).\($0.action)" }
                .joined(separator: "|")
        })

        expect(actual == expected, "bare key overloads were \(actual.sorted())")
    }

    private static func recolorBindingsUseTUIKeys() {
        expect(Keymap.List.recolorSession.keys == ["c"], "session recolor key mismatch")
        expect(Keymap.List.recolorRepo.keys == ["C"], "repo recolor key mismatch")
        expect(Keymap.List.recolorRepo.matchesExactly("C"), "repo recolor should match uppercase C exactly")
        expect(!Keymap.List.recolorRepo.matchesExactly("c"), "repo recolor should not match lowercase c")
        expect(
            !Keymap.bareKeyBindings.contains { $0.action == "recolor" },
            "legacy recolor action should not be bound"
        )
    }

    private static func boardDeleteUsesXWhileTrackerXIsFreed() {
        expect(Keymap.List.deleteQuest.keys == ["x"], "board quest delete key mismatch")
        let xMeanings = Keymap.contextScopedBareKeyOverloads.first { $0.key == "x" }?.meanings.map(\.action) ?? []
        expect(xMeanings.contains("delete-quest"), "x should document board delete-quest")
        expect(xMeanings.contains("freed"), "x should document tracker freed")
    }

    private static func toggleTrackerRailUsesCommandT() {
        expect(Keymap.Command.toggleTrackerRail.keyEquivalent == "t", "toggle tracker key was \(Keymap.Command.toggleTrackerRail.keyEquivalent)")
        expect(
            Keymap.commandBindings.contains(Keymap.Command.toggleTrackerRail),
            "toggle tracker binding missing from command list"
        )
    }

    private static func continueBindingIsFoldedIntoEnter() {
        expect(
            !Keymap.bareKeyBindings.contains { $0.action == "continue-session" },
            "continue-session should not have a bare key binding"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("KeymapTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
