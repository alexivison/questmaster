import AppKit
import QuestmasterCore
import SwiftUI

/// The colour input's focus plumbing, shared by the modals that show a colour input: the caret goes into the text as a search
/// starts and leaves it as the field returns to SELECT.
struct ModalColorFocus {
    var textNonce = 0
    var sinkNonce = 0

    /// `PickerFieldMode.caretChange`, with the colour input focused.
    mutating func follow(from before: PickerFieldMode, to after: PickerFieldMode) {
        switch PickerFieldMode.caretChange(from: before, to: after, fieldFocused: true) {
        case .intoText:
            textNonce += 1
        case .outOfText:
            sinkNonce += 1
        case nil:
            break
        }
    }
}

/// The edit sheets' colour input and its keys.
struct ModalColorInput: View {
    @Binding var color: ColorFieldModel
    @Binding var colorFocus: ModalColorFocus
    let focused: Bool
    var onFocus: () -> Void

    var body: some View {
        ColorField(
            model: $color,
            focusNonce: colorFocus.textNonce,
            focused: focused,
            onClickText: {
                onFocus()
                let before = color.mode
                color.startSearch(.editCurrent)
                colorFocus.follow(from: before, to: color.mode)
            },
            onSwatchClick: {
                onFocus()
                let before = color.mode
                color.cycle(1)
                colorFocus.follow(from: before, to: color.mode)
            }
        )
    }

    /// Runs the key the focused colour input takes: its own ⌥←/⌥→ (`ColorFieldModel.optionCycleDelta`), then the shared
    /// picker keys (`PickerFieldKey`). In SELECT, ←/→ and h/l are the modal's select keys, so they pass: a search
    /// must not start on h or l. The caret follows the mode.
    static func handle(_ event: NSEvent, color: inout ColorFieldModel, colorFocus: inout ModalColorFocus) -> Bool {
        let before = color.mode
        let press = event.keymapPress
        if let delta = ColorFieldModel.optionCycleDelta(press) {
            color.cycle(delta)
        } else if before == .select, ModalKeys.cycleStep(press) != nil {
            return false
        } else if let command = PickerFieldKey.command(press, mode: before, showsSuggestions: color.showsSuggestions) {
            color.apply(command)
        } else {
            return false
        }
        colorFocus.follow(from: before, to: color.mode)
        return true
    }

    /// The modal's cycle for the colour, ←/→ in SELECT: the next or previous colour, without a search.
    static func cycle(_ step: Int, color: inout ColorFieldModel, colorFocus: inout ModalColorFocus) {
        let before = color.mode
        color.cycle(step)
        colorFocus.follow(from: before, to: color.mode)
    }
}
