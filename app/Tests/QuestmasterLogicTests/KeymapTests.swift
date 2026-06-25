import Foundation
import QuestmasterCore

struct KeymapTests {
    static func run() {
        commandChordsAreUnique()
        recolorBindingsUseTUIKeys()
        viewerBindingsUseTUIQuestDetailKeys()
        commentComposerBindingsUseTUIKeys()
        listBindingsUseVimIntoForOpen()
        newSessionSelectBindingsIncludeVimKeys()
        unifiedDeleteBindingsUseD()
        regionToggleCommandsUseRedesignChords()
        controlHandoffMapsListControlDirections()
        print("KeymapTests: all tests passed")
    }

    private static func commandChordsAreUnique() {
        var seen: [String: String] = [:]
        var duplicates: [String] = []

        for binding in commandBindings {
            let chord = chordDescription(binding)
            if let existing = seen[chord] {
                duplicates.append("\(chord): \(existing), \(binding.title)")
            } else {
                seen[chord] = binding.title
            }
        }

        expect(duplicates.isEmpty, "duplicate command chords: \(duplicates.joined(separator: "; "))")
    }

    private static func recolorBindingsUseTUIKeys() {
        expect(Keymap.List.recolorSession.keys == ["c"], "session recolor key mismatch")
        expect(Keymap.List.recolorRepo.keys == ["C"], "repo recolor key mismatch")
        expect(Keymap.List.recolorRepo.matchesExactly("C"), "repo recolor should match uppercase C exactly")
        expect(!Keymap.List.recolorRepo.matchesExactly("c"), "repo recolor should not match lowercase c")
    }

    private static func viewerBindingsUseTUIQuestDetailKeys() {
        expect(Keymap.Viewer.moveUpCharacters.keys == ["k"], "viewer move up key mismatch")
        expect(Keymap.Viewer.moveDownCharacters.keys == ["j"], "viewer move down key mismatch")
        expect(Keymap.Viewer.moveUpKeyCodes.keyCodes == [126], "viewer up arrow key mismatch")
        expect(Keymap.Viewer.moveDownKeyCodes.keyCodes == [125], "viewer down arrow key mismatch")
        expect(Keymap.Viewer.commentAdd.keys == ["c"], "comment add key mismatch")
        expect(Keymap.Viewer.commentEdit.keys == ["e"], "comment edit key mismatch")
        expect(Keymap.Viewer.commentDelete.keys == ["d"], "comment delete key mismatch")
        expect(Keymap.Viewer.commentDelete.modifiers.isEmpty, "comment delete should be plain d")
        expect(Keymap.Viewer.commentResolve.keys == ["R"], "comment resolve key mismatch")
        expect(Keymap.Viewer.commentResolve.modifiers == [.shift], "comment resolve should document shift")
        expect(Keymap.Viewer.openRelated.keys == ["o"], "open related key mismatch")
        expect(Keymap.Viewer.back.keys == ["h", "\u{1b}"], "viewer back key mismatch")
        expect(Keymap.Viewer.backKeyCodes.keyCodes == [123], "viewer back left arrow mismatch")
        expect(Keymap.Viewer.done.keys == ["f"], "viewer done key should be f for finish")
        expect(Keymap.Viewer.gateToggle.matches("x"), "viewer x should toggle gates")
    }

    private static func listBindingsUseVimIntoForOpen() {
        expect(Keymap.List.moveUpCharacters.keys == ["k"], "list move up key mismatch")
        expect(Keymap.List.moveDownCharacters.keys == ["j"], "list move down key mismatch")
        expect(Keymap.List.openCharacters.keys == ["l"], "list open character mismatch")
        expect(Keymap.List.moveUpKeyCodes.keyCodes.isEmpty, "up arrow should not move list selection")
        expect(Keymap.List.moveDownKeyCodes.keyCodes.isEmpty, "down arrow should not move list selection")
        expect(!Keymap.List.moveUpCharacters.matches("h"), "h should not move list selection up")
        expect(!Keymap.List.moveUpKeyCodes.matches(123), "left arrow should not move list selection up")
        expect(!Keymap.List.moveUpKeyCodes.matches(126), "up arrow should not move list selection up")
        expect(!Keymap.List.moveDownKeyCodes.matches(125), "down arrow should not move list selection down")
        expect(!Keymap.List.moveDownKeyCodes.matches(124), "right arrow should not move list selection down")
        expect(!Keymap.List.moveDownCharacters.matches("l"), "l should not move list selection down")
        expect(Keymap.List.openCharacters.matches("l"), "l should open list selection")
        expect(Keymap.List.open.keyCodes == [36, 76], "enter should open list selection")
        expect(!Keymap.List.open.matches(124), "right arrow should not open list selection")
    }

    private static func commentComposerBindingsUseTUIKeys() {
        expect(Keymap.CommentComposer.submitEnter.keyCodes == [36, 76], "comment composer enter submit mismatch")
        expect(Keymap.CommentComposer.submitControlS.keys == ["s"], "comment composer ctrl-s submit mismatch")
        expect(Keymap.CommentComposer.newlineControlJ.keys == ["j"], "comment composer ctrl-j newline mismatch")
        expect(Keymap.CommentComposer.newlineOptionEnter.keyCodes == [36, 76], "comment composer option-enter newline mismatch")
        expect(Keymap.CommentComposer.cancel.keyCodes == [53], "comment composer escape cancel mismatch")
    }

    private static func newSessionSelectBindingsIncludeVimKeys() {
        expect(Keymap.NewSession.selectLeft.keyCodes == [123], "new session left arrow mismatch")
        expect(Keymap.NewSession.selectRight.keyCodes == [124], "new session right arrow mismatch")
        expect(Keymap.NewSession.previousRole.keyCodes == [33], "new session previous role key mismatch")
        expect(Keymap.NewSession.previousRole.modifiers == [.control], "new session previous role should require control")
        expect(Keymap.NewSession.nextRole.keyCodes == [30], "new session next role key mismatch")
        expect(Keymap.NewSession.nextRole.modifiers == [.control], "new session next role should require control")
        expect(Keymap.NewSession.selectLeftCharacter.keys == ["h"], "new session h select-left mismatch")
        expect(Keymap.NewSession.selectRightCharacter.keys == ["l"], "new session l select-right mismatch")
        expect(Keymap.NewSession.nextFieldOption.keyCodes == [40], "new session option-k field mismatch")
    }

    private static func unifiedDeleteBindingsUseD() {
        expect(Keymap.List.delete.keys == ["d"], "tracker delete key mismatch")
        expect(!Keymap.List.delete.matches("x"), "x should not delete list items")
        expect(Keymap.Viewer.commentDelete.keys == ["d"], "viewer comment delete key mismatch")
        expect(Keymap.Viewer.gateToggle.keys.contains("x"), "viewer gate toggle should keep x")
    }

    private static func regionToggleCommandsUseRedesignChords() {
        expect(Keymap.Command.toggleTracker.keyEquivalent == "1", "toggle tracker key was \(Keymap.Command.toggleTracker.keyEquivalent)")
        expect(Keymap.Command.toggleDock.keyEquivalent == "3", "toggle dock key was \(Keymap.Command.toggleDock.keyEquivalent)")
        expect(commandBindings.contains(Keymap.Command.toggleTracker), "toggle tracker binding missing from command list")
        expect(!commandBindings.contains { $0.keyEquivalent == "j" && $0.modifiers == [.command] }, "alternate dock binding should be retired")
        expect(Keymap.Command.focusRegionLeft.modifiers == [.command, .control], "focus left should be control-command")
        expect(Keymap.Command.focusRegionRight.modifiers == [.command, .control], "focus right should be control-command")
        expect(commandBindings.contains(Keymap.Command.focusRegionLeft), "focus left binding missing from command list")
        expect(commandBindings.contains(Keymap.Command.focusRegionRight), "focus right binding missing from command list")
        expect(!commandBindings.contains { $0.keyEquivalent == "t" }, "legacy tracker rail binding should be retired")
    }

    private static func controlHandoffMapsListControlDirections() {
        expect(Keymap.ControlHandoff.direction(forKeyCode: 4) == .left, "plain ctrl-h should become list-left handoff")
        expect(Keymap.ControlHandoff.direction(forKeyCode: 37) == .right, "plain ctrl-l should become list-right handoff")
        expect(Keymap.ControlHandoff.direction(forKeyCode: 38) == .down, "plain ctrl-j should stay list down")
        expect(Keymap.ControlHandoff.direction(forKeyCode: 40) == .up, "plain ctrl-k should stay list up")
    }

    private static var commandBindings: [Keymap.CommandBinding] {
        [
            Keymap.Command.quitQuestmaster,
            Keymap.Command.newSession,
            Keymap.Command.newMasterSession,
            Keymap.Command.toggleTracker,
            Keymap.Command.focusTerminal,
            Keymap.Command.toggleDock,
            Keymap.Command.focusRegionLeft,
            Keymap.Command.focusRegionRight,
            Keymap.Command.copy,
            Keymap.Command.paste,
            Keymap.Command.selectAll,
        ]
    }

    private static func chordDescription(_ binding: Keymap.CommandBinding) -> String {
        (binding.modifiers.map(\.rawValue) + [binding.keyEquivalent]).joined(separator: "+")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("KeymapTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
