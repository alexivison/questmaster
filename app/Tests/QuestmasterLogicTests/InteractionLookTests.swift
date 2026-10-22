import Foundation
import QuestmasterCore

struct InteractionLookTests {
    static func run() {
        rowsPickTheirLook()
        tabsFieldsTogglesAndBandsPickTheirLook()
        hoverNeverEqualsAnotherState()
        eachStateStepIsBrighterThanTheOneBelow()
        boldGoldAndBrassStayInTheirPlace()
        thePointerMovesTheCursor()
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
        expect(OutlineLook.tab(selected: false, highlighted: false, areaFocused: true) == .tabRest, "a plain tab should rest")
        expect(OutlineLook.tab(selected: true, highlighted: false, areaFocused: true) == .tabSelected, "a selected tab in a focused row")
        expect(OutlineLook.tab(selected: false, highlighted: true, areaFocused: true) == .tabSelected, "a highlighted tab looks selected")
        expect(OutlineLook.tab(selected: true, highlighted: false, areaFocused: false) == .tabSelectedUnfocused, "a selected tab in an unfocused row dims")
        expect(OutlineLook.field(focused: false) == .fieldRest, "a field at rest")
        expect(OutlineLook.field(focused: true) == .fieldFocused, "a focused field")
        expect(OutlineLook.frame(focused: false) == .frameRest && OutlineLook.frame(focused: true) == .frameFocused, "a dock frame lifts with focus")
        expect(OutlineLook.tabSelected.recessed && OutlineLook.tabSelectedUnfocused.recessed, "a selected tab's disc is recessed")
        expect(!OutlineLook.tabRest.recessed, "a resting tab's disc is not recessed")
        expect(ToggleLook.of(on: true) == .on && ToggleLook.of(on: false) == .off, "a toggle is on or off")
        expect(PlateBand.color(highlighted: false, areaFocused: true, recoloring: false) == nil, "a plain plate has no band")
        expect(PlateBand.color(highlighted: true, areaFocused: true, recoloring: true) == .accent, "the recolour band wins over the highlight")
    }

    /// Hover is the highlight, so it must read apart from rest, from its own dimmed unfocused step, from a lasting
    /// selection and from the recolour hint.
    private static func hoverNeverEqualsAnotherState() {
        let hover = RowLook.pick(highlighted: true, areaFocused: true)
        for other in [RowLook.rest, .highlightedUnfocused, .selected] {
            expect(hover != other, "a hovered row should not look like \(other)")
        }
        let tabHover = OutlineLook.tab(selected: false, highlighted: true, areaFocused: true)
        for other in [OutlineLook.tabRest, .tabSelectedUnfocused] {
            expect(tabHover != other, "a hovered tab should not look like \(other)")
        }
        let bands = [
            PlateBand.color(highlighted: true, areaFocused: true, recoloring: false),
            PlateBand.color(highlighted: true, areaFocused: false, recoloring: false),
            PlateBand.color(highlighted: false, areaFocused: true, recoloring: true),
            PlateBand.color(highlighted: false, areaFocused: true, recoloring: false),
        ]
        expect(Set(bands.map { $0?.rawValue ?? 0 }).count == bands.count, "every plate band state should differ: \(bands)")
        expect(OutlineLook.fieldFocused != .fieldRest, "a focused field should not look at rest")
        expect(OutlineLook.frameFocused != .frameRest, "a focused dock frame should not look at rest")
        expect(ToggleLook.on != .off, "an on toggle should not look off")
    }

    private static func eachStateStepIsBrighterThanTheOneBelow() {
        expectBrighter([RowLook.rest, .highlightedUnfocused, .highlighted].map(levels), "pick rows")
        expectBrighter([RowLook.rest, .selected].map(levels), "lasting rows")
        expectBrighter([OutlineLook.tabRest, .tabSelectedUnfocused, .tabSelected].map(levels), "tabs")
        expectBrighter([OutlineLook.fieldRest, .fieldFocused].map(levels), "fields")
        expectBrighter([OutlineLook.frameRest, .frameFocused].map(levels), "dock frames")
        expectBrighter([ToggleLook.off, .on].map { [$0.border.luminance] }, "toggles")
        let band = { (focused: Bool) in PlateBand.color(highlighted: true, areaFocused: focused, recoloring: false)?.luminance ?? 0 }
        expectBrighter([[0], [band(false)], [band(true)]], "plate bands")
        expectBrighter([StateColor.textMeta, .textMetaHighlighted, .textBody, .textSelected].map { [$0.luminance] }, "text steps")
    }

    /// Bold means selected, so only a lasting selection is bold. Gold marks the recolour band only; brass means a
    /// toggle is on and nothing else.
    private static func boldGoldAndBrassStayInTheirPlace() {
        let rows = [RowLook.rest, .highlighted, .highlightedUnfocused, .selected]
        expect(rows.filter(\.bold) == [.selected], "only the lasting selection should be bold")
        let rowColors = rows.flatMap { [$0.fill, $0.text, $0.meta, $0.icon, $0.iconBorder].compactMap { $0 } }
        let outlineColors = [OutlineLook.tabRest, .tabSelected, .tabSelectedUnfocused, .fieldRest, .fieldFocused, .frameRest, .frameFocused].flatMap { [$0.border, $0.label] }
        for color in rowColors + outlineColors {
            expect(color != .accent && color != .brassActive, "rows, tabs and fields carry no gold or brass, got \(color)")
        }
        expect(ToggleLook.off.border != .brassActive, "an off toggle carries no brass")
    }

    /// Hover is the cursor: the row under the pointer becomes the highlight, as an arrow move would make it, so Return
    /// takes it; a picker's rows stay where they are.
    private static func thePointerMovesTheCursor() {
        var list = SuggestionList()
        list.show(["a", "b", "c"])
        list.highlight(2)
        expect(list.highlightedIndex == 2 && list.moved, "the pointed-at path row should be the highlight, as if moved to")
        list.highlight(5)
        expect(list.highlightedIndex == 2, "a row past the list should leave the highlight alone")

        var window = PickerListWindow(visibleRows: 3)
        window.reset(highlighting: 0, count: 10)
        window.move(4, count: 10)
        let start = window.start
        window.highlight(visibleRow: 0, count: 10)
        expect(window.start == start, "pointing at a row should not scroll the picker's rows")
        expect(window.highlightedIndex == start && window.visibleHighlightIndex == 0 && window.moved, "the pointed-at picker row should be the highlight")
        window.highlight(visibleRow: 3, count: 10)
        expect(window.visibleHighlightIndex == 0, "a row past the visible ones should leave the highlight alone")
        var short = PickerListWindow(visibleRows: 5)
        short.reset(highlighting: 0, count: 2)
        short.highlight(visibleRow: 3, count: 2)
        expect(short.highlightedIndex == 0, "a row past a short list's end should leave the highlight alone")
    }

    /// A look's colours as luminances, in a fixed order; no fill counts as 0, below any fill.
    private static func levels(_ look: RowLook) -> [Double] {
        [look.fill?.luminance ?? 0, look.text.luminance, look.meta.luminance, look.icon.luminance, look.iconBorder.luminance]
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
