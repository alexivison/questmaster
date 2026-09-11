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

    /// Role groups shown for the active tab, top-to-bottom.
    private static let roleGroups = [("master", "Master"), ("worker", "Worker")]

    private enum Metrics {
        static let sidebarWidth: CGFloat = 224
        static let controlWidth: CGFloat = 280
    }

    init(presentation: SettingsSheetPresentation, dismiss: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SettingsSheetModel(presentation: presentation, dismiss: dismiss))
    }

    var body: some View {
        ModalSheetScaffold(
            title: "Settings",
            footerText: "[ ] tab · ←→/hl change value · ⌃j/⌃k move · esc cancel · ⏎ done",
            errorMessage: model.errorMessage,
            cancelLabel: "Cancel",
            onCancel: { model.cancel() },
            primaryLabel: "Done",
            onPrimary: { model.confirm() }
        ) {
            HStack(alignment: .top, spacing: Token.Spacing.section) {
                sidebar
                VStack(alignment: .leading, spacing: Token.Spacing.section) {
                    tabBar
                    ForEach(Array(Self.roleGroups.enumerated()), id: \.offset) { offset, group in
                        roleFieldGroup(role: group.0, title: group.1)
                        if offset < Self.roleGroups.count - 1 {
                            SettingsSeparator()
                        }
                    }
                }
                .padding(.top, Token.Spacing.element)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Token.Spacing.content)
        }
        .frame(width: SettingsSheetModel.sheetSize.width, height: SettingsSheetModel.sheetSize.height, alignment: .top)
        .background(AppPalette.panel.swiftUI)
        .background(SheetKeyEventMonitor { model.handle($0) })
        .onAppear { model.present() }
        .onDisappear { model.disappear() }
    }

    private var sidebar: some View {
        VStack(spacing: Token.Spacing.element) {
            SettingsSidebarItem(title: "Models and Reasoning", symbolName: "slider.horizontal.3", selected: true)
        }
        .padding(.top, Token.Spacing.element)
        .frame(width: Metrics.sidebarWidth, alignment: .top)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.state.agents.enumerated()), id: \.offset) { index, agent in
                SettingsAgentTab(
                    title: AgentKind.displayName(for: agent),
                    selected: index == model.state.selectedAgentIndex,
                    onSelect: { model.selectTab(index) }
                )
            }
        }
    }

    @ViewBuilder
    private func roleFieldGroup(role: String, title: String) -> some View {
        if let rowIndex = model.state.index(agent: model.state.selectedAgent, role: role) {
            let row = model.state.rows[rowIndex]
            let isFocusedRole = RoleDefaultsSettingsModel.roles[model.state.focusedRoleIndex] == role
            VStack(alignment: .leading, spacing: Token.Spacing.element) {
                Text(title)
                    .font(AppFonts.bodyBold.swiftUI)
                    .foregroundStyle(AppPalette.text.swiftUI)
                SettingsFormFieldRow(
                    title: "Model",
                    subtitle: "The default \(role) model and reasoning effort",
                    value: row.selectedModelOption.label,
                    isLoading: !row.hasResolvedModelOptions,
                    focused: isFocusedRole && model.state.focusedField == .model,
                    controlWidth: Metrics.controlWidth,
                    onSelect: { model.focus(role: role, field: .model) }
                )
                SettingsFormFieldRow(
                    title: "Reasoning effort",
                    subtitle: "The default \(role) model and reasoning effort",
                    value: row.selectedEffortOption.label,
                    isLoading: !row.hasResolvedEffortOptions,
                    focused: isFocusedRole && model.state.focusedField == .effort,
                    controlWidth: Metrics.controlWidth,
                    onSelect: { model.focus(role: role, field: .effort) }
                )
            }
        }
    }
}

/// A sidebar section entry, styled as the same riveted `ItemCardShape` card
/// every Tracker/Quest/Artifact row uses — `cornerOrnament: nil` gives it the
/// plain corner-bolt dots a Tracker worker row shows (master/standalone rows
/// are the ones that swap those dots for a fancier ornament image).
private struct SettingsSidebarItem: View {
    let title: String
    let symbolName: String
    let selected: Bool

    var body: some View {
        ListRow(
            selected: selected,
            background: { selected, hovered in
                ItemCardShape(selected: selected, hovered: hovered)
            },
            content: {
                // Same content insets every Tracker/Quest/Artifact row uses,
                // so this card reads at the same scale as the ones it's
                // styled after instead of a cramped custom pill. A plain SF
                // Symbol (unlike those rows' agent-mark badges) sits right at
                // the icon column's edge, so this row adds extra clearance on
                // top of the shared insets to keep it off the corner bolts.
                HStack(spacing: ItemCardShape.iconLabelGap) {
                    Image(systemName: symbolName)
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(AppFonts.itemTitle.swiftUI)
                .foregroundStyle((selected ? AppPalette.bright : AppPalette.text).swiftUI)
                .padding(.leading, ItemCardShape.contentPadding + Token.Spacing.element)
                .padding(.trailing, ItemCardShape.trailingContentPadding + Token.Spacing.element)
                .padding(.vertical, ItemCardShape.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
    }
}

/// One agent tab: gold text + underline when selected, dim otherwise —
/// `[`/`]` (`Keymap.Settings.previousTab`/`.nextTab`) move between these,
/// a click jumps straight to one.
private struct SettingsAgentTab: View {
    let title: String
    let selected: Bool
    var onSelect: () -> Void

    var body: some View {
        VStack(spacing: Token.Spacing.hairline) {
            Text(title)
                .font(AppFonts.bodyBold.swiftUI)
                .foregroundStyle((selected ? AppPalette.accent : AppPalette.dim).swiftUI)
            Rectangle()
                .fill((selected ? AppPalette.accent : AppPalette.lineSoftSubtle).swiftUI)
                .frame(height: Token.Size.divider)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

private struct SettingsSeparator: View {
    var body: some View {
        Rectangle()
            .fill(AppPalette.lineSoftSubtle.swiftUI)
            .frame(height: Token.Size.divider)
    }
}

/// One labeled select field: a title + description on the left, a
/// `ModalSelectControl` on the right, docked to the row's trailing edge.
private struct SettingsFormFieldRow: View {
    let title: String
    let subtitle: String
    let value: String
    let isLoading: Bool
    let focused: Bool
    let controlWidth: CGFloat
    var onSelect: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Token.Spacing.content) {
            VStack(alignment: .leading, spacing: Token.Spacing.hairline) {
                Text(title)
                    .font(AppFonts.modalHelperLarge.swiftUI)
                    .foregroundStyle(AppPalette.text.swiftUI)
                Text(subtitle)
                    .font(AppFonts.modalHelper.swiftUI)
                    .italic()
                    .foregroundStyle(AppPalette.dim.swiftUI)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isLoading {
                SettingsSkeletonControl()
                    .frame(width: controlWidth, height: 36)
            } else {
                ModalSelectControl(title: value, swatchColor: nil, focused: focused, disabled: false)
                    .frame(width: controlWidth, height: 36)
                    .onTapGesture(perform: onSelect)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Pulsing placeholder shown in place of a select control until its options
/// resolve — same visual language as `TerminalAttachSkeleton`/the tracker's
/// skeleton, sized to one control instead of a whole pane.
private struct SettingsSkeletonControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: Token.Radius.control)
            .fill(AppPalette.item.swiftUI)
            .opacity(pulse ? 0.7 : 0.5)
            .onAppear {
                guard !reduceMotion else {
                    pulse = true
                    return
                }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .onDisappear {
                pulse = false
            }
    }
}

@MainActor
final class SettingsSheetModel: ObservableObject {
    /// Deliberately taller than the tab redesign's own content — the sheet
    /// keeps its original footprint, with content anchored to the top
    /// (`alignment: .top` on the frame below) rather than shrinking or
    /// centering in the leftover space.
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
        let rowCount = RoleDefaultsSettingsModel.defaultAgents.count * RoleDefaultsSettingsModel.roles.count
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

    func focus(role: String, field: RoleDefaultField) {
        guard let roleIndex = RoleDefaultsSettingsModel.roles.firstIndex(of: role) else {
            return
        }
        state.focusedRoleIndex = roleIndex
        state.focusedField = field
    }

    func selectTab(_ index: Int) {
        state.selectTab(index)
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
            cycleFocusedValue(-1)
            return true
        }
        if Keymap.NewSession.selectRight.matches(event.keyCode) || Keymap.NewSession.selectRightCharacter.matches(chars) {
            cycleFocusedValue(1)
            return true
        }
        if Keymap.Settings.previousTab.matches(chars) {
            state.moveTab(-1)
            return true
        }
        if Keymap.Settings.nextTab.matches(chars) {
            state.moveTab(1)
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

    /// Cycles whichever field currently has focus. Changing the model
    /// invalidates the effort list (valid levels can depend on the model), so
    /// only that case re-fetches; cycling the effort itself needs no refetch.
    private func cycleFocusedValue(_ delta: Int) {
        guard let rowIndex = state.focusedRowIndex else {
            return
        }
        let field = state.focusedField
        state.cycleFocusedValue(delta)
        if field == .model {
            requestEffortSuggestions(rowIndex: rowIndex)
        }
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
