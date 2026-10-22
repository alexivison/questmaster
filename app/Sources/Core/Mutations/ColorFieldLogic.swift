import Foundation

/// The colour input (color-input.svg): the colour's name with its swatch at the end, a picker field
/// (`PickerFieldMode`). In SELECT, ←/→ cycle the colours as the old colour select did. In SEARCH, typing
/// filters the names; the dropdown lists the matches three at a time, and the swatch previews the
/// highlighted one while ↑/↓ move through them; Tab or Return picks.
public struct ColorFieldModel: Equatable {
    /// "" is no colour: the first option, shown as "none".
    public let colors: [String]
    public private(set) var selectedIndex: Int
    /// The field's text: the selected colour's name until the user types.
    public private(set) var text: String
    /// Into `matches`.
    public private(set) var highlightedIndex = 0
    /// The first of the `visibleRows` matches the dropdown shows; it follows the highlight.
    public private(set) var windowStart = 0
    public private(set) var isPreviewing = false
    public private(set) var isDismissed = true
    public private(set) var mode = PickerFieldMode.select

    public static let visibleRows = 3

    public init(colors: [String] = NewSessionFormModel.defaultColors, selected: String) {
        self.colors = colors.isEmpty ? NewSessionFormModel.defaultColors : colors
        let name = selected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let index = self.colors.firstIndex(of: name) ?? self.colors.firstIndex(of: NewSessionFormModel.noColor) ?? 0
        selectedIndex = index
        text = Self.label(self.colors[index])
    }

    /// A colour's name as the app has it: lowercase, and "none" for no colour.
    public static func label(_ color: String) -> String {
        color.isEmpty ? NewSessionFormModel.noColorLabel : color
    }

    public var selectedColor: String {
        colors[selectedIndex]
    }

    /// The colours whose names contain the text. Text that is exactly one of the names (the selected
    /// colour's, as the field starts) or empty lists them all, so the field browses.
    public var matches: [String] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let browsing = query.isEmpty || colors.contains { Self.label($0) == query }
        return browsing ? colors : colors.filter { Self.label($0).contains(query) }
    }

    public var visibleMatches: [String] {
        Array(matches.dropFirst(windowStart).prefix(Self.visibleRows))
    }

    /// The highlighted row's position among `visibleMatches`.
    public var visibleHighlightIndex: Int {
        highlightedIndex - windowStart
    }

    public var highlightedColor: String? {
        let all = matches
        return all.indices.contains(highlightedIndex) ? all[highlightedIndex] : nil
    }

    /// The swatch: the highlighted colour while moving through the list, otherwise the selected one.
    public var swatchColor: String {
        isPreviewing ? highlightedColor ?? selectedColor : selectedColor
    }

    /// The list shows only while searching.
    public var showsSuggestions: Bool {
        mode == .search && !isDismissed && !matches.isEmpty
    }

    /// A key, or a click into the text, starts a search: on that text, or editing the colour's name.
    public mutating func startSearch(_ start: PickerFieldMode.SearchStart) {
        mode = .search
        switch start {
        case .seed(let text):
            type(text)
        case .editCurrent:
            open()
        }
    }

    /// The list opens on the selected colour.
    private mutating func open() {
        isDismissed = false
        isPreviewing = false
        let all = matches
        highlightedIndex = all.firstIndex(of: selectedColor) ?? 0
        windowStart = min(highlightedIndex, max(0, all.count - Self.visibleRows))
    }

    public mutating func type(_ text: String) {
        mode = .search
        self.text = text
        isDismissed = false
        isPreviewing = false
        highlightedIndex = 0
        windowStart = 0
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
        let count = matches.count
        highlightedIndex = (highlightedIndex + delta + count) % count
        if highlightedIndex < windowStart {
            windowStart = highlightedIndex
        } else if highlightedIndex >= windowStart + Self.visibleRows {
            windowStart = highlightedIndex - Self.visibleRows + 1
        }
        isPreviewing = true
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

    /// Esc, or focus leaving the field: back to SELECT, the text back to the selected colour's name.
    public mutating func endSearch() {
        mode = .select
        text = Self.label(selectedColor)
        isDismissed = true
        isPreviewing = false
    }

    private mutating func select(_ index: Int) {
        selectedIndex = index
        endSearch()
    }
}

public enum ColorFieldCommand: Equatable {
    case cycle(Int)
    case moveHighlight(Int)
    case pick
    case startSearch(PickerFieldMode.SearchStart)
    case endSearch
}

public extension ColorFieldModel {
    mutating func apply(_ command: ColorFieldCommand) {
        switch command {
        case .cycle(let delta):
            cycle(delta)
        case .moveHighlight(let delta):
            moveHighlight(delta)
        case .pick:
            pick()
        case .startSearch(let start):
            startSearch(start)
        case .endSearch:
            endSearch()
        }
    }

    /// The keys the focused colour input takes; the rest (Tab in SELECT, ⌘ keys) stay the sheet's.
    static func command(keyCode: UInt16, characters: String?, command: Bool, control: Bool, option: Bool, mode: PickerFieldMode, showsSuggestions: Bool) -> ColorFieldCommand? {
        if command || control {
            return nil
        }
        if option {
            if Keymap.ColorField.cyclePrevious.matches(keyCode) { return .cycle(-1) }
            if Keymap.ColorField.cycleNext.matches(keyCode) { return .cycle(1) }
            return nil
        }
        switch mode {
        case .select:
            if Keymap.NewSession.selectLeft.matches(keyCode) { return .cycle(-1) }
            if Keymap.NewSession.selectRight.matches(keyCode) { return .cycle(1) }
            return PickerFieldMode.searchStart(characters: characters, keyCode: keyCode, command: command, control: control, option: option).map(ColorFieldCommand.startSearch)
        case .search:
            if Keymap.NewSession.suggestionUp.matches(keyCode) { return .moveHighlight(-1) }
            if Keymap.NewSession.suggestionDown.matches(keyCode) { return .moveHighlight(1) }
            if Keymap.NewSession.cancel.matches(keyCode) { return .endSearch }
            if Keymap.NewSession.completePath.matches(keyCode) || Keymap.NewSession.create.matches(characters) {
                return showsSuggestions ? .pick : .endSearch
            }
            return nil
        }
    }
}
