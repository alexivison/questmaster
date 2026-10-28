import Foundation

/// The colour input (color-input.svg): the colour's name with its swatch at the end, a picker field
/// (`PickerFieldMode`). In SELECT, ←/→ cycle the colours as the old colour select did. In SEARCH, typing
/// filters the names, best match first; the dropdown lists them three at a time, and the swatch
/// previews the highlighted one; Tab or Return picks.
public struct ColorFieldModel: Equatable {
    /// "" is no colour: the first option, shown as "none".
    public let colors: [String]
    public private(set) var selectedIndex: Int
    /// The field's text: the selected colour's name until the user types.
    public private(set) var text: String
    /// The highlight over all of `matches`, and the visible rows following it.
    public private(set) var window = PickerListWindow(visibleRows: ColorFieldModel.visibleRows)
    public private(set) var isDismissed = true
    public private(set) var mode = PickerFieldMode.select
    /// The text the search started from: while it is unchanged (Backspace editing the name),
    /// the list browses every colour.
    private var searchStartText: String

    public static let visibleRows = 3

    public init(colors: [String] = NewSessionFormModel.defaultColors, selected: String) {
        self.colors = colors.isEmpty ? NewSessionFormModel.defaultColors : colors
        let name = selected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let index = self.colors.firstIndex(of: name) ?? self.colors.firstIndex(of: NewSessionFormModel.noColor) ?? 0
        selectedIndex = index
        text = Self.label(self.colors[index])
        searchStartText = text
    }

    /// A colour's name as the app has it: lowercase, and "none" for no colour.
    public static func label(_ color: String) -> String {
        color.isEmpty ? NewSessionFormModel.noColorLabel : color
    }

    public var selectedColor: String {
        colors[selectedIndex]
    }

    /// The colours matching the text, best first (`PickerFieldMode.ranked`). An empty search, or the
    /// text the search started from, lists every colour.
    public var matches: [String] {
        guard !isBrowsing else {
            return colors
        }
        return PickerFieldMode.ranked(colors, query: query) { Self.label($0) }
    }

    private var query: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isBrowsing: Bool {
        query.isEmpty || text == searchStartText
    }

    public var visibleMatches: [String] {
        window.visible(matches)
    }

    /// The highlighted row's position among `visibleMatches`.
    public var visibleHighlightIndex: Int {
        window.visibleHighlightIndex
    }

    public var highlightedColor: String? {
        window.highlighted(matches)
    }

    /// The swatch: the highlighted colour while the list shows (the best match as you type, each colour
    /// as ↑/↓ move), otherwise the selected one.
    public var swatchColor: String {
        showsSuggestions ? highlightedColor ?? selectedColor : selectedColor
    }

    /// The list shows only while searching.
    public var showsSuggestions: Bool {
        mode == .search && !isDismissed && !matches.isEmpty
    }

    /// A key, or a click into the text, starts a search: on that text, or editing the colour's name.
    public mutating func startSearch(_ start: PickerFieldMode.SearchStart) {
        mode = .search
        searchStartText = text
        switch start {
        case .seed(let text):
            type(text)
        case .editCurrent:
            open()
        }
    }

    private mutating func open() {
        isDismissed = false
        resetHighlight()
    }

    public mutating func type(_ text: String) {
        mode = .search
        self.text = text
        open()
    }

    /// The best match, or the selected colour while the list browses every colour.
    private mutating func resetHighlight() {
        let all = matches
        window.reset(highlighting: isBrowsing ? all.firstIndex(of: selectedColor) ?? 0 : 0, count: all.count)
    }

    /// ↑/↓ while searching: opens a closed list, then moves through it (wrapping), previewing each colour.
    public mutating func moveHighlight(_ delta: Int) {
        guard mode == .search else {
            return
        }
        guard showsSuggestions else {
            open()
            return
        }
        window.move(delta, count: matches.count)
    }

    /// Saving while a search shows a highlight takes that colour first: the swatch already shows it.
    public mutating func commitPendingPick() {
        if showsSuggestions {
            pick()
        }
    }

    /// Tab, Return or a click: the highlighted colour becomes the selection. False with no list open.
    @discardableResult
    public mutating func pick() -> Bool {
        guard showsSuggestions, let color = highlightedColor, let index = colors.firstIndex(of: color) else {
            return false
        }
        select(index)
        return true
    }

    public mutating func pick(visibleRow row: Int) {
        let visible = visibleMatches
        guard visible.indices.contains(row), let index = colors.firstIndex(of: visible[row]) else {
            return
        }
        select(index)
    }

    /// ←/→ in SELECT, ⌥←/⌥→ in either state: the next or previous colour, wrapping, without the list.
    public mutating func cycle(_ delta: Int) {
        select((selectedIndex + delta + colors.count) % colors.count)
    }

    /// Esc, Tab or Return with no row to take, or focus leaving the field: back to SELECT, the text back to the
    /// selected colour's name.
    public mutating func endSearch() {
        mode = .select
        text = Self.label(selectedColor)
        isDismissed = true
    }

    private mutating func select(_ index: Int) {
        selectedIndex = index
        endSearch()
    }
}

public extension ColorFieldModel {
    /// The shared picker keys (`PickerFieldKey`) applied to the colour. A colour's text is its name, so
    /// nothing typed is kept: ending a search, by Tab or Return or Esc, shows the selected colour again.
    mutating func apply(_ command: PickerFieldCommand) {
        switch command {
        case .startSearch(let start):
            startSearch(start)
        case .moveHighlight(let delta):
            moveHighlight(delta)
        case .pick:
            pick()
        case .endSearch, .restore:
            endSearch()
        }
    }

    /// The direction ⌥←/⌥→ (both states) and ←/→ (SELECT) cycle the colours in, or nil for another key.
    static func cycleDelta(_ press: Keymap.KeyPress, mode: PickerFieldMode) -> Int? {
        if Keymap.matches(press, .optionCycleLeft) { return -1 }
        if Keymap.matches(press, .optionCycleRight) { return 1 }
        guard mode == .select else {
            return nil
        }
        if Keymap.matches(press, .cycleLeft) { return -1 }
        if Keymap.matches(press, .cycleRight) { return 1 }
        return nil
    }
}
