import AppKit
import QuestmasterCore
import SwiftUI

/// What the Edit Project sheet opens with: the draft and the client its Save sends through.
struct ProjectEditPresentation: Identifiable {
    let id = UUID()
    let draft: ProjectEditDraft
    let mutationClient: ServeMutationSending
}

/// The sheet's fields. The path shows only when adding: a listed project's folder can't change.
enum ProjectEditField: Equatable {
    case path
    case name
    case color
}

/// Add Project: the path, the display name and the colour input; Edit Project: the name and the colour, under the
/// shared header. Its keys are the colour
/// input's own, then the shared modal keys (`ModalKeys`), as the tracker's edit sheets take them.
@MainActor
final class ProjectEditModel: ObservableObject {
    @Published var draft: ProjectEditDraft
    @Published var color: ColorFieldModel
    @Published var colorFocus = ModalColorFocus()
    @Published private(set) var focus: ProjectEditField
    @Published var nameNonce = 0
    @Published var pathNonce = 0
    @Published var errorMessage: String?

    private let initialColorIndex: Int
    private let mutationClient: ServeMutationSending
    private let dismissSheet: () -> Void

    init(presentation: ProjectEditPresentation, dismiss: @escaping () -> Void) {
        draft = presentation.draft
        let colorField = ColorFieldModel(selected: presentation.draft.color)
        color = colorField
        initialColorIndex = colorField.selectedIndex
        mutationClient = presentation.mutationClient
        dismissSheet = dismiss
        // Add Project starts at the path, unless a folder already filled it in: then the name is what's left to type.
        let needsPath = presentation.draft.target == .add && presentation.draft.path.isEmpty
        focus = needsPath ? .path : .name
    }

    var title: String {
        draft.target == .add ? "Add Project" : "Edit Project"
    }

    /// The fields top to bottom, the order Tab moves between them.
    var fields: [ProjectEditField] {
        draft.target == .add ? [.path, .name, .color] : [.name, .color]
    }

    /// The sheet's first focus, its top field: the path when adding (it has to be given), else the name.
    func appear() {
        if focus == .path {
            pathNonce += 1
        } else {
            nameNonce += 1
        }
    }

    /// A click into a field focuses it; the click already placed the caret.
    func moveFocus(to field: ProjectEditField, byClick: Bool = false) {
        guard field != focus else {
            return
        }
        if focus == .color {
            color.endSearch()
        }
        focus = field
        guard !byClick else {
            return
        }
        switch field {
        case .color:
            colorFocus.sinkNonce += 1
        case .name:
            nameNonce += 1
        case .path:
            pathNonce += 1
        }
    }

    func cancel() {
        dismissSheet()
    }

    func handle(_ event: NSEvent) -> Bool {
        ModalKeyActions(
            context: { self.keyContext },
            fieldKey: { self.handleFieldKey($0) },
            submit: { self.submit() },
            cancel: { self.cancel() },
            moveFocus: { self.moveFocus(by: $0) },
            cycle: { self.cycleColor($0) }
        ).handle(event)
    }

    /// Saving mid-search takes the colour the swatch shows. A colour left as it was keeps the project's own value, so
    /// a colour the palette doesn't list isn't taken for "none".
    func submit() {
        var committed = color
        committed.commitPendingPick()
        color = committed
        let isUnchanged = committed.selectedIndex == initialColorIndex
        var saved = draft
        saved.color = isUnchanged ? draft.initialColor : committed.selectedColor
        draft = saved
        do {
            guard let request = try draft.saveRequest() else {
                dismissSheet()
                return
            }
            errorMessage = nil
            mutationClient.send(request) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    switch result {
                    case .success:
                        self.dismissSheet()
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var keyContext: ModalKeyContext {
        ModalKeyContext(focus: focus == .color && color.mode == .select ? .select : .line, fieldCount: fields.count, hasTextFields: true, submitting: false, submits: true)
    }

    private func handleFieldKey(_ event: NSEvent) -> Bool {
        focus == .color && ModalColorInput.handle(event, color: &color, colorFocus: &colorFocus)
    }

    private func cycleColor(_ step: Int) {
        ModalColorInput.cycle(step, color: &color, colorFocus: &colorFocus)
    }

    private func moveFocus(by delta: Int) {
        guard let index = fields.firstIndex(of: focus) else {
            return
        }
        let next = (index + delta + fields.count) % fields.count
        moveFocus(to: fields[next])
    }
}

struct ProjectEditSheetView: View {
    @StateObject private var model: ProjectEditModel

    init(presentation: ProjectEditPresentation, dismiss: @escaping () -> Void) {
        _model = StateObject(wrappedValue: ProjectEditModel(presentation: presentation, dismiss: dismiss))
    }

    var body: some View {
        ModalFormSheet(
            title: model.title,
            errorMessage: model.errorMessage,
            primaryLabel: "Save",
            canSubmit: true,
            size: CGSize(width: ModalFormMetrics.editWidth, height: ModalFormMetrics.height(fields: model.fields.count)),
            buttonWidth: ModalFormMetrics.editButtonWidth,
            onCancel: model.cancel,
            onPrimary: model.submit
        ) {
            VStack(spacing: ModalFormMetrics.fieldSpacing) {
                if model.fields.contains(.path) {
                    pathField
                }
                nameField
                ModalColorInput(
                    color: $model.color,
                    colorFocus: $model.colorFocus,
                    focused: model.focus == .color,
                    onFocus: { model.moveFocus(to: .color, byClick: true) }
                )
            }
            .background(FocusSink(nonce: model.colorFocus.sinkNonce))
        }
        .scoopedPanel()
        .floatingDropdownHost()
        .background(SheetKeyEventMonitor(onKeyDown: model.handle))
        .onAppear { model.appear() }
    }

    private var nameField: some View {
        FormTextField(
            text: $model.draft.name,
            placeholder: model.draft.defaultName.isEmpty ? "Project name" : model.draft.defaultName,
            focusNonce: model.nameNonce,
            focused: model.focus == .name,
            onFocusChanged: { editing in
                if editing {
                    model.moveFocus(to: .name, byClick: true)
                }
            }
        )
        .accessibilityLabel("Project name")
    }

    private var pathField: some View {
        FormTextField(
            text: $model.draft.path,
            placeholder: "Folder path",
            focusNonce: model.pathNonce,
            focused: model.focus == .path,
            onFocusChanged: { editing in
                if editing {
                    model.moveFocus(to: .path, byClick: true)
                }
            }
        )
        .accessibilityLabel("Project path")
    }
}
