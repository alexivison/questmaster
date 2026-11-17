import Foundation
import QuestmasterCore

struct InteractionLookTests {
    static func run() {
        rowsPickTheirLook()
        tabsFieldsTogglesAndBandsPickTheirLook()
        hoverNeverEqualsAnotherState()
        eachStateStepIsBrighterThanTheOneBelow()
        boldGoldAndBrassStayInTheirPlace()
        thePointerShowsTheHoverLookAndMovesNoCursor()
        aCursorThePointerMovedDoesNotScroll()
        aRegionHasTheKeysOnlyWithoutAModal()
        missingFilesAndMarksKeepTheirColours()
        rowsOnARaisedSurfaceStepUpFromItsFill()
        scoopedListItemsKeepHoverApartFromTheCursor()
        cardCursorsPointOutsideTheirCard()
        watcherCursorPointsOnlyWhileTheKeysAreThere()
        textTabsFollowThePillTabsAndLightUnderThePointer()
        print("InteractionLookTests: all tests passed")
    }

    /// The Watcher's cursor points while the panel has the keys and hides with them; a pointed row takes no hover outline,
    /// and a row that isn't the cursor keeps its hover look.
    private static func watcherCursorPointsOnlyWhileTheKeysAreThere() {
        let cursor = RowLook.pointedCursor(highlighted: true, areaFocused: true)
        expect(cursor.pointer == .textSelected && cursor.fill == .item, "the Watcher's focused cursor should point in selected text on its fill")
        expect(RowLook.pointedCursor(highlighted: true, areaFocused: false) == .rest, "the Watcher's pointer should hide with the keys")
        expect(RowLook.pointedCursor(highlighted: false, areaFocused: true) == .rest, "a row that isn't the Watcher's cursor should rest, with no pointer")
        expect(cursor.underPointer(true) == cursor, "a pointed row should take no hover outline")
        expect(RowLook.rest.underPointer(true).outline == .line, "a resting Watcher row should keep its hover outline")
    }

    /// The card cursor's pointer, and what keeps it: menus, the tracker and the projects list never draw one.
    private static func cardCursorsPointOutsideTheirCard() {
        let cursor = RowLook.cardPick(highlighted: true, areaFocused: true, marksInGutter: false)
        expect(cursor.pointer == .textSelected && cursor.text == .textSelected, "a focused card cursor should point in textSelected")
        expect(cursor.listItem(underPointer: false).outline == .line, "a pointed card cursor should drop its controlBorder outline for the resting border")
        expect(cursor.listItem(underPointer: true) == cursor.listItem(underPointer: false), "hover should leave a pointed card cursor alone")
        let unfocused = RowLook.cardPick(highlighted: true, areaFocused: false, marksInGutter: false)
        expect(unfocused.pointer == .textBody && unfocused.text == .textBody, "an unfocused card cursor's pointer should dim to body text")
        expect(RowLook.cardPick(highlighted: false, areaFocused: true, marksInGutter: false) == .rest, "a card that isn't the cursor should rest, with no pointer")
        let marks = RowLook.cardPick(highlighted: true, areaFocused: true, marksInGutter: true)
        expect(marks.pointer == nil && marks.listItem(underPointer: false).outline == .controlBorder, "while the delete marks take the gutter the cursor keeps its outline and no pointer")
        let selected = RowLook.cardLasting(selected: true)
        expect(selected.pointer == .textSelected && selected.bold, "a Quest Log selection should point and stay bold")
        expect(selected.listItem(underPointer: false).outline == .line, "a Quest Log selection should drop its controlBorder outline too")
        expect(RowLook.cardLasting(selected: false) == .rest, "an unselected Quest Log card should rest")
        expect(cursor.dimmed.pointer == cursor.dimmed.text && cursor.dimmed.text == cursor.meta, "an out-of-date card's pointer should dim with its text, to meta")
        expect(cursor.warned.pointer == .textSelected, "a missing file's card keeps its pointer")
        for menu in [RowLook.pick(highlighted: true, areaFocused: true), .pick(highlighted: true, areaFocused: false), .raisedPick(highlighted: true)] {
            expect(menu.pointer == nil, "a menu row should never draw the pointer")
        }
        expect(RowLook.cursor(highlighted: true, areaFocused: true).pointer == nil, "the tracker's cursor should never draw the pointer")
        expect(RowLook.projectCursor.pointer == nil, "the projects cursor should keep its own outline and no pointer")
    }

    private static func rowsPickTheirLook() {
        expect(RowLook.pick(highlighted: false, areaFocused: true) == .rest, "an unhighlighted pick row should rest")
        expect(RowLook.pick(highlighted: false, areaFocused: false) == .rest, "an unhighlighted pick row should rest unfocused too")
        expect(RowLook.pick(highlighted: true, areaFocused: true) == .highlighted, "the highlight in a focused area should be full strength")
        expect(RowLook.pick(highlighted: true, areaFocused: false) == .highlightedUnfocused, "the highlight in an unfocused area should dim, not hide")
        expect(RowLook.lasting(selected: true) == .selected, "a lasting selection should look selected")
        expect(RowLook.lasting(selected: false) == .rest, "an unselected lasting row should rest")
    }

    private static func scoopedListItemsKeepHoverApartFromTheCursor() {
        let rest = RowLook.rest.listItem(underPointer: false)
        let hover = RowLook.rest.listItem(underPointer: true)
        expect(rest.fill == .item && rest.outline == .line, "a list card should keep its fill and border at rest")
        expect(hover.fill == rest.fill && hover.outline == .controlBorder, "hover should lift only the card's border")
        expect(hover.text == rest.text && hover.icon == rest.icon && hover.meta == rest.meta && !hover.bold, "hover should leave text, icons and weight alone")
        for look in [RowLook.highlighted, .highlightedUnfocused, .selected, .projectCursor] {
            expect(look.listItem(underPointer: true) == look.listItem(underPointer: false), "hover should leave a card's cursor or selection alone")
            expect(look.listItem(underPointer: false) != hover, "hover should remain distinct from a card's cursor or selection")
        }
        expect(RowLook.selected.listItem(underPointer: false).bold, "a lasting selection should stay bold")
        expect(RowLook.rest.missingFile.listItem(underPointer: true).icon == .warn, "hover should keep a missing artifact's warning")
    }

    private static func tabsFieldsTogglesAndBandsPickTheirLook() {
        expect(OutlineLook.tab(selected: false, areaFocused: true) == .tabRest, "a plain tab should rest")
        expect(OutlineLook.tab(selected: true, areaFocused: true) == .tabSelected, "a selected tab in a focused row")
        expect(OutlineLook.tab(selected: true, areaFocused: false) == .tabSelectedUnfocused, "a selected tab in an unfocused row dims")
        expect(OutlineLook.field(focused: false) == .fieldRest, "a field at rest")
        expect(OutlineLook.field(focused: true) == .fieldFocused, "a focused field")
        expect(OutlineLook.frame(focused: false) == .frameRest && OutlineLook.frame(focused: true) == .frameFocused, "a dock frame lifts with focus")
        expect(OutlineLook.tabSelected.recessed && OutlineLook.tabSelectedUnfocused.recessed, "a selected tab's disc is recessed")
        expect(!OutlineLook.tabRest.recessed, "a resting tab's disc is not recessed")
        let button = { (active: Bool, on: Bool, hovered: Bool) in ActionBarButtonLook.of(active: active, on: on, hovered: hovered) }
        let recessed = button(false, false, false), raised = button(true, false, false), on = button(false, true, false)
        expect(recessed.fill == .well && recessed.border == .lineSoftSubtle && recessed.icon == .textMeta && !recessed.filled, "a resting action-bar button is a recessed well with a soft border and a meta line glyph")
        expect(raised.fill == .item && raised.border == .line && raised.icon == .textSelected && raised.filled, "an active action-bar button (its panel shows) is raised, with the filled glyph in selected text")
        expect(button(false, false, true).icon == .textSelected && button(false, false, true).border == .line && button(false, false, true).fill == .well, "the pointer lights a recessed button's icon and lifts its border one step")
        expect(button(true, false, true).border == .controlBorder && button(true, false, true).icon == .textSelected && button(true, false, true).fill == .item, "the pointer lifts a raised button's border one step and keeps its fill and icon")
        expect(on.fill == .item && on.border == .line && on.icon == .accent && on.filled, "a toggle that is on is raised, with the one gold icon")
        expect(button(true, true, false).icon == .accent, "an on toggle keeps its gold icon while its panel shows")
        expect([recessed, button(false, false, true), raised, button(true, false, true)].allSatisfy { $0.icon != .accent }, "the gold icon is for an on toggle only, never active or under the pointer")
        expect(on.on.spins && on.on.glowOpacity > 0, "a toggle that is on glows and spins")
        expect(OnLook.of(true) == .on && OnLook.of(false) == .off, "a refresh or a toggle that is on takes the on look")
        expect(PlateBand.color(showsCursor: false, pointerOver: false, recoloring: false) == nil, "a plain plate has no band")
        expect(PlateBand.color(showsCursor: true, pointerOver: true, recoloring: true) == .accent, "the recolour band wins over the cursor and hover")
        expect(PlateBand.showsCursor(highlighted: true, areaFocused: true), "the cursor shows while the tracker has keys")
        expect(!PlateBand.showsCursor(highlighted: true, areaFocused: false), "the cursor hides when the tracker loses them")
        expect(PlateBand.color(showsCursor: false, pointerOver: true, recoloring: false) == .controlBorder, "the plate under the pointer shows the hover band")
        expect(PlateBand.color(showsCursor: true, pointerOver: true, recoloring: false) == .textSelected, "the cursor's band wins over hover")
        expect(RowLook.cursor(highlighted: true, areaFocused: true) == .highlighted, "a pure cursor row shows the highlight while its area has the keys")
        expect(RowLook.cursor(highlighted: true, areaFocused: false) == .rest, "and hides it (no unfocused look) when they leave")
        expect(RowLook.cursor(highlighted: false, areaFocused: true) == .rest && RowLook.cursor(highlighted: false, areaFocused: false) == .rest, "a row that isn't the cursor rests")
    }

    /// The hover look reads apart from rest, from the cursor and highlight (focused or not) and from a lasting
    /// selection; the plate's hover band apart from the cursor's and the recolour hint's.
    private static func hoverNeverEqualsAnotherState() {
        // Not by the icon, which some rows lack: by the outline against rest, and by the fill against every lit look.
        expect(RowLook.hovered.outline == .line && RowLook.rest.outline == nil, "hover adds an outline to the resting row")
        for lit in [RowLook.highlighted, .highlightedUnfocused, .selected] {
            expect(lit.fill == .item && lit.outline == nil, "\(lit) should be filled, without the hover outline")
            expect(RowLook.hovered.fill == nil, "a hovered row should have no fill, unlike \(lit)")
        }
        // A shell's cursor is an outline too, so it reads apart from the hover's by the outline's colour, a step brighter; the
        // viewed shell under it is the only look with both.
        expect(RowLook.shellCursor.outline == .controlBorder && RowLook.shellCursor.outline != RowLook.hovered.outline, "the shell cursor's outline differs from the hover's")
        expect(RowLook.shellCursor.fill == nil && RowLook.shellSelectedCursor.fill == .item && RowLook.shellSelectedCursor.outline == .controlBorder, "only the viewed shell under the cursor is filled and outlined")
        let bands = [
            PlateBand.color(showsCursor: true, pointerOver: false, recoloring: false),
            PlateBand.color(showsCursor: false, pointerOver: true, recoloring: false),
            PlateBand.color(showsCursor: false, pointerOver: false, recoloring: true),
            PlateBand.color(showsCursor: false, pointerOver: false, recoloring: false),
        ]
        expect(Set(bands.map { $0?.rawValue ?? 0 }).count == bands.count, "every plate band state should differ: \(bands)")
        expect(OutlineLook.fieldFocused != .fieldRest, "a focused field should not look at rest")
        expect(OutlineLook.frameFocused != .frameRest, "a focused dock frame should not look at rest")
        expect(ActionBarButtonLook.of(active: false, on: true, hovered: false) != .of(active: false, on: false, hovered: false), "an on toggle should not look off")
        // The pointer lights a recessed button, and lifts a raised one's border; neither may read as the other's active look.
        let recessedHovered = ActionBarButtonLook.of(active: false, on: false, hovered: true)
        let raisedRest = ActionBarButtonLook.of(active: true, on: false, hovered: false)
        expect(recessedHovered.fill != raisedRest.fill && recessedHovered.filled != raisedRest.filled, "a recessed button under the pointer should not look active")
        expect(ActionBarButtonLook.of(active: true, on: false, hovered: true) != raisedRest, "a raised button under the pointer should differ from its rest")
    }

    private static func eachStateStepIsBrighterThanTheOneBelow() {
        expectBrighter([RowLook.rest, .highlightedUnfocused, .highlighted].map(levels), "pick rows")
        expectBrighter([RowLook.rest, .selected].map(levels), "lasting rows")
        expectBrighter([RowLook.shellRest, .shellCursor, .shellSelectedCursor].map(levels), "shell rows: rest, the cursor, the viewed shell under it")
        expectBrighter([RowLook.shellRest, .selected, .shellSelectedCursor].map(levels), "shell rows: rest, the viewed shell, the viewed shell under the cursor")
        expectBrighter([OutlineLook.tabRest, .tabSelectedUnfocused, .tabSelected].map(levels), "tabs")
        expectBrighter([OutlineLook.fieldRest, .fieldFocused].map(levels), "fields")
        expectBrighter([OutlineLook.frameRest, .frameFocused].map(levels), "dock frames")
        let button = { (active: Bool, hovered: Bool) in ActionBarButtonLook.of(active: active, on: false, hovered: hovered) }
        expectBrighter([button(false, false), button(true, false)].map { [$0.fill.luminance] }, "action-bar fills: the recessed well, then the raised tile")
        expectBrighter([button(false, false), button(false, true)].map { [$0.border.luminance] }, "action-bar borders: recessed rest, then under the pointer")
        expectBrighter([button(true, false), button(true, true)].map { [$0.border.luminance] }, "action-bar borders: raised rest, then under the pointer")
        expectBrighter([button(false, false), button(false, true)].map { [$0.icon.luminance] }, "action-bar icons: recessed rest, then under the pointer")
        expectBrighter([button(false, false), button(true, false)].map { [$0.icon.luminance] }, "action-bar icons: recessed rest, then active")
        let band = { (cursor: Bool, pointer: Bool) in PlateBand.color(showsCursor: cursor, pointerOver: pointer, recoloring: false)?.luminance ?? 0 }
        expectBrighter([[0], [band(false, true)], [band(true, false)]], "plate bands: none, hover, cursor")
        expectBrighter([StateColor.textMeta, .textMetaHighlighted, .textBody, .textSelected].map { [$0.luminance] }, "text steps")
    }

    /// Bold means selected, so only a lasting selection is bold. Gold marks the recolour band only; brass means a
    /// toggle is on and nothing else.
    private static func boldGoldAndBrassStayInTheirPlace() {
        let rows = [RowLook.rest, .hovered, .highlighted, .highlightedUnfocused, .selected, .shellRest, .shellCursor, .shellSelectedCursor]
        expect(rows.filter(\.bold) == [.selected, .shellSelectedCursor], "only a lasting selection (the viewed shell, under the cursor or not) should be bold")
        let rowColors = rows.flatMap { [$0.fill, $0.outline, $0.text, $0.meta, $0.icon, $0.iconBorder].compactMap { $0 } }
        let outlineColors = [OutlineLook.tabRest, .tabSelected, .tabSelectedUnfocused, .fieldRest, .fieldFocused, .frameRest, .frameFocused].flatMap { [$0.border, $0.label] }
        for color in rowColors + outlineColors {
            expect(color != .accent && color != .brassActive, "rows, tabs and fields carry no gold or brass, got \(color)")
        }
        let off = ActionBarButtonLook.of(active: true, on: false, hovered: true)
        expect(off.on.glowOpacity == 0 && !off.on.spins, "an off toggle carries no brass and no spinner")
    }

    /// The pointer only shows the hover look on a resting row; a highlighted or selected row keeps its look.
    private static func thePointerShowsTheHoverLookAndMovesNoCursor() {
        expect(RowLook.rest.underPointer(true) == .hovered, "a resting row under the pointer shows the hover look")
        expect(RowLook.rest.underPointer(false) == .rest, "a resting row away from the pointer rests")
        for look in [RowLook.highlighted, .highlightedUnfocused, .selected, .shellCursor, .shellSelectedCursor] {
            expect(look.underPointer(true) == look, "the pointer should leave \(look) as it is")
        }
        expect(RowLook.hovered.fill == nil && RowLook.hovered.outline == .line && !RowLook.hovered.bold, "the hover look is a line outline, no fill")
        expect(RowLook.hovered.text == RowLook.rest.text && RowLook.hovered.meta == RowLook.rest.meta && RowLook.hovered.icon == RowLook.rest.icon,
               "the hover look keeps the resting text and icon")
    }

    /// The raised surface is `item`: a cursor filled with `item` would vanish on it, and a `line` hover outline barely
    /// shows. So the cursor steps up to `line`, and the hover outline to `controlBorder`, still an outline and never a fill.
    private static func rowsOnARaisedSurfaceStepUpFromItsFill() {
        expect(RowLook.raisedPick(highlighted: false) == .raisedRest && RowLook.raisedPick(highlighted: true) == .raisedHighlighted, "raised rows pick rest or the highlight")
        expect(RowLook.raisedHighlighted.fill == .line && RowLook.raisedHighlighted.fill != .item, "the raised cursor is filled one step above the surface")
        expectBrighter([[StateColor.item.luminance], [RowLook.raisedHighlighted.fill?.luminance ?? 0]], "raised surface, then its cursor")
        expect(RowLook.raisedRest.fill == nil && RowLook.raisedRest.outline == nil, "a raised row at rest shows the surface")
        expect(RowLook.raisedRest.underPointer(true).outline == .controlBorder && RowLook.raisedRest.underPointer(true).fill == nil, "a raised row under the pointer is outlined in controlBorder, unfilled")
        expect(RowLook.raisedRest.underPointer(true).outline != RowLook.raisedHighlighted.fill, "the hover outline and the cursor fill differ")
        expectBrighter([[StateColor.item.luminance], [StateColor.controlBorder.luminance]], "raised surface, then the hover outline")
        expect(RowLook.raisedHighlighted.underPointer(true) == .raisedHighlighted, "the pointer leaves the raised cursor as it is")
        expect(RowLook.raisedRest.text == RowLook.rest.text && RowLook.raisedHighlighted.text == RowLook.highlighted.text, "raised rows keep the text steps")
        expect(!RowLook.raisedRest.bold && !RowLook.raisedHighlighted.bold, "raised rows are never bold")
        expect(RowLook.rest.hoverOutline == .line && RowLook.hovered.outline == .line, "the other rows keep the line hover outline")
        expect(RowLook.raisedRest.missingFile.underPointer(true).outline == .controlBorder, "a look's hover outline survives the missing-file variant")
    }

    /// The Worker Log's text tabs: meta text at rest, body text under the pointer, and the selected tab bold in a selected pill
    /// tab's label colour, which dims while the panel has no keys. The pointer adds nothing to the selected tab.
    private static func textTabsFollowThePillTabsAndLightUnderThePointer() {
        let rest = TextTabLook.tab(selected: false, areaFocused: true, underPointer: false)
        let hovered = TextTabLook.tab(selected: false, areaFocused: true, underPointer: true)
        let selected = TextTabLook.tab(selected: true, areaFocused: true, underPointer: false)
        let unfocused = TextTabLook.tab(selected: true, areaFocused: false, underPointer: false)
        expect(rest == .rest && rest.label == .textMeta && !rest.bold, "an unselected tab is regular meta text")
        expect(hovered == .hovered && hovered.label == .textBody && !hovered.bold, "the pointer lights an unselected tab to body text, still regular")
        expect(TextTabLook.tab(selected: false, areaFocused: false, underPointer: false) == rest, "an unselected tab looks the same in an unfocused panel")
        expect(selected.bold && selected.label == OutlineLook.tabSelected.label, "the selected tab is bold in a selected pill tab's label colour")
        expect(unfocused.bold && unfocused.label == OutlineLook.tabSelectedUnfocused.label, "and one step dimmer without the keys")
        expect(TextTabLook.tab(selected: true, areaFocused: true, underPointer: true) == selected, "the pointer adds nothing to the selected tab")
        expect(TextTabLook.tab(selected: true, areaFocused: false, underPointer: true) == unfocused, "nor to the unfocused selected tab")
        expectBrighter([rest, hovered, selected].map { [$0.label.luminance] }, "text tabs: rest, under the pointer, selected")
        expect(unfocused.label == hovered.label && unfocused.bold != hovered.bold, "the unfocused selected tab differs from a hovered one by its weight")
        for look in [rest, hovered, selected, unfocused] {
            expect(look.label != .accent && look.label != .brassActive, "tabs carry no gold or brass")
        }
    }

    private static func missingFilesAndMarksKeepTheirColours() {
        for look in [RowLook.rest, .highlighted, .highlightedUnfocused] {
            expect(look.missingFile.icon == .warn, "a missing file's icon should warn in every state")
            expect(look.missingFile.text == look.text && look.missingFile.fill == look.fill, "only the icon should change for a missing file")
        }
        let hoveredMissing = RowLook.rest.missingFile.underPointer(true)
        expect(hoveredMissing.fill == nil && hoveredMissing.outline == RowLook.hovered.outline && !hoveredMissing.bold,
               "a missing file's resting row under the pointer shows the hover outline")
        expect(hoveredMissing.icon == .warn, "and keeps its warning icon")
        for look in [RowLook.rest, .highlighted, .highlightedUnfocused] {
            expect(look.dimmed.text == look.meta && look.dimmed.icon == look.meta && look.dimmed.meta == look.meta, "a dimmed row's text and icon drop to the meta step")
            expect(look.dimmed.fill == look.fill && look.dimmed.iconBorder == look.iconBorder && !look.dimmed.bold, "dimming leaves the fill and border alone")
            expect(look.dimmed.warned.icon == .warn && look.dimmed.warned.text == look.meta, "a dimmed row can still warn")
        }
        expect(MarkLook.color(marked: true) == .accent, "a mark is the one gold")
        expect(MarkLook.color(marked: false) != .accent, "an unmarked row carries no gold")
    }

    /// Mouse movement doesn't stop the keys scrolling: only the change the pointer itself made is skipped, once, and it
    /// drops a key scroll still queued (j, then the pointer onto a plate within the debounce: the queued scroll would
    /// slide that plate out from under the pointer).
    private static func aCursorThePointerMovedDoesNotScroll() {
        var cursor = PointerCursor()
        expect(cursor.scrollStep(to: "b") == .scroll, "after mouse movement alone, j to the row below the edge should scroll")
        cursor.pointerMoved(to: "a")
        expect(cursor.scrollStep(to: "a") == .cancelQueued, "the cursor the pointer moved is under it already, and a queued key scroll drops")
        expect(cursor.scrollStep(to: "a") == .scroll, "a later key move back to that row scrolls")
        cursor.pointerMoved(to: "a")
        expect(cursor.scrollStep(to: "b") == .scroll, "a key move to another row scrolls even right after the pointer moved")
    }

    /// A region's focus looks follow whether it has the keys: focused, and no modal drawn.
    private static func aRegionHasTheKeysOnlyWithoutAModal() {
        let navigation = NavigationStore(state: AppNavigationState(focusedRegion: .tracker))
        expect(navigation.hasKeys(.tracker) && !navigation.hasKeys(.dock), "the focused region has the keys")
        navigation.setModalDrawn(true)
        expect(!navigation.hasKeys(.tracker), "under a modal no region has the keys")
        navigation.setModalDrawn(false)
        expect(navigation.hasKeys(.tracker), "the keys come back with the modal gone")
    }

    /// A look's colours as luminances, in a fixed order; no fill or outline counts as 0, below any.
    private static func levels(_ look: RowLook) -> [Double] {
        [look.fill?.luminance ?? 0, look.outline?.luminance ?? 0, look.text.luminance, look.meta.luminance, look.icon.luminance, look.iconBorder.luminance]
    }

    private static func levels(_ look: OutlineLook) -> [Double] {
        [look.border.luminance, look.label.luminance]
    }

    /// Each step is at least as bright as the one below in every part, and brighter in one.
    private static func expectBrighter(_ steps: [[Double]], _ name: String) {
        for (lower, upper) in zip(steps, steps.dropFirst()) {
            let noneDarker = zip(lower, upper).allSatisfy { $0 <= $1 }
            let someBrighter = zip(lower, upper).contains { $0 < $1 }
            expect(noneDarker && someBrighter, "\(name): \(upper) should be one step brighter than \(lower)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
