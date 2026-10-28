import AppKit
import QuestmasterCore
import SwiftUI

/// Edit Session and Edit Repo (user-edit-modals.png): no labels; the session's title row (or the repo's fixed
/// name) and the colour input, 20 apart, then Cancel and Save, under the shared header. The overview's
/// fields and buttons put them at 460 wide (the old modals were 420), with 150-wide buttons (the overview's 152).
/// A master's or worker's title row starts with its portrait, 5 taller than a field.
private enum TrackerEditMetrics {
    static let width: CGFloat = 460
    static let buttonWidth: CGFloat = 150

    static func size(fields: Int, portraitRow: Bool = false) -> CGSize {
        CGSize(width: width, height: ModalFormMetrics.height(fields: fields, portraitRow: portraitRow))
    }
}

/// The edit sheets' keyboard focus: the title (Edit Session only) or the colour input.
enum TrackerEditField: Equatable {
    case title
    case color
}

/// The colour input's focus plumbing, shared by both sheets: the caret goes into the text as a search
/// starts and leaves it as the field returns to SELECT.
private struct TrackerColorFocus {
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

struct TrackerEditSessionSheet: View {
    let dismiss: () -> Void
    /// Saves the title, the colour and the portrait's class.
    let save: (String, String, EditSessionPortrait) -> Bool
    let allowsColor: Bool

    @State private var title: String
    @State private var portrait: EditSessionPortrait
    @State private var color: ColorFieldModel
    @State private var focus: TrackerEditField
    @State private var titleNonce = 0
    @State private var colorFocus = TrackerColorFocus()
    @State private var errorMessage: String?
    private let initialColor: String
    private let initialColorIndex: Int

    /// `colorSearch`: opens with the colour input searching (the renders' open dropdown).
    init(session: TrackerEditSession, initialFocus: TrackerEditField = .title, colorSearch: PickerFieldMode.SearchStart? = nil, dismiss: @escaping () -> Void, save: @escaping (String, String, EditSessionPortrait) -> Bool) {
        self.dismiss = dismiss
        self.save = save
        allowsColor = session.allowsColor
        _title = State(initialValue: session.title)
        _portrait = State(initialValue: session.portrait)
        var color = ColorFieldModel(selected: session.color)
        if let colorSearch {
            color.startSearch(colorSearch)
        }
        _color = State(initialValue: color)
        _focus = State(initialValue: session.allowsColor ? initialFocus : .title)
        initialColor = session.color
        initialColorIndex = color.selectedIndex
    }

    var body: some View {
        ModalFormSheet(
            title: "Edit Session",
            errorMessage: errorMessage,
            primaryLabel: "Save",
            canSubmit: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            size: TrackerEditMetrics.size(fields: allowsColor ? 2 : 1, portraitRow: portrait.portrait != nil),
            buttonWidth: TrackerEditMetrics.buttonWidth,
            onCancel: dismiss,
            onPrimary: submit
        ) {
            VStack(spacing: ModalFormMetrics.fieldSpacing) {
                titleRow
                if allowsColor {
                    TrackerColorInput(color: $color, colorFocus: $colorFocus, focused: focus == .color, onFocus: { moveFocus(to: .color, byClick: true) })
                }
            }
            .background(FocusSink(nonce: colorFocus.sinkNonce))
        }
        .scoopedPanel()
        .floatingDropdownHost()
        .background(SheetKeyEventMonitor(onKeyDown: handle))
        .onAppear {
            if focus == .title {
                titleNonce += 1
            } else {
                colorFocus.sinkNonce += 1
            }
        }
    }

    /// The title with the portrait before it: a master's class (its name at the field's end, or "Random" while it has
    /// none) cycles on ⌃e in the title and on a click; a worker's familiar only shows. A row with neither (a shell) is the
    /// title alone.
    private var titleRow: some View {
        SessionTitleRow(
            portrait: portrait.portrait,
            portraitLabel: portrait.accessibilityLabel ?? "",
            onPortraitClick: portrait.isEditable ? { portrait.cycle() } : nil
        ) {
            FormTextField(
                text: $title,
                placeholder: "Title of the Session",
                focusNonce: titleNonce,
                focused: focus == .title,
                onFocusChanged: { editing in
                    if editing {
                        moveFocus(to: .title, byClick: true)
                    }
                }
            ) {
                if let label = portrait.label {
                    FormFieldSegment(text: label, color: AppPalette.textMeta)
                }
            }
        }
    }

    private func submit() {
        // Saving mid-search takes the colour the swatch is showing.
        var committed = color
        committed.commitPendingPick()
        color = committed
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            errorMessage = "title is required"
            return
        }
        let resolvedColor = NewSessionFormModel.resolvedColorForSave(
            selectedColor: committed.selectedColor,
            selectedColorIndex: committed.selectedIndex,
            initialColorIndex: initialColorIndex,
            initialColor: initialColor
        )
        guard save(cleanTitle, resolvedColor, portrait) else {
            errorMessage = "could not save session"
            return
        }
        dismiss()
    }

    /// `byClick`: the click already placed the caret (or, on the colour input, starts the search itself).
    private func moveFocus(to field: TrackerEditField, byClick: Bool = false) {
        guard field != focus else {
            return
        }
        // Leaving the colour input ends its search; the caret goes where focus goes, not to the sink.
        if focus == .color {
            color.endSearch()
        }
        focus = field
        guard !byClick else {
            return
        }
        switch field {
        case .title:
            titleNonce += 1
        case .color:
            colorFocus.sinkNonce += 1
        }
    }

    /// The sheet's keys: the focused field's own (`handleFieldKey`), then the shared modal keys (`ModalKeys`).
    private func handle(_ event: NSEvent) -> Bool {
        ModalKeyActions(
            context: { modalKeyContext },
            fieldKey: { handleFieldKey($0) },
            submit: { submit() },
            cancel: { dismiss() },
            moveFocus: { _ in moveFocus(to: focus == .title ? .color : .title) },
            cycle: { cycleColor($0) }
        ).handle(event)
    }

    private var modalKeyContext: ModalKeyContext {
        ModalKeyContext(focus: keyFocus, fieldCount: allowsColor ? 2 : 1, submitting: false, submits: true)
    }

    /// The colour input takes ←/→ to cycle only in SELECT; while it searches they move the caret.
    private var keyFocus: ModalKeyContext.Focus {
        focus == .color && color.mode == .select ? .select : .line
    }

    /// The colour input's keys, then the class key (⌃e in the title, for a master).
    private func handleFieldKey(_ event: NSEvent) -> Bool {
        if focus == .color, TrackerColorInput.handle(event, color: &color, colorFocus: &colorFocus) {
            return true
        }
        guard portrait.isEditable, SessionClassKey.cycles(event.keymapPress, titleFocused: focus == .title) else {
            return false
        }
        portrait.cycle()
        return true
    }

    private func cycleColor(_ step: Int) {
        TrackerColorInput.cycle(step, color: &color, colorFocus: &colorFocus)
    }
}

struct TrackerEditRepoSheet: View {
    let repo: TrackerEditRepo
    let dismiss: () -> Void
    let save: (String) -> Bool

    @State private var color: ColorFieldModel
    @State private var colorFocus = TrackerColorFocus()
    @State private var errorMessage: String?
    private let initialColor: String
    private let initialColorIndex: Int

    init(repo: TrackerEditRepo, colorSearch: PickerFieldMode.SearchStart? = nil, dismiss: @escaping () -> Void, save: @escaping (String) -> Bool) {
        self.repo = repo
        self.dismiss = dismiss
        self.save = save
        var color = ColorFieldModel(selected: repo.color)
        if let colorSearch {
            color.startSearch(colorSearch)
        }
        _color = State(initialValue: color)
        initialColor = repo.color
        initialColorIndex = color.selectedIndex
    }

    var body: some View {
        ModalFormSheet(
            title: "Edit Repo",
            errorMessage: errorMessage,
            primaryLabel: "Save",
            canSubmit: true,
            size: TrackerEditMetrics.size(fields: 2),
            buttonWidth: TrackerEditMetrics.buttonWidth,
            onCancel: dismiss,
            onPrimary: submit
        ) {
            VStack(spacing: ModalFormMetrics.fieldSpacing) {
                // Repos can't be renamed (serve only recolours them), so the name is fixed: no focus, dim.
                BaselineText(repo.name.isEmpty ? repo.identity : repo.name, font: AppFonts.questLogBody, color: AppPalette.textMeta, baseline: FormFieldMetrics.baseline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, FormFieldMetrics.textInset)
                    .frame(maxWidth: .infinity, minHeight: FormFieldMetrics.height, maxHeight: FormFieldMetrics.height, alignment: .topLeading)
                    .fieldChrome(focused: false)
                    .accessibilityLabel("Repo \(repo.name)")
                TrackerColorInput(color: $color, colorFocus: $colorFocus, focused: true, onFocus: {})
            }
            .background(FocusSink(nonce: colorFocus.sinkNonce))
        }
        .scoopedPanel()
        .floatingDropdownHost()
        .background(SheetKeyEventMonitor(onKeyDown: handle))
        .onAppear { colorFocus.sinkNonce += 1 }
    }

    private func submit() {
        // Saving mid-search takes the colour the swatch is showing.
        var committed = color
        committed.commitPendingPick()
        color = committed
        let resolvedColor = NewSessionFormModel.resolvedColorForSave(
            selectedColor: committed.selectedColor,
            selectedColorIndex: committed.selectedIndex,
            initialColorIndex: initialColorIndex,
            initialColor: initialColor
        )
        guard save(resolvedColor) else {
            errorMessage = "could not save repo"
            return
        }
        dismiss()
    }

    /// The sheet's keys: the colour input's own, then the shared modal keys (`ModalKeys`). The colour is the only
    /// field, so Tab does nothing.
    private func handle(_ event: NSEvent) -> Bool {
        ModalKeyActions(
            context: { modalKeyContext },
            fieldKey: { handleFieldKey($0) },
            submit: { submit() },
            cancel: { dismiss() },
            cycle: { cycleColor($0) }
        ).handle(event)
    }

    private var modalKeyContext: ModalKeyContext {
        ModalKeyContext(focus: color.mode == .select ? .select : .line, fieldCount: 1, submitting: false, submits: true)
    }

    private func handleFieldKey(_ event: NSEvent) -> Bool {
        TrackerColorInput.handle(event, color: &color, colorFocus: &colorFocus)
    }

    private func cycleColor(_ step: Int) {
        TrackerColorInput.cycle(step, color: &color, colorFocus: &colorFocus)
    }
}

/// The edit sheets' colour input and its keys.
private struct TrackerColorInput: View {
    @Binding var color: ColorFieldModel
    @Binding var colorFocus: TrackerColorFocus
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
    static func handle(_ event: NSEvent, color: inout ColorFieldModel, colorFocus: inout TrackerColorFocus) -> Bool {
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
    static func cycle(_ step: Int, color: inout ColorFieldModel, colorFocus: inout TrackerColorFocus) {
        let before = color.mode
        color.cycle(step)
        colorFocus.follow(from: before, to: color.mode)
    }
}
