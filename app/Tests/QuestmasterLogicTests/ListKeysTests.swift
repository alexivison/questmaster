import Foundation
import QuestmasterCore

/// The shared list keys (`ListKeyResolver`) against each surface's capabilities: the tracker, the artifact list, Version
/// Control, the Quest Log, the Worker Log's dropdown and feed, and the read surfaces (the artifact viewer takes no list keys).
struct ListKeysTests {
    static func run() {
        sharedMovesAndTheirAliases()
        ggAndGArePerSurface()
        returnOpensOnlyWhereTheListOpens()
        leftAndRightNeverOpenOrMove()
        tabsAreBracketsWhereTheSurfaceHasThem()
        surfaceSpecificKeysAreGivenOnlyToTheirSurfaces()
        scrollKeysAreTheSameOnEveryReadSurface()
        gPrefixExpiresAndIsCancelledByAnotherKey()
        navigationChordMovesTheList()
        print("ListKeysTests: all tests passed")
    }

    private static func press(_ character: String?, _ modifiers: Set<Keymap.Modifier> = [], keyCode: UInt16 = 0) -> Keymap.KeyPress {
        Keymap.KeyPress(keyCode: keyCode, character: character, modifiers: modifiers)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("ListKeysTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }

    /// What a press asks on a fresh resolver, so no `gg` is pending.
    private static func command(_ press: Keymap.KeyPress, _ capabilities: ListCapabilities) -> ListCommand? {
        var keys = ListKeyResolver()
        return keys.command(for: press, in: capabilities)
    }

    private static let lists: [(name: String, capabilities: ListCapabilities)] = [
        ("tracker", .tracker),
        ("artifacts", .artifacts),
        ("version control", .versionControl),
        ("quest log", .questLog),
    ]

    private static func sharedMovesAndTheirAliases() {
        for list in lists {
            expect(command(press(nil, keyCode: 125), list.capabilities) == .move(1), "↓ should move down in the \(list.name)")
            expect(command(press(nil, keyCode: 126), list.capabilities) == .move(-1), "↑ should move up in the \(list.name)")
            expect(command(press("j", keyCode: 38), list.capabilities) == .move(1), "j should move down in the \(list.name)")
            expect(command(press("k", keyCode: 40), list.capabilities) == .move(-1), "k should move up in the \(list.name)")
            expect(command(press("j", [.control], keyCode: 38), list.capabilities) == .move(1), "⌃j should move down in the \(list.name)")
            expect(command(press("k", [.control], keyCode: 40), list.capabilities) == .move(-1), "⌃k should move up in the \(list.name)")
            expect(command(press("j", [.command], keyCode: 38), list.capabilities) == nil, "⌘j is no list key in the \(list.name)")
            expect(command(press("h", [.control], keyCode: 4), list.capabilities) == nil, "⌃h hands focus over, it is no list key in the \(list.name)")
            expect(command(press("l", [.control], keyCode: 37), list.capabilities) == nil, "⌃l hands focus over, it is no list key in the \(list.name)")
        }
        expect(command(press(nil, keyCode: 125), .tracker) == .move(1), "the tracker takes the arrows")
        expect(command(press("y", keyCode: 16), .tracker) == .copy, "y should copy in the tracker")
        expect(command(press("y", keyCode: 16), .versionControl) == .copy, "y should copy in Version Control")
        expect(command(press("y", keyCode: 16), .artifacts) == .copy, "y should copy in the artifact list")
        expect(command(press("y", keyCode: 16), .questLog) == .copy, "y should copy in the Quest Log")
        expect(command(press("x", keyCode: 7), .tracker) == nil, "x is unbound in the tracker")
        expect(command(press("j", [.option], keyCode: 38), .tracker) == nil, "⌥j is not j")
    }

    private static func ggAndGArePerSurface() {
        for list in lists {
            expect(command(press("G", [.shift], keyCode: 5), list.capabilities) == .jumpToBottom, "G should jump to the last row in the \(list.name)")
            expect(command(press("g", keyCode: 5), list.capabilities) == .jumpToTopPrefix, "one g should only arm gg in the \(list.name)")
        }
        expect(command(press("G", [.shift], keyCode: 5), .questLog) == .jumpToBottom, "G jumps to the last quest")
    }

    private static func returnOpensOnlyWhereTheListOpens() {
        expect(command(press("\r", keyCode: 36), .tracker) == .open, "Return should open the tracker's selection")
        expect(command(press(nil, keyCode: 76), .tracker) == .open, "keypad Enter should open the tracker's selection")
        expect(command(press("\r", keyCode: 36), .artifacts) == .open, "Return should open the artifact")
        expect(command(press("\r", keyCode: 36), .versionControl) == .open, "Return should open the pull request")
        expect(command(press("\r", keyCode: 36), .questLog) == nil, "Return should do nothing in the Quest Log: e edits")
        expect(command(press(nil, keyCode: 76), .questLog) == nil, "keypad Enter should do nothing in the Quest Log")
        expect(command(press("\r", [.shift], keyCode: 36), .tracker) == nil, "shift-Return is no list key")
        expect(command(press("\r", keyCode: 36), .workerLogMenu) == .open, "Return ticks a row in the Worker Log's dropdown")
    }

    /// `l` never opens, and h, l, ← and → move nothing in a list: the tabs are `[` and `]`.
    private static func leftAndRightNeverOpenOrMove() {
        for list in lists {
            expect(command(press("l", keyCode: 37), list.capabilities) == nil, "l should not act in the \(list.name)")
            expect(command(press("h", keyCode: 4), list.capabilities) == nil, "h should not act in the \(list.name)")
            expect(command(press(nil, keyCode: 123), list.capabilities) == nil, "← should not act in the \(list.name)")
            expect(command(press(nil, keyCode: 124), list.capabilities) == nil, "→ should not act in the \(list.name)")
        }
    }

    private static func tabsAreBracketsWhereTheSurfaceHasThem() {
        expect(command(press("[", keyCode: 33), .artifacts) == .previousTab, "[ should step the artifact tabs back")
        expect(command(press("]", keyCode: 30), .artifacts) == .nextTab, "] should step the artifact tabs forward")
        expect(command(press("]", keyCode: 30), .workerLogFeed) == .nextTab, "] should step the Worker Log's tabs")
        expect(command(press("[", keyCode: 33), .workerLogMenu) == .previousTab, "[ should step the Worker Log's tabs with the dropdown open")
        expect(command(press("[", keyCode: 33), .tracker) == nil, "the tracker has no tabs, so [ does nothing")
        expect(command(press("]", keyCode: 30), .versionControl) == nil, "Version Control has no tabs")
        expect(command(press("]", keyCode: 30), .questLog) == nil, "the Quest Log has no tabs")
        expect(command(press("[", [.control], keyCode: 33), .artifacts) == nil, "⌃[ is Esc, not a tab")
    }

    private static func surfaceSpecificKeysAreGivenOnlyToTheirSurfaces() {
        expect(command(press("e", keyCode: 14), .tracker) == .edit, "e should edit the tracker's session")
        expect(command(press("e", keyCode: 14), .questLog) == .edit, "e should edit the Quest Log's quest")
        expect(command(press("e", keyCode: 14), .artifacts) == nil, "e does nothing in the artifact list")
        expect(command(press("e", keyCode: 14), .versionControl) == nil, "e does nothing in Version Control")

        expect(command(press("E", [.shift], keyCode: 14), .tracker) == .editRepo, "E should edit the tracker's repo")
        expect(command(press("E", [.shift], keyCode: 14), .questLog) == nil, "E is no Quest Log key")

        expect(command(press("d", keyCode: 2), .tracker) == .delete, "d should delete in the tracker")
        expect(command(press("d", keyCode: 2), .artifacts) == .delete, "d should delete an artifact")
        expect(command(press("d", keyCode: 2), .questLog) == .delete, "d should delete a quest")
        expect(command(press("d", keyCode: 2), .versionControl) == nil, "d does nothing in Version Control")
        expect(command(press("d", [.control], keyCode: 2), .artifacts) == .halfPage(1), "⌃d is half a page, not delete")

        expect(command(press(" ", keyCode: 49), .artifacts) == .toggleMark, "Space should mark an artifact")
        expect(command(press(" ", keyCode: 49), .questLog) == .toggleMark, "Space should mark a quest")
        expect(command(press(" ", keyCode: 49), .tracker) == nil, "Space does nothing in the tracker")
        expect(command(press(" ", keyCode: 49), .versionControl) == nil, "Space does nothing in Version Control")

        expect(command(press("/", keyCode: 44), .artifacts) == .focusFilter, "/ should focus the artifact filter")
        expect(command(press("/", keyCode: 44), .questLog) == .focusFilter, "/ should focus the Quest Log filter")
        expect(command(press("/", keyCode: 44), .tracker) == nil, "/ does nothing in the tracker")

        expect(command(press("r", keyCode: 15), .versionControl) == .refresh, "r should refresh Version Control")
        expect(command(press("r", keyCode: 15), .tracker) == nil, "r does nothing in the tracker")
        expect(command(press("r", keyCode: 15), .artifacts) == nil, "r does nothing in the artifact list")

        expect(command(press("c", keyCode: 8), .tracker) == .toggleWorkersCollapsed, "c should collapse the workers")
        expect(command(press("C", [.shift], keyCode: 8), .tracker) == .toggleAllWorkersCollapsed, "C should collapse every master's workers")
        expect(command(press("c", keyCode: 8), .questLog) == nil, "c does nothing in the Quest Log")

        expect(command(press("s", keyCode: 1), .questLog) == .start, "s should send the quest forth")
        expect(command(press("s", keyCode: 1), .tracker) == nil, "s does nothing in the tracker")

        expect(command(press(nil, keyCode: 53), .questLog) == .close, "Esc should close the Quest Log")
        expect(command(press("[", [.control], keyCode: 33), .questLog) == .close, "⌃[ should close the Quest Log")
        expect(command(press(nil, keyCode: 53), .artifacts) == nil, "Esc does nothing in the artifact list: the viewer's Esc goes back")
        expect(command(press(nil, keyCode: 53), .tracker) == nil, "Esc does nothing in the tracker")
        expect(command(press(nil, keyCode: 53), .workerLogMenu) == .close, "Esc should close the Worker Log's dropdown")
        expect(command(press(nil, keyCode: 53), .workerLogFeed) == nil, "Esc does nothing with the Worker Log's dropdown closed")
    }

    /// The viewer and the Worker Log's feed scroll alike: a line for j, k and the arrows, a page for PgUp, PgDn, ⌃b and ⌃f,
    /// half a page for ⌃u and ⌃d, and gg and G for the ends. ⌃j and ⌃k do not scroll.
    private static func scrollKeysAreTheSameOnEveryReadSurface() {
        for surface in [ListCapabilities.workerLogFeed, [], .questLog] {
            expect(command(press("j", keyCode: 38), surface) == .move(1), "j should scroll a line")
            expect(command(press("k", keyCode: 40), surface) == .move(-1), "k should scroll a line")
            expect(command(press(nil, keyCode: 125), surface) == .move(1), "↓ should scroll a line")
            expect(command(press(nil, keyCode: 116), surface) == .page(-1), "PageUp should scroll a page up")
            expect(command(press(nil, keyCode: 121), surface) == .page(1), "PageDown should scroll a page down")
            expect(command(press("b", [.control], keyCode: 11), surface) == .page(-1), "⌃b should scroll a page up")
            expect(command(press("f", [.control], keyCode: 3), surface) == .page(1), "⌃f should scroll a page down")
            expect(command(press("u", [.control], keyCode: 32), surface) == .halfPage(-1), "⌃u should scroll half a page up")
            expect(command(press("d", [.control], keyCode: 2), surface) == .halfPage(1), "⌃d should scroll half a page down")
            expect(command(press("G", [.shift], keyCode: 5), surface) == .jumpToBottom, "G should go to the bottom")
        }
        expect(command(press("j", [.control], keyCode: 38), .workerLogFeed) == nil, "⌃j does not scroll the Worker Log")
        expect(command(press("k", [.control], keyCode: 40), .workerLogMenu) == nil, "⌃k does not move the Worker Log's dropdown")
        expect(command(press("j", [.control], keyCode: 38), []) == nil, "⌃j does not scroll the viewer")
        expect(command(press("l", keyCode: 37), []) == nil, "l does nothing in the viewer")
        expect(command(press("[", keyCode: 33), []) == nil, "[ steps no tabs in the viewer")
    }

    /// `gg` takes two `g`s within the window; another key between them, or a long pause, cancels the first.
    private static func gPrefixExpiresAndIsCancelledByAnotherKey() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var keys = ListKeyResolver()
        let g = press("g", keyCode: 5)
        expect(keys.command(for: g, in: .tracker, now: start) == .jumpToTopPrefix, "one g should only arm gg")
        expect(keys.command(for: g, in: .tracker, now: start.addingTimeInterval(0.3)) == .jumpToTop, "two g's inside the window should jump to the top")
        expect(keys.command(for: g, in: .tracker, now: start.addingTimeInterval(0.4)) == .jumpToTopPrefix, "after a jump, g arms again")

        var interrupted = ListKeyResolver()
        expect(interrupted.command(for: g, in: .artifacts, now: start) == .jumpToTopPrefix, "one g arms gg")
        expect(interrupted.command(for: press("j", keyCode: 38), in: .artifacts, now: start) == .move(1), "j is the list's")
        expect(interrupted.command(for: g, in: .artifacts, now: start) == .jumpToTopPrefix, "a key between the g's cancels gg, so the next g only arms it")

        var expired = ListKeyResolver()
        expect(expired.command(for: g, in: .questLog, now: start) == .jumpToTopPrefix, "one g arms gg")
        expect(expired.command(for: g, in: .questLog, now: start.addingTimeInterval(5)) == .jumpToTopPrefix, "a g after the window only arms gg again")

        var reset = ListKeyResolver()
        _ = reset.command(for: g, in: .tracker, now: start)
        reset.reset()
        expect(reset.command(for: g, in: .tracker, now: start.addingTimeInterval(0.1)) == .jumpToTopPrefix, "reset cancels a pending g")

        var afterBottom = ListKeyResolver()
        _ = afterBottom.command(for: g, in: .tracker, now: start)
        expect(afterBottom.command(for: press("G", [.shift], keyCode: 5), in: .tracker, now: start) == .jumpToBottom, "G is not the second g")
        expect(afterBottom.command(for: g, in: .tracker, now: start) == .jumpToTopPrefix, "G cancels a pending g")

        var option = ListKeyResolver()
        _ = option.command(for: g, in: .tracker, now: start)
        expect(option.command(for: press("g", [.option], keyCode: 5), in: .tracker, now: start) == nil, "⌥g is no list key and cancels gg")
        expect(option.command(for: g, in: .tracker, now: start) == .jumpToTopPrefix, "a g after ⌥g only arms gg")
    }

    private static func navigationChordMovesTheList() {
        expect(ListCommand.navigation(for: .down) == .move(1), "⇧⌘J should move down like j")
        expect(ListCommand.navigation(for: .up) == .move(-1), "⇧⌘K should move up like k")
        expect(ListCommand.navigation(for: .left) == nil && ListCommand.navigation(for: .right) == nil, "⇧⌘H and ⇧⌘L have no list meaning")
    }
}
