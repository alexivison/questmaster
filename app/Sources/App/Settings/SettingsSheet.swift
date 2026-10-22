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

/// settings-models.svg (900 x 780): the sections as pill tabs down the left (250 wide), and the selected
/// section on the right (x 290-880): the agent tabs, then a "Master" and a "Worker" section, each a bold
/// title over a vine-ended rule and two rows of label, description and a compact "‹ value ›" picker.
private enum SettingsMetrics {
    static let inset = Space.section
    static let sidebarWidth: CGFloat = 250
    static let columnSpacing = Space.section
    static let columnWidth = SettingsSheetModel.sheetSize.width - 2 * inset - sidebarWidth - columnSpacing
    static let sidebarSpacing = Space.section
    /// From the top of the agent tabs: the first section title's baseline, then each next one 175 on.
    static let firstSectionBaseline: CGFloat = 65
    static let sectionPitch: CGFloat = 175
    /// From a section title's baseline: its rule, then each row's picker top, 55 apart (a field and the 20 between).
    static let ruleDrop: CGFloat = 15
    static let firstRowDrop: CGFloat = 35
    static let rowPitch = pickerHeight + Space.section
    /// From a row's picker top: the label's baseline and the description's.
    static let labelBaseline: CGFloat = 11
    static let descriptionBaseline: CGFloat = 29
    /// The picker is a field: 35 high in the shared field chrome, "‹", the value and "›" 10 apart and 10 in, the text
    /// on the field's baseline.
    static let pickerHeight = ControlHeight.field
    static let pickerInset = Space.item
    static let pickerSpacing = Space.item
    static let pickerBaseline = FormFieldMetrics.baseline
    static let skeletonWidth: CGFloat = 90
}

/// The sidebar's sections. Only the ones that exist are listed; a new one is a new case.
private enum SettingsSection: CaseIterable {
    case modelsAndReasoning

    var title: String {
        switch self {
        case .modelsAndReasoning:
            return "Models and Reasoning"
        }
    }

    var symbolName: String {
        switch self {
        case .modelsAndReasoning:
            return "slider.vertical.3"
        }
    }
}

struct SettingsSheetView: View {
    @StateObject private var model: SettingsSheetModel

    /// Role groups shown for the active tab, top-to-bottom, with each row's description.
    private static let roleGroups = [("master", "Master"), ("worker", "Worker")]

    init(presentation: SettingsSheetPresentation, dismiss: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SettingsSheetModel(presentation: presentation, dismiss: dismiss))
    }

    var body: some View {
        ModalSheetScaffold(
            title: "Settings",
            errorMessage: model.errorMessage
        ) {
            HStack(alignment: .top, spacing: SettingsMetrics.columnSpacing) {
                sidebar
                sectionColumn
            }
            .padding(.horizontal, SettingsMetrics.inset)
            // Greedy on height so this area absorbs the sheet's fixed 900 x 780 footprint and the
            // content stays pinned to the top.
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: SettingsSheetModel.sheetSize.width, height: SettingsSheetModel.sheetSize.height)
        .scoopedPanel()
        .background(SheetKeyEventMonitor { model.handle($0) })
        .onAppear { model.present() }
        .onDisappear { model.disappear() }
    }

    private var sidebar: some View {
        VStack(spacing: SettingsMetrics.sidebarSpacing) {
            ForEach(SettingsSection.allCases, id: \.self) { section in
                PillTab(
                    title: section.title,
                    icon: AppSymbolStyle.image(name: section.symbolName, pointSize: 14, weight: .regular, color: OutlineLook.tabSelected.label.color, canvasSize: NSSize(width: PillTabMetrics.iconSide, height: PillTabMetrics.iconSide)),
                    look: .tabSelected,
                    selected: true,
                    help: "\(section.title) settings",
                    accessibilityLabel: "Settings section \(section.title)"
                )
            }
        }
        .frame(width: SettingsMetrics.sidebarWidth)
    }

    private var sectionColumn: some View {
        ZStack(alignment: .topLeading) {
            PillTabRow(
                tabs: model.state.agents.map { .agent($0) },
                selectedID: model.state.selectedAgent,
                // The sheet's tab keys drive these tabs, so they always have keyboard focus.
                focused: true,
                onSelect: { agent in
                    if let index = model.state.agents.firstIndex(of: agent) {
                        model.selectTab(index)
                    }
                }
            )
            ForEach(Array(Self.roleGroups.enumerated()), id: \.offset) { offset, group in
                roleSection(role: group.0, title: group.1)
                    .offset(y: SettingsMetrics.firstSectionBaseline + CGFloat(offset) * SettingsMetrics.sectionPitch)
            }
        }
        .frame(width: SettingsMetrics.columnWidth, alignment: .topLeading)
    }

    /// Laid out from the title's baseline, which sits at the section's top.
    @ViewBuilder
    private func roleSection(role: String, title: String) -> some View {
        if let rowIndex = model.state.index(agent: model.state.selectedAgent, role: role) {
            let row = model.state.rows[rowIndex]
            let isFocusedRole = RoleDefaultsSettingsModel.roles[model.state.focusedRoleIndex] == role
            ZStack(alignment: .topLeading) {
                BaselineText(title, font: AppFonts.settingsSectionTitle, color: AppPalette.settingsText, baseline: 0)
                SettingsSectionRule(width: SettingsMetrics.columnWidth)
                    .offset(y: SettingsMetrics.ruleDrop)
                SettingsRoleRow(
                    title: "Model",
                    description: "The default \(role) model",
                    value: row.selectedModelOption?.label ?? "Not configured",
                    isLoading: !row.hasResolvedModelOptions,
                    focused: isFocusedRole && model.state.focusedField == .model,
                    onSelect: { model.focus(role: role, field: .model) }
                )
                .offset(y: SettingsMetrics.firstRowDrop)
                SettingsRoleRow(
                    title: "Reasoning effort",
                    description: "The default \(role) reasoning effort",
                    value: row.selectedEffortOption?.label ?? "Not configured",
                    isLoading: !row.hasResolvedEffortOptions,
                    focused: isFocusedRole && model.state.focusedField == .effort,
                    onSelect: { model.focus(role: role, field: .effort) }
                )
                .offset(y: SettingsMetrics.firstRowDrop + SettingsMetrics.rowPitch)
            }
            .frame(width: SettingsMetrics.columnWidth, alignment: .topLeading)
        }
    }
}

/// The rule under a section title: a 1pt line with the Quest Log's rule vines at each end. `QuestLogArt`
/// draws them about its rule at y 206 from x 20; here they hang off a line at the frame's top.
private struct SettingsSectionRule: View {
    let width: CGFloat

    private static let artRuleY: CGFloat = 206
    private static let artVineLeft: CGFloat = 20
    private static let artVineRight: CGFloat = 453
    /// The vine art stands 8 above the line and 9 below it; the line runs 4 in from each end, into the vines.
    private static let bandAbove: CGFloat = 8
    private static let artBandHeight: CGFloat = 17
    private static let artLineInset: CGFloat = 4

    var body: some View {
        Canvas { context, _ in
            let color = GraphicsContext.Shading.color(AppPalette.line.swiftUI)
            let dy = Self.bandAbove - Self.artRuleY
            let pieces = QuestLogArt.ruleVineLeft.map { (SVGPath.parse($0.d, dx: -Self.artVineLeft, dy: dy), $0.evenOdd) }
                + QuestLogArt.ruleVineRight.map { (SVGPath.parse($0.d, dx: width - Self.artVineRight, dy: dy), $0.evenOdd) }
            for (path, evenOdd) in pieces {
                context.fill(path, with: color, style: FillStyle(eoFill: evenOdd))
            }
            context.fill(Path(CGRect(x: Self.artLineInset, y: Self.bandAbove, width: width - 2 * Self.artLineInset, height: Token.Size.divider)), with: color)
        }
        .frame(width: width, height: Self.artBandHeight)
        .offset(y: -Self.bandAbove)
    }
}

/// A setting: its label and description on the left, its compact picker right-aligned. Laid out from
/// the picker's top.
private struct SettingsRoleRow: View {
    let title: String
    let description: String
    let value: String
    let isLoading: Bool
    let focused: Bool
    var onSelect: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            BaselineText(title, font: AppFonts.settingsLabel, color: AppPalette.settingsText, baseline: SettingsMetrics.labelBaseline)
            BaselineText(description, font: AppFonts.settingsDescription, color: AppPalette.settingsDescription, baseline: SettingsMetrics.descriptionBaseline)
            picker
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: SettingsMetrics.columnWidth, height: SettingsMetrics.pickerHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private var picker: some View {
        if isLoading {
            SettingsSkeletonControl()
                .frame(width: SettingsMetrics.skeletonWidth, height: SettingsMetrics.pickerHeight)
        } else {
            HStack(spacing: SettingsMetrics.pickerSpacing) {
                BaselineText("<", font: AppFonts.settingsLabel, color: AppPalette.textMeta, baseline: SettingsMetrics.pickerBaseline)
                BaselineText(value, font: AppFonts.settingsLabel, color: AppPalette.textBody, baseline: SettingsMetrics.pickerBaseline)
                BaselineText(">", font: AppFonts.settingsLabel, color: AppPalette.textMeta, baseline: SettingsMetrics.pickerBaseline)
            }
            .padding(.horizontal, SettingsMetrics.pickerInset)
            .frame(height: SettingsMetrics.pickerHeight)
            .fieldChrome(focused: focused)
            .fixedSize()
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .accessibilityLabel("\(title) \(value)")
        }
    }
}

/// Pulsing placeholder shown in place of a select control until its options
/// resolve — same visual language as `TerminalAttachSkeleton`/the tracker's
/// skeleton, sized to one control instead of a whole pane.
private struct SettingsSkeletonControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: FormFieldMetrics.cornerRadius)
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
            close()
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

    /// Closes the sheet. Every change already applies the moment it's made,
    /// so there's no separate commit/discard step left — closing never waits
    /// on an in-flight save. A save that fails after the sheet is gone has
    /// nowhere left to show its error; that's an accepted tradeoff of
    /// applying live instead of batching behind a confirm step.
    func close() {
        disappear()
        dismiss()
    }

    /// Cycles whichever field currently has focus and, if that actually
    /// changed the row's value, sends it immediately. Changing the model
    /// invalidates the effort list (valid levels can depend on the model), so
    /// only that case re-fetches; cycling the effort itself needs no refetch.
    private func cycleFocusedValue(_ delta: Int) {
        guard let rowIndex = state.focusedRowIndex else {
            return
        }
        let field = state.focusedField
        let previousRow = state.rows[rowIndex]
        state.cycleFocusedValue(delta)
        if field == .model {
            requestEffortSuggestions(rowIndex: rowIndex)
        }
        let row = state.rows[rowIndex]
        // Guards against sending both fields empty (which the backend
        // rejects) when a cycle press lands before this row's options have
        // resolved and produces no real change.
        guard row.selectedModel != previousRow.selectedModel || row.selectedReasoningEffort != previousRow.selectedReasoningEffort else {
            return
        }
        errorMessage = nil
        sendRoleDefault(agent: row.agent, role: row.role, model: row.selectedModel, reasoningEffort: row.selectedReasoningEffort)
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
                    self.state.setModelOptions(
                        response.models,
                        defaultModel: response.defaultModel,
                        agent: row.agent,
                        role: row.role
                    )
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
                    self.state.setEffortOptions(
                        response.efforts,
                        defaultLevel: response.defaultEffort,
                        agent: row.agent,
                        role: row.role
                    )
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
                    switch result {
                    case .success(let ack):
                        let persisted = ack.data as? [String: Any]
                        self.state.markSaved(
                            agent: agent,
                            role: role,
                            model: persisted?["model"] as? String ?? model,
                            reasoningEffort: persisted?["reasoning_effort"] as? String ?? reasoningEffort,
                            sentModel: model,
                            sentReasoningEffort: reasoningEffort
                        )
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
