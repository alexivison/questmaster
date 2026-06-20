import Foundation
import QuestmasterCore

struct KeymapTests {
    static func run() {
        commandChordsAreUnique()
        documentedBareKeyOverloadsStayIntentional()
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
            "x:list.recolor|viewer.gate-toggle",
        ]
        let actual = Set(Keymap.contextScopedBareKeyOverloads.map { overload in
            "\(overload.key):" + overload.meanings
                .map { "\($0.context).\($0.action)" }
                .joined(separator: "|")
        })

        expect(actual == expected, "bare key overloads were \(actual.sorted())")
    }

    private static func toggleTrackerRailUsesCommandT() {
        expect(Keymap.Command.toggleTrackerRail.keyEquivalent == "t", "toggle tracker key was \(Keymap.Command.toggleTrackerRail.keyEquivalent)")
        expect(
            Keymap.commandBindings.contains(Keymap.Command.toggleTrackerRail),
            "toggle tracker binding missing from command list"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("KeymapTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
