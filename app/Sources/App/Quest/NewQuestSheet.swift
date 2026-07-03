import AppKit
import QuestmasterCore
import SwiftUI

@MainActor
final class NewQuestSheetPresenter: ObservableObject {
    @Published var presentation: NewQuestSheetPresentation?

    func present(
        projects: [NewQuestProjectOption],
        selectedProjectID: String,
        initialContent: String = "",
        questID: String = "",
        sessionID: String?,
        mutationClient: ServeMutationSending,
        onSuccess: @escaping () -> Void
    ) {
        presentation = NewQuestSheetPresentation(
            projects: projects,
            selectedProjectID: selectedProjectID,
            initialContent: initialContent,
            questID: questID,
            sessionID: sessionID ?? "",
            mutationClient: mutationClient,
            onSuccess: onSuccess
        )
    }

    func dismiss() {
        presentation = nil
    }
}

struct NewQuestSheetPresentation: Identifiable {
    let id = UUID()
    let projects: [NewQuestProjectOption]
    let selectedProjectID: String
    let initialContent: String
    let questID: String
    let sessionID: String
    let mutationClient: ServeMutationSending
    let onSuccess: () -> Void
}

struct NewQuestSheetView: View {
    @StateObject private var model: NewQuestSheetModel

    init(presentation: NewQuestSheetPresentation, dismiss: @escaping () -> Void) {
        _model = StateObject(wrappedValue: NewQuestSheetModel(presentation: presentation, dismiss: dismiss))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(AppPalette.bright.swiftUI)
                Spacer()
            }
            .frame(height: 58)
            .padding(.horizontal, 18)
            Rectangle().fill(AppPalette.line.swiftUI).frame(height: 1)
            projectRow
            contentRow
            errorRow
            Rectangle().fill(AppPalette.line.swiftUI).frame(height: 1)
            footer
        }
        .frame(width: NewSessionSheetModel.sheetSize.width, height: NewSessionSheetModel.sheetSize.height)
        .background(AppPalette.panel.swiftUI)
        .background(NewQuestKeyEventMonitor { model.handle($0) })
    }

    private var projectRow: some View {
        ModalFormRow(label: "Project:", labelWidth: 64) {
            HStack(spacing: 12) {
                ModalSelectControl(
                    title: model.projectTitle,
                    swatchColor: nil,
                    focused: model.model.focusedField == .project,
                    disabled: model.model.submitting
                )
                .frame(width: 220, height: 36)
                .onTapGesture {
                    model.focus(.project)
                }
                Text("project for this quest")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppPalette.dim.swiftUI)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var contentRow: some View {
        ModalFormRow(label: "Content:", labelWidth: 64, topAligned: true, fill: true) {
            ModalPromptEditor(
                text: Binding(get: { model.model.content }, set: { model.model.content = $0 }),
                isEditable: !model.model.submitting,
                isFocused: model.model.focusedField == .content,
                onFocus: { model.focus(.content) },
                onCreate: { model.submit() }
            )
            .background(AppPalette.panelAlt.swiftUI)
            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.control)
                    .strokeBorder((model.model.focusedField == .content ? AppPalette.accent : AppPalette.line).swiftUI, lineWidth: model.model.focusedField == .content ? 2 : 1)
            )
            .frame(maxHeight: .infinity)
        }
        .padding(.bottom, 7)
    }

    private var errorRow: some View {
        Text(model.model.errorMessage ?? "")
            .font(AppFonts.monoSmall.swiftUI)
            .foregroundStyle(AppPalette.deleted.swiftUI)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .frame(height: model.model.errorMessage == nil ? 0 : 24)
    }

    private var footer: some View {
        Text(model.footerText)
            .font(AppFonts.monoSmall.swiftUI)
            .foregroundStyle(AppPalette.dim.swiftUI)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .frame(height: 42)
    }
}

@MainActor
final class NewQuestSheetModel: ObservableObject {
    @Published var model: NewQuestFormModel

    private let mutationClient: ServeMutationSending
    private let questID: String
    private let sessionID: String
    private let onSuccess: () -> Void
    private let dismiss: () -> Void

    init(presentation: NewQuestSheetPresentation, dismiss: @escaping () -> Void) {
        model = NewQuestFormModel(
            content: presentation.initialContent,
            projects: presentation.projects,
            selectedProjectID: presentation.selectedProjectID
        )
        questID = presentation.questID
        mutationClient = presentation.mutationClient
        sessionID = presentation.sessionID
        onSuccess = presentation.onSuccess
        self.dismiss = dismiss
    }

    var projectTitle: String {
        model.selectedProject?.projectName ?? "No project"
    }

    var title: String {
        questID.isEmpty ? "New Quest" : "Edit Quest"
    }

    var actionTitle: String {
        questID.isEmpty ? "Create" : "Save"
    }

    var footerText: String {
        NewQuestSheetFooterText.text(isEditing: !questID.isEmpty, submitting: model.submitting)
    }

    func focus(_ field: NewQuestField) {
        guard !model.submitting else {
            return
        }
        model.focusedField = field
    }

    func handle(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers?.lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        if event.keyCode == 53 {
            dismiss()
            return true
        }
        if event.modifierFlags.contains(.command) {
            return false
        }
        if model.submitting {
            return true
        }
        if option, Keymap.NewSession.nextFieldOption.matches(event.keyCode) {
            model.moveFocus(1)
            return true
        }
        if control, Keymap.NewSession.nextField.matches(chars) {
            model.moveFocus(1)
            return true
        }
        if control, Keymap.NewSession.previousField.matches(chars) {
            model.moveFocus(-1)
            return true
        }
        if control, Keymap.NewSession.createFromPrompt.matches(chars), model.focusedField == .content {
            submit()
            return true
        }
        if model.focusedField == .project {
            if Keymap.NewSession.selectLeft.matches(event.keyCode) || Keymap.NewSession.selectLeftCharacter.matches(chars) {
                model.cycleProject(-1)
                return true
            }
            if Keymap.NewSession.selectRight.matches(event.keyCode) || Keymap.NewSession.selectRightCharacter.matches(chars) {
                model.cycleProject(1)
                return true
            }
        }
        return false
    }

    func submit() {
        guard !model.submitting, let payload = model.submitPayload() else {
            return
        }
        model.submitting = true
        do {
            let request = try mutationRequest(for: payload)
            mutationClient.send(request) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    switch result {
                    case .success:
                        self.onSuccess()
                        self.dismiss()
                    case .failure(let error):
                        self.model.submitting = false
                        self.model.errorMessage = error.localizedDescription
                    }
                }
            }
        } catch {
            model.submitting = false
            model.errorMessage = error.localizedDescription
        }
    }

    private func mutationRequest(for payload: NewQuestSubmitPayload) throws -> ServeMutationRequest {
        if questID.isEmpty {
            return try ServeMutationRequests.questAdd(payload, sessionID: sessionID)
        }
        return try ServeMutationRequests.questEdit(questID: questID, payload: payload)
    }
}

enum NewQuestSheetFooterText {
    static func text(isEditing: Bool, submitting: Bool) -> String {
        if submitting {
            return isEditing ? "Saving…" : "Creating…"
        }
        let action = isEditing ? "save" : "create"
        return "↵ \(action) · ⇧↵ newline · ^s \(action) · ^j ^k field · h/l select · esc cancel"
    }
}

private struct NewQuestKeyEventMonitor: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        MonitorView(onKeyDown: onKeyDown)
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onKeyDown = onKeyDown
    }

    final class MonitorView: NSView {
        var onKeyDown: (NSEvent) -> Bool
        private var eventMonitor: Any?

        init(onKeyDown: @escaping (NSEvent) -> Bool) {
            self.onKeyDown = onKeyDown
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else {
                    return event
                }
                return self.onKeyDown(event) ? nil : event
            }
        }
    }
}
