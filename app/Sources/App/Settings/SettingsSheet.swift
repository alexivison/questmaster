import AppKit
import QuestmasterCore
import SwiftUI

@MainActor
final class SettingsSheetPresenter: ObservableObject {
    @Published var presentation: SettingsSheetPresentation?

    func present(
        mutationClient: ServeMutationSending,
        modelClient: ServeModelSuggesting?,
        effortClient: ServeReasoningEffortSuggesting?
    ) {
        presentation = SettingsSheetPresentation(
            mutationClient: mutationClient,
            modelClient: modelClient,
            effortClient: effortClient
        )
    }

    func dismiss() {
        presentation = nil
    }
}

struct SettingsSheetPresentation: Identifiable {
    let id = UUID()
    let mutationClient: ServeMutationSending
    let modelClient: ServeModelSuggesting?
    let effortClient: ServeReasoningEffortSuggesting?
}

struct SettingsSheetView: View {
    @StateObject private var model: SettingsSheetModel

    private enum Metrics {
        static let labelWidth: CGFloat = 170
        static let selectWidth: CGFloat = 280
        static let horizontalInset: CGFloat = 32
    }

    init(presentation: SettingsSheetPresentation, dismiss: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SettingsSheetModel(presentation: presentation, dismiss: dismiss))
    }

    var body: some View {
        ModalSheetScaffold(
            title: "Settings",
            footerText: "←→ select model · e effort · ⌥j/⌥k row · esc cancel · ⏎ done",
            errorMessage: model.errorMessage,
            cancelLabel: "Cancel",
            onCancel: { model.cancel() },
            primaryLabel: "Done",
            onPrimary: { model.confirm() }
        ) {
            ScrollView {
                VStack(spacing: Token.Spacing.element) {
                    ForEach(Array(model.state.rows.enumerated()), id: \.offset) { index, row in
                        roleDefaultRow(index: index, row: row)
                    }
                }
                .padding(.vertical, Token.Spacing.element)
            }
        }
        .frame(width: SettingsSheetModel.sheetSize.width, height: SettingsSheetModel.sheetSize.height)
        .background(AppPalette.panel.swiftUI)
        .background(SheetKeyEventMonitor { model.handle($0) })
        .onAppear { model.present() }
        .onDisappear { model.disappear() }
    }

    private func roleDefaultRow(index: Int, row: RoleDefaultRow) -> some View {
        ModalSelectRow(
            label: Self.rowLabel(row),
            labelWidth: Metrics.labelWidth,
            title: row.selectedModelOption.label,
            note: row.selectedModelOption.note,
            swatchColor: nil,
            focused: model.state.focusedRowIndex == index,
            disabled: false,
            controlWidth: Metrics.selectWidth,
            horizontalInset: Metrics.horizontalInset,
            onSelect: { model.focus(index) },
            subtext: { AnyView(effortSubtext(for: row)) }
        )
    }

    private func effortSubtext(for row: RoleDefaultRow) -> some View {
        Text(row.selectedEffortOption.label)
            .font(AppFonts.modalHelper.swiftUI)
            .italic()
            .foregroundStyle(AppPalette.dim.swiftUI)
            .lineLimit(1)
            .padding(.leading, Token.Radius.control + 3)
    }

    private static func rowLabel(_ row: RoleDefaultRow) -> String {
        let role = row.role.prefix(1).uppercased() + row.role.dropFirst()
        return "\(AgentKind.displayName(for: row.agent)) \(role)"
    }
}

@MainActor
final class SettingsSheetModel: ObservableObject {
    static let sheetSize = CGSize(width: 900, height: 780)

    @Published var state = RoleDefaultsSettingsModel()
    @Published var errorMessage: String?

    private let mutationClient: ServeMutationSending
    private let modelClient: ServeModelSuggesting?
    private let effortClient: ServeReasoningEffortSuggesting?
    private let dismiss: () -> Void

    /// Guards each row's in-flight suggestion fetches independently, so a
    /// response for a model the user has since cycled away from can't
    /// clobber a newer one — mirrors NewSessionSheetModel's request-ID guard.
    private var modelRequestIDs: [Int]
    private var effortRequestIDs: [Int]

    init(presentation: SettingsSheetPresentation, dismiss: @escaping () -> Void) {
        mutationClient = presentation.mutationClient
        modelClient = presentation.modelClient
        effortClient = presentation.effortClient
        self.dismiss = dismiss
        let rowCount = RoleDefaultsSettingsModel.agents.count * RoleDefaultsSettingsModel.roles.count
        modelRequestIDs = Array(repeating: 0, count: rowCount)
        effortRequestIDs = Array(repeating: 0, count: rowCount)
    }

    func present() {
        for index in state.rows.indices {
            requestModelSuggestions(rowIndex: index)
            requestEffortSuggestions(rowIndex: index)
        }
    }

    /// Invalidates any in-flight suggestion fetches so a response arriving
    /// after the sheet closes cannot mutate state nobody will ever see.
    func disappear() {
        for index in modelRequestIDs.indices {
            modelRequestIDs[index] += 1
        }
        for index in effortRequestIDs.indices {
            effortRequestIDs[index] += 1
        }
    }

    func focus(_ index: Int) {
        state.focusedRowIndex = index
    }

    func handle(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers?.lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        if Keymap.NewSession.cancel.matches(event.keyCode) {
            cancel()
            return true
        }
        if Keymap.NewSession.create.matches(chars) {
            confirm()
            return true
        }
        if event.modifierFlags.contains(.command) {
            return false
        }
        if option, Keymap.NewSession.nextFieldOption.matches(event.keyCode) {
            state.moveFocus(1)
            return true
        }
        if control, Keymap.NewSession.nextField.matches(chars) {
            state.moveFocus(1)
            return true
        }
        if control, Keymap.NewSession.previousField.matches(chars) {
            state.moveFocus(-1)
            return true
        }
        if Keymap.NewSession.selectLeft.matches(event.keyCode) || Keymap.NewSession.selectLeftCharacter.matches(chars) {
            cycleModel(-1)
            return true
        }
        if Keymap.NewSession.selectRight.matches(event.keyCode) || Keymap.NewSession.selectRightCharacter.matches(chars) {
            cycleModel(1)
            return true
        }
        if Keymap.NewSession.cycleReasoningEffort.matches(chars) {
            cycleEffort()
            return true
        }
        return false
    }

    /// Discards every change made in this sheet session — nothing selected
    /// since the sheet opened is persisted.
    func cancel() {
        disappear()
        dismiss()
    }

    /// Persists every row's current selection, then closes.
    func confirm() {
        for row in state.rows {
            sendRoleDefault(agent: row.agent, role: row.role, model: row.selectedModel, reasoningEffort: row.selectedReasoningEffort)
        }
        disappear()
        dismiss()
    }

    private func cycleModel(_ delta: Int) {
        let rowIndex = state.focusedRowIndex
        state.cycleFocusedModel(delta)
        requestEffortSuggestions(rowIndex: rowIndex)
    }

    private func cycleEffort() {
        state.cycleFocusedEffort(1)
    }

    private func requestModelSuggestions(rowIndex: Int) {
        guard let modelClient, state.rows.indices.contains(rowIndex) else {
            return
        }
        modelRequestIDs[rowIndex] += 1
        let requestID = modelRequestIDs[rowIndex]
        let row = state.rows[rowIndex]
        modelClient.suggestModels(agent: row.agent, role: row.role, refresh: false) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.modelRequestIDs[rowIndex] == requestID else {
                    return
                }
                if case .success(let response) = result {
                    self.state.setModelOptions(response.models, defaultModel: response.defaultModel, agent: row.agent, role: row.role)
                }
            }
        }
    }

    private func requestEffortSuggestions(rowIndex: Int) {
        guard let effortClient, state.rows.indices.contains(rowIndex) else {
            return
        }
        effortRequestIDs[rowIndex] += 1
        let requestID = effortRequestIDs[rowIndex]
        let row = state.rows[rowIndex]
        let model = row.selectedModel
        effortClient.suggestReasoningEfforts(agent: row.agent, role: row.role, model: model) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.effortRequestIDs[rowIndex] == requestID else {
                    return
                }
                if case .success(let response) = result {
                    self.state.setEffortOptions(response.efforts, defaultLevel: response.defaultEffort, agent: row.agent, role: row.role)
                }
            }
        }
    }

    private func sendRoleDefault(agent: String, role: String, model: String, reasoningEffort: String) {
        do {
            let request = try ServeMutationRequests.setRoleDefault(agent: agent, role: role, model: model, reasoningEffort: reasoningEffort)
            mutationClient.send(request) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    if case .failure(let error) = result {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
