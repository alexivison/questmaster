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
        print("InteractionLookTests: all tests passed")
    }

    private static func rowsPickTheirLook() {
        expect(RowLook.pick(highlighted: false, areaFocused: true) == .rest, "an unhighlighted pick row should rest")
        expect(RowLook.pick(highlighted: false, areaFocused: false) == .rest, "an unhighlighted pick row should rest unfocused too")
        expect(RowLook.pick(highlighted: true, areaFocused: true) == .highlighted, "the highlight in a focused area should be full strength")
        expect(RowLook.pick(highlighted: true, areaFocused: false) == .highlightedUnfocused, "the highlight in an unfocused area should dim, not hide")
        expect(RowLook.lasting(selected: true) == .selected, "a lasting selection should look selected")
        expect(RowLook.lasting(selected: false) == .rest, "an unselected lasting row should rest")
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
        expect(ToggleLook.of(on: true) == .on && ToggleLook.of(on: false) == .off, "a toggle is on or off")
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
        expect(ToggleLook.on != .off, "an on toggle should not look off")
    }

    private static func eachStateStepIsBrighterThanTheOneBelow() {
        expectBrighter([RowLook.rest, .highlightedUnfocused, .highlighted].map(levels), "pick rows")
        expectBrighter([RowLook.rest, .selected].map(levels), "lasting rows")
        expectBrighter([RowLook.shellRest, .shellCursor, .shellSelectedCursor].map(levels), "shell rows: rest, the cursor, the viewed shell under it")
        expectBrighter([RowLook.shellRest, .selected, .shellSelectedCursor].map(levels), "shell rows: rest, the viewed shell, the viewed shell under the cursor")
        expectBrighter([OutlineLook.tabRest, .tabSelectedUnfocused, .tabSelected].map(levels), "tabs")
        expectBrighter([OutlineLook.fieldRest, .fieldFocused].map(levels), "fields")
        expectBrighter([OutlineLook.frameRest, .frameFocused].map(levels), "dock frames")
        expectBrighter([ToggleLook.off, .on].map { [$0.border.luminance] }, "toggles")
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
        expect(ToggleLook.off.border != .brassActive, "an off toggle carries no brass")
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
