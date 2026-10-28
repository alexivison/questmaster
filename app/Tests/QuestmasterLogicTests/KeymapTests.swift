import Foundation
import QuestmasterCore

struct KeymapTests {
    static func run() {
        commandChordsAreUnique()
        editModalCommandsFollowDeleteShortcutPattern()
        regionToggleCommandsUseRedesignChords()
        trackerSessionSelectBindingsUsePlainCommandDigits()
        displayGlyphOrdersModifiersAndUppercasesTheKey()
        chordMatchesTheKeyAndTheExactModifiers()
        everyActionHasChords()
        shiftIsPartOfThePrintableCharacter()
        listKeysAreArrowsAndLetters()
        openAndEditUseReturnAndLetters()
        submitTakesPlainReturnAndCommandReturn()
        controlBracketIsEscape()
        tabAndBackTabAreDistinct()
        fieldKeysUseControlAndOption()
        pickerKeysUseArrowsAndControlPN()
        navigationChordMatchesOnlyShiftCommandHJKL()
        navigationChordRepeatsAreConsumedWithoutDispatch()
        controlHandoffMapsListControlDirections()
        gPrefixTrackerResolvesDoubleGWithinWindowAndExpiresAfter()
        gPrefixTrackerResetClearsPendingState()
        print("KeymapTests: all tests passed")
    }

    private static func press(_ character: String?, _ modifiers: Set<Keymap.Modifier> = [], keyCode: UInt16 = 0) -> Keymap.KeyPress {
        Keymap.KeyPress(keyCode: keyCode, character: character, modifiers: modifiers)
    }

    private static func matches(_ press: Keymap.KeyPress, _ action: Keymap.Action) -> Bool {
        Keymap.matches(press, action)
    }

    private static func chordMatchesTheKeyAndTheExactModifiers() {
        expect(matches(press("j"), .moveDown), "plain j should move down")
        expect(!matches(press("j", [.control]), .moveDown), "⌃j must not be plain j")
        expect(!matches(press("j", [.command]), .moveDown), "⌘j must not be plain j")
        expect(!matches(press("j", [.option]), .moveDown), "⌥j must not be plain j")
        expect(!matches(press("j", [.control, .option]), .moveDown), "⌃⌥j must not be plain j")
        expect(matches(press("j", [.control]), .nextField), "⌃j should move to the next field")
        expect(!matches(press("j"), .nextField), "plain j must not move to the next field")
        expect(matches(press(nil, [.option], keyCode: 40), .nextField), "⌥k should move to the next field by key code, since it types ˚")
        expect(!matches(press("k"), .nextField), "plain k must not move to the next field")
        expect(!matches(press("˚", keyCode: 40), .nextField), "⌥k without its modifier must not match")
    }

    private static func everyActionHasChords() {
        let empty = Keymap.Action.allCases.filter { Keymap.chords(for: $0).isEmpty }
        expect(empty.isEmpty, "actions without chords: \(empty)")
    }

    private static func shiftIsPartOfThePrintableCharacter() {
        expect(matches(press("G", [.shift]), .jumpToBottom), "shift-g should jump to bottom")
        expect(!matches(press("G", [.shift]), .jumpToTop), "shift-g must not arm the gg chord")
        expect(matches(press("g"), .jumpToTop), "g should arm the gg chord")
        expect(!matches(press("E", [.shift]), .editSession), "shift-e must not edit the session")
        expect(matches(press("E", [.shift]), .editRepo), "shift-e should edit the repo")
        expect(matches(press("C", [.shift]), .toggleAllWorkersCollapsed), "shift-c should collapse every worker")
        expect(!matches(press("K", [.shift]), .moveUp), "shift-k must not move the list up")
        expect(matches(press("H", [.command, .shift]), .focusLeft), "⇧⌘H should focus left")
        expect(!matches(press("h", [.command, .shift]), .focusLeft), "⇧⌘h is not the focus chord: the chord types H")
        expect(!matches(press("h", [.command]), .focusLeft), "⌘h must not focus left")
        expect(!matches(press("?", [.shift]), .focusFilter), "shift-/ types ? and is not the filter key")
        expect(matches(press("/"), .focusFilter), "/ should focus the filter")
    }

    private static func listKeysAreArrowsAndLetters() {
        expect(matches(press(nil, keyCode: 126), .moveUp), "up arrow should move up")
        expect(matches(press(nil, keyCode: 125), .moveDown), "down arrow should move down")
        expect(matches(press("k"), .moveUp), "k should move up")
        expect(!matches(press(nil, [.shift], keyCode: 126), .moveUp), "shift-up is not a list move")
        expect(!matches(press("h"), .moveUp), "h should not move the list up")
        expect(!matches(press("l"), .moveDown), "l should not move the list down")
        expect(matches(press(nil, keyCode: 123), .cycleLeft), "left arrow cycles left")
        expect(matches(press("h"), .cycleLeft), "h cycles left")
        expect(!matches(press("H"), .cycleLeft), "shift-h is not cycle-left")
        expect(matches(press(nil, keyCode: 124), .cycleRight), "right arrow cycles right")
        expect(matches(press("u", [.control]), .halfPageUp), "⌃u should page up by half")
        expect(!matches(press("u"), .halfPageUp), "plain u should not page up")
        expect(matches(press("d", [.control]), .halfPageDown), "⌃d should page down by half")
        expect(!matches(press("d", [.control]), .delete), "⌃d must not delete")
        expect(matches(press("d"), .delete), "plain d should delete")
        expect(!matches(press("x"), .delete), "x should not delete list items")
        expect(!matches(press("y", [.option]), .copy), "⌥y must not copy")
    }

    private static func openAndEditUseReturnAndLetters() {
        expect(matches(press("\r", keyCode: 36), .open), "Return should open the selection")
        expect(matches(press(nil, keyCode: 76), .open), "keypad Enter should open the selection")
        expect(matches(press("l"), .open), "l should open the selection in the tracker")
        expect(!matches(press(nil, keyCode: 124), .open), "right arrow should not open the selection")
        expect(!matches(press("\r", [.shift], keyCode: 36), .open), "shift-Return should not open the selection")
        expect(matches(press("e"), .editSession), "e should edit the session")
        expect(matches(press("e"), .editQuest), "e should edit a quest")
        expect(matches(press("\r", keyCode: 36), .editQuest), "Return should edit a quest, as the Quest Log always has")
        expect(!matches(press("\r", keyCode: 36), .editSession), "Return should not edit a session: it opens")
    }

    private static func submitTakesPlainReturnAndCommandReturn() {
        expect(matches(press("\r", keyCode: 36), .submit), "Return should submit")
        expect(matches(press(nil, keyCode: 76), .submit), "keypad Enter should submit")
        expect(matches(press("\r", [.command], keyCode: 36), .submit), "command-Return should submit")
        expect(!matches(press("\r", [.shift], keyCode: 36), .submit), "shift-Return is a newline, not submit")
        expect(!matches(press("\r", [.control], keyCode: 36), .submit), "control-Return should not submit")
        expect(!matches(press("\r", [.option], keyCode: 36), .submit), "option-Return should not submit")
        expect(matches(press("s", [.control]), .createFromPrompt), "⌃s should create from the prompt")
        expect(matches(press(nil, keyCode: 53), .cancel), "Esc should cancel")
        expect(!matches(press(nil, [.command], keyCode: 53), .cancel), "command-Esc is not cancel")
    }

    private static func controlBracketIsEscape() {
        expect(matches(press("[", [.control], keyCode: 33), .cancel), "⌃[ should cancel, as Esc does")
        expect(!matches(press("[", keyCode: 33), .cancel), "plain [ must not cancel")
        expect(matches(press("[", [.control], keyCode: 33), .back), "⌃[ should go back, as Esc does")
        expect(!matches(press("[", [.command, .control], keyCode: 33), .cancel), "⌘⌃[ is not cancel")
    }

    private static func tabAndBackTabAreDistinct() {
        expect(matches(press(nil, keyCode: 48), .tab), "Tab should be tab")
        expect(!matches(press(nil, keyCode: 48), .backTab), "Tab must not be back-tab")
        expect(matches(press(nil, [.shift], keyCode: 48), .backTab), "⇧Tab should be back-tab")
        expect(!matches(press(nil, [.shift], keyCode: 48), .tab), "⇧Tab must not be tab")
        expect(!matches(press(nil, [.control], keyCode: 48), .tab), "⌃Tab must not be tab")
    }

    private static func fieldKeysUseControlAndOption() {
        expect(matches(press("k", [.control]), .previousField), "⌃k should move to the previous field")
        expect(!matches(press("k"), .previousField), "plain k must not move to the previous field")
        expect(matches(press(nil, [.control], keyCode: 14), .cycleClass), "⌃e is the class key")
        expect(matches(press(nil, [.control], keyCode: 14), .cycleEffort), "⌃e cycles the effort")
        expect(matches(press("e"), .cycleEffort), "e cycles the effort in SELECT")
        expect(matches(press(nil, [.control], keyCode: 15), .refreshModels), "⌃r refreshes the models")
        expect(matches(press("r", [.control]), .recentPaths), "⌃r lists recent paths in the path field")
        expect(matches(press(nil, [.option], keyCode: 123), .optionCycleLeft), "⌥← cycles the colour back")
        expect(!matches(press(nil, keyCode: 123), .optionCycleLeft), "plain ← is not the option cycle")
        expect(matches(press(nil, keyCode: 51), .backspace), "Backspace should be backspace")
    }

    private static func pickerKeysUseArrowsAndControlPN() {
        expect(matches(press(nil, keyCode: 126), .suggestionUp), "↑ should highlight the row above")
        expect(matches(press(nil, keyCode: 125), .suggestionDown), "↓ should highlight the row below")
        expect(matches(press(nil, [.control], keyCode: 35), .suggestionPrevious), "⌃p should highlight the row above, by key code")
        expect(matches(press(nil, [.control], keyCode: 45), .suggestionNext), "⌃n should highlight the row below, by key code")
        expect(!matches(press("p"), .suggestionPrevious), "plain p must not highlight")
        expect(!matches(press(nil, [.control], keyCode: 35), .suggestionUp), "⌃p is not the arrow")
        expect(!matches(press(nil, keyCode: 126), .suggestionPrevious), "↑ is not ⌃p")
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

    private static func editModalCommandsFollowDeleteShortcutPattern() {
        expect(Keymap.Command.editFocusedSession.keyEquivalent == "e", "session edit command key mismatch")
        expect(Keymap.Command.editFocusedSession.modifiers == [.command], "session edit command should use command")
        expect(Keymap.Command.editFocusedRepo.keyEquivalent == "e", "repo edit command key mismatch")
        expect(Keymap.Command.editFocusedRepo.modifiers == [.command, .shift], "repo edit command should use command-shift")
    }

    private static func regionToggleCommandsUseRedesignChords() {
        expect(Keymap.Command.toggleTracker.keyEquivalent == "\\", "toggle tracker key was \(Keymap.Command.toggleTracker.keyEquivalent)")
        expect(Keymap.Command.newQuest.keyEquivalent == "t", "new quest key was \(Keymap.Command.newQuest.keyEquivalent)")
        expect(Keymap.Command.newTerminal.keyEquivalent == "s", "new terminal key was \(Keymap.Command.newTerminal.keyEquivalent)")
        expect(Keymap.Command.deleteFocusedSession.keyEquivalent == "d", "delete focused session key was \(Keymap.Command.deleteFocusedSession.keyEquivalent)")
        expect(Keymap.Command.deleteFocusedSession.modifiers == [.command, .shift], "delete focused session should be command-shift-d")
        expect(Keymap.Command.toggleDock.keyEquivalent == "a", "toggle dock key was \(Keymap.Command.toggleDock.keyEquivalent)")
        expect(Keymap.Command.toggleQuestLog.keyEquivalent == "t", "toggle quest log key was \(Keymap.Command.toggleQuestLog.keyEquivalent)")
        expect(Keymap.Command.widenDock.keyEquivalent == ".", "widen dock key was \(Keymap.Command.widenDock.keyEquivalent)")
        expect(Keymap.Command.narrowDock.keyEquivalent == ",", "narrow dock key was \(Keymap.Command.narrowDock.keyEquivalent)")
        expect(Keymap.Command.widenDock.modifiers == [.command, .shift], "widen dock should be command-shift-period, matching vim's Ctrl-w > convention")
        expect(Keymap.Command.narrowDock.modifiers == [.command, .shift], "narrow dock should be command-shift-comma, matching vim's Ctrl-w < convention")
        expect(Keymap.Command.toggleCaffeine.keyEquivalent == "c", "toggle caffeinate key was \(Keymap.Command.toggleCaffeine.keyEquivalent)")
        expect(Keymap.Command.toggleTracker.modifiers == [.command], "toggle tracker should be plain command-backslash, freeing Cmd+1 for session select")
        expect(Keymap.Command.focusTerminal.modifiers == [.command, .option], "focus terminal moved to command-option to free Cmd+2 for session select")
        expect(Keymap.Command.toggleDock.modifiers == [.command, .shift], "toggle dock should be command-shift-a, freeing Cmd+3 for session select")
        expect(Keymap.Command.toggleQuestLog.modifiers == [.command, .shift], "toggle quest log should be command-shift-t, freeing Cmd+4 for session select")
        expect(Keymap.Command.toggleWorkerChatDock.displayGlyph == "⇧⌘W", "toggle worker chat glyph was \(Keymap.Command.toggleWorkerChatDock.displayGlyph)")
        expect(Keymap.Command.toggleVersionControlDock.displayGlyph == "⇧⌘R", "toggle version control glyph was \(Keymap.Command.toggleVersionControlDock.displayGlyph), not command-shift-v, which Ghostty binds to paste_from_selection")
        expect(Keymap.Command.focusDockTop.displayGlyph == "⇧⌘K" && Keymap.Command.focusDockBottom.displayGlyph == "⇧⌘J", "the dock panel focus chords are shift-command K (up) and J (down), beside ⇧⌘H/L: all navigation shares the modifiers")
        expect(Keymap.Command.focusDockTop.modifiers == Keymap.Command.focusRegionLeft.modifiers && Keymap.Command.focusDockBottom.modifiers == Keymap.Command.focusRegionRight.modifiers, "the dock panel chords use the region chords' modifiers")
        expect(Keymap.Command.toggleCaffeine.modifiers == [.command, .shift], "toggle caffeinate should be command-shift, matching the other dock toggle chords")
        expect(Keymap.Command.copySessionID.keyEquivalent == "y", "copy session id key was \(Keymap.Command.copySessionID.keyEquivalent)")
        expect(Keymap.Command.copySessionID.modifiers == [.command], "copy session id should be command")
        expect(commandBindings.contains(Keymap.Command.newQuest), "new quest binding missing from command list")
        expect(commandBindings.contains(Keymap.Command.newTerminal), "new terminal binding missing from command list")
        expect(commandBindings.contains(Keymap.Command.deleteFocusedSession), "delete focused session binding missing from command list")
        expect(commandBindings.contains(Keymap.Command.toggleTracker), "toggle tracker binding missing from command list")
        expect(commandBindings.contains(Keymap.Command.toggleCaffeine), "toggle caffeinate binding missing from command list")
        expect(commandBindings.contains(Keymap.Command.copySessionID), "copy session id binding missing from command list")
        expect(!commandBindings.contains { $0.keyEquivalent == "j" && $0.modifiers == [.command] }, "alternate dock binding should be retired")
        expect(Keymap.Command.focusRegionLeft.modifiers == [.command, .shift], "focus left should be shift-command")
        expect(Keymap.Command.focusRegionRight.modifiers == [.command, .shift], "focus right should be shift-command")
        expect(commandBindings.contains(Keymap.Command.focusRegionLeft), "focus left binding missing from command list")
        expect(commandBindings.contains(Keymap.Command.focusRegionRight), "focus right binding missing from command list")
        expect(
            commandBindings.filter { $0.keyEquivalent == "t" && $0.modifiers == [.command] } == [Keymap.Command.newQuest],
            "Cmd-T should be reserved for New Quest"
        )
    }

    private static func trackerSessionSelectBindingsUsePlainCommandDigits() {
        expect(Keymap.Command.selectSession.count == 9, "expected nine session-select bindings, got \(Keymap.Command.selectSession.count)")
        for (index, binding) in Keymap.Command.selectSession.enumerated() {
            let digit = "\(index + 1)"
            expect(binding.keyEquivalent == digit, "session-select binding \(index) should be digit \(digit), was \(binding.keyEquivalent)")
            expect(binding.modifiers == [.command], "session-select binding for \(digit) should be plain command, was \(binding.modifiers)")
        }
        expect(commandBindings.contains(Keymap.Command.selectSession[0]), "session-select bindings missing from command list")
    }

    private static func displayGlyphOrdersModifiersAndUppercasesTheKey() {
        expect(Keymap.Command.toggleTracker.displayGlyph == "⌘\\", "toggle tracker glyph was \(Keymap.Command.toggleTracker.displayGlyph)")
        expect(Keymap.Command.toggleDock.displayGlyph == "⇧⌘A", "toggle dock glyph was \(Keymap.Command.toggleDock.displayGlyph)")
        expect(Keymap.Command.toggleQuestLog.displayGlyph == "⇧⌘T", "toggle quest log glyph was \(Keymap.Command.toggleQuestLog.displayGlyph)")
        expect(Keymap.Command.focusTerminal.displayGlyph == "⌥⌘2", "focus terminal glyph was \(Keymap.Command.focusTerminal.displayGlyph)")
        expect(Keymap.Command.toggleCaffeine.displayGlyph == "⇧⌘C", "toggle caffeinate glyph was \(Keymap.Command.toggleCaffeine.displayGlyph)")
        expect(Keymap.Command.deleteFocusedSession.displayGlyph == "⇧⌘D", "delete focused session glyph was \(Keymap.Command.deleteFocusedSession.displayGlyph)")
        expect(Keymap.Command.copySessionID.displayGlyph == "⌘Y", "copy session id glyph was \(Keymap.Command.copySessionID.displayGlyph)")
        expect(Keymap.Command.focusRegionLeft.displayGlyph == "⇧⌘H", "focus region left glyph was \(Keymap.Command.focusRegionLeft.displayGlyph)")
        expect(Keymap.Command.selectSession[0].displayGlyph == "⌘1", "session 1 glyph was \(Keymap.Command.selectSession[0].displayGlyph)")
        expect(Keymap.Command.selectSession[8].displayGlyph == "⌘9", "session 9 glyph was \(Keymap.Command.selectSession[8].displayGlyph)")
    }

    private static func navigationChordMatchesOnlyShiftCommandHJKL() {
        for (key, direction) in [("H", NavigationDirection.left), ("J", .down), ("K", .up), ("L", .right)] {
            expect(Keymap.NavigationChord.direction(for: press(key, [.command, .shift])) == direction, "⇧⌘\(key) direction mismatch")
        }
        expect(Keymap.NavigationChord.direction(for: press("j", [.command])) == nil, "⌘j without shift must not be a navigation chord")
        expect(Keymap.NavigationChord.direction(for: press("J", [.command, .shift, .option])) == nil, "⇧⌘⌥J must not be a navigation chord")
        expect(Keymap.NavigationChord.direction(for: press("X", [.command, .shift])) == nil, "⇧⌘X must not be a navigation chord")
    }

    private static func navigationChordRepeatsAreConsumedWithoutDispatch() {
        expect(Keymap.NavigationChord.route(for: press("J", [.command, .shift]), isRepeat: false) == .navigate(.down), "the initial ⇧⌘J should navigate down")
        expect(Keymap.NavigationChord.route(for: press("J", [.command, .shift]), isRepeat: true) == .consume, "a repeated ⇧⌘J should be consumed without navigating")
        expect(Keymap.NavigationChord.route(for: press("j", [.command]), isRepeat: true) == .passThrough, "a non-navigation repeat should pass through")
    }

    private static func controlHandoffMapsListControlDirections() {
        expect(Keymap.chords(for: .handoffLeft) == [.code(4, [.control])], "⌃h should hand focus left")
        expect(Keymap.chords(for: .handoffDown) == [.code(38, [.control])], "⌃j should hand focus down")
        expect(Keymap.chords(for: .handoffUp) == [.code(40, [.control])], "⌃k should hand focus up")
        expect(Keymap.chords(for: .handoffRight) == [.code(37, [.control])], "⌃l should hand focus right")
    }

    private static func gPrefixTrackerResolvesDoubleGWithinWindowAndExpiresAfter() {
        var tracker = GPrefixTracker()
        let start = Date()
        expect(tracker.handleG(now: start) == .pendingSecondG, "first g should arm the chord")
        expect(tracker.handleG(now: start.addingTimeInterval(0.2)) == .jumpToTop, "second g within the window should resolve to jumpToTop")

        expect(tracker.handleG(now: start.addingTimeInterval(1)) == .pendingSecondG, "g after a resolved chord should re-arm")
        expect(
            tracker.handleG(now: start.addingTimeInterval(1).addingTimeInterval(2)) == .pendingSecondG,
            "g after the window expires should re-arm instead of resolving"
        )
    }

    private static func gPrefixTrackerResetClearsPendingState() {
        var tracker = GPrefixTracker()
        let start = Date()
        expect(tracker.handleG(now: start) == .pendingSecondG, "first g should arm the chord")
        tracker.reset()
        expect(
            tracker.handleG(now: start.addingTimeInterval(0.1)) == .pendingSecondG,
            "g after a reset should re-arm rather than resolve, as a non-g key between presses would require"
        )
    }

    private static var commandBindings: [Keymap.CommandBinding] {
        [
            Keymap.Command.quitQuestmaster,
            Keymap.Command.newSession,
            Keymap.Command.newQuest,
            Keymap.Command.newTerminal,
            Keymap.Command.newMasterSession,
            Keymap.Command.editFocusedSession,
            Keymap.Command.editFocusedRepo,
            Keymap.Command.deleteFocusedSession,
            Keymap.Command.toggleTracker,
            Keymap.Command.focusTerminal,
            Keymap.Command.toggleDock,
            Keymap.Command.toggleQuestLog,
            Keymap.Command.toggleWorkerChatDock,
            Keymap.Command.toggleVersionControlDock,
            Keymap.Command.widenDock,
            Keymap.Command.narrowDock,
            Keymap.Command.toggleCaffeine,
            Keymap.Command.copySessionID,
            Keymap.Command.focusRegionLeft,
            Keymap.Command.focusRegionRight,
            Keymap.Command.focusDockTop,
            Keymap.Command.focusDockBottom,
            Keymap.Command.copy,
            Keymap.Command.paste,
            Keymap.Command.selectAll,
        ] + Keymap.Command.selectSession
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
